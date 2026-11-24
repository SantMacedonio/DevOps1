#!/usr/bin/env bash
# Despliegue del pipeline con Helm (etapa 5 del Jenkinsfile).
# Variables: DEPLOY_ENV (prod|dev), IMAGE_REPO, IMAGE_TAG, SWITCH_TRAFFIC (true|false)
#            KUBECONFIG (kubeconfig de la ServiceAccount jenkins-deployer)
#
# prod (Blue/Green):
#   1. La imagen nueva se despliega en GREEN (la versión "nueva"); BLUE queda
#      como versión estable para volver atrás.
#   2. Smoke test directo sobre los pods green, ANTES de mandarles tráfico.
#   3. Switch: el Service pasa a green.  4. helm test sobre el Service.
# dev: la imagen nueva se despliega en los dos colores y se corre helm test.
# Si algo falla después de modificar la release, se hace "helm rollback" a la
# revisión anterior y el script termina con error.
set -euo pipefail

case "${DEPLOY_ENV:-prod}" in
    prod) RELEASE=shape-game;     NS=default;   VALUES=helm-chart/values-prod.yaml ;;
    dev)  RELEASE=shape-game-dev; NS=shape-dev; VALUES=helm-chart/values-dev.yaml ;;
    *) echo "DEPLOY_ENV inválido: $DEPLOY_ENV"; exit 1 ;;
esac
: "${IMAGE_REPO:?falta IMAGE_REPO}" "${IMAGE_TAG:?falta IMAGE_TAG}"
SWITCH_TRAFFIC=${SWITCH_TRAFFIC:-true}
HELM_TIMEOUT=${HELM_TIMEOUT:-5m}   # tiempo máximo de espera de cada operación de Helm

log() { echo ""; echo ">>> $*"; }

# --- Estado previo (para poder volver atrás) ----------------------------------
PREV_REV=""
if helm status "$RELEASE" -n "$NS" > /dev/null 2>&1; then
    PREV_REV=$(helm history "$RELEASE" -n "$NS" --max 1 -o json | node -e 'let d="";process.stdin.on("data",c=>d+=c).on("end",()=>console.log(JSON.parse(d)[0].revision))')
    VALUES_ARGS=(--reset-then-reuse-values)   # conserva los valores de la release (color activo, etc.)
    log "Release $RELEASE existente (revisión $PREV_REV) en $NS"
else
    VALUES_ARGS=(-f "$VALUES")
    log "Release $RELEASE no existe: primera instalación con $VALUES"
fi

rollback() {
    local rc=$?
    if [ -n "$PREV_REV" ]; then
        echo ""
        echo "[X] Falló el despliegue: helm rollback $RELEASE a la revisión $PREV_REV"
        helm rollback "$RELEASE" "$PREV_REV" -n "$NS" --wait --timeout "$HELM_TIMEOUT" || true
    fi
    exit $rc
}
trap rollback ERR

# --- 1. Desplegar la imagen nueva ---------------------------------------------
if [ "$DEPLOY_ENV" == "prod" ]; then
    IMAGE_ARGS=(--set "app.versions.green.image.repository=$IMAGE_REPO" --set "app.versions.green.image.tag=$IMAGE_TAG")
else
    IMAGE_ARGS=(--set "app.versions.green.image.repository=$IMAGE_REPO" --set "app.versions.green.image.tag=$IMAGE_TAG"
                --set "app.versions.blue.image.repository=$IMAGE_REPO"  --set "app.versions.blue.image.tag=$IMAGE_TAG")
fi
log "helm upgrade --install $RELEASE con la imagen $IMAGE_REPO:$IMAGE_TAG"
helm upgrade --install "$RELEASE" ./helm-chart -n "$NS" "${VALUES_ARGS[@]}" "${IMAGE_ARGS[@]}" --wait --timeout "$HELM_TIMEOUT"

# --- 2. Smoke test de green (antes de mandarle tráfico) -------------------------
log "Smoke test de los pods green"
DEPLOY="$RELEASE-green"
IMAGE_NOW=$(kubectl get deploy "$DEPLOY" -n "$NS" -o jsonpath='{.spec.template.spec.containers[0].image}')
[ "$IMAGE_NOW" == "$IMAGE_REPO:$IMAGE_TAG" ] || { echo "El Deployment usa $IMAGE_NOW y se esperaba $IMAGE_REPO:$IMAGE_TAG"; false; }
# Solo los pods nuevos: los de la versión anterior pueden seguir en "Terminating"
# (que figura como phase=Running), así que se descartan los que tienen deletionTimestamp.
GREEN_PODS=$(kubectl get pods -n "$NS" -l "app.kubernetes.io/instance=$RELEASE,version=green" --field-selector=status.phase=Running \
    -o go-template='{{range .items}}{{if not .metadata.deletionTimestamp}}{{.metadata.name}} {{end}}{{end}}')
[ -n "$GREEN_PODS" ] || { echo "No hay pods green en ejecución"; false; }
for POD in $GREEN_PODS; do
    OK=""
    for i in $(seq 1 15); do
        RESP=$(kubectl exec -n "$NS" "$POD" -- wget -qO- http://localhost:3000/readyz 2> /dev/null || true)
        if echo "$RESP" | grep -q '"redis":"connected"'; then OK=1; break; fi
        sleep 2
    done
    [ -n "$OK" ] || { echo "$POD no está listo o no se conecta a Redis: $RESP"; false; }
    echo "  $POD -> $RESP"
done

# --- 3. Switch Blue/Green -------------------------------------------------------
if [ "$DEPLOY_ENV" == "prod" ] && [ "$SWITCH_TRAFFIC" == "true" ]; then
    log "Switch: el Service pasa a GREEN"
    helm upgrade "$RELEASE" ./helm-chart -n "$NS" --reset-then-reuse-values --set app.activeColor=green --wait --timeout "$HELM_TIMEOUT"
fi

# --- 4. helm test sobre el Service ----------------------------------------------
log "helm test $RELEASE"
helm test "$RELEASE" -n "$NS" --logs

trap - ERR
log "Despliegue OK"
helm history "$RELEASE" -n "$NS" --max 5
echo "Color activo: $(kubectl get svc "$RELEASE" -n "$NS" -o jsonpath='{.spec.selector.version}')"
