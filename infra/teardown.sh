#!/usr/bin/env bash
# Deletes EVERYTHING this project created in AWS so charges stop.
#   ./infra/teardown.sh          (Git Bash / Linux / macOS, after `aws configure`)
# Order matters: app + load balancers first, then the cluster, then leftovers.
# Takes ~20 minutes. Safe to re-run if it stops halfway.
set -uo pipefail
export MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*'   # Git Bash path-rewriting off
export AWS_DEFAULT_REGION=${REGION:-ap-south-1}
CLUSTER=blogapp-eks-cluster
CI_NAME=blogapp-cicd-server

echo "This permanently deletes the EKS cluster, the blog + its database, monitoring,"
echo "the CI/CD server (Jenkins/SonarQube/Nexus), ECR images and all their disks."
read -rp "Type DELETE to continue: " ok
[ "$ok" = "DELETE" ] || { echo "Cancelled."; exit 1; }
step() { printf '\n\033[1;31m>> %s\033[0m\n' "$*"; }

if aws eks describe-cluster --name "$CLUSTER" >/dev/null 2>&1; then
  aws eks update-kubeconfig --name "$CLUSTER" >/dev/null
  step "1/7 Deleting the blog app (removes its AWS load balancer)"
  kubectl delete ingress --all -n blogapp --ignore-not-found --wait=true --timeout=5m
  kubectl delete namespace blogapp --ignore-not-found --wait=true --timeout=10m

  step "2/7 Removing monitoring (Prometheus/Grafana)"
  helm uninstall kube-prometheus-stack -n monitoring 2>/dev/null || true
  kubectl delete namespace monitoring --ignore-not-found --wait=true --timeout=10m

  step "3/7 Removing the load balancer controller"
  sleep 30   # give the controller time to finish deleting the ALB
  helm uninstall aws-load-balancer-controller -n kube-system 2>/dev/null || true

  step "4/7 Deleting the EKS cluster (~10-15 min)"
  eksctl delete cluster --name "$CLUSTER" --wait || \
    { echo "Cluster delete reported an error - waiting 2 min and retrying"; sleep 120; eksctl delete cluster --name "$CLUSTER" --wait; }
else
  step "1-4/7 EKS cluster already gone - skipping"
fi

step "5/7 Terminating the CI/CD server"
IDS=$(aws ec2 describe-instances --filters "Name=tag:Name,Values=$CI_NAME" \
      "Name=instance-state-name,Values=pending,running,stopping,stopped" \
      --query 'Reservations[].Instances[].InstanceId' --output text)
if [ -n "$IDS" ]; then
  aws ec2 terminate-instances --instance-ids $IDS >/dev/null
  aws ec2 wait instance-terminated --instance-ids $IDS && echo "   terminated: $IDS"
fi
SG=$(aws ec2 describe-security-groups --filters Name=group-name,Values=$CI_NAME-sg \
     --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null)
[ -n "$SG" ] && [ "$SG" != "None" ] && aws ec2 delete-security-group --group-id "$SG" && echo "   security group deleted"
aws ec2 delete-key-pair --key-name blogapp-key 2>/dev/null && echo "   key pair deleted"
rm -f "$HOME/blogapp-key.pem"

step "6/7 Deleting ECR repositories and images"
for r in blogapp-backend blogapp-frontend; do
  aws ecr delete-repository --repository-name "$r" --force >/dev/null 2>&1 && echo "   $r deleted"
done

step "7/7 Deleting leftover disks (gp3 StorageClass keeps them on purpose)"
sleep 20
VOLS=$(aws ec2 describe-volumes --filters Name=status,Values=available Name=tag-key,Values=CSIVolumeName \
       --query 'Volumes[].VolumeId' --output text)
for v in $VOLS; do aws ec2 delete-volume --volume-id "$v" && echo "   volume $v deleted"; done

echo
echo "================ Check: everything below should be empty ================"
echo "EKS clusters     : $(aws eks list-clusters --query clusters --output text)"
echo "Instances        : $(aws ec2 describe-instances --filters "Name=tag:Name,Values=$CI_NAME" "Name=instance-state-name,Values=pending,running,stopping,stopped" --query 'Reservations[].Instances[].InstanceId' --output text)"
echo "Load balancers   : $(aws elbv2 describe-load-balancers --query "LoadBalancers[?starts_with(LoadBalancerName,'k8s-')].LoadBalancerName" --output text)"
echo "Unattached disks : $(aws ec2 describe-volumes --filters Name=status,Values=available --query 'Volumes[].VolumeId' --output text)"
echo "Stacks           : $(aws cloudformation describe-stacks --query "Stacks[?contains(StackName,'blogapp')].StackName" --output text)"
echo "NAT gateways     : $(aws ec2 describe-nat-gateways --filter Name=state,Values=available --query 'NatGateways[].NatGatewayId' --output text)"
echo "========================================================================="
echo "Last step (in the AWS console): IAM -> Users -> blogapp-admin -> delete the access key, then the user."
