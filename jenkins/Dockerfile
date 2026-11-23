# syntax=docker/dockerfile:1
# =============================================================================
# Jenkins para el pipeline de Shape Popper (ver Jenkinsfile en la raíz).
# Incluye, con versiones fijas, todas las herramientas que usa el pipeline:
# Node.js, docker CLI + buildx, kubectl, Helm, Trivy, Snyk y Semgrep.
# La configuración (usuario, credenciales y job) viene de casc.yaml
# (Jenkins Configuration as Code): no hay pasos manuales en la interfaz.
# =============================================================================
FROM jenkins/jenkins:2.580.2-lts-jdk21

ARG NODE_VERSION=22.23.5
ARG DOCKER_VERSION=29.10.0
ARG BUILDX_VERSION=0.39.1
ARG KUBECTL_VERSION=1.37.2
ARG HELM_VERSION=4.3.2
ARG TRIVY_VERSION=0.76.1
ARG SNYK_VERSION=1.1309.0
ARG SEMGREP_VERSION=1.186.0

USER root

# Paquetes base (python para Semgrep, xz para el tarball de Node)
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl git xz-utils python3 python3-venv \
    && rm -rf /var/lib/apt/lists/*

# Node.js (misma versión mayor que la imagen de la app) para npm ci / npm test
RUN curl -fsSL "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-x64.tar.xz" \
      | tar -xJ --strip-components=1 -C /usr/local \
    && node --version

# docker CLI + plugin buildx (el daemon es el de Docker Desktop, vía socket)
RUN curl -fsSL "https://download.docker.com/linux/static/stable/x86_64/docker-${DOCKER_VERSION}.tgz" \
      | tar -xz --strip-components=1 -C /usr/local/bin docker/docker \
    && mkdir -p /usr/local/lib/docker/cli-plugins \
    && curl -fsSL -o /usr/local/lib/docker/cli-plugins/docker-buildx \
      "https://github.com/docker/buildx/releases/download/v${BUILDX_VERSION}/buildx-v${BUILDX_VERSION}.linux-amd64" \
    && chmod +x /usr/local/lib/docker/cli-plugins/docker-buildx

# kubectl (con verificación del checksum publicado)
RUN curl -fsSL -o /usr/local/bin/kubectl "https://dl.k8s.io/release/v${KUBECTL_VERSION}/bin/linux/amd64/kubectl" \
    && echo "$(curl -fsSL https://dl.k8s.io/release/v${KUBECTL_VERSION}/bin/linux/amd64/kubectl.sha256)  /usr/local/bin/kubectl" | sha256sum -c - \
    && chmod +x /usr/local/bin/kubectl

# Helm 4
RUN curl -fsSL "https://get.helm.sh/helm-v${HELM_VERSION}-linux-amd64.tar.gz" \
      | tar -xz --strip-components=1 -C /usr/local/bin linux-amd64/helm \
    && helm version --short

# Trivy (escaneo de la imagen antes de publicarla)
RUN curl -fsSL "https://github.com/aquasecurity/trivy/releases/download/v${TRIVY_VERSION}/trivy_${TRIVY_VERSION}_Linux-64bit.tar.gz" \
      | tar -xz -C /usr/local/bin trivy \
    && trivy --version

# Snyk CLI (análisis de dependencias)
RUN npm install -g "snyk@${SNYK_VERSION}" && npm cache clean --force && snyk --version

# Semgrep en un entorno virtual de Python (análisis estático)
RUN python3 -m venv /opt/semgrep \
    && /opt/semgrep/bin/pip install --no-cache-dir "semgrep==${SEMGREP_VERSION}" \
    && ln -s /opt/semgrep/bin/semgrep /usr/local/bin/semgrep \
    && semgrep --version

# Plugins de Jenkins (versiones fijas en plugins.txt)
COPY plugins.txt /usr/share/jenkins/ref/plugins.txt
RUN jenkins-plugin-cli --plugin-file /usr/share/jenkins/ref/plugins.txt

# Configuration as Code
COPY casc.yaml /usr/share/jenkins/ref/casc.yaml
ENV CASC_JENKINS_CONFIG=/usr/share/jenkins/ref/casc.yaml

# - Sin asistente de instalación (todo lo configura casc.yaml)
# - Memoria de la JVM limitada (Docker Desktop tiene poca RAM disponible)
# - Permite clonar el repo local montado en /repo mientras no se use GitHub
ENV JAVA_OPTS="-Djenkins.install.runSetupWizard=false -Xmx768m -Dhudson.plugins.git.GitSCM.ALLOW_LOCAL_CHECKOUT=true"

# El repo local montado pertenece a otro usuario: git lo bloquearía
RUN git config --system --add safe.directory '*'

# Jenkins corre con su usuario sin privilegios (uid 1000)
USER jenkins
