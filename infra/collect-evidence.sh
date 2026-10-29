#!/usr/bin/env bash
# =====================================================================
#  Collects evaluation evidence into docs/evidence/ (text files that
#  complement the screenshots). Run after a green pipeline build:
#     CI_IP=<server ip> JENKINS_PASSWORD=<pw> ./infra/collect-evidence.sh
#  (infra/bootstrap-all.sh calls it automatically.)
#  No secret values are written - only names, statuses and app data.
# =====================================================================
set -uo pipefail
export MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*'
export AWS_DEFAULT_REGION=${REGION:-ap-south-1}
cd "$(dirname "$0")/.."
: "${CI_IP:?set CI_IP}"; : "${JENKINS_PASSWORD:?set JENKINS_PASSWORD}"
OUT=docs/evidence; mkdir -p "$OUT"
NS=blogapp
J="http://$CI_IP:8080/job/blogapp-cicd"
AUTH=(-s -u "admin:$JENKINS_PASSWORD")
hdr() { printf '\n========== %s ==========\n' "$*"; }
run() { printf '\n$ %s\n' "$*"; "$@" 2>&1; }
note() { echo "   -> $OUT/$1"; }
ALB=$(kubectl -n $NS get ingress blogapp-ingress -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
APP="http://$ALB"

# ---------------------------------------------------------------- Jenkins
{
  hdr "Jenkins pipeline - last build, every stage"
  curl "${AUTH[@]}" "$J/lastBuild/wfapi/describe" | perl -MJSON::PP -e '
    local $/; my $d = decode_json(<STDIN>);
    printf "Build %s   status: %s   total: %.1f min\n\n", $d->{name}, $d->{status}, $d->{durationMillis}/60000;
    printf "%-3s %-42s %-10s %8s\n", "#", "STAGE", "STATUS", "TIME";
    my $i = 0;
    printf "%-3d %-42s %-10s %7.1fs\n", ++$i, $_->{name}, $_->{status}, $_->{durationMillis}/1000 for @{$d->{stages}};'
  hdr "Build history"
  curl "${AUTH[@]}" "$J/api/json?tree=builds[number,result,timestamp]" | perl -MJSON::PP -e '
    local $/; my $d = decode_json(<STDIN>);
    printf "#%-4s %-8s %s\n", $_->{number}, $_->{result} // "RUNNING", scalar localtime($_->{timestamp}/1000) for @{$d->{builds}};'
} > "$OUT/01-jenkins-pipeline-stages.txt"; note 01-jenkins-pipeline-stages.txt
curl "${AUTH[@]}" "$J/lastBuild/consoleText" > "$OUT/02-jenkins-console-output.txt"; note 02-jenkins-console-output.txt

# ---------------------------------------------------------------- SonarQube + Trivy + Nexus + ECR
{
  hdr "SonarQube Quality Gate (project blogapp)"
  curl -s -u "admin:$JENKINS_PASSWORD" "http://$CI_IP:9000/api/qualitygates/project_status?projectKey=blogapp" | perl -MJSON::PP -e '
    local $/; my $d = decode_json(<STDIN>)->{projectStatus};
    print "Quality Gate: $d->{status}\n"; printf "  %-35s %-6s actual=%s\n", $_->{metricKey}, $_->{status}, $_->{actualValue}//"-" for @{$d->{conditions}};'
  hdr "SonarQube measures"
  curl -s -u "admin:$JENKINS_PASSWORD" "http://$CI_IP:9000/api/measures/component?component=blogapp&metricKeys=bugs,vulnerabilities,code_smells,coverage,duplicated_lines_density,ncloc,security_hotspots" | perl -MJSON::PP -e '
    local $/; printf "  %-28s %s\n", $_->{metric}, $_->{value} for @{decode_json(<STDIN>)->{component}{measures}};'
} > "$OUT/03-sonarqube.txt"; note 03-sonarqube.txt

{
  for f in trivy-fs-report.txt trivy-blogapp-backend-report.txt trivy-blogapp-frontend-report.txt; do
    hdr "Trivy: $f (pipeline gate = fail on fixable HIGH/CRITICAL)"
    curl "${AUTH[@]}" "$J/lastSuccessfulBuild/artifact/$f"
  done
} > "$OUT/04-trivy-reports.txt"; note 04-trivy-reports.txt

{
  for repo in blogapp-artifacts blogapp-docker; do
    hdr "Nexus repository: $repo"
    curl -s -u "admin:$JENKINS_PASSWORD" "http://$CI_IP:8081/service/rest/v1/components?repository=$repo" | perl -MJSON::PP -e '
      local $/; for my $c (@{decode_json(<STDIN>)->{items}}) {
        printf "  %-60s %s\n", $c->{name}, ($c->{version} ? "version=$c->{version}" : "") }'
  done
  for repo in blogapp-backend blogapp-frontend; do
    hdr "Amazon ECR: $repo (versioned, immutable tags, scan on push)"
    run aws ecr describe-images --repository-name $repo --query 'sort_by(imageDetails,&imagePushedAt)[].{tag:imageTags[0],pushed:imagePushedAt,sizeMB:imageSizeInBytes}' --output table
  done
} > "$OUT/05-nexus-and-ecr-images.txt"; note 05-nexus-and-ecr-images.txt

# ---------------------------------------------------------------- EKS
{
  hdr "Cluster and nodes"
  run kubectl get nodes -o wide
  hdr "All application resources"
  run kubectl -n $NS get deploy,sts,rs,pods,svc,ingress,hpa,pdb -o wide
  hdr "Image versions actually running (match the pipeline build tag)"
  run kubectl -n $NS get pods -o 'custom-columns=POD:.metadata.name,IMAGE:.spec.containers[*].image,NODE:.spec.nodeName,READY:.status.containerStatuses[*].ready'
  hdr "Replicas, rolling update strategy, probes, requests/limits"
  run kubectl -n $NS get deploy -o 'custom-columns=NAME:.metadata.name,REPLICAS:.spec.replicas,STRATEGY:.spec.strategy.type,MAX_SURGE:.spec.strategy.rollingUpdate.maxSurge,MAX_UNAVAIL:.spec.strategy.rollingUpdate.maxUnavailable,READINESS:.spec.template.spec.containers[0].readinessProbe.httpGet.path,LIVENESS:.spec.template.spec.containers[0].livenessProbe.httpGet.path,CPU_REQ:.spec.template.spec.containers[0].resources.requests.cpu,CPU_LIM:.spec.template.spec.containers[0].resources.limits.cpu,MEM_REQ:.spec.template.spec.containers[0].resources.requests.memory,MEM_LIM:.spec.template.spec.containers[0].resources.limits.memory'
  hdr "Backend deployment (full description)"
  run kubectl -n $NS describe deploy backend
  hdr "Frontend deployment (full description)"
  run kubectl -n $NS describe deploy frontend
  hdr "Service discovery (ClusterIP services + endpoints)"
  run kubectl -n $NS get endpoints
  hdr "External access - ALB Ingress"
  run kubectl -n $NS describe ingress blogapp-ingress
  hdr "ConfigMaps and Secrets (names/keys only - values are never printed)"
  run kubectl -n $NS get configmap
  run kubectl -n $NS get secret
  run kubectl -n $NS describe secret mysql-secret backend-secret
  hdr "Rollout history"
  run kubectl -n $NS rollout history deployment/backend
  run kubectl -n $NS rollout history deployment/frontend
  hdr "Archived by the pipeline: eks-deployment-report.txt"
  curl "${AUTH[@]}" "$J/lastSuccessfulBuild/artifact/eks-deployment-report.txt"
} > "$OUT/06-eks-deployment.txt"; note 06-eks-deployment.txt

# ---------------------------------------------------------------- Three-tier app output
EMAIL="evaluator$(date +%s)@blogapp.dev"
{
  hdr "Three-tier flow through the public ALB:  browser -> ALB -> frontend (nginx) -> /api -> backend (Node) -> MySQL"
  echo "Application URL: $APP"
  hdr "1. Frontend (nginx serving the React app)"
  printf '$ curl -s %s/ | grep -o "<title>.*</title>"\n' "$APP"
  curl -s "$APP/" | grep -o "<title>.*</title>"
  run curl -s -o /dev/null -w "HTTP %{http_code}  %{size_download} bytes  %{time_total}s\n" "$APP/"
  hdr "2. Frontend health  /healthz"
  run curl -s "$APP/healthz"; echo
  hdr "3. Backend API via the frontend proxy:  GET /api/posts"
  run curl -s "$APP/api/posts?limit=3"; echo
  hdr "4. Register a user  (backend writes to MySQL)"
  REG=$(curl -s -X POST "$APP/api/auth/register" -H 'Content-Type: application/json' \
        -d "{\"name\":\"Evaluator\",\"email\":\"$EMAIL\",\"password\":\"Evaluate#2026\"}")
  echo "$REG" | sed 's/"token":"[^"]*"/"token":"<JWT issued - hidden>"/'
  TOKEN=$(echo "$REG" | sed -n 's/.*"token":"\([^"]*\)".*/\1/p')
  hdr "5. Log in  (backend reads the user back from MySQL, bcrypt check)"
  curl -s -X POST "$APP/api/auth/login" -H 'Content-Type: application/json' \
       -d "{\"email\":\"$EMAIL\",\"password\":\"Evaluate#2026\"}" | sed 's/"token":"[^"]*"/"token":"<JWT - hidden>"/'; echo
  hdr "6. Create a post with the JWT  (authenticated write)"
  POST=$(curl -s -X POST "$APP/api/posts" -H 'Content-Type: application/json' -H "Authorization: Bearer $TOKEN" \
        -d '{"title":"Evaluation post from the CI/CD demo","body":"This post was written through the ALB, the nginx frontend and the Node.js API, and stored in MySQL running as a StatefulSet on EKS with an encrypted EBS gp3 volume.","tag":"devops"}')
  echo "$POST"
  SLUG=$(echo "$POST" | sed -n 's/.*"slug":"\([^"]*\)".*/\1/p')
  hdr "7. Read it back  GET /api/posts/$SLUG"
  run curl -s "$APP/api/posts/$SLUG"; echo
  hdr "8. Add a comment and read the post again"
  curl -s -X POST "$APP/api/posts/$SLUG/comments" -H 'Content-Type: application/json' -H "Authorization: Bearer $TOKEN" -d '{"body":"Verified end-to-end."}'; echo
  curl -s "$APP/api/posts/$SLUG" | grep -o '"comments":\[.*\]'
  hdr "9. Unauthenticated write is rejected"
  run curl -s -w "  (HTTP %{http_code})\n" -X POST "$APP/api/posts" -H 'Content-Type: application/json' -d '{"title":"x","body":"no token"}'
  echo; echo "Open in a browser: $APP/post/$SLUG"
} > "$OUT/07-three-tier-application-output.txt"; note 07-three-tier-application-output.txt

# ---------------------------------------------------------------- Database
SQL() { kubectl -n $NS exec mysql-0 -c mysql -- sh -c "mysql -t -uroot -p\"\$MYSQL_ROOT_PASSWORD\" blogdb -e \"$1\" 2>/dev/null"; }
{
  hdr "MySQL StatefulSet, headless service and persistent volume"
  run kubectl -n $NS get sts,pod/mysql-0,svc/mysql-service -o wide
  run kubectl -n $NS get pvc -o wide
  run kubectl get pv -o 'custom-columns=PV:.metadata.name,CLAIM:.spec.claimRef.name,SIZE:.spec.capacity.storage,CLASS:.spec.storageClassName,RECLAIM:.spec.persistentVolumeReclaimPolicy,EBS_VOLUME:.spec.csi.volumeHandle'
  run kubectl get storageclass gp3 -o 'custom-columns=NAME:.metadata.name,PROVISIONER:.provisioner,TYPE:.parameters.type,ENCRYPTED:.parameters.encrypted,RECLAIM:.reclaimPolicy'
  hdr "Credentials come from a Kubernetes Secret (injected by Jenkins), not from git"
  run kubectl -n $NS get sts mysql -o 'jsonpath={range .spec.template.spec.containers[0].env[*]}{.name}{" <- "}{.valueFrom.secretKeyRef.name}{"/"}{.valueFrom.secretKeyRef.key}{.value}{"\n"}{end}'
  hdr "Initialization: schema from ConfigMap mysql-init-script (database/init.sql)"
  echo '$ SHOW TABLES;'; SQL "SHOW TABLES;"
  echo '$ DESCRIBE posts;'; SQL "DESCRIBE posts;"
  hdr "Backend integration: rows written by the API calls in 07-three-tier-application-output.txt"
  echo '$ SELECT id,name,email,created_at FROM users;'; SQL "SELECT id,name,email,created_at FROM users;"
  echo '$ SELECT id,title,tag,author_id,created_at FROM posts;'; SQL "SELECT id,title,tag,author_id,created_at FROM posts;"
  echo '$ SELECT id,post_id,author_id,body FROM comments;'; SQL "SELECT id,post_id,author_id,body FROM comments;"
  hdr "Backend connects as the least-privilege app user, not root"
  run kubectl -n $NS get deploy backend -o 'jsonpath={range .spec.template.spec.containers[0].env[*]}{.name}{" <- "}{.valueFrom.secretKeyRef.name}{"/"}{.valueFrom.secretKeyRef.key}{"\n"}{end}'
  echo "\$ SHOW GRANTS FOR 'bloguser'@'%';"; SQL "SHOW GRANTS FOR 'bloguser'@'%';"
  hdr "Persistence test: delete the MySQL pod, Kubernetes recreates it on the same EBS volume"
  BEFORE=$(SQL "SELECT COUNT(*) AS posts_before FROM posts;")
  echo "$BEFORE"
  run kubectl -n $NS delete pod mysql-0 --wait=true
  run kubectl -n $NS wait --for=condition=Ready pod/mysql-0 --timeout=300s
  sleep 5
  SQL "SELECT COUNT(*) AS posts_after_restart FROM posts;"
  run kubectl -n $NS get pod mysql-0 -o wide
  hdr "Backend readiness (checks the DB connection) after the restart"
  sleep 15
  run curl -s "$APP/api/posts?limit=1"; echo
} > "$OUT/08-database-mysql.txt"; note 08-database-mysql.txt

# ---------------------------------------------------------------- Monitoring + security
{
  hdr "Prometheus + Grafana (kube-prometheus-stack)"
  run kubectl -n monitoring get pods,svc,pvc
  run kubectl -n $NS get servicemonitor,prometheusrule
  hdr "Prometheus is scraping the backend /metrics (query: up{namespace=\"blogapp\"})"
  kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 19090:9090 >/dev/null 2>&1 & PF=$!
  sleep 6
  curl -s 'http://127.0.0.1:19090/api/v1/query?query=up%7Bnamespace%3D%22blogapp%22%7D' | perl -MJSON::PP -e '
    local $/; printf "  %-30s %-20s up=%s\n", $_->{metric}{pod}, $_->{metric}{job}, $_->{value}[1] for @{decode_json(<STDIN>)->{data}{result}};'
  hdr "Request rate by route (last 5 min)"
  curl -s 'http://127.0.0.1:19090/api/v1/query?query=sum%20by%20(route)%20(rate(http_request_duration_seconds_count%7Bnamespace%3D%22blogapp%22%7D%5B5m%5D))' | perl -MJSON::PP -e '
    local $/; printf "  %-30s %.3f req/s\n", $_->{metric}{route}, $_->{value}[1] for @{decode_json(<STDIN>)->{data}{result}};'
  hdr "Alert rules loaded"
  curl -s 'http://127.0.0.1:19090/api/v1/rules' | perl -MJSON::PP -e '
    local $/; for my $g (@{decode_json(<STDIN>)->{data}{groups}}) { next unless $g->{name} eq "blogapp.rules";
      printf "  %-28s state=%s\n", $_->{name}, $_->{state} for @{$g->{rules}} }'
  kill $PF 2>/dev/null
  hdr "Logging: recent backend logs (morgan access log)"
  run kubectl -n $NS logs deploy/backend --tail=15
} > "$OUT/09-monitoring-and-logging.txt"; note 09-monitoring-and-logging.txt

{
  hdr "Network security: NetworkPolicies (frontend -> backend -> mysql only)"
  run kubectl -n $NS describe networkpolicy
  hdr "Container security: pod security context per workload"
  run kubectl -n $NS get pods -o 'custom-columns=POD:.metadata.name,RUN_AS_NON_ROOT:.spec.securityContext.runAsNonRoot,USER:.spec.securityContext.runAsUser,SECCOMP:.spec.securityContext.seccompProfile.type,NO_PRIV_ESC:.spec.containers[0].securityContext.allowPrivilegeEscalation,READONLY_FS:.spec.containers[0].securityContext.readOnlyRootFilesystem,DROP_CAPS:.spec.containers[0].securityContext.capabilities.drop'
  run kubectl get ns $NS --show-labels
  hdr "Namespace quotas and default limits"
  run kubectl -n $NS describe resourcequota,limitrange
  hdr "IAM / RBAC: who can access the cluster (EKS access entries) and IRSA service accounts"
  run aws eks list-access-entries --cluster-name blogapp-eks-cluster --output table
  run kubectl -n kube-system get sa aws-load-balancer-controller ebs-csi-controller-sa -o 'custom-columns=SA:.metadata.name,IAM_ROLE:.metadata.annotations.eks\.amazonaws\.com/role-arn'
  run kubectl auth can-i --list -n $NS --as=system:serviceaccount:$NS:default
} > "$OUT/10-security.txt"; note 10-security.txt

echo
echo "Evidence written to $OUT/. Blog URL: $APP"
