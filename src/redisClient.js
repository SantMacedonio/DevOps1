const Redis = require('ioredis');
const config = require('./config');

let redis = null;
let isConnected = false;

// In-memory fallback cache for local dev / graceful resilience
const localMemoryStore = new Map();

function initRedis() {
  try {
    redis = new Redis({
      host: config.redis.host,
      port: config.redis.port,
      password: config.redis.password,
      retryStrategy: config.redis.retryStrategy,
      maxRetriesPerRequest: 3,
      enableOfflineQueue: true,
      connectTimeout: 5000
    });

    redis.on('connect', () => {
      isConnected = true;
      console.log(`[Redis] Connected to ${config.redis.host}:${config.redis.port}`);
    });

    redis.on('ready', () => {
      isConnected = true;
      console.log('[Redis] Ready to accept commands');
    });

    redis.on('error', (err) => {
      isConnected = false;
      console.warn(`[Redis] Connection warning: ${err.message}. Fallback in memory active.`);
    });

    redis.on('close', () => {
      isConnected = false;
    });
  } catch (error) {
    console.error('[Redis] Failed to initialize Redis client:', error.message);
  }
}

initRedis();

async function getPlayerState(playerId) {
  if (!playerId) return null;

  if (isConnected && redis) {
    try {
      const data = await redis.get(`player:${playerId}`);
      if (data) {
        return JSON.parse(data);
      }
    } catch (err) {
      console.error(`[Redis] Error fetching state for ${playerId}:`, err.message);
    }
  }

  // Fallback to local memory if Redis is down or not connected
  if (localMemoryStore.has(playerId)) {
    return localMemoryStore.get(playerId);
  }

  return null;
}

async function savePlayerState(playerId, state) {
  if (!playerId || !state) return false;

  const serialized = JSON.stringify(state);

  // Always keep in local memory fallback
  localMemoryStore.set(playerId, state);

  if (isConnected && redis) {
    try {
      // Key expires after 30 days of inactivity
      await redis.set(`player:${playerId}`, serialized, 'EX', 30 * 24 * 60 * 60);
      return true;
    } catch (err) {
      console.error(`[Redis] Error saving state for ${playerId}:`, err.message);
      return false;
    }
  }

  return true;
}

async function pingRedis() {
  if (!isConnected || !redis) return false;
  try {
    const res = await redis.ping();
    return res === 'PONG';
  } catch {
    return false;
  }
}

module.exports = {
  getPlayerState,
  savePlayerState,
  pingRedis,
  isRedisConnected: () => isConnected
};
