#!/usr/bin/env bash
# Levanta Jenkins (contenedor "shape-jenkins") listo para correr el pipeline:
#   1. Permisos de Jenkins en Kubernetes (k8s/jenkins/rbac.yaml)
#   2. kubeconfig de la ServiceAccount jenkins-deployer -> .jenkins/kubeconfig
#   3. Credenciales desde .env.jenkins (se crea desde .env.jenkins.example)
#   4. Imagen de Jenkins (jenkins/Dockerfile) y contenedor
# Jenkins queda en http://localhost:8080 (usuario admin).
set -euo pipefail
cd "$(dirname "$0")/.."
export MSYS_NO_PATHCONV=1

IMAGE=shape-jenkins:1.0.0
CONTAINER=shape-jenkins
# Ruta del repo para montarla en el contenedor (formato Windows en Git Bash)
if command -v cygpath &> /dev/null; then REPO_DIR=$(cygpath -w "$PWD"); else REPO_DIR=$PWD; fi

echo "=========================================="
echo "  Starting Jenkins"
echo "=========================================="

echo "[1/5] Kubernetes permissions for Jenkins (jenkins-deployer)..."
kubectl apply -f k8s/jenkins/rbac.yaml > /dev/null
until [ -n "$(kubectl get secret jenkins-deployer-token -n jenkins-ci -o jsonpath='{.data.token}' 2> /dev/null)" ]; do sleep 1; done

echo "[2/5] kubeconfig with the jenkins-deployer token -> .jenkins/kubeconfig"
mkdir -p .jenkins
TOKEN=$(kubectl get secret jenkins-deployer-token -n jenkins-ci -o jsonpath='{.data.token}' | base64 -d)
CA=$(kubectl get secret jenkins-deployer-token -n jenkins-ci -o jsonpath='{.data.ca\.crt}')
# Jenkins corre en la red Docker "minikube": llega a la API por la IP del nodo
SERVER="https://$(minikube ip):8443"
cat > .jenkins/kubeconfig <<EOF
apiVersion: v1
kind: Config
clusters:
  - name: minikube
    cluster:
      server: $SERVER
      certificate-authority-data: $CA
users:
  - name: jenkins-deployer
    user:
      token: $TOKEN
contexts:
  - name: jenkins
    context:
      cluster: minikube
      user: jenkins-deployer
      namespace: default
current-context: jenkins
EOF

echo "[3/5] Credentials (.env.jenkins)..."
if [ ! -f .env.jenkins ]; then
    cp .env.jenkins.example .env.jenkins
    echo "      .env.jenkins created from .env.jenkins.example"
fi
if ! grep -qE '^JENKINS_ADMIN_PASSWORD=.+' .env.jenkins; then
    PASS=$(head -c 18 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 16)
    sed -i "s/^JENKINS_ADMIN_PASSWORD=.*/JENKINS_ADMIN_PASSWORD=$PASS/" .env.jenkins
    echo "      Generated a random admin password"
fi
grep -qE '^SNYK_TOKEN=.+' .env.jenkins || echo "      [!] SNYK_TOKEN is empty: the Snyk stage will fail until you set it"

echo "[4/5] Building $IMAGE..."
docker build -t "$IMAGE" jenkins/

echo "[5/5] Starting container $CONTAINER..."
docker rm -f "$CONTAINER" > /dev/null 2>&1 || true
# --network minikube : para llegar a la API de Kubernetes (IP del nodo)
# docker.sock        : para construir imágenes con el Docker del host
# --group-add 0      : el socket es root:root 660; Jenkins sigue siendo uid 1000
# /repo (solo lectura): repositorio local que clona el pipeline
docker run -d --name "$CONTAINER" \
    --network minikube \
    -p 8080:8080 \
    --memory 1500m \
    --group-add 0 \
    -v shape-jenkins-home:/var/jenkins_home \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v "$REPO_DIR:/repo:ro" \
    -v "$REPO_DIR/.jenkins/kubeconfig:/run/secrets/kubeconfig:ro" \
    --env-file .env.jenkins \
    "$IMAGE" > /dev/null

printf "      Waiting for Jenkins"
until curl -s -o /dev/null -w '%{http_code}' http://localhost:8080/login | grep -q 200; do printf "."; sleep 3; done
echo ""

echo ""
echo "[OK] Jenkins is running: http://localhost:8080"
echo "     user: admin   password: $(grep '^JENKINS_ADMIN_PASSWORD=' .env.jenkins | cut -d= -f2)"
echo "     job:  shape-game (Build with Parameters)"
