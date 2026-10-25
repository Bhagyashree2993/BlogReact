#!/usr/bin/env bash
# One-time cluster bootstrap: LB controller, monitoring stack, ECR repos, Jenkins access.
# Usage: JENKINS_ROLE_ARN=arn:aws:iam::<acct>:role/<jenkins-role-or-user> ./infra/setup-eks-addons.sh
set -euo pipefail
CLUSTER=${CLUSTER:-blogapp-eks-cluster}
REGION=${REGION:-ap-south-1}

aws eks update-kubeconfig --name "$CLUSTER" --region "$REGION"
VPC_ID=$(aws eks describe-cluster --name "$CLUSTER" --region "$REGION" \
          --query 'cluster.resourcesVpcConfig.vpcId' --output text)

echo ">> AWS Load Balancer Controller"
helm repo add eks https://aws.github.io/eks-charts
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system --set clusterName="$CLUSTER" --set region="$REGION" --set vpcId="$VPC_ID" \
  --set serviceAccount.create=false --set serviceAccount.name=aws-load-balancer-controller

echo ">> gp3 StorageClass (needed by the monitoring PVCs below)"
kubectl apply -f "$(dirname "$0")/../k8s/base/storageclass.yaml"

echo ">> kube-prometheus-stack (Prometheus, Alertmanager, Grafana)"
helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  -n monitoring --create-namespace \
  -f "$(dirname "$0")/../k8s/monitoring/kube-prometheus-values.yaml"

echo ">> ECR repositories"
for repo in blogapp-backend blogapp-frontend; do
  aws ecr describe-repositories --repository-names "$repo" --region "$REGION" >/dev/null 2>&1 || \
    aws ecr create-repository --repository-name "$repo" --region "$REGION" \
      --image-scanning-configuration scanOnPush=true --image-tag-mutability IMMUTABLE
done

if [[ -n "${JENKINS_ROLE_ARN:-}" ]]; then
  echo ">> Granting Jenkins ($JENKINS_ROLE_ARN) admin on the cluster via EKS access entries"
  aws eks create-access-entry --cluster-name "$CLUSTER" --region "$REGION" \
    --principal-arn "$JENKINS_ROLE_ARN" 2>/dev/null || true
  aws eks associate-access-policy --cluster-name "$CLUSTER" --region "$REGION" \
    --principal-arn "$JENKINS_ROLE_ARN" \
    --policy-arn arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy \
    --access-scope type=cluster
fi

kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller
kubectl get pods -n monitoring
echo "Grafana: kubectl -n monitoring get svc kube-prometheus-stack-grafana (user: admin)"
