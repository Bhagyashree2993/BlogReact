# Setup Runbook — From Zero to a Live Blog on EKS

Follow these steps in order. Region used throughout: **ap-south-1 (Mumbai)** — change
`AWS_REGION` in the `Jenkinsfile` and `infra/*.yaml|sh` if you use another one.

## Fastest path: one command
After step 0 (tools + `aws configure`), this builds everything below, runs the
pipeline and writes the evaluation evidence to `docs/evidence/` (~60–75 min, unattended):
```bash
./infra/bootstrap-all.sh
```
Tear everything down afterwards with `./infra/teardown.sh`. The manual steps follow.

| # | What | Time |
|---|------|------|
| 1 | Create the EKS cluster | ~20 min |
| 2 | Launch the CI/CD server (Jenkins + SonarQube + Nexus) | ~15 min |
| 3 | Configure Nexus | 5 min |
| 4 | Configure SonarQube | 5 min |
| 5 | Configure Jenkins (plugins, tools, credentials, job) | 15 min |
| 6 | Bootstrap the cluster add-ons & monitoring | 10 min |
| 7 | Run the pipeline and verify | 15 min |

---

## 0. Local prerequisites (your laptop)
`aws` CLI v2 (configured with an IAM user that can create EKS/EC2/IAM/ECR), `eksctl`,
`kubectl`, `helm`, `git`.

## 1. Create the EKS cluster
```bash
eksctl create cluster -f infra/eks-cluster.yaml
kubectl get nodes          # 3 nodes Ready
```
This enables OIDC, the EBS CSI driver (MySQL volume), metrics-server (HPA),
VPC CNI network policies, and an IRSA service account for the AWS Load Balancer Controller.

## 2. Launch the CI/CD server
1. EC2 → Launch instance: **Ubuntu 24.04, t3.large, 50 GB gp3** (4 GB swap is added by the setup script).
2. Security group inbound: 22 (your IP), 8080, 9000, 8081, 8083 (your IP).
3. Attach an **IAM role** to the instance (recommended) with: `AmazonEC2ContainerRegistryPowerUser`
   and an inline policy allowing `eks:DescribeCluster`. Note its ARN.
4. SSH in, clone this repo, and run:
   ```bash
   sudo bash infra/setup-cicd-server.sh
   ```
   It prints the URLs and initial passwords for Jenkins, SonarQube and Nexus.

## 3–5. Configure Nexus, SonarQube and Jenkins — automated
One command does steps 3, 4 and 5 below (repos, realm, token, webhook, plugins,
the 6 credentials, the `blogapp-cicd` job) and starts the first build:
```bash
ssh -t -i ~/blogapp-key.pem ubuntu@<server-public-ip> \
  'cd /opt/BlogReact && sudo git pull && sudo bash infra/configure-cicd.sh'
```
It asks for the `blogapp-admin` AWS access key and prints the logins at the end
(also saved on the server in `/root/blogapp-credentials.txt`). The manual steps
below are kept for reference.

## 3. Configure Nexus (`http://<server-ip>:8081`)
1. Sign in as `admin` (password: `docker exec nexus cat /nexus-data/admin.password`), finish the wizard.
2. **Create repository → raw (hosted)** → name `blogapp-artifacts`.
3. **Create repository → docker (hosted)** → name `blogapp-docker`, tick **HTTP**, port **8083**.
4. **Security → Realms** → activate **Docker Bearer Token Realm**.
5. **Security → Users** → create `jenkins` with role `nx-admin` (or a scoped deploy role).
6. Nothing to edit: the `Jenkinsfile` reaches Nexus at `localhost`, since it runs on the same server as Jenkins.

## 4. Configure SonarQube (`http://<server-ip>:9000`)
1. Log in `admin/admin`, set a new password.
2. **My Account → Security → Generate token** (type: Global Analysis) — copy it.
3. **Administration → Configuration → Webhooks → Create**:
   URL `http://<server-private-ip>:8080/sonarqube-webhook/` (needed for the Quality Gate stage).
4. Optional: **Quality Gates** → customize "Sonar way" thresholds.

## 5. Configure Jenkins (`http://<server-ip>:8080`)
1. Unlock with the initial password, install suggested plugins, create the admin user.
2. **Manage Jenkins → Plugins → Available**, install:
   `SonarQube Scanner`, `Pipeline: AWS Steps`, `CloudBees AWS Credentials`,
   `Docker Pipeline`, `Pipeline Stage View`, `Workspace Cleanup`.
3. **Manage Jenkins → Tools → SonarQube Scanner installations** → Add, name **`sonar-scanner`**,
   "Install automatically".
4. **Manage Jenkins → System → SonarQube servers** → name **`sonarqube-server`**,
   URL `http://<server-private-ip>:9000`, token = credential `sonarqube-token` (below).
5. **Manage Jenkins → Credentials → Global** — add:

   | ID | Kind | Value |
   |---|---|---|
   | `sonarqube-token` | Secret text | SonarQube token from step 4 |
   | `nexus-creds` | Username with password | Nexus `jenkins` user |
   | `aws-creds` | AWS Credentials | Access key of an IAM user with ECR push + `eks:DescribeCluster` (if you used an instance role, still create it — keys can be for that role's user) |
   | `mysql-root-password` | Secret text | strong random string |
   | `mysql-app-password` | Secret text | strong random string |
   | `jwt-secret` | Secret text | `openssl rand -hex 32` |

6. **New Item → Pipeline** named `blogapp-cicd`:
   - *Build Triggers*: **GitHub hook trigger for GITScm polling**
   - *Pipeline*: **Pipeline script from SCM** → Git → `https://github.com/Vennilavanguvi/BlogReact.git`,
     branch `*/main`, script path `Jenkinsfile`.
7. GitHub repo → **Settings → Webhooks → Add**: `http://<server-public-ip>:8080/github-webhook/`,
   content type `application/json`, event "Just the push event".

## 6. Bootstrap the cluster (from your laptop)
Give the Jenkins identity cluster access and install the LB controller + monitoring:
```bash
JENKINS_ROLE_ARN=arn:aws:iam::<ACCOUNT_ID>:user/<jenkins-iam-user> ./infra/setup-eks-addons.sh
```
(Use the ARN of the IAM user behind `aws-creds`.)

Before the first run, commit a backend lock file so builds are reproducible:
```bash
cd backend && npm install && git add package-lock.json && git commit -m "Add backend lockfile" && git push
```

## 7. Run & verify
Click **Build Now** (or push a commit). Stages: Checkout → Install → Lint & Test → SonarQube →
Quality Gate → Trivy FS → Nexus artifacts → Docker build → Trivy image → Push (Nexus + ECR) →
Deploy to EKS → Deployment Validation.

Verify:
```bash
kubectl -n blogapp get pods,svc,hpa,ingress
kubectl -n blogapp get ingress blogapp-ingress -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
```
Open the ALB hostname in a browser — the "Marginal" blog loads with four seeded posts.
Register an account to publish your own posts.

**Evidence to capture for the project report**
- Jenkins Stage View (all green) — `Jenkins → blogapp-cicd`
- SonarQube project dashboard + passed Quality Gate
- Trivy reports — archived on each build (`trivy-*.txt`)
- Nexus → Browse → `blogapp-artifacts/blogapp/<tag>/` and `blogapp-docker` images
- ECR repositories with image tags
- `kubectl get all -n blogapp`, the live site via the ALB
- Grafana → Dashboards → **BlogApp – Three-Tier Overview**; Prometheus → Alerts (`blogapp.rules`)

### Monitoring access
```bash
kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80   # http://localhost:3000, admin / CHANGE_ME
kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090   # http://localhost:9090
```
Generate some traffic (`for i in $(seq 200); do curl -s http://<ALB>/api/posts >/dev/null; done`)
to see request rate and latency move on the dashboard.

## Troubleshooting
| Symptom | Fix |
|---|---|
| Quality Gate stage hangs | SonarQube webhook to Jenkins missing or wrong URL (step 4.3) |
| `docker push` to Nexus: "server gave HTTP response to HTTPS client" | Server IP not in `/etc/docker/daemon.json` `insecure-registries`; restart docker |
| `kubectl` "You must be logged in" in Jenkins | Run step 6 with the correct `JENKINS_ROLE_ARN` |
| `no matches for kind ServiceMonitor` | kube-prometheus-stack not installed — rerun step 6 |
| MySQL pod `Pending` | EBS CSI driver add-on missing / PVC not bound: `kubectl -n blogapp describe pvc` |
| Ingress has no ADDRESS | LB controller logs: `kubectl -n kube-system logs deploy/aws-load-balancer-controller` |
| Trivy fails the build | Read `trivy-*-report.txt`; bump the vulnerable package or base image, rebuild |
| Changed DB password but backend can't connect | MySQL only reads credentials on first init of an empty volume — rotate the user inside MySQL, or delete the PVC in non-prod |

## Teardown (avoid AWS charges)
```bash
kubectl delete -k k8s/                       # removes the ALB
helm -n monitoring uninstall kube-prometheus-stack
eksctl delete cluster -f infra/eks-cluster.yaml
# Delete retained EBS volumes (StorageClass reclaimPolicy: Retain) in EC2 → Volumes,
# the ECR repos, and terminate the CI/CD EC2 instance.
```
