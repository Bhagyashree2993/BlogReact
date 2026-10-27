#!/usr/bin/env bash
# Bootstraps ONE Ubuntu 22.04/24.04 EC2 instance (t3.xlarge, 50 GB) as the CI/CD server:
#   Jenkins :8080 | SonarQube :9000 | Nexus :8081 (UI) + :8083 (docker-hosted)
# plus every CLI the Jenkinsfile calls: node 20, docker, trivy, awscli v2, kubectl, helm, eksctl.
# Security group: open 8080, 9000, 8081, 8083 to your IP (and 22 for SSH).
# Run as root:  sudo bash infra/setup-cicd-server.sh   (safe to re-run)
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
PUBLIC_IP=$(curl -s http://checkip.amazonaws.com || hostname -I | awk '{print $1}')
PRIVATE_IP=$(hostname -I | awk '{print $1}')

# A Jenkins repo left by an earlier run with an outdated key would make the first
# 'apt-get update' fail - drop it; it is re-added with the current key below.
rm -f /etc/apt/sources.list.d/jenkins.list
apt-get update -y
apt-get install -y ca-certificates curl gnupg unzip jq git fontconfig openjdk-21-jre

echo ">> Docker"
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor --yes -o /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
  > /etc/apt/sources.list.d/docker.list
apt-get update -y && apt-get install -y docker-ce docker-ce-cli containerd.io
# Nexus docker connector is plain HTTP -> allow it as an insecure registry
cat > /etc/docker/daemon.json <<JSON
{ "insecure-registries": ["${PRIVATE_IP}:8083", "${PUBLIC_IP}:8083", "localhost:8083"] }
JSON
systemctl restart docker

echo ">> Jenkins"
# Jenkins rotated its repository signing key in Dec 2025 (jenkins.io-2026.key)
curl -fsSL https://pkg.jenkins.io/debian-stable/jenkins.io-2026.key -o /usr/share/keyrings/jenkins-keyring.asc
echo "deb [signed-by=/usr/share/keyrings/jenkins-keyring.asc] https://pkg.jenkins.io/debian-stable binary/" \
  > /etc/apt/sources.list.d/jenkins.list
apt-get update -y && apt-get install -y jenkins
usermod -aG docker jenkins
systemctl enable --now jenkins && systemctl restart jenkins

echo ">> Node.js 22 LTS"
command -v node >/dev/null && node -v | grep -q '^v22' || \
  { curl -fsSL https://deb.nodesource.com/setup_22.x | bash - && apt-get install -y nodejs; }

echo ">> Trivy"
curl -sfL https://raw.githubusercontent.com/aquasecurity/trivy/main/contrib/install.sh | sh -s -- -b /usr/local/bin
trivy --version | head -1

echo ">> AWS CLI v2, kubectl, helm, eksctl"
curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscli.zip
unzip -qo /tmp/awscli.zip -d /tmp && /tmp/aws/install --update
curl -fsSLo /usr/local/bin/kubectl "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
chmod +x /usr/local/bin/kubectl
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
curl -fsSL "https://github.com/eksctl-io/eksctl/releases/latest/download/eksctl_Linux_amd64.tar.gz" | tar xz -C /usr/local/bin
aws --version && kubectl version --client && helm version --short

echo ">> SonarQube + Nexus containers"
sysctl -w vm.max_map_count=524288 && echo 'vm.max_map_count=524288' > /etc/sysctl.d/99-sonarqube.conf
docker volume create sonarqube_data >/dev/null; docker volume create nexus-data >/dev/null
docker inspect sonarqube >/dev/null 2>&1 || docker run -d --name sonarqube --restart unless-stopped -p 9000:9000 \
  -e SONAR_VALIDATEWEBHOOKS=false -v sonarqube_data:/opt/sonarqube/data sonarqube:community
docker inspect nexus >/dev/null 2>&1 || docker run -d --name nexus --restart unless-stopped -p 8081:8081 -p 8083:8083 \
  -v nexus-data:/nexus-data sonatype/nexus3:latest
touch /var/log/blogapp-setup.done

echo
echo "================ CI/CD server ready ================"
echo "Jenkins   : http://${PUBLIC_IP}:8080   initial password: $(cat /var/lib/jenkins/secrets/initialAdminPassword 2>/dev/null || echo 'see /var/lib/jenkins/secrets/initialAdminPassword')"
echo "SonarQube : http://${PUBLIC_IP}:9000   admin / admin (forced change on first login)"
echo "Nexus     : http://${PUBLIC_IP}:8081   admin / password in: docker exec nexus cat /nexus-data/admin.password"
echo "           (Nexus takes 2-3 minutes to start)"
echo "Next: sudo bash infra/configure-cicd.sh"
