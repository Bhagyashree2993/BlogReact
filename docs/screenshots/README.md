# Project Evidence — Screenshots

Save each screenshot in this folder using the file name below, then push to GitHub.
(Windows: press **Win + Shift + S**, select the area, then paste into Paint and save as PNG,
or use the Snipping Tool's save button.)

| # | File name | What to capture |
|---|-----------|-----------------|
| 1 | `01-github-repo.png` | GitHub repo page showing the code and the merged pull request |
| 2 | `02-jenkins-stage-view.png` | Jenkins → blogapp-cicd → Stage View with all stages green |
| 3 | `03-jenkins-console-live-url.png` | End of the build log showing `Application is live at: http://...` |
| 4 | `04-sonarqube-quality-gate.png` | SonarQube → blogapp project with the Quality Gate **Passed** |
| 5 | `05-trivy-report.png` | Jenkins build → Build Artifacts → a `trivy-*-report.txt` opened |
| 6 | `06-nexus-artifacts.png` | Nexus → Browse → `blogapp-artifacts` (backend, frontend, db files) |
| 7 | `07-nexus-docker.png` | Nexus → Browse → `blogapp-docker` (both images) |
| 8 | `08-ecr-repositories.png` | AWS console → ECR → `blogapp-backend` / `blogapp-frontend` with tags |
| 9 | `09-eks-cluster.png` | AWS console → EKS → `blogapp-eks-cluster` (Active, 2 nodes) |
| 10 | `10-kubectl-get-all.png` | Git Bash output of `kubectl get all -n blogapp` |
| 11 | `11-blog-home.png` | The live blog home page through the ALB address |
| 12 | `12-blog-new-post.png` | A post you published after registering (proves frontend → backend → DB) |
| 13 | `13-grafana-dashboard.png` | Grafana → **BlogApp – Three-Tier Overview** with live graphs |
| 14 | `14-prometheus-alerts.png` | Prometheus → Alerts showing the `blogapp.rules` group |

> **Before saving, check that no password, access key or token is visible** in any screenshot.
> Crop or blur it out if so.
