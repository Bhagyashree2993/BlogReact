// =====================================================================
//  BlogApp (Marginal) – Production CI/CD pipeline for Amazon EKS
//
//  GitHub → Install → Lint & Test → SonarQube + Quality Gate → Trivy FS
//         → Package & publish artifacts to Nexus → Docker build
//         → Trivy image scan → Push images (Nexus + ECR) → Deploy to EKS
//         → Deployment validation (auto-rollback on failure) → Monitoring
//
//  Jenkins prerequisites (see docs/SETUP.md):
//    Plugins : Pipeline, Git, Credentials Binding, SonarQube Scanner,
//              Pipeline: AWS Steps (or CloudBees AWS Credentials), Workspace Cleanup
//    Tools   : SonarQube Scanner tool named "sonar-scanner"
//    Server  : SonarQube server config named "sonarqube-server" + webhook
//              http://<jenkins>/sonarqube-webhook/ on the SonarQube side
//    Creds   : aws-creds (AWS), nexus-creds (user/pass),
//              mysql-root-password, mysql-app-password, jwt-secret (secret text)
// =====================================================================

pipeline {
    agent any

    options {
        timestamps()
        disableConcurrentBuilds()
        buildDiscarder(logRotator(numToKeepStr: '20'))
        timeout(time: 60, unit: 'MINUTES')
    }

    parameters {
        booleanParam(name: 'SKIP_DEPLOY', defaultValue: false, description: 'Run CI only (no EKS deploy)')
        choice(name: 'TRIVY_SEVERITY', choices: ['CRITICAL,HIGH', 'CRITICAL'], description: 'Severities that fail the build')
    }

    environment {
        AWS_REGION      = 'ap-south-1'
        CLUSTER_NAME    = 'blogapp-eks-cluster'
        K8S_NAMESPACE   = 'blogapp'

        // ---- Nexus (change to your Nexus host) ----
        NEXUS_URL       = 'http://NEXUS_HOST:8081'          // web UI / raw + npm repos
        NEXUS_DOCKER    = 'NEXUS_HOST:8083'                 // docker-hosted connector
        NEXUS_RAW_REPO  = 'blogapp-artifacts'               // raw (hosted) repository

        BACKEND_IMAGE   = 'blogapp-backend'
        FRONTEND_IMAGE  = 'blogapp-frontend'
        SCANNER_HOME    = tool 'sonar-scanner'
    }

    stages {

        stage('Checkout') {
            steps {
                checkout scm
                script {
                    env.GIT_SHORT = sh(script: 'git rev-parse --short HEAD', returnStdout: true).trim()
                    env.IMAGE_TAG = "${env.BUILD_NUMBER}-${env.GIT_SHORT}"
                    currentBuild.displayName = "#${env.BUILD_NUMBER} (${env.GIT_SHORT})"
                }
                echo "Image tag for this build: ${IMAGE_TAG}"
            }
        }

        stage('Install Dependencies') {
            parallel {
                stage('Backend') {
                    steps {
                        dir('backend') {
                            sh '[ -f package-lock.json ] && npm ci || npm install'
                        }
                    }
                }
                stage('Frontend') {
                    steps {
                        dir('frontend') { sh 'npm ci' }
                    }
                }
            }
        }

        stage('Lint & Unit Test') {
            parallel {
                stage('Backend tests') {
                    steps {
                        dir('backend') {
                            sh 'npm run lint || true'     // lint is advisory; SonarQube gates quality
                            sh 'npm test'                 // produces coverage/lcov.info for SonarQube
                        }
                    }
                }
                stage('Frontend build check') {
                    steps {
                        dir('frontend') {
                            sh 'npm run lint || true'
                            sh 'npm run build'
                        }
                    }
                }
            }
        }

        stage('SonarQube Analysis') {
            steps {
                withSonarQubeEnv('sonarqube-server') {
                    sh """
                        ${SCANNER_HOME}/bin/sonar-scanner \
                          -Dsonar.projectVersion=${IMAGE_TAG}
                    """
                }
            }
        }

        stage('Quality Gate') {
            steps {
                timeout(time: 10, unit: 'MINUTES') {
                    waitForQualityGate abortPipeline: true
                }
            }
        }

        stage('Trivy Filesystem Scan') {
            steps {
                // Full report (deps, leaked secrets, Dockerfile/K8s misconfig) is archived;
                // the build is gated on fixable dependency CVEs and leaked secrets.
                sh """
                    trivy fs --scanners vuln,secret,misconfig --severity ${params.TRIVY_SEVERITY},MEDIUM \
                      --exit-code 0 --format table -o trivy-fs-report.txt .
                    trivy fs --scanners vuln,secret --severity ${params.TRIVY_SEVERITY} \
                      --ignore-unfixed --exit-code 1 .
                """
            }
        }

        stage('Package & Publish Artifacts to Nexus') {
            steps {
                sh """
                    mkdir -p dist-artifacts
                    (cd backend && npm pack --pack-destination ../dist-artifacts)
                    tar -czf dist-artifacts/blogapp-frontend-${IMAGE_TAG}.tar.gz -C frontend/dist .
                    mv dist-artifacts/blogapp-backend-*.tgz dist-artifacts/blogapp-backend-${IMAGE_TAG}.tgz
                    cp database/init.sql dist-artifacts/blogapp-db-init-${IMAGE_TAG}.sql
                    ls -lh dist-artifacts
                """
                withCredentials([usernamePassword(credentialsId: 'nexus-creds',
                                                  usernameVariable: 'NEXUS_USER',
                                                  passwordVariable: 'NEXUS_PASS')]) {
                    sh '''
                        for f in dist-artifacts/*; do
                          echo "Uploading $(basename "$f")"
                          curl -fsS -u "$NEXUS_USER:$NEXUS_PASS" --upload-file "$f" \
                            "$NEXUS_URL/repository/$NEXUS_RAW_REPO/blogapp/$IMAGE_TAG/$(basename "$f")"
                        done
                    '''
                }
            }
        }

        stage('Docker Build') {
            parallel {
                stage('Backend image') {
                    steps {
                        sh "docker build --pull -t ${BACKEND_IMAGE}:${IMAGE_TAG} " +
                           "--label org.opencontainers.image.revision=${GIT_SHORT} ./backend"
                    }
                }
                stage('Frontend image') {
                    steps {
                        sh "docker build --pull -t ${FRONTEND_IMAGE}:${IMAGE_TAG} " +
                           "--label org.opencontainers.image.revision=${GIT_SHORT} ./frontend"
                    }
                }
            }
        }

        stage('Trivy Image Scan') {
            steps {
                script {
                    [env.BACKEND_IMAGE, env.FRONTEND_IMAGE].each { img ->
                        sh """
                            trivy image --severity ${params.TRIVY_SEVERITY},MEDIUM --exit-code 0 \
                              --format table -o trivy-${img}-report.txt ${img}:${IMAGE_TAG}
                            trivy image --severity ${params.TRIVY_SEVERITY} --ignore-unfixed \
                              --exit-code 1 ${img}:${IMAGE_TAG}
                        """
                    }
                }
            }
        }

        stage('Push Images') {
            parallel {
                stage('Push to Nexus registry') {
                    steps {
                        withCredentials([usernamePassword(credentialsId: 'nexus-creds',
                                                          usernameVariable: 'NEXUS_USER',
                                                          passwordVariable: 'NEXUS_PASS')]) {
                            sh '''
                                echo "$NEXUS_PASS" | docker login "$NEXUS_DOCKER" -u "$NEXUS_USER" --password-stdin
                                for img in "$BACKEND_IMAGE" "$FRONTEND_IMAGE"; do
                                  docker tag "$img:$IMAGE_TAG" "$NEXUS_DOCKER/$img:$IMAGE_TAG"
                                  docker push "$NEXUS_DOCKER/$img:$IMAGE_TAG"
                                done
                                docker logout "$NEXUS_DOCKER"
                            '''
                        }
                    }
                }
                stage('Push to Amazon ECR') {
                    steps {
                        withCredentials([[$class: 'AmazonWebServicesCredentialsBinding', credentialsId: 'aws-creds']]) {
                            script {
                                def account = sh(script: 'aws sts get-caller-identity --query Account --output text',
                                                 returnStdout: true).trim()
                                env.ECR_REGISTRY = "${account}.dkr.ecr.${env.AWS_REGION}.amazonaws.com"
                            }
                            sh '''
                                aws ecr get-login-password --region "$AWS_REGION" | \
                                  docker login --username AWS --password-stdin "$ECR_REGISTRY"
                                for img in "$BACKEND_IMAGE" "$FRONTEND_IMAGE"; do
                                  aws ecr describe-repositories --repository-names "$img" --region "$AWS_REGION" >/dev/null 2>&1 || \
                                    aws ecr create-repository --repository-name "$img" --region "$AWS_REGION" \
                                      --image-scanning-configuration scanOnPush=true --image-tag-mutability IMMUTABLE
                                  docker tag "$img:$IMAGE_TAG" "$ECR_REGISTRY/$img:$IMAGE_TAG"
                                  docker push "$ECR_REGISTRY/$img:$IMAGE_TAG"
                                done
                            '''
                        }
                    }
                }
            }
        }

        stage('Deploy to EKS') {
            when { expression { !params.SKIP_DEPLOY } }
            steps {
                withCredentials([
                    [$class: 'AmazonWebServicesCredentialsBinding', credentialsId: 'aws-creds'],
                    string(credentialsId: 'mysql-root-password', variable: 'MYSQL_ROOT_PASSWORD'),
                    string(credentialsId: 'mysql-app-password',  variable: 'MYSQL_APP_PASSWORD'),
                    string(credentialsId: 'jwt-secret',          variable: 'JWT_SECRET')
                ]) {
                    sh '''
                        set -e
                        aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$AWS_REGION"

                        # Namespace first so the secrets/configmap have somewhere to live
                        kubectl apply -f k8s/base/namespace.yaml

                        # Secrets come from the Jenkins credential store - never from git
                        kubectl -n "$K8S_NAMESPACE" create secret generic mysql-secret \
                          --from-literal=MYSQL_ROOT_PASSWORD="$MYSQL_ROOT_PASSWORD" \
                          --from-literal=MYSQL_USER=bloguser \
                          --from-literal=MYSQL_PASSWORD="$MYSQL_APP_PASSWORD" \
                          --dry-run=client -o yaml | kubectl apply -f -
                        kubectl -n "$K8S_NAMESPACE" create secret generic backend-secret \
                          --from-literal=JWT_SECRET="$JWT_SECRET" \
                          --dry-run=client -o yaml | kubectl apply -f -

                        # Database schema + seed (only runs on first MySQL boot / empty volume)
                        kubectl -n "$K8S_NAMESPACE" create configmap mysql-init-script \
                          --from-file=init.sql=database/init.sql \
                          --dry-run=client -o yaml | kubectl apply -f -

                        # Point kustomize at the images built in this run
                        sed -i \
                          -e "s#newName: ECR_REGISTRY/#newName: $ECR_REGISTRY/#" \
                          -e "s#newTag: latest#newTag: $IMAGE_TAG#" \
                          k8s/kustomization.yaml
                        kubectl kustomize k8s/ > rendered-manifests.yaml
                        kubectl apply -k k8s/

                        kubectl -n "$K8S_NAMESPACE" rollout status statefulset/mysql   --timeout=300s
                        kubectl -n "$K8S_NAMESPACE" rollout status deployment/backend  --timeout=300s
                        kubectl -n "$K8S_NAMESPACE" rollout status deployment/frontend --timeout=300s
                    '''
                }
            }
            post {
                failure {
                    withCredentials([[$class: 'AmazonWebServicesCredentialsBinding', credentialsId: 'aws-creds']]) {
                        sh '''
                            echo "Rollout failed - rolling back to previous revision"
                            kubectl -n "$K8S_NAMESPACE" rollout undo deployment/backend  || true
                            kubectl -n "$K8S_NAMESPACE" rollout undo deployment/frontend || true
                            kubectl -n "$K8S_NAMESPACE" get pods -o wide || true
                        '''
                    }
                }
            }
        }

        stage('Deployment Validation') {
            when { expression { !params.SKIP_DEPLOY } }
            steps {
                withCredentials([[$class: 'AmazonWebServicesCredentialsBinding', credentialsId: 'aws-creds']]) {
                    sh '''
                        set -e
                        echo "--- Running pods ---"
                        kubectl -n "$K8S_NAMESPACE" get pods,svc,hpa,ingress

                        echo "--- In-cluster smoke tests ---"
                        kubectl -n "$K8S_NAMESPACE" run smoke-$BUILD_NUMBER --rm -i --restart=Never \
                          --image=curlimages/curl:8.10.1 --labels=role=smoke-test -- sh -c '
                            set -e
                            curl -fsS http://frontend-service/healthz && echo " frontend OK"
                            curl -fsS http://backend-service:5000/healthz && echo " backend live"
                            curl -fsS http://backend-service:5000/readyz  && echo " backend ready (DB reachable)"
                            curl -fsS "http://frontend-service/api/posts?limit=1" | grep -q "\\"data\\"" && echo "frontend -> backend -> DB path OK"
                          '

                        echo "--- Public ALB check ---"
                        for i in $(seq 1 30); do
                          ALB=$(kubectl -n "$K8S_NAMESPACE" get ingress blogapp-ingress \
                                -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
                          if [ -n "$ALB" ] && curl -fsS -o /dev/null "http://$ALB/healthz"; then
                            echo "Application is live at: http://$ALB"
                            echo "http://$ALB" > app-url.txt
                            exit 0
                          fi
                          echo "Waiting for ALB ($i/30)..."; sleep 20
                        done
                        echo "WARNING: ALB not reachable yet (DNS can take a few minutes) - in-cluster checks passed"
                    '''
                }
            }
            post {
                failure {
                    withCredentials([[$class: 'AmazonWebServicesCredentialsBinding', credentialsId: 'aws-creds']]) {
                        sh '''
                            echo "Smoke tests failed - rolling back"
                            kubectl -n "$K8S_NAMESPACE" rollout undo deployment/backend  || true
                            kubectl -n "$K8S_NAMESPACE" rollout undo deployment/frontend || true
                        '''
                    }
                }
            }
        }
    }

    post {
        always {
            archiveArtifacts artifacts: 'trivy-*.txt, rendered-manifests.yaml, app-url.txt, dist-artifacts/*',
                             allowEmptyArchive: true
            sh '''
                docker rmi "$BACKEND_IMAGE:$IMAGE_TAG" "$FRONTEND_IMAGE:$IMAGE_TAG" 2>/dev/null || true
                docker image prune -f || true
            '''
            cleanWs()
        }
        success {
            echo "✅ Build ${IMAGE_TAG} deployed. Grafana dashboard: 'BlogApp – Three-Tier Overview'"
        }
        failure {
            echo "❌ Pipeline failed at build ${env.BUILD_NUMBER}. Check the stage logs and Trivy reports."
        }
    }
}
