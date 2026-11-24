#!/usr/bin/env bash
# Despliegue del pipeline con Helm (etapa 5 del Jenkinsfile).
# Variables: DEPLOY_ENV (prod|dev), IMAGE_REPO, IMAGE_TAG, SWITCH_TRAFFIC (true|false)
#            KUBECONFIG (kubeconfig de la ServiceAccount jenkins-deployer)
#
# prod (Blue/Green):
#   1. La imagen nueva se despliega en el color INACTIVO (el que no recibe
#      tráfico). El color activo no se toca: sigue atendiendo a los jugadores
#      y es la versión a la que se vuelve si algo sale mal.
#   2. Smoke test directo sobre los pods del color nuevo, ANTES de mandarles tráfico.
#   3. Switch: el Service pasa al color nuevo.  4. helm test sobre el Service.
#   Así los colores se alternan en cada despliegue: blue -> green -> blue ...
#   En el pipeline el color es solo una "ranura": la versión nueva lleva su
#   propia configuración (versión = tag de la imagen, prestigio activado),
#   caiga en blue o en green.
# dev: la imagen nueva se despliega en los dos colores y se prueba green.
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

# --- Color de destino ---------------------------------------------------------
if [ "$DEPLOY_ENV" == "prod" ]; then
    # Color activo = el que selecciona hoy el Service (blue si la release es nueva)
    ACTIVE=$(kubectl get svc "$RELEASE" -n "$NS" -o jsonpath='{.spec.selector.version}' 2> /dev/null || true)
    ACTIVE=${ACTIVE:-blue}
    if [ "$ACTIVE" == "blue" ]; then TARGET=green; else TARGET=blue; fi
    log "Color activo: ${ACTIVE^^}. La versión nueva va al color inactivo: ${TARGET^^}"
    IMAGE_ARGS=(--set "app.versions.$TARGET.image.repository=$IMAGE_REPO" --set "app.versions.$TARGET.image.tag=$IMAGE_TAG"
                --set-string "app.versions.$TARGET.appVersion=$IMAGE_TAG" --set "app.versions.$TARGET.prestigeEnabled=true")
else
    TARGET=green
    IMAGE_ARGS=(--set "app.versions.green.image.repository=$IMAGE_REPO" --set "app.versions.green.image.tag=$IMAGE_TAG"
                --set "app.versions.blue.image.repository=$IMAGE_REPO"  --set "app.versions.blue.image.tag=$IMAGE_TAG")
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
log "helm upgrade --install $RELEASE con la imagen $IMAGE_REPO:$IMAGE_TAG"
helm upgrade --install "$RELEASE" ./helm-chart -n "$NS" "${VALUES_ARGS[@]}" "${IMAGE_ARGS[@]}" --wait --timeout "$HELM_TIMEOUT"

# --- 2. Smoke test del color nuevo (antes de mandarle tráfico) -----------------
log "Smoke test de los pods ${TARGET^^}"
DEPLOY="$RELEASE-$TARGET"
IMAGE_NOW=$(kubectl get deploy "$DEPLOY" -n "$NS" -o jsonpath='{.spec.template.spec.containers[0].image}')
[ "$IMAGE_NOW" == "$IMAGE_REPO:$IMAGE_TAG" ] || { echo "El Deployment usa $IMAGE_NOW y se esperaba $IMAGE_REPO:$IMAGE_TAG"; false; }
# Solo los pods nuevos: los de la versión anterior pueden seguir en "Terminating"
# (que figura como phase=Running), así que se descartan los que tienen deletionTimestamp.
TARGET_PODS=$(kubectl get pods -n "$NS" -l "app.kubernetes.io/instance=$RELEASE,version=$TARGET" --field-selector=status.phase=Running \
    -o go-template='{{range .items}}{{if not .metadata.deletionTimestamp}}{{.metadata.name}} {{end}}{{end}}')
[ -n "$TARGET_PODS" ] || { echo "No hay pods $TARGET en ejecución"; false; }
for POD in $TARGET_PODS; do
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
    log "Switch: el Service pasa de ${ACTIVE^^} a ${TARGET^^}"
    helm upgrade "$RELEASE" ./helm-chart -n "$NS" --reset-then-reuse-values --set "app.activeColor=$TARGET" --wait --timeout "$HELM_TIMEOUT"
elif [ "$DEPLOY_ENV" == "prod" ]; then
    log "SWITCH_TRAFFIC=false: ${TARGET^^} queda desplegado sin tráfico (el activo sigue siendo ${ACTIVE^^})"
fi

# --- 4. helm test sobre el Service ----------------------------------------------
log "helm test $RELEASE"
helm test "$RELEASE" -n "$NS" --logs

trap - ERR
log "Despliegue OK"
helm history "$RELEASE" -n "$NS" --max 5
echo "Color activo: $(kubectl get svc "$RELEASE" -n "$NS" -o jsonpath='{.spec.selector.version}')"
