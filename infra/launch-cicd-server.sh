#!/usr/bin/env bash
# Launches the CI/CD server (Jenkins + SonarQube + Nexus) on EC2 with one command.
# Run from Git Bash / Linux / macOS after `aws configure`:
#     ./infra/launch-cicd-server.sh
# The instance installs everything itself (infra/setup-cicd-server.sh) - allow ~10 minutes.
set -euo pipefail
# Git Bash on Windows rewrites args starting with "/" into Windows paths (breaks SSM parameter names)
export MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*'
REGION=${REGION:-ap-south-1}
NAME=blogapp-cicd-server
KEY_NAME=blogapp-key
KEY_FILE="$HOME/blogapp-key.pem"
REPO_URL=${REPO_URL:-https://github.com/Bhagyashree2993/BlogReact.git}
INSTANCE_TYPE=${INSTANCE_TYPE:-t3.xlarge}
export AWS_DEFAULT_REGION=$REGION

MY_IP=$(curl -s https://checkip.amazonaws.com | tr -d '[:space:]')
echo ">> Your public IP: $MY_IP (ports will be opened only to this IP)"

echo ">> Key pair"
if ! aws ec2 describe-key-pairs --key-names "$KEY_NAME" >/dev/null 2>&1; then
  aws ec2 create-key-pair --key-name "$KEY_NAME" --query KeyMaterial --output text > "$KEY_FILE"
  chmod 400 "$KEY_FILE" 2>/dev/null || true
  echo "   saved private key to $KEY_FILE"
else
  echo "   key pair $KEY_NAME already exists (using $KEY_FILE)"
fi

echo ">> Security group (default VPC)"
VPC_ID=$(aws ec2 describe-vpcs --filters Name=isDefault,Values=true --query 'Vpcs[0].VpcId' --output text)
if [ "$VPC_ID" = "None" ]; then
  echo "No default VPC in $REGION. Create one with: aws ec2 create-default-vpc"; exit 1
fi
SG_ID=$(aws ec2 describe-security-groups --filters Name=group-name,Values=$NAME-sg Name=vpc-id,Values=$VPC_ID \
        --query 'SecurityGroups[0].GroupId' --output text)
if [ "$SG_ID" = "None" ]; then
  SG_ID=$(aws ec2 create-security-group --group-name $NAME-sg --vpc-id "$VPC_ID" \
          --description "BlogApp CI/CD server" --query GroupId --output text)
fi
for p in 22 8080 9000 8081 8083; do
  aws ec2 authorize-security-group-ingress --group-id "$SG_ID" --protocol tcp --port $p \
    --cidr "$MY_IP/32" >/dev/null 2>&1 || true
done
# GitHub webhook deliveries come from GitHub's IP ranges -> allow Jenkins port from anywhere
# only if you want push-triggered builds (uncomment):
# aws ec2 authorize-security-group-ingress --group-id "$SG_ID" --protocol tcp --port 8080 --cidr 0.0.0.0/0

echo ">> Ubuntu 24.04 AMI"
AMI_ID=$(aws ssm get-parameter \
  --name /aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id \
  --query Parameter.Value --output text)

USER_DATA=$(cat <<EOF
#!/bin/bash
set -e
exec > /var/log/blogapp-setup.log 2>&1
apt-get update -y && apt-get install -y git
git clone $REPO_URL /opt/BlogReact
bash /opt/BlogReact/infra/setup-cicd-server.sh
touch /var/log/blogapp-setup.done
EOF
)

echo ">> Launching $INSTANCE_TYPE"
INSTANCE_ID=$(aws ec2 run-instances --image-id "$AMI_ID" --instance-type "$INSTANCE_TYPE" \
  --key-name "$KEY_NAME" --security-group-ids "$SG_ID" \
  --block-device-mappings 'DeviceName=/dev/sda1,Ebs={VolumeSize=50,VolumeType=gp3}' \
  --user-data "$USER_DATA" \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$NAME}]" \
  --query 'Instances[0].InstanceId' --output text)
aws ec2 wait instance-running --instance-ids "$INSTANCE_ID"
read -r PUBLIC_IP PRIVATE_IP < <(aws ec2 describe-instances --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].[PublicIpAddress,PrivateIpAddress]' --output text)

cat <<EOF

================ CI/CD server launched ================
Instance   : $INSTANCE_ID
Public IP  : $PUBLIC_IP
Private IP : $PRIVATE_IP

Software is installing now (~10 min). Check progress with:
  ssh -i $KEY_FILE ubuntu@$PUBLIC_IP 'tail -5 /var/log/blogapp-setup.log'
It's finished when this prints the URLs and passwords:
  ssh -i $KEY_FILE ubuntu@$PUBLIC_IP 'sudo tail -8 /var/log/blogapp-setup.log'

Then configure Jenkins + SonarQube + Nexus and start the first build:
  ssh -t -i $KEY_FILE ubuntu@$PUBLIC_IP 'cd /opt/BlogReact && sudo git pull && sudo bash infra/configure-cicd.sh'

Then open:
  Jenkins   http://$PUBLIC_IP:8080
  SonarQube http://$PUBLIC_IP:9000
  Nexus     http://$PUBLIC_IP:8081
EOF
