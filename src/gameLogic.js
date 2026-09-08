// Map-Based Shape Popper Game Logic & Formulas

const SHAPES = [
  {
    tier: 1,
    sides: 3,
    name: 'Triangle',
    baseHp: 6,
    baseReward: 2,
    radius: 18,
    color: '#ffffff',
    fillColor: 'rgba(255, 255, 255, 0.08)'
  },
  {
    tier: 2,
    sides: 4,
    name: 'Square',
    baseHp: 16,
    baseReward: 6,
    radius: 22,
    color: '#e2e8f0',
    fillColor: 'rgba(226, 232, 240, 0.08)'
  },
  {
    tier: 3,
    sides: 5,
    name: 'Pentagon',
    baseHp: 40,
    baseReward: 16,
    radius: 26,
    color: '#cbd5e1',
    fillColor: 'rgba(203, 213, 225, 0.08)'
  },
  {
    tier: 4,
    sides: 6,
    name: 'Hexagon',
    baseHp: 90,
    baseReward: 42,
    radius: 30,
    color: '#94a3b8',
    fillColor: 'rgba(148, 163, 184, 0.08)'
  },
  {
    tier: 5,
    sides: 8,
    name: 'Octagon',
    baseHp: 220,
    baseReward: 110,
    radius: 34,
    color: '#64748b',
    fillColor: 'rgba(100, 116, 139, 0.08)'
  },
  {
    tier: 6,
    sides: 10,
    name: 'Decagon',
    baseHp: 600,
    baseReward: 320,
    radius: 38,
    color: '#475569',
    fillColor: 'rgba(71, 85, 105, 0.08)'
  }
];

const UPGRADES_DEF = {
  clickDamage: {
    id: 'clickDamage',
    name: 'Click Damage',
    desc: '+1 click damage',
    baseCost: 10,
    costMultiplier: 1.25,
    getEffect: (lvl) => 1 + lvl
  },
  blastRadius: {
    id: 'blastRadius',
    name: 'Blast Radius',
    desc: '+12px AoE radius',
    baseCost: 15,
    costMultiplier: 1.30,
    maxLevel: 15,
    getEffect: (lvl) => 35 + (lvl * 12) // Radius in px
  },
  spawnRate: {
    id: 'spawnRate',
    name: 'Field Spawner',
    desc: '+cap & faster spawn',
    baseCost: 25,
    costMultiplier: 1.35,
    maxLevel: 10,
    getEffect: (lvl) => ({
      cap: Math.min(40, 6 + Math.round((lvl / 10) * 34)),
      intervalMs: Math.max(400, 1600 - (lvl * 120))
    })
  },
  clusterSpawn: {
    id: 'clusterSpawn',
    name: 'Spawn Surge',
    desc: '+1 spawn/tick (max 5)',
    baseCost: 150,
    costMultiplier: 2.2,
    maxLevel: 4,
    getEffect: (lvl) => Math.min(5, 1 + lvl) // Level 0: 1, Level 1: 2, Level 2: 3, Level 3: 4, Level 4: 5
  },
  rapidPulse: {
    id: 'rapidPulse',
    name: 'Rapid Pulse',
    desc: '+0.5 hold clicks/s',
    baseCost: 25,
    costMultiplier: 1.35,
    maxLevel: 8,
    getEffect: (lvl) => 1.0 + (lvl * 0.5) // clicks per second: 1.0, 1.5, 2.0, ...
  },
  chainLightning: {
    id: 'chainLightning',
    name: 'Chain Strike',
    desc: '+1 chain arc (50% dmg)',
    baseCost: 35,
    costMultiplier: 1.45,
    maxLevel: 5,
    getEffect: (lvl) => ({
      jumps: lvl,
      damagePercent: 0.50
    })
  },
  tierAffinity: {
    id: 'tierAffinity',
    name: 'Shape Evolution',
    desc: 'Unlocks next shape tier',
    baseCost: 45,
    costMultiplier: 1.45,
    maxLevel: 5,
    getEffect: (lvl) => 1 + lvl // max unlocked tier
  },
  pointMultiplier: {
    id: 'pointMultiplier',
    name: 'Energy Multiplier',
    desc: '+15% energy reward',
    baseCost: 40,
    costMultiplier: 1.30,
    getEffect: (lvl) => 1 + (lvl * 0.15)
  },
  // v2 Green Exclusive Automation Upgrade
  autoTurret: {
    id: 'autoTurret',
    name: 'Defense Turrets',
    desc: 'Corner auto-lasers',
    baseCost: 45,
    costMultiplier: 2.5,
    maxLevel: 8,
    isV2Only: true,
    requiresPrestige: 1,
    getEffect: (lvl) => ({
      turrets: Math.min(4, Math.ceil(lvl / 2)),
      damage: lvl * 2,
      fireRateMs: Math.max(500, 1200 - (lvl * 60))
    })
  }
};

// Prestige Perks (v2 - Green Edition)
const PRESTIGE_PERKS = {
  shardsMultiplier: {
    name: 'Prismatic Attunement',
    desc: '+10% power per shard'
  }
};

function getUpgradeCost(upgradeKey, currentLevel) {
  const def = UPGRADES_DEF[upgradeKey];
  if (!def) return Infinity;
  if (def.maxLevel && currentLevel >= def.maxLevel) return Infinity;
  return Math.floor(def.baseCost * Math.pow(def.costMultiplier, currentLevel));
}

function createInitialState(playerId) {
  return {
    playerId: playerId,
    points: 0,
    currentRunPoints: 0,
    currentRunPops: 0,
    lifetimePoints: 0,
    lifetimePops: 0,
    upgrades: {
      clickDamage: 0,
      blastRadius: 0,
      spawnRate: 0,
      clusterSpawn: 0,
      rapidPulse: 0,
      chainLightning: 0,
      tierAffinity: 0,
      pointMultiplier: 0,
      autoTurret: 0
    },
    prestige: {
      shards: 0,
      totalShardsEarned: 0,
      ascensions: 0,
      globalMultiplier: 1.0,
      perks: {}
    },
    stats: {
      totalClicks: 0,
      totalPops: 0,
      createdAt: Date.now(),
      lastSaved: Date.now()
    }
  };
}

// Ensure state loaded from Redis has all expected fields (forward & backward compatibility)
function sanitizeState(rawState, playerId, prestigeEnabled = true) {
  const initial = createInitialState(playerId);
  if (!rawState || typeof rawState !== 'object') {
    return initial;
  }

  // Handle migration from legacy upgrade names (e.g. clickPower -> clickDamage)
  const legacyUpgrades = rawState.upgrades || {};
  const migratedUpgrades = {
    ...initial.upgrades,
    ...legacyUpgrades,
    clickDamage: typeof legacyUpgrades.clickDamage === 'number' ? legacyUpgrades.clickDamage : (legacyUpgrades.clickPower || 0),
    clusterSpawn: legacyUpgrades.clusterSpawn || 0,
    rapidPulse: legacyUpgrades.rapidPulse || 0,
    autoTurret: prestigeEnabled ? (legacyUpgrades.autoTurret || 0) : 0
  };

  const merged = {
    ...initial,
    ...rawState,
    currentRunPoints: typeof rawState.currentRunPoints === 'number' ? rawState.currentRunPoints : (rawState.points || 0),
    currentRunPops: typeof rawState.currentRunPops === 'number' ? rawState.currentRunPops : (rawState.stats?.totalPops || 0),
    upgrades: migratedUpgrades,
    prestige: {
      ...initial.prestige,
      ...(rawState.prestige || {})
    },
    stats: {
      ...initial.stats,
      ...(rawState.stats || {})
    }
  };

  // Recalculate global multiplier: ONLY active if prestigeEnabled (Green v2)
  const shards = merged.prestige.shards || 0;
  if (prestigeEnabled && shards > 0) {
    merged.prestige.globalMultiplier = 1.0 + (shards * 0.10);
  } else {
    merged.prestige.globalMultiplier = 1.0;
  }

  return merged;
}

// Calculate potential prestige shards on reset: depends strictly on current run progress
function calculatePrestigeShards(currentRunPoints, currentRunPops) {
  if (currentRunPoints < 500 || currentRunPops < 30) return 0;
  const shards = Math.floor(Math.sqrt(currentRunPoints / 500));
  return Math.max(1, shards);
}

module.exports = {
  SHAPES,
  UPGRADES_DEF,
  PRESTIGE_PERKS,
  getUpgradeCost,
  createInitialState,
  sanitizeState,
  calculatePrestigeShards
};
