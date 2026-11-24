// Definición de la app Express (rutas, middlewares, métricas).
// Se exporta sin ponerla a escuchar para poder testearla (tests/api.test.js);
// el arranque del servidor está en server.js.
const express = require('express');
const helmet = require('helmet');
const path = require('path');
const config = require('./config');
const redisClient = require('./redisClient');
const gameLogic = require('./gameLogic');
const metrics = require('./metrics');

const app = express();

// IDs de jugador válidos: letras, números, "_" y "-", entre 5 y 64 caracteres.
// Evita claves arbitrarias en Redis y texto inyectado en los logs.
const PLAYER_ID_PATTERN = /^[A-Za-z0-9_-]{5,64}$/;
const isValidPlayerId = (id) => typeof id === 'string' && PLAYER_ID_PATTERN.test(id);

// Métricas HTTP (RPS, latencia) de todas las peticiones, incluidos los estáticos
app.use(metrics.httpMetricsMiddleware);

// Headers de seguridad (CSP, X-Content-Type-Options, X-Frame-Options, etc.)
// y sin el header "X-Powered-By: Express".
// No se usa CORS: el frontend se sirve desde el mismo origen que la API.
app.use(helmet({
  contentSecurityPolicy: {
    useDefaults: true,
    directives: {
      'default-src': ["'self'"],
      'script-src': ["'self'"],
      'style-src': ["'self'", 'https://fonts.googleapis.com'],
      'font-src': ["'self'", 'https://fonts.gstatic.com'],
      'img-src': ["'self'", 'data:'],
      'connect-src': ["'self'"],
      // La app se sirve por HTTP en minikube: no forzar HTTPS
      'upgrade-insecure-requests': null
    }
  },
  // Sin TLS no tiene sentido HSTS
  strictTransportSecurity: false
}));

// Límite de tamaño del body (el estado de un jugador ocupa pocos KB)
app.use(express.json({ limit: '100kb' }));

// Endpoint scrapeado por Prometheus
app.get('/metrics', metrics.metricsHandler);

// Serve static frontend assets
app.use(express.static(path.join(__dirname, 'public')));

// Kubernetes Health & Readiness Probes
app.get('/healthz', (req, res) => {
  res.status(200).json({
    status: 'healthy',
    uptime: process.uptime(),
    pod: config.podName,
    color: config.appColor,
    version: config.appVersion
  });
});

app.get('/readyz', async (req, res) => {
  // App is ready to serve traffic
  res.status(200).json({
    status: 'ready',
    pod: config.podName,
    color: config.appColor,
    version: config.appVersion,
    redis: redisClient.isRedisConnected() ? 'connected' : 'offline-memory-mode'
  });
});

// App Version & Pod Metadata API (used by frontend badge)
app.get('/api/version', (req, res) => {
  const availableUpgrades = {};
  for (const [k, def] of Object.entries(gameLogic.UPGRADES_DEF)) {
    if (!def.isV2Only || config.prestigeEnabled) {
      availableUpgrades[k] = def;
    }
  }

  res.json({
    version: config.appVersion,
    color: config.appColor,
    prestigeEnabled: config.prestigeEnabled,
    podName: config.podName,
    redisConnected: redisClient.isRedisConnected(),
    shapes: gameLogic.SHAPES,
    upgradesDef: availableUpgrades
  });
});

// Get or initialize player state
app.get('/api/state/:playerId', async (req, res) => {
  const { playerId } = req.params;
  if (!isValidPlayerId(playerId)) {
    return res.status(400).json({ error: 'Valid playerId is required' });
  }

  try {
    const rawState = await redisClient.getPlayerState(playerId);
    const state = gameLogic.sanitizeState(rawState, playerId, config.prestigeEnabled);
    
    // If it was a new player, save initial state
    await redisClient.touchActivePlayer(playerId);

    if (!rawState) {
      await redisClient.savePlayerState(playerId, state);
    }

    res.json({
      success: true,
      state,
      podName: config.podName,
      color: config.appColor
    });
  } catch (err) {
    console.error(`[API] Error loading state for ${playerId}:`, err);
    res.status(500).json({ error: 'Failed to retrieve game state' });
  }
});

// Save player state
app.post('/api/save', async (req, res) => {
  const { playerId, state } = req.body;
  if (!isValidPlayerId(playerId) || !state || typeof state !== 'object') {
    return res.status(400).json({ error: 'PlayerId and state payload required' });
  }

  try {
    const sanitized = gameLogic.sanitizeState(state, playerId, config.prestigeEnabled);
    sanitized.stats.lastSaved = Date.now();

    // Progreso desde el último guardado, comparado contra el estado compartido en
    // Redis (así no importa a qué pod llegó el guardado anterior)
    const previousState = await redisClient.getPlayerState(playerId);
    metrics.recordProgress(previousState, sanitized);

    await redisClient.savePlayerState(playerId, sanitized);
    await redisClient.touchActivePlayer(playerId);

    res.json({
      success: true,
      podName: config.podName,
      color: config.appColor,
      savedAt: sanitized.stats.lastSaved
    });
  } catch (err) {
    console.error(`[API] Error saving state for ${playerId}:`, err);
    res.status(500).json({ error: 'Failed to save game state' });
  }
});

// Buy Upgrade endpoint
app.post('/api/upgrade', async (req, res) => {
  const { playerId, upgradeKey } = req.body;
  // hasOwn: evita que claves heredadas como "constructor" o "__proto__"
  // pasen la validación como si fueran mejoras reales
  const upgradeDef = typeof upgradeKey === 'string' && Object.hasOwn(gameLogic.UPGRADES_DEF, upgradeKey)
    ? gameLogic.UPGRADES_DEF[upgradeKey]
    : null;
  if (!isValidPlayerId(playerId) || !upgradeDef) {
    return res.status(400).json({ error: 'Invalid playerId or upgradeKey' });
  }

  if (upgradeDef.isV2Only && !config.prestigeEnabled) {
    return res.status(403).json({ error: 'This upgrade is only available in Version 2.0 (Green Edition)!' });
  }

  try {
    const rawState = await redisClient.getPlayerState(playerId);
    const state = gameLogic.sanitizeState(rawState, playerId, config.prestigeEnabled);

    if (upgradeDef.requiresPrestige) {
      const ascensions = (state.prestige && state.prestige.ascensions) || 0;
      if (ascensions < upgradeDef.requiresPrestige) {
        return res.status(403).json({
          error: 'This upgrade unlocks after your first Prestige Ascension!'
        });
      }
    }
    
    const currentLvl = state.upgrades[upgradeKey] || 0;
    const cost = gameLogic.getUpgradeCost(upgradeKey, currentLvl);

    if (state.points < cost) {
      return res.status(400).json({ error: 'Not enough points', currentPoints: state.points, cost });
    }

    // Deduct cost and increment level
    state.points -= cost;
    state.upgrades[upgradeKey] = currentLvl + 1;

    // Special handling for tier unlock
    if (upgradeKey === 'tierUnlock') {
      const maxUnlockedTier = 1 + state.upgrades.tierUnlock;
      state.currentTier = Math.min(maxUnlockedTier, gameLogic.SHAPES.length);
    }

    state.stats.lastSaved = Date.now();
    await redisClient.savePlayerState(playerId, state);
    metrics.upgradePurchased(upgradeKey);
    await redisClient.touchActivePlayer(playerId);

    res.json({
      success: true,
      state,
      podName: config.podName,
      color: config.appColor
    });
  } catch (err) {
    console.error(`[API] Error processing upgrade:`, err);
    res.status(500).json({ error: 'Failed to buy upgrade' });
  }
});

// Prestige Ascension (v2 Green Feature)
app.post('/api/prestige', async (req, res) => {
  if (!config.prestigeEnabled) {
    return res.status(403).json({
      error: 'Prestige Ascension is only available in Version 2.0 (Green Edition)!'
    });
  }

  const { playerId } = req.body;
  if (!isValidPlayerId(playerId)) {
    return res.status(400).json({ error: 'PlayerId is required' });
  }

  try {
    const rawState = await redisClient.getPlayerState(playerId);
    const state = gameLogic.sanitizeState(rawState, playerId, true);

    const currentPoints = state.currentRunPoints || 0;
    const currentPops = state.currentRunPops || 0;
    const earnedShards = gameLogic.calculatePrestigeShards(currentPoints, currentPops);
    if (earnedShards <= 0) {
      return res.status(400).json({
        error: 'You need more energy (500+) and shape pops (30+) in the current run to earn Prismatic Shards!'
      });
    }

    // Preserve lifetime statistics & prestige history
    const oldPrestige = state.prestige;
    const oldStats = state.stats;
    const newShards = oldPrestige.shards + earnedShards;
    const totalEarned = oldPrestige.totalShardsEarned + earnedShards;
    const newAscensions = oldPrestige.ascensions + 1;

    // Reset standard progress and current run counters, but grant prestige shards & multiplier
    const newState = gameLogic.createInitialState(playerId);
    newState.points = 0;
    newState.currentRunPoints = 0;
    newState.currentRunPops = 0;
    newState.lifetimePoints = state.lifetimePoints;
    newState.lifetimePops = state.lifetimePops;
    newState.stats = {
      ...oldStats,
      lastSaved: Date.now()
    };
    newState.prestige = {
      shards: newShards,
      totalShardsEarned: totalEarned,
      ascensions: newAscensions,
      globalMultiplier: 1.0 + (newShards * 0.10),
      perks: oldPrestige.perks || {}
    };

    await redisClient.savePlayerState(playerId, newState);
    metrics.prestigeAscended(earnedShards);

    res.json({
      success: true,
      state: newState,
      earnedShards,
      podName: config.podName,
      color: config.appColor,
      message: `Ascended successfully! Earned ${earnedShards} Prismatic Shards.`
    });
  } catch (err) {
    console.error(`[API] Error during prestige:`, err);
    res.status(500).json({ error: 'Failed to ascend' });
  }
});

module.exports = app;
