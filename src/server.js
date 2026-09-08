const express = require('express');
const cors = require('cors');
const path = require('path');
const config = require('./config');
const redisClient = require('./redisClient');
const gameLogic = require('./gameLogic');

const app = express();

app.use(cors());
app.use(express.json());

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
  if (!playerId || playerId.length < 5) {
    return res.status(400).json({ error: 'Valid playerId is required' });
  }

  try {
    const rawState = await redisClient.getPlayerState(playerId);
    const state = gameLogic.sanitizeState(rawState, playerId, config.prestigeEnabled);
    
    // If it was a new player, save initial state
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
  if (!playerId || !state) {
    return res.status(400).json({ error: 'PlayerId and state payload required' });
  }

  try {
    const sanitized = gameLogic.sanitizeState(state, playerId, config.prestigeEnabled);
    sanitized.stats.lastSaved = Date.now();
    await redisClient.savePlayerState(playerId, sanitized);

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
  const upgradeDef = gameLogic.UPGRADES_DEF[upgradeKey];
  if (!playerId || !upgradeKey || !upgradeDef) {
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
  if (!playerId) {
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

// Start Server
const server = app.listen(config.port, () => {
  console.log(`==============================================`);
  console.log(` Shape Popper Game Server Started             `);
  console.log(` Version:  ${config.appVersion} (${config.appColor.toUpperCase()})`);
  console.log(` Pod Host: ${config.podName}`);
  console.log(` Port:     ${config.port}`);
  console.log(` Prestige: ${config.prestigeEnabled ? 'ENABLED (v2)' : 'DISABLED (v1)'}`);
  console.log(` Redis:    ${config.redis.host}:${config.redis.port}`);
  console.log(`==============================================`);
});

// Graceful Shutdown for Kubernetes Pod Terminations
const handleShutdown = (signal) => {
  console.log(`[Server] Received ${signal}. Shutting down gracefully...`);
  server.close(() => {
    console.log('[Server] HTTP server closed.');
    process.exit(0);
  });
};

process.on('SIGTERM', () => handleShutdown('SIGTERM'));
process.on('SIGINT', () => handleShutdown('SIGINT'));
