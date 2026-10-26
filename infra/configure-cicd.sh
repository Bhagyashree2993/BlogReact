#!/usr/bin/env bash
# =====================================================================
#  Configures Nexus, SonarQube and Jenkins on the CI/CD server end-to-end
#  and starts the first pipeline build. Run ON the server, after
#  infra/setup-cicd-server.sh has finished:
#
#     cd /opt/BlogReact && sudo git pull
#     sudo bash infra/configure-cicd.sh
#
#  It asks for the AWS access key Jenkins should use (the blogapp-admin
#  user that created the EKS cluster). Everything else is generated.
#  Safe to re-run: existing repos/tokens/webhooks are reused or replaced.
#  All logins are written to /root/blogapp-credentials.txt
# =====================================================================
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "Run with sudo"; exit 1; }
for t in aws kubectl docker trivy node java; do
  command -v $t >/dev/null || { echo "'$t' is missing - run: sudo bash infra/setup-cicd-server.sh"; exit 1; }
done
id jenkins >/dev/null 2>&1 || { echo "Jenkins is not installed - run: sudo bash infra/setup-cicd-server.sh"; exit 1; }

REPO_URL=${REPO_URL:-$(git -C "$(dirname "$0")/.." remote get-url origin 2>/dev/null || echo https://github.com/Bhagyashree2993/BlogReact.git)}
CRED_FILE=/root/blogapp-credentials.txt
PRIVATE_IP=$(hostname -I | awk '{print $1}')
PUBLIC_IP=$(curl -s --max-time 5 http://checkip.amazonaws.com || echo "$PRIVATE_IP")
JENKINS_HOME=/var/lib/jenkins
SCANNER_VERSION=6.2.1.4610
PLUGIN_MANAGER_VERSION=2.13.2

log() { printf '\n\033[1;32m>> %s\033[0m\n' "$*"; }
wait_for() {   # wait_for <name> <url> <expected-substring>
  log "Waiting for $1"
  for _ in $(seq 1 90); do
    if curl -fsS --max-time 5 "$2" 2>/dev/null | grep -q "$3"; then echo "   $1 is up"; return 0; fi
    sleep 10
  done
  echo "$1 did not come up at $2"; exit 1
}
rand() { openssl rand -hex "$1"; }

# ---------- reuse secrets on re-run, otherwise generate ----------
if [ -f "$CRED_FILE" ]; then
  # shellcheck disable=SC1090
  . "$CRED_FILE"
fi
ADMIN_PASSWORD=${ADMIN_PASSWORD:-"Blog-$(rand 6)-A1"}       # letters, digits, dash: meets SonarQube rules
MYSQL_ROOT_PASSWORD=${MYSQL_ROOT_PASSWORD:-$(rand 16)}
MYSQL_APP_PASSWORD=${MYSQL_APP_PASSWORD:-$(rand 16)}
JWT_SECRET=${JWT_SECRET:-$(rand 32)}

if [ -z "${AWS_ACCESS_KEY_ID:-}" ] || [ -z "${AWS_SECRET_ACCESS_KEY:-}" ]; then
  echo "Jenkins needs the AWS access key of the user that created the EKS cluster (blogapp-admin)."
  read -rp  "AWS Access Key ID     : " AWS_ACCESS_KEY_ID
  read -rsp "AWS Secret Access Key : " AWS_SECRET_ACCESS_KEY; echo
fi
AWS_ACCESS_KEY_ID=$(echo "$AWS_ACCESS_KEY_ID" | tr -d '[:space:]')
AWS_SECRET_ACCESS_KEY=$(echo "$AWS_SECRET_ACCESS_KEY" | tr -d '[:space:]')
log "Checking the AWS key"
AWS_ACCESS_KEY_ID=$AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY=$AWS_SECRET_ACCESS_KEY \
  aws sts get-caller-identity --region ap-south-1 --query Arn --output text

umask 077
cat > "$CRED_FILE" <<EOF
ADMIN_PASSWORD='$ADMIN_PASSWORD'
MYSQL_ROOT_PASSWORD='$MYSQL_ROOT_PASSWORD'
MYSQL_APP_PASSWORD='$MYSQL_APP_PASSWORD'
JWT_SECRET='$JWT_SECRET'
AWS_ACCESS_KEY_ID='$AWS_ACCESS_KEY_ID'
AWS_SECRET_ACCESS_KEY='$AWS_SECRET_ACCESS_KEY'
EOF
umask 022

# =====================================================================
#  NEXUS
# =====================================================================
wait_for Nexus http://localhost:8081/service/rest/v1/status/writable ""
sleep 5
NX=http://localhost:8081/service/rest
if docker exec nexus test -f /nexus-data/admin.password 2>/dev/null; then
  log "Nexus: setting admin password"
  INITIAL=$(docker exec nexus cat /nexus-data/admin.password)
  curl -fsS -u "admin:$INITIAL" -X PUT -H 'Content-Type: text/plain' \
       --data "$ADMIN_PASSWORD" "$NX/v1/security/users/admin/change-password"
  curl -fsS -u "admin:$ADMIN_PASSWORD" -X PUT -H 'Content-Type: application/json' \
       --data '{"enabled": false}' "$NX/v1/security/anonymous" >/dev/null || true
fi
NXA=(-fsS -u "admin:$ADMIN_PASSWORD" -H 'Content-Type: application/json')

# Newer Nexus Community Edition releases require the EULA to be accepted before use
EULA=$(curl "${NXA[@]}" "$NX/v1/system/eula" 2>/dev/null || true)
if echo "$EULA" | grep -q '"accepted" *: *false'; then
  log "Nexus: accepting Community Edition EULA"
  echo "$EULA" | python3 -c 'import json,sys; d=json.load(sys.stdin); d["accepted"]=True; print(json.dumps(d))' \
    | curl "${NXA[@]}" -X POST --data @- "$NX/v1/system/eula" || true
fi

log "Nexus: enabling Docker Bearer Token realm"
REALMS=$(curl "${NXA[@]}" "$NX/v1/security/realms/active")
if ! echo "$REALMS" | grep -q DockerToken; then
  NEW=$(echo "$REALMS" | python3 -c 'import json,sys; r=json.load(sys.stdin); r.append("DockerToken"); print(json.dumps(r))')
  curl "${NXA[@]}" -X PUT --data "$NEW" "$NX/v1/security/realms/active"
fi

log "Nexus: repositories blogapp-artifacts (raw) and blogapp-docker (:8083)"
curl "${NXA[@]}" -X POST "$NX/v1/repositories/raw/hosted" --data '{
  "name":"blogapp-artifacts","online":true,
  "storage":{"blobStoreName":"default","strictContentTypeValidation":false,"writePolicy":"allow"}}' \
  2>/dev/null || echo "   blogapp-artifacts already exists"
curl "${NXA[@]}" -X POST "$NX/v1/repositories/docker/hosted" --data '{
  "name":"blogapp-docker","online":true,
  "storage":{"blobStoreName":"default","strictContentTypeValidation":true,"writePolicy":"allow"},
  "docker":{"v1Enabled":false,"forceBasicAuth":true,"httpPort":8083}}' \
  2>/dev/null || echo "   blogapp-docker already exists"

# =====================================================================
#  SONARQUBE
# =====================================================================
wait_for SonarQube http://localhost:9000/api/system/status '"status":"UP"'
SQ=http://localhost:9000/api
if curl -fsS -u admin:admin "$SQ/authentication/validate" | grep -q '"valid":true'; then
  log "SonarQube: setting admin password"
  curl -fsS -u admin:admin -X POST "$SQ/users/change_password" \
       --data-urlencode login=admin --data-urlencode previousPassword=admin \
       --data-urlencode "password=$ADMIN_PASSWORD"
fi
SQA=(-fsS -u "admin:$ADMIN_PASSWORD")

log "SonarQube: analysis token for Jenkins"
curl "${SQA[@]}" -X POST "$SQ/user_tokens/revoke" --data name=jenkins >/dev/null 2>&1 || true
SONAR_TOKEN=$(curl "${SQA[@]}" -X POST "$SQ/user_tokens/generate" --data name=jenkins \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["token"])')

log "SonarQube: webhook -> Jenkins (for the Quality Gate stage)"
for key in $(curl "${SQA[@]}" "$SQ/webhooks/list" | python3 -c 'import json,sys; [print(w["key"]) for w in json.load(sys.stdin)["webhooks"] if w["name"]=="jenkins"]'); do
  curl "${SQA[@]}" -X POST "$SQ/webhooks/delete" --data "webhook=$key"
done
curl "${SQA[@]}" -X POST "$SQ/webhooks/create" --data name=jenkins \
     --data-urlencode "url=http://$PRIVATE_IP:8080/sonarqube-webhook/" >/dev/null

# =====================================================================
#  JENKINS
# =====================================================================
log "Installing SonarScanner CLI $SCANNER_VERSION -> /opt/sonar-scanner"
if [ ! -x /opt/sonar-scanner/bin/sonar-scanner ]; then
  curl -fsSL -o /tmp/scanner.zip \
    "https://binaries.sonarsource.com/Distribution/sonar-scanner-cli/sonar-scanner-cli-${SCANNER_VERSION}-linux-x64.zip"
  unzip -qo /tmp/scanner.zip -d /opt && rm -rf /opt/sonar-scanner && mv /opt/sonar-scanner-${SCANNER_VERSION}-linux-x64 /opt/sonar-scanner
fi

log "Jenkins: installing plugins (takes a few minutes)"
systemctl stop jenkins
curl -fsSL -o /opt/jenkins-plugin-manager.jar \
  "https://github.com/jenkinsci/plugin-installation-manager-tool/releases/download/${PLUGIN_MANAGER_VERSION}/jenkins-plugin-manager-${PLUGIN_MANAGER_VERSION}.jar"
java -jar /opt/jenkins-plugin-manager.jar --war /usr/share/java/jenkins.war \
  --plugin-download-directory "$JENKINS_HOME/plugins" --verbose=false --plugins \
  configuration-as-code job-dsl workflow-aggregator pipeline-stage-view git github \
  credentials-binding aws-credentials sonar docker-workflow \
  ws-cleanup timestamper build-timeout matrix-auth
chown -R jenkins:jenkins "$JENKINS_HOME/plugins"

log "Jenkins: configuration as code (admin user, credentials, SonarQube, job)"
cat > "$JENKINS_HOME/casc.yaml" <<EOF
jenkins:
  systemMessage: "BlogApp CI/CD - configured by infra/configure-cicd.sh"
  numExecutors: 2
  securityRealm:
    local:
      allowsSignup: false
      users:
        - id: admin
          password: "$ADMIN_PASSWORD"
  authorizationStrategy:
    loggedInUsersCanDoAnything:
      allowAnonymousRead: false
unclassified:
  location:
    url: "http://$PUBLIC_IP:8080/"
  sonarGlobalConfiguration:
    buildWrapperEnabled: true
    installations:
      - name: sonarqube-server
        serverUrl: "http://localhost:9000"
        credentialsId: sonarqube-token
tool:
  sonarRunnerInstallation:
    installations:
      - name: sonar-scanner
        home: /opt/sonar-scanner
credentials:
  system:
    domainCredentials:
      - credentials:
          - string:
              scope: GLOBAL
              id: sonarqube-token
              secret: "$SONAR_TOKEN"
          - usernamePassword:
              scope: GLOBAL
              id: nexus-creds
              username: admin
              password: "$ADMIN_PASSWORD"
          - aws:
              scope: GLOBAL
              id: aws-creds
              accessKey: "$AWS_ACCESS_KEY_ID"
              secretKey: "$AWS_SECRET_ACCESS_KEY"
          - string:
              scope: GLOBAL
              id: mysql-root-password
              secret: "$MYSQL_ROOT_PASSWORD"
          - string:
              scope: GLOBAL
              id: mysql-app-password
              secret: "$MYSQL_APP_PASSWORD"
          - string:
              scope: GLOBAL
              id: jwt-secret
              secret: "$JWT_SECRET"
jobs:
  - script: |
      pipelineJob('blogapp-cicd') {
        description('GitHub -> SonarQube -> Test -> Docker -> Trivy -> Nexus/ECR -> EKS -> Validation')
        properties {
          pipelineTriggers {
            triggers {
              pollSCM { scmpoll_spec('H/5 * * * *') }
            }
          }
        }
        definition {
          cpsScm {
            scm {
              git {
                remote { url('$REPO_URL') }
                branch('*/main')
              }
            }
            scriptPath('Jenkinsfile')
            lightweight(true)
          }
        }
      }
EOF
chown jenkins:jenkins "$JENKINS_HOME/casc.yaml"; chmod 600 "$JENKINS_HOME/casc.yaml"

mkdir -p /etc/systemd/system/jenkins.service.d
cat > /etc/systemd/system/jenkins.service.d/override.conf <<EOF
[Service]
Environment="JAVA_OPTS=-Djava.awt.headless=true -Djenkins.install.runSetupWizard=false"
Environment="CASC_JENKINS_CONFIG=$JENKINS_HOME/casc.yaml"
TimeoutStartSec=600
EOF
echo 2.0 > "$JENKINS_HOME/jenkins.install.UpgradeWizard.state"
echo 2.0 > "$JENKINS_HOME/jenkins.install.InstallUtil.lastExecVersion"
chown jenkins:jenkins "$JENKINS_HOME"/jenkins.install.*
usermod -aG docker jenkins
systemctl daemon-reload
systemctl start jenkins
wait_for Jenkins http://localhost:8080/login "Jenkins"

log "Jenkins: waiting for the blogapp-cicd job"
JA=(-fsS -u "admin:$ADMIN_PASSWORD")
for _ in $(seq 1 30); do
  curl "${JA[@]}" http://localhost:8080/job/blogapp-cicd/api/json >/dev/null 2>&1 && break
  sleep 5
done

log "Jenkins: starting the first build"
COOKIES=$(mktemp)
CRUMB=$(curl "${JA[@]}" -c "$COOKIES" http://localhost:8080/crumbIssuer/api/json \
        | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["crumbRequestField"]+":"+d["crumb"])')
curl "${JA[@]}" -b "$COOKIES" -H "$CRUMB" -X POST http://localhost:8080/job/blogapp-cicd/build
rm -f "$COOKIES"

cat >> "$CRED_FILE" <<EOF
SONAR_TOKEN='$SONAR_TOKEN'
EOF

cat <<EOF

=====================================================================
  CI/CD server configured. First pipeline build has started.
---------------------------------------------------------------------
  Jenkins    http://$PUBLIC_IP:8080/job/blogapp-cicd/    admin / $ADMIN_PASSWORD
  SonarQube  http://$PUBLIC_IP:9000                      admin / $ADMIN_PASSWORD
  Nexus      http://$PUBLIC_IP:8081                      admin / $ADMIN_PASSWORD
---------------------------------------------------------------------
  The build takes ~15 minutes. Jenkins polls GitHub every 5 minutes,
  so every push to main triggers a new build automatically.
  All passwords are saved in $CRED_FILE (root only).
=====================================================================
EOF
