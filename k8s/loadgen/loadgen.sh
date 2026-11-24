#!/bin/sh
# Generador de tráfico (POSIX sh). Corre DENTRO del cluster como Job, así las
# peticiones pasan por el Service shape-game: se reparten entre las
# réplicas y siguen al selector cuando se hace el switch Blue -> Green.
# Usa el wget de busybox (viene en la imagen de la app), sin depender de curl.
# Variables: TARGET_URL, DURATION (segundos), PLAYERS
URL=${TARGET_URL:-http://shape-game}
DURATION=${DURATION:-300}
PLAYERS=${PLAYERS:-8}
UPGRADES="clickDamage blastRadius spawnRate clusterSpawn rapidPulse"

get() {
    wget -q -O /dev/null "$URL$1" 2> /dev/null
}

post() {
    # Los 400/403 esperables (sin puntos, prestigio en Blue) se ignoran
    wget -q -O /dev/null --header 'Content-Type: application/json' --post-data "$2" "$URL$1" 2> /dev/null
}

pick_upgrade() {
    n=$(( $(echo $UPGRADES | wc -w) ))
    idx=$(( RANDOM % n + 1 ))
    echo $UPGRADES | cut -d' ' -f$idx
}

for i in $(seq 1 "$PLAYERS"); do
    eval "POPS_$i=0; POINTS_$i=0"
done

echo "Generating traffic against $URL for ${DURATION}s with $PLAYERS players..."
END=$(( $(date +%s) + DURATION ))
ITER=0
while [ "$(date +%s)" -lt "$END" ]; do
    for i in $(seq 1 "$PLAYERS"); do
        P="loadtest-player-$i"
        get "/api/version"
        get "/api/state/$P"

        # El jugador destruye figuras y gana energía entre guardados
        eval "POPS_$i=\$(( POPS_$i + RANDOM % 20 + 5 )); POINTS_$i=\$(( POINTS_$i + RANDOM % 400 + 100 ))"
        eval "POPS=\$POPS_$i; POINTS=\$POINTS_$i"
        post /api/save "{\"playerId\":\"$P\",\"state\":{\"points\":$POINTS,\"lifetimePoints\":$POINTS,\"lifetimePops\":$POPS,\"currentRunPoints\":$POINTS,\"currentRunPops\":$POPS}}"

        # De vez en cuando compra una mejora
        if [ $(( RANDOM % 3 )) -eq 0 ]; then
            post /api/upgrade "{\"playerId\":\"$P\",\"upgradeKey\":\"$(pick_upgrade)\"}"
        fi
        # Y muy de vez en cuando intenta ascender (solo funciona en Green; en Blue responde 403)
        if [ $(( RANDOM % 40 )) -eq 0 ]; then
            post /api/prestige "{\"playerId\":\"$P\"}"
            eval "POPS_$i=0; POINTS_$i=0"
        fi
    done
    # Pausa corta entre rondas: carga moderada (~50-100 RPS) que no satura
    # el límite de CPU de los pods (200m)
    sleep 0.2
    ITER=$(( ITER + 1 ))
    if [ $(( ITER % 10 )) -eq 0 ]; then
        echo "  ... $ITER rounds, $(( END - $(date +%s) ))s left"
    fi
done
echo "[OK] Done"
