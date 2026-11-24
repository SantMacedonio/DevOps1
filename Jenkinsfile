// =============================================================================
// Pipeline CI/CD de Shape Popper
//   1. Checkout            -> clona el repositorio
//   2. Seguridad del código -> Semgrep (SAST) y Snyk (dependencias), en paralelo
//   3. Build y tests       -> npm ci + tests (reporte JUnit)
//   4. Imagen Docker       -> build + Trivy (corta si hay CRITICAL o secretos) + publicación
//   5. Deploy con Helm     -> Blue/Green en Kubernetes (ver ci/deploy.sh)
// Si Semgrep, Snyk o Trivy encuentran problemas críticos, el pipeline se
// detiene en esa etapa, informa el motivo y no construye ni despliega nada.
// Las herramientas vienen instaladas en la imagen de Jenkins (jenkins/Dockerfile).
//
// La RAMA decide el entorno (job Multibranch, ver jenkins/casc.yaml):
//   main       -> publica la imagen en ghcr.io y despliega en PROD (Blue/Green)
//   feature/*  -> despliega en DEV (la imagen se carga directo en minikube)
//   otra rama  -> solo análisis, tests e imagen; no despliega
// Así, a prod solo llega código que pasó por un Pull Request a main.
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

    // No hay parámetro de entorno: lo decide la rama. Los builds automáticos
    // los lanza el job Multibranch al detectar commits nuevos (cada 5 minutos).
    parameters {
        booleanParam(name: 'PUBLISH_IMAGE', defaultValue: false,
               description: 'Solo ramas feature/*: publicar también la imagen en ghcr.io. En main siempre se publica.')
        booleanParam(name: 'SWITCH_TRAFFIC', defaultValue: true,
               description: 'Solo main (prod): pasar el tráfico al color nuevo (el que estaba inactivo) después del smoke test.')
    }

    environment {
        APP_NAME     = 'shape-game'
        REGISTRY     = 'ghcr.io/santmacedonio'
        REPORTS      = 'reports/ci'
        SEMGREP_CONFIGS = '--config p/javascript --config p/nodejs --config p/expressjs --config p/xss --config p/owasp-top-ten --config p/security-audit --config p/secrets --config p/dockerfile --config p/kubernetes --config semgrep/shape-popper.yaml'  // oficiales + reglas propias
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
                    // Entorno según la rama (BRANCH_NAME lo define el job Multibranch)
                    def branch = env.BRANCH_NAME ?: 'sin-rama'
                    env.DEPLOY_ENV = branch == 'main' ? 'prod' : (branch.startsWith('feature/') ? 'dev' : 'ninguno')
                    env.PUBLISH    = (branch == 'main' || params.PUBLISH_IMAGE) ? 'true' : 'false'
                    // Tag inmutable y rastreable: versión-rama-build-commit (nunca "latest").
                    // La rama evita que dos ramas con el mismo commit y número de build choquen.
                    def branchLabel = branch.replaceAll('[^A-Za-z0-9]+', '-').toLowerCase().take(40)
                    env.IMAGE_TAG  = "${version}-${branchLabel}-${env.BUILD_NUMBER}-${shortSha}"
                    env.IMAGE_REPO = env.PUBLISH == 'true' ? "${env.REGISTRY}/${env.APP_NAME}" : env.APP_NAME
                    currentBuild.displayName = "#${env.BUILD_NUMBER} ${shortSha} -> ${env.DEPLOY_ENV}"
                    echo "Rama: ${branch}  ->  entorno: ${env.DEPLOY_ENV}  |  publicar en ghcr.io: ${env.PUBLISH}"
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
                                --exclude k8s/security/tests --exclude semgrep/shape-popper.js \
                                --json-output="$REPORTS/semgrep.json" --text-output="$REPORTS/semgrep-report.txt"
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
                                // La línea "Organization:" muestra el usuario de Snyk: se filtra de la consola
                                def rc = sh(returnStatus: true, script: '''
                                    snyk --version
                                    rc=0
                                    snyk test --severity-threshold=critical --json-file-output="$REPORTS/snyk.json" > "$REPORTS/snyk.txt" 2>&1 || rc=$?
                                    grep -v '^Organization:' "$REPORTS/snyk.txt" | tee "$REPORTS/snyk.txt.tmp"
                                    mv "$REPORTS/snyk.txt.tmp" "$REPORTS/snyk.txt"
                                    exit $rc
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
                    # --pull --no-cache: siempre la base más reciente del tag y un "apk upgrade" real
                    # (con caché, esa capa se reutiliza y la imagen queda sin los últimos parches)
                    docker build --pull --no-cache \
                        --label org.opencontainers.image.revision="$(git rev-parse HEAD)" \
                        --label org.opencontainers.image.created="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
                        --label org.opencontainers.image.source="https://github.com/SantMacedonio/DevOps1" \
                        --label org.opencontainers.image.version="$IMAGE_TAG" \
                        -t "$IMAGE_REPO:$IMAGE_TAG" .
                    docker image ls "$IMAGE_REPO:$IMAGE_TAG"
                '''
                script {
                    // Trivy no deja que dos procesos usen su caché a la vez. Si corren dos builds
                    // juntos (por ejemplo, main y una rama feature), flock hace que el segundo
                    // espere su turno (hasta 10 minutos) en lugar de fallar.
                    // Reporte completo + corte si hay vulnerabilidades CRITICAL (antes de publicar)
                    sh 'flock -w 600 "$HOME/.cache/trivy.lock" trivy image --quiet --scanners vuln,secret --format table --output "$REPORTS/trivy.txt" "$IMAGE_REPO:$IMAGE_TAG" && cat "$REPORTS/trivy.txt"'
                    def rc = sh(returnStatus: true, script: 'flock -w 600 "$HOME/.cache/trivy.lock" trivy image --quiet --scanners vuln --severity CRITICAL --exit-code 1 "$IMAGE_REPO:$IMAGE_TAG"')
                    if (rc != 0) {
                        error('Trivy encontró vulnerabilidades CRÍTICAS en la imagen: no se publica ni se despliega (ver reports/ci/trivy.txt).')
                    }
                    // Corte por secretos (claves, tokens, contraseñas) de cualquier severidad:
                    // la imagen se publica en un registry público, así que nada sensible puede viajar adentro
                    rc = sh(returnStatus: true, script: 'flock -w 600 "$HOME/.cache/trivy.lock" trivy image --quiet --scanners secret --exit-code 1 "$IMAGE_REPO:$IMAGE_TAG"')
                    if (rc != 0) {
                        error('Trivy encontró SECRETOS dentro de la imagen: no se publica ni se despliega (ver el detalle arriba y reports/ci/trivy.txt).')
                    }
                    if (env.PUBLISH == 'true') {
                        withCredentials([usernamePassword(credentialsId: 'ghcr', usernameVariable: 'GHCR_USER', passwordVariable: 'GHCR_TOKEN')]) {
                            // El login se guarda en una carpeta temporal del workspace (no en el
                            // home de Jenkins) y se cierra y borra al salir, aunque el push falle.
                            // Si el build se cancela a la fuerza, cleanWs borra la carpeta igual.
                            sh '''
                                export DOCKER_CONFIG="$(mktemp -d -p "$WORKSPACE" .docker-ghcr.XXXXXX)"
                                trap 'docker logout ghcr.io > /dev/null 2>&1 || true; rm -rf "$DOCKER_CONFIG"' EXIT
                                echo "$GHCR_TOKEN" | docker login ghcr.io -u "$GHCR_USER" --password-stdin
                                docker push "$IMAGE_REPO:$IMAGE_TAG"
                            '''
                        }
                    } else {
                        // Modo local: equivale a "minikube image load" (sin registry)
                        sh '''
                            echo "Sin publicar: se carga la imagen directo en minikube (sin registry)"
                            docker save --platform linux/amd64 "$IMAGE_REPO:$IMAGE_TAG" | docker exec -i minikube ctr -n k8s.io images import -
                        '''
                    }
                }
            }
        }

        stage('5. Deploy con Helm') {
            // Solo main y feature/* despliegan; otras ramas terminan en la etapa 4
            when { expression { env.DEPLOY_ENV in ['prod', 'dev'] } }
            steps {
                script {
                    env.CURRENT_STAGE = env.STAGE_NAME
                    // Segunda barrera: aunque alguien edite este archivo en otra rama,
                    // a prod solo se despliega desde main
                    if (env.DEPLOY_ENV == 'prod' && env.BRANCH_NAME != 'main') {
                        error("Solo la rama main puede desplegar en prod (rama actual: ${env.BRANCH_NAME}).")
                    }
                }
                withCredentials([file(credentialsId: 'kubeconfig', variable: 'KUBECONFIG')]) {
                    withEnv(["SWITCH_TRAFFIC=${params.SWITCH_TRAFFIC}"]) {
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
            echo "[OK] Pipeline completo: ${env.IMAGE_REPO}:${env.IMAGE_TAG} lista (entorno: ${env.DEPLOY_ENV})"
        }
        failure {
            echo "[X] Pipeline DETENIDO en la etapa '${env.CURRENT_STAGE}'. Ver el log de esa etapa y los reportes archivados (reports/ci/)."
        }
        cleanup {
            cleanWs(deleteDirs: true, notFailBuild: true)
        }
    }
}
