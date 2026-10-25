# Marginal — Blog App on EKS (CI/CD Reference Project)

A production-style 3-tier blog application — **React frontend, Node.js/Express backend,
MySQL database** — deployed to **Amazon EKS** through a Jenkins pipeline that runs
**SonarQube** (code quality), **Nexus** (artifact storage), **Trivy** (container scanning),
and ships with **Prometheus/Grafana** monitoring hooks.

## Architecture

```
                         ┌────────────────────────┐
 Browser ── HTTPS ──▶    │   ALB Ingress (EKS)     │
                         └───────────┬─────────────┘
                     ┌───────────────┴───────────────┐
                     ▼                                ▼
          ┌─────────────────────┐          ┌─────────────────────┐
          │ frontend-service     │  /api → │ backend-service      │
          │ (nginx + React SPA)  │────────▶│ (Node/Express API)   │
          │ 3+ pods, HPA         │          │ 3+ pods, HPA          │
          └─────────────────────┘          └──────────┬───────────┘
                                                        ▼
                                            ┌─────────────────────┐
                                            │ mysql StatefulSet    │
                                            │ + EBS gp3 volume     │
                                            └─────────────────────┘

CI/CD:  GitHub push → Jenkins → npm test (Jest) → SonarQube + Quality Gate →
        Trivy FS scan → artifacts to Nexus (raw) → docker build → Trivy image scan
        (fails on fixable CRITICAL/HIGH) → push to Nexus docker + ECR →
        kubectl apply -k (EKS) → rollout status → in-cluster + ALB smoke tests
        → auto rollback on failure

Monitoring: Prometheus Operator scrapes backend /metrics via ServiceMonitor,
            PrometheusRule alerts on 5xx rate / crash loops / DB down,
            Grafana dashboards on top (bring your own kube-prometheus-stack).
```

## Repository layout

```
BlogReact/
├── frontend/                React (Vite) SPA → nginx-unprivileged image (:8080, /healthz, /api proxy)
├── backend/                 Express API, MySQL, JWT auth, /healthz /readyz /metrics
│   └── tests/               Jest + Supertest API tests (DB mocked) → coverage for SonarQube
├── database/init.sql        Schema + seed data
├── k8s/
│   ├── base/                Namespace, encrypted gp3 StorageClass, ResourceQuota/LimitRange
│   ├── mysql/               StatefulSet + EBS volume, headless Service (secret created by pipeline)
│   ├── backend/             Deployment, Service, ConfigMap, HPA, PodDisruptionBudget
│   ├── frontend/            Deployment, Service, HPA, PodDisruptionBudget
│   ├── ingress/             AWS ALB Ingress
│   ├── security/            NetworkPolicies (frontend → backend → mysql only)
│   ├── monitoring/          ServiceMonitor, PrometheusRule alerts, Grafana dashboard, Helm values
│   └── kustomization.yaml   `kubectl apply -k k8s/`
├── infra/
│   ├── eks-cluster.yaml     eksctl cluster definition (OIDC, EBS CSI, metrics-server, netpol)
│   ├── setup-cicd-server.sh One-shot EC2 bootstrap: Jenkins, SonarQube, Nexus, Trivy, CLIs
│   └── setup-eks-addons.sh  LB controller, kube-prometheus-stack, ECR repos, Jenkins access
├── docs/SETUP.md            Step-by-step runbook (start here)
├── Jenkinsfile              Full CI/CD pipeline
├── sonar-project.properties SonarQube project config
└── docker-compose.yml       Local dev: mysql + backend + frontend
```

**Start here → [`docs/SETUP.md`](docs/SETUP.md)** for the end-to-end setup.

## Run it locally first

```bash
docker compose up --build
# frontend  → http://localhost:3000
# backend   → http://localhost:5000/healthz
# mysql     → localhost:3306 (bloguser / changeme)
```

The seed data ships four demo posts; register a new account to write your own entries.

## Deploying manually (what the pipeline automates)

```bash
aws eks update-kubeconfig --name blogapp-eks-cluster --region ap-south-1

# Load the real schema into the init ConfigMap
kubectl apply -f k8s/base/namespace.yaml
kubectl -n blogapp create secret generic mysql-secret --from-literal=MYSQL_ROOT_PASSWORD=<root> \
  --from-literal=MYSQL_USER=bloguser --from-literal=MYSQL_PASSWORD=<app>
kubectl -n blogapp create secret generic backend-secret --from-literal=JWT_SECRET=$(openssl rand -hex 32)

# Load the real schema into the init ConfigMap
kubectl create configmap mysql-init-script \
  --from-file=init.sql=database/init.sql -n blogapp \
  --dry-run=client -o yaml | kubectl apply -f -

# Build & push images
docker build -t <ECR_REGISTRY>/blogapp-backend:v1 ./backend
docker build -t <ECR_REGISTRY>/blogapp-frontend:v1 ./frontend
trivy image --severity CRITICAL,HIGH <ECR_REGISTRY>/blogapp-backend:v1
docker push <ECR_REGISTRY>/blogapp-backend:v1
docker push <ECR_REGISTRY>/blogapp-frontend:v1

# Point kustomize at the images you just pushed, then apply
sed -i -e "s#newName: ECR_REGISTRY/#newName: <ECR_REGISTRY>/#" -e "s#newTag: latest#newTag: v1#" k8s/kustomization.yaml
kubectl apply -k k8s/
kubectl rollout status deployment/backend -n blogapp
kubectl rollout status deployment/frontend -n blogapp
kubectl get ingress blogapp-ingress -n blogapp
```

## Secrets

No secrets live in git. The pipeline creates `mysql-secret` and `backend-secret` from Jenkins
credentials (`mysql-root-password`, `mysql-app-password`, `jwt-secret`) on every deploy.
`k8s/mysql/secret.example.yaml` shows the shape. For a hardened setup, move them to AWS
Secrets Manager + External Secrets Operator.

## What each tool is doing in the pipeline

| Stage | Tool | Purpose |
|---|---|---|
| Static analysis | **SonarQube** | Code smells, bugs, coverage, quality gate blocks bad merges |
| Artifact storage | **Nexus** | Versioned backend package, frontend bundle and DB script (raw repo) + Docker images (docker-hosted repo) |
| Image scanning | **Trivy** | Fails the build on CRITICAL/HIGH CVEs in either image, plus a filesystem/dependency scan |
| Registry | **ECR** | Stores the scanned, tagged images the cluster pulls from |
| Deploy | **kubectl + kustomize** | Applies the full manifest set to EKS, waits for rollout health |
| Validation | **kubectl + curl** | Rollout status, in-cluster smoke test of every tier, public ALB check, automatic `rollout undo` on failure |
| Monitoring | **Prometheus + Grafana** | Scrapes `/metrics`, alerts on error rate / latency / crash loops / DB / disk, pre-built Grafana dashboard |

## Frontend design notes

The UI ("Marginal") is a custom-built design system, not a component-library
default: a paper-grain background, Fraunces/Inter/IBM Plex Mono type pairing,
moss-and-rust accent ink, and a signature **reading-spine** scroll-progress
ruler on article pages. All tokens live in `frontend/src/index.css`.
