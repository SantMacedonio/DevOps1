// Métricas Prometheus de la aplicación (expuestas en GET /metrics)
// @prometheus-io/client es el sucesor oficial de prom-client (misma API)
const client = require('@prometheus-io/client');
const config = require('./config');
const redisClient = require('./redisClient');

const register = new client.Registry();

// Etiquetas comunes a todas las series: permiten separar Blue / Green en Grafana.
// (El nombre del pod lo agrega Prometheus al descubrir el target.)
register.setDefaultLabels({
  color: config.appColor,
  app_version: config.appVersion
});

// Métricas del proceso Node: CPU, memoria, event loop, GC, handles...
client.collectDefaultMetrics({ register });

// --- Métricas HTTP -----------------------------------------------------------
const httpRequestsTotal = new client.Counter({
  name: 'http_requests_total',
  help: 'Total de peticiones HTTP procesadas',
  labelNames: ['method', 'route', 'status_code'],
  registers: [register]
});

const httpRequestDuration = new client.Histogram({
  name: 'http_request_duration_seconds',
  help: 'Duración de las peticiones HTTP en segundos',
  labelNames: ['method', 'route', 'status_code'],
  buckets: [0.001, 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5],
  registers: [register]
});

// La etiqueta "route" usa el patrón de Express (/api/state/:playerId) y nunca la
// URL real, para no crear una serie nueva por cada playerId (alta cardinalidad).
function routeLabel(req, res) {
  if (req.route && req.route.path) return req.baseUrl + req.route.path;
  return res.statusCode === 404 ? 'not_found' : 'static';
}

function httpMetricsMiddleware(req, res, next) {
  if (req.path === '/metrics') return next(); // no medir el propio scrape
  const end = httpRequestDuration.startTimer();
  res.on('finish', () => {
    const labels = {
      method: req.method,
      route: routeLabel(req, res),
      status_code: String(res.statusCode)
    };
    end(labels);
    httpRequestsTotal.inc(labels);
  });
  next();
}

// --- Métricas de negocio -----------------------------------------------------
const upgradesPurchased = new client.Counter({
  name: 'shape_game_upgrades_purchased_total',
  help: 'Mejoras compradas en la tienda, por tipo de mejora',
  labelNames: ['upgrade'],
  registers: [register]
});

const prestigeAscensions = new client.Counter({
  name: 'shape_game_prestige_ascensions_total',
  help: 'Ascensiones de prestigio realizadas (solo disponibles en Green v2)',
  registers: [register]
});

const shardsEarned = new client.Counter({
  name: 'shape_game_prestige_shards_earned_total',
  help: 'Fragmentos prismáticos obtenidos en ascensiones',
  registers: [register]
});

const shapesPopped = new client.Counter({
  name: 'shape_game_shapes_popped_total',
  help: 'Figuras destruidas por los jugadores (diferencia entre guardados)',
  registers: [register]
});

const pointsEarned = new client.Counter({
  name: 'shape_game_points_earned_total',
  help: 'Energía (puntos) generada por los jugadores (diferencia entre guardados)',
  registers: [register]
});

const ACTIVE_WINDOW_MS = 5 * 60 * 1000;
// eslint-disable-next-line no-new
new client.Gauge({
  name: 'shape_game_active_players',
  help: 'Jugadores con actividad en los últimos 5 minutos (global, calculado en Redis)',
  registers: [register],
  async collect() {
    this.set(await redisClient.countActivePlayers(ACTIVE_WINDOW_MS));
  }
});

// eslint-disable-next-line no-new
new client.Gauge({
  name: 'shape_game_redis_connected',
  help: '1 si el pod está conectado a Redis, 0 si usa el modo en memoria',
  registers: [register],
  collect() {
    this.set(redisClient.isRedisConnected() ? 1 : 0);
  }
});

// Suma al contador solo el progreso nuevo (delta positivo) entre dos guardados.
function recordProgress(previousState, newState) {
  if (!previousState || !newState) return;
  const popsDelta = (newState.lifetimePops || 0) - (previousState.lifetimePops || 0);
  const pointsDelta = (newState.lifetimePoints || 0) - (previousState.lifetimePoints || 0);
  // Se descartan valores negativos (reinicio de partida) o absurdos (cliente manipulado)
  if (popsDelta > 0 && popsDelta < 100000) shapesPopped.inc(popsDelta);
  if (pointsDelta > 0 && Number.isFinite(pointsDelta)) pointsEarned.inc(pointsDelta);
}

async function metricsHandler(req, res) {
  try {
    res.set('Content-Type', register.contentType);
    res.end(await register.metrics());
  } catch (err) {
    res.status(500).end(err.message);
  }
}

module.exports = {
  httpMetricsMiddleware,
  metricsHandler,
  recordProgress,
  upgradePurchased: (upgradeKey) => upgradesPurchased.inc({ upgrade: upgradeKey }),
  prestigeAscended: (shards) => {
    prestigeAscensions.inc();
    shardsEarned.inc(shards);
  }
};
