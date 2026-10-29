# Project Evidence — Screenshots

**Most screenshots are taken automatically** of the live system by
`infra/capture-screenshots.sh` (run by `infra/bootstrap-all.sh`) and saved in
[`auto/`](auto/): Jenkins pipeline overview + stage view + console sections, the blog
pages, the three-tier API flow, MySQL, EKS, images, SonarQube, Trivy, Grafana and
Prometheus. Anything it could not capture is listed in `auto/MISSING.md`.

Only these are by hand (2 minutes):
- `B2-app-register.png` / `B3-app-new-post.png`: register in the browser and write a post
- `D1-eks-console.png`: AWS console → EKS → blogapp-eks-cluster → Resources

The full manual list below is kept for reference.

Text evidence for every area is generated automatically in [`docs/evidence/`](../evidence/)
by `infra/collect-evidence.sh`. The screenshots below show the same things visually.
Save each one here with the file name given, then push to GitHub.
(Windows: **Win + Shift + S** → select → paste into Paint → Save as PNG.)

## A. Jenkins pipeline — full view + console (reviewer request)
| File | What to capture |
|---|---|
| `A1-jenkins-pipeline-overview.png` | Build → **Pipeline Overview**: the full graph, every stage green |
| `A2-jenkins-stage-view.png` | Job page → **Stage View** (zoom out with Ctrl − so all stages fit) |
| `A3-jenkins-console-start.png` | Build → **Console Output**, top: checkout + tests |
| `A4-jenkins-console-sonar-trivy.png` | Console: Quality Gate passed + Trivy scan results |
| `A5-jenkins-console-deploy.png` | Console: `kubectl apply`, `rollout status ... successfully rolled out` |
| `A6-jenkins-console-end.png` | Console end: smoke tests OK, `Application is live at`, `Finished: SUCCESS` |
| `A7-jenkins-artifacts.png` | Build page → Build Artifacts (Trivy reports, eks-deployment-report.txt) |

## B. Application output — three-tier communication (reviewer request)
| File | What to capture |
|---|---|
| `B1-app-home.png` | Blog home page through the ALB address (address bar visible) |
| `B2-app-register.png` | Register page after creating an account |
| `B3-app-new-post.png` | Writing a new post (New Post page) |
| `B4-app-post-published.png` | The published post + a comment (frontend → backend → MySQL) |
| `B5-app-devtools-api.png` | Browser DevTools (F12) → Network → the `/api/posts` call with its JSON response |

## C. Database — StatefulSet, persistence, credentials, integration (reviewer request)
| File | What to capture |
|---|---|
| `C1-db-statefulset-pvc.png` | Terminal: `kubectl -n blogapp get sts,pod/mysql-0,pvc` |
| `C2-db-rows.png` | Terminal: the users/posts tables from `docs/evidence/08-database-mysql.txt` |
| `C3-db-persistence.png` | Terminal: the "Persistence test" section (same count after pod restart) |

## D. EKS deployment (reviewer request)
| File | What to capture |
|---|---|
| `D1-eks-console.png` | AWS console → EKS → blogapp-eks-cluster → Resources → Workloads |
| `D2-kubectl-get-all.png` | Terminal: `kubectl -n blogapp get all,ingress,hpa,pdb -o wide` |
| `D3-image-versions.png` | Terminal: image-versions table from `06-eks-deployment.txt` (tag = build number) |
| `D4-ecr-images.png` | AWS console → ECR → blogapp-backend with the same tag |

## E. Quality, security, monitoring
| File | What to capture |
|---|---|
| `E1-sonarqube.png` | SonarQube → blogapp: Quality Gate **Passed** |
| `E2-nexus-artifacts.png` | Nexus → Browse → blogapp-artifacts |
| `E3-nexus-docker.png` | Nexus → Browse → blogapp-docker |
| `E4-grafana-dashboard.png` | Grafana → BlogApp – Three-Tier Overview with traffic |
| `E5-prometheus-targets.png` | Prometheus → Status → Targets: backend endpoints UP |

> **Before saving, make sure no password, access key or token is visible.**
