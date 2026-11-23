// =============================================================================
// Pipeline CI/CD de Shape Popper
//   1. Checkout            -> clona el repositorio
//   2. Seguridad del código -> Semgrep (SAST) y Snyk (dependencias), en paralelo
//   3. Build y tests       -> npm ci + tests (reporte JUnit)
//   4. Imagen Docker       -> build + Trivy (corta si hay CRITICAL) + publicación
//   5. Deploy con Helm     -> Blue/Green en Kubernetes (ver ci/deploy.sh)
// Si Semgrep, Snyk o Trivy encuentran problemas críticos, el pipeline se
// detiene en esa etapa, informa el motivo y no construye ni despliega nada.
// Las herramientas vienen instaladas en la imagen de Jenkins (jenkins/Dockerfile).
// =============================================================================
pipeline {
    agent any

    options {
        skipDefaultCheckout(true)      // el checkout es una etapa explícita (1)
        timestamps()
        ansiColor('xterm')
        timeout(time: 40, unit: 'MINUTES')
        disableConcurrentBuilds()      // dos despliegues simultáneos se pisarían
        buildDiscarder(logRotator(numToKeepStr: '20'))
    }

    parameters {
        choice(name: 'DEPLOY_ENV', choices: ['prod', 'dev'],
               description: 'prod: release "shape-game" (namespace default, Blue/Green). dev: release "shape-game-dev" (namespace shape-dev).')
        booleanParam(name: 'PUBLISH_IMAGE', defaultValue: false,
               description: 'true: publica la imagen en ghcr.io (credencial "ghcr"). false: la carga directo en minikube, sin registry.')
        booleanParam(name: 'SWITCH_TRAFFIC', defaultValue: true,
               description: 'Solo prod: pasar el tráfico a green después del smoke test.')
    }

    triggers {
        // GitHub no puede avisarle a un Jenkins local (sin webhook): se revisa el repo cada 5 min
        pollSCM('H/5 * * * *')
    }

    environment {
        APP_NAME     = 'shape-game'
        REGISTRY     = 'ghcr.io/santmacedonio'
        REPORTS      = 'reports/ci'
        SEMGREP_CONFIGS = '--config p/javascript --config p/nodejs --config p/expressjs --config p/xss --config p/owasp-top-ten --config p/security-audit --config p/secrets --config p/dockerfile --config p/kubernetes'
        npm_config_cache = "${WORKSPACE}/.npm-cache"
    }

    stages {
        stage('1. Checkout') {
            steps {
                script { env.CURRENT_STAGE = env.STAGE_NAME }
                checkout scm
                sh '''
                    echo "Repositorio clonado:"
                    git log -1 --format="  Commit:  %H%n  Autor:   %an%n  Fecha:   %ad%n  Mensaje: %s"
                    mkdir -p "$REPORTS"
                '''
                script {
                    def shortSha = sh(returnStdout: true, script: 'git rev-parse --short HEAD').trim()
                    def version  = sh(returnStdout: true, script: "node -p \"require('./package.json').version\"").trim()
                    // Tag inmutable y rastreable: versión-build-commit (nunca "latest")
                    env.IMAGE_TAG  = "${version}-${env.BUILD_NUMBER}-${shortSha}"
                    env.IMAGE_REPO = params.PUBLISH_IMAGE ? "${env.REGISTRY}/${env.APP_NAME}" : env.APP_NAME
                    currentBuild.displayName = "#${env.BUILD_NUMBER} ${env.IMAGE_TAG} (${params.DEPLOY_ENV})"
                    echo "Imagen a construir: ${env.IMAGE_REPO}:${env.IMAGE_TAG}"
                }
            }
        }

        stage('2. Seguridad del código') {
            parallel {
                stage('Semgrep (SAST)') {
                    steps {
                        script { env.CURRENT_STAGE = 'Semgrep (SAST)' }
                        sh '''
                            semgrep --version
                            semgrep scan $SEMGREP_CONFIGS --metrics=off --no-git-ignore \
                                --exclude node_modules --exclude reports --exclude .npm-cache \
                                --exclude k8s/security/tests \
                                --json-output="$REPORTS/semgrep.json" --text-output="$REPORTS/semgrep.txt"
                        '''
                        // Corta el pipeline si hay hallazgos de severidad ERROR
                        sh 'node ci/semgrep-gate.js "$REPORTS/semgrep.json"'
                    }
                }
                stage('Snyk (dependencias)') {
                    steps {
                        script {
                            env.CURRENT_STAGE = 'Snyk (dependencias)'
                            withCredentials([string(credentialsId: 'snyk-token', variable: 'SNYK_TOKEN')]) {
                                // Códigos de salida: 0 = OK, 1 = vulnerabilidades >= umbral, 2/3 = error de Snyk
                                def rc = sh(returnStatus: true, script: '''
                                    snyk --version
                                    snyk test --severity-threshold=critical --json-file-output="$REPORTS/snyk.json"
                                ''')
                                sh 'node ci/snyk-summary.js "$REPORTS/snyk.json"'
                                if (rc == 1) {
                                    error('Snyk encontró vulnerabilidades CRÍTICAS en las dependencias: el pipeline se detiene (ver el detalle arriba y reports/ci/snyk.json).')
                                } else if (rc != 0) {
                                    error("Snyk no pudo completar el análisis (código ${rc}). ¿Está configurado SNYK_TOKEN en .env.jenkins?")
                                }
                            }
                        }
                    }
                }
            }
        }

        stage('3. Build y tests') {
            steps {
                script { env.CURRENT_STAGE = env.STAGE_NAME }
                sh '''
                    node --version
                    npm ci --no-audit --no-fund
                    npm run test:ci
                '''
            }
            post {
                always {
                    junit allowEmptyResults: true, testResults: 'reports/tests/junit.xml'
                }
            }
        }

        stage('4. Imagen Docker') {
            steps {
                script { env.CURRENT_STAGE = env.STAGE_NAME }
                sh '''
                    docker build \
                        --label org.opencontainers.image.revision="$(git rev-parse HEAD)" \
                        --label org.opencontainers.image.created="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
                        --label org.opencontainers.image.source="https://github.com/SantMacedonio/DevOps1" \
                        --label org.opencontainers.image.version="$IMAGE_TAG" \
                        -t "$IMAGE_REPO:$IMAGE_TAG" .
                    docker image ls "$IMAGE_REPO:$IMAGE_TAG"
                '''
                script {
                    // Reporte completo + corte si hay vulnerabilidades CRITICAL (antes de publicar)
                    sh 'trivy image --quiet --scanners vuln,secret --format table --output "$REPORTS/trivy.txt" "$IMAGE_REPO:$IMAGE_TAG" && cat "$REPORTS/trivy.txt"'
                    def rc = sh(returnStatus: true, script: 'trivy image --quiet --scanners vuln --severity CRITICAL --exit-code 1 "$IMAGE_REPO:$IMAGE_TAG"')
                    if (rc != 0) {
                        error('Trivy encontró vulnerabilidades CRÍTICAS en la imagen: no se publica ni se despliega (ver reports/ci/trivy.txt).')
                    }
                    if (params.PUBLISH_IMAGE) {
                        withCredentials([usernamePassword(credentialsId: 'ghcr', usernameVariable: 'GHCR_USER', passwordVariable: 'GHCR_TOKEN')]) {
                            sh '''
                                echo "$GHCR_TOKEN" | docker login ghcr.io -u "$GHCR_USER" --password-stdin
                                docker push "$IMAGE_REPO:$IMAGE_TAG"
                                docker logout ghcr.io
                            '''
                        }
                    } else {
                        // Modo local: equivale a "minikube image load" (sin registry)
                        sh '''
                            echo "PUBLISH_IMAGE=false: se carga la imagen directo en minikube (sin registry)"
                            docker save --platform linux/amd64 "$IMAGE_REPO:$IMAGE_TAG" | docker exec -i minikube ctr -n k8s.io images import -
                        '''
                    }
                }
            }
        }

        stage('5. Deploy con Helm') {
            steps {
                script { env.CURRENT_STAGE = env.STAGE_NAME }
                withCredentials([file(credentialsId: 'kubeconfig', variable: 'KUBECONFIG')]) {
                    withEnv(["DEPLOY_ENV=${params.DEPLOY_ENV}", "SWITCH_TRAFFIC=${params.SWITCH_TRAFFIC}"]) {
                        sh '''
                            helm version --short
                            kubectl version --client
                            bash ci/deploy.sh
                        '''
                    }
                }
            }
        }
    }

    post {
        always {
            archiveArtifacts artifacts: 'reports/ci/**, reports/tests/**', allowEmptyArchive: true
            // La imagen ya está en el registry o en minikube: se libera espacio en Docker
            sh 'docker image rm "$IMAGE_REPO:$IMAGE_TAG" > /dev/null 2>&1 || true'
        }
        success {
            echo "[OK] Pipeline completo: ${env.IMAGE_REPO}:${env.IMAGE_TAG} desplegada en ${params.DEPLOY_ENV}"
        }
        failure {
            echo "[X] Pipeline DETENIDO en la etapa '${env.CURRENT_STAGE}'. Ver el log de esa etapa y los reportes archivados (reports/ci/)."
        }
        cleanup {
            cleanWs(deleteDirs: true, notFailBuild: true)
        }
    }
}
