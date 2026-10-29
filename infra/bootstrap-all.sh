#!/usr/bin/env bash
# =====================================================================
#  One command: rebuild the whole project in AWS, run the pipeline,
#  and collect the evaluation evidence.
#
#     ./infra/bootstrap-all.sh          (Git Bash, after `aws configure`)
#
#  1. EKS cluster + add-ons (EBS CSI, metrics-server, LB controller)
#  2. Prometheus + Grafana (kube-prometheus-stack)
#  3. CI/CD server (Jenkins + SonarQube + Nexus) - installed and configured
#  4. First pipeline build, waits for the result
#  5. infra/collect-evidence.sh -> docs/evidence/, infra/capture-screenshots.sh -> docs/screenshots/auto/
#  Unattended: ~60-75 minutes. Safe to re-run; finished parts are skipped.
# =====================================================================
set -uo pipefail
export MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*'
export AWS_DEFAULT_REGION=${REGION:-ap-south-1}
cd "$(dirname "$0")/.."
CLUSTER=blogapp-eks-cluster
CI_NAME=blogapp-cicd-server
KEY_FILE="$HOME/blogapp-key.pem"
SSH_OPTS=(-i "$KEY_FILE" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15 -o ServerAliveInterval=30)
step() { printf '\n\033[1;36m==== %s ====\033[0m  (%s)\n' "$*" "$(date +%H:%M)"; }
die()  { printf '\n\033[1;31mSTOPPED: %s\033[0m\n' "$*"; exit 1; }

step "0/6 Checking tools and AWS access"
for t in aws eksctl kubectl helm ssh curl perl; do command -v $t >/dev/null || die "'$t' not found"; done
aws sts get-caller-identity --query Arn --output text || die "AWS keys not working - run: aws configure"

# ---------------------------------------------------------------- 1
step "1/6 EKS cluster"
if aws eks describe-cluster --name "$CLUSTER" >/dev/null 2>&1; then
  echo "   cluster exists"
else
  eksctl create cluster -f infra/eks-cluster.yaml --timeout 45m || die "cluster creation failed (see CloudFormation console)"
fi
aws eks update-kubeconfig --name "$CLUSTER" >/dev/null
eksctl create addon -f infra/eks-cluster.yaml 2>&1 | grep -v "already exists" || true
kubectl wait --for=condition=Ready nodes --all --timeout=10m || die "nodes not Ready"
kubectl get nodes

# ---------------------------------------------------------------- 2
step "2/6 Load balancer controller, gp3 storage, Prometheus + Grafana, ECR"
bash infra/setup-eks-addons.sh || die "add-on installation failed"
kubectl get crd servicemonitors.monitoring.coreos.com >/dev/null || die "Prometheus CRDs missing"

# ---------------------------------------------------------------- 3
step "3/6 CI/CD server"
ci_ip() {
  aws ec2 describe-instances --filters "Name=tag:Name,Values=$CI_NAME" "Name=instance-state-name,Values=running" \
    --query 'Reservations[0].Instances[0].PublicIpAddress' --output text
}
IP=$(ci_ip)
if [ -z "$IP" ] || [ "$IP" = "None" ]; then
  bash infra/launch-cicd-server.sh || die "server launch failed"
  IP=$(ci_ip)
fi
echo "   CI/CD server: $IP"
# your public IP may have changed since the server was launched - allow it again
MY_IP=$(curl -s https://checkip.amazonaws.com | tr -d '[:space:]')
SG=$(aws ec2 describe-security-groups --filters Name=group-name,Values=$CI_NAME-sg --query 'SecurityGroups[0].GroupId' --output text)
for p in 22 8080 9000 8081; do
  aws ec2 authorize-security-group-ingress --group-id "$SG" --protocol tcp --port $p --cidr "$MY_IP/32" >/dev/null 2>&1 || true
done
remote() { ssh "${SSH_OPTS[@]}" "ubuntu@$IP" "$@"; }

echo "   waiting for the server to finish installing (up to 40 min)..."
for i in $(seq 1 80); do
  remote 'test -f /var/log/blogapp-setup.done' 2>/dev/null && { echo "   installation finished"; break; }
  [ "$i" = 80 ] && { remote 'sudo tail -30 /var/log/blogapp-setup.log'; die "server installation did not finish"; }
  sleep 30
done

# ---------------------------------------------------------------- 4
step "4/6 Configuring Jenkins, SonarQube, Nexus"
if remote 'sudo grep -q SONAR_TOKEN /root/blogapp-credentials.txt' 2>/dev/null; then
  echo "   already configured"
else
  AK=$(aws configure get aws_access_key_id); SK=$(aws configure get aws_secret_access_key)
  [ -n "$AK" ] && [ -n "$SK" ] || die "could not read your AWS keys from 'aws configure'"
  # hand the AWS key to the server over SSH stdin (never on a command line)
  printf "AWS_ACCESS_KEY_ID='%s'\nAWS_SECRET_ACCESS_KEY='%s'\n" "$AK" "$SK" | \
    remote 'sudo test -f /root/blogapp-credentials.txt || sudo sh -c "umask 077; cat > /root/blogapp-credentials.txt"'
  remote 'cd /opt/BlogReact && sudo git pull -q && sudo nohup bash infra/configure-cicd.sh > /tmp/configure.log 2>&1 < /dev/null &'
  echo "   running on the server (~10 min)..."
  sleep 30
  for i in $(seq 1 60); do
    remote 'pgrep -f configure-cicd.sh >/dev/null' 2>/dev/null || break
    sleep 20
  done
  remote 'tail -14 /tmp/configure.log'
  remote 'sudo grep -q SONAR_TOKEN /root/blogapp-credentials.txt' || die "configuration failed - see the log above"
fi

# ---------------------------------------------------------------- 5
step "5/6 Waiting for the Jenkins pipeline"
PW=$(remote "sudo sed -n \"s/^ADMIN_PASSWORD='\\(.*\\)'/\\1/p\" /root/blogapp-credentials.txt")
J="http://$IP:8080/job/blogapp-cicd"
build_json() { curl -s -u "admin:$PW" "$J/lastBuild/api/json?tree=number,building,result"; }
for i in $(seq 1 40); do build_json | grep -q '"number"' && break; sleep 15; done
for i in $(seq 1 100); do
  JSON=$(build_json)
  echo "$JSON" | grep -q '"building":false' && break
  printf '   build running... %s\r' "$(date +%H:%M:%S)"; sleep 30
done
RESULT=$(echo "$JSON" | sed -n 's/.*"result":"\([A-Z]*\)".*/\1/p')
NUM=$(echo "$JSON" | sed -n 's/.*"number":\([0-9]*\).*/\1/p')
echo; echo "   Build #$NUM finished: $RESULT"
if [ "$RESULT" != "SUCCESS" ]; then
  curl -s -u "admin:$PW" "$J/lastBuild/consoleText" | tail -60
  die "pipeline build #$NUM = $RESULT. Paste the lines above to Claude."
fi

# ---------------------------------------------------------------- 6
step "6/6 Collecting evidence"
CI_IP=$IP JENKINS_PASSWORD=$PW bash infra/collect-evidence.sh
step "Capturing screenshots of the live system (Edge headless)"
CI_IP=$IP JENKINS_PASSWORD=$PW bash infra/capture-screenshots.sh || echo "   screenshot capture had problems - rerun: CI_IP=$IP JENKINS_PASSWORD=<pw> ./infra/capture-screenshots.sh"

ALB=$(kubectl -n blogapp get ingress blogapp-ingress -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
cat <<EOF

=====================================================================
  ALL DONE - pipeline build #$NUM is green and evidence is collected
---------------------------------------------------------------------
  Blog (live)   http://$ALB
  Jenkins       $J/            admin / (password: see below)
  Pipeline view open build #$NUM in Jenkins -> "Pipeline Overview" (full graph)
  SonarQube     http://$IP:9000
  Nexus         http://$IP:8081
  Grafana       run: kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80
                then http://localhost:3000   admin / CHANGE_ME
  Password for Jenkins/SonarQube/Nexus: $PW

  Evidence: docs/evidence/   Screenshots (automatic): docs/screenshots/auto/
  Still take by hand: B2-B3 in the browser (register + new post) and D1 EKS console - see docs/screenshots/README.md
  When finished:  git add docs && git commit -m "Evaluation evidence" && git push personal main
                  ./infra/teardown.sh   (stops AWS charges)
=====================================================================
EOF
