// Shape Popper Map Engine & Telemetry Client

(function() {
  'use strict';

  // Game State
  let state = {
    playerId: null,
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
      globalMultiplier: 1.0
    },
    stats: {
      totalClicks: 0,
      totalPops: 0
    }
  };

  let serverInfo = {
    version: 'v1.0.0',
    color: 'blue',
    prestigeEnabled: false,
    podName: 'detecting...',
    redisConnected: false,
    shapes: [],
    upgradesDef: {}
  };

  let isDirty = false;
  let lastFrameTime = performance.now();
  let lastSpawnTime = performance.now();
  let lastTurretFireTime = performance.now();
  let lastHoldClickTime = 0;
  let upgradesListRendered = false;

  // Canvas & Map State
  const canvas = document.getElementById('map-canvas');
  const ctx = canvas.getContext('2d');
  const canvasWrapper = document.getElementById('canvas-wrapper');
  let canvasRect = { width: 800, height: 500 };
  let dpr = window.devicePixelRatio || 1;

  // Active Entities on Map
  let shapesOnField = [];
  let shockwaves = [];
  let lightningArcs = [];
  let laserBeams = [];
  let particles = [];

  // Mouse / Pointer State
  const pointer = {
    x: -999,
    y: -999,
    isHovering: false,
    isDown: false
  };

  // DOM Elements Cache
  const els = {
    versionBadge: document.getElementById('version-badge'),
    versionLabel: document.getElementById('version-label'),
    podHostname: document.getElementById('pod-hostname'),
    syncIndicator: document.getElementById('sync-indicator'),
    syncText: document.getElementById('sync-text'),
    pointsDisplay: document.getElementById('points-display'),
    fieldCountDisplay: document.getElementById('field-count-display'),
    blastRadiusDisplay: document.getElementById('blast-radius-display'),
    chainDisplay: document.getElementById('chain-display'),
    turretChip: document.getElementById('turret-chip'),
    turretsDisplay: document.getElementById('turrets-display'),
    effectsOverlay: document.getElementById('effects-overlay'),
    upgradesContainer: document.getElementById('upgrades-container'),
    tabUpgradesBtn: document.getElementById('tab-upgrades-btn'),
    tabPrestigeBtn: document.getElementById('tab-prestige-btn'),
    tabUpgrades: document.getElementById('tab-upgrades'),
    tabPrestige: document.getElementById('tab-prestige'),
    prestigeLockPill: document.getElementById('prestige-lock-pill'),
    prestigeMultiplierBanner: document.getElementById('prestige-multiplier-banner'),
    globalMultiplierText: document.getElementById('global-multiplier-text'),
    currentShardsDisplay: document.getElementById('current-shards-display'),
    currentMultiplierDisplay: document.getElementById('current-multiplier-display'),
    pendingShardsDisplay: document.getElementById('pending-shards-display'),
    ascendBtn: document.getElementById('ascend-btn'),
    ascendReqMsg: document.getElementById('ascend-req-msg'),
    statLifetimePoints: document.getElementById('stat-lifetime-points'),
    statLifetimePops: document.getElementById('stat-lifetime-pops'),
    statTotalClicks: document.getElementById('stat-total-clicks'),
    saveBtn: document.getElementById('save-btn'),
    resetBtn: document.getElementById('reset-btn')
  };

  // Helper: UUID Generator
  function getOrCreatePlayerId() {
    let id = localStorage.getItem('shape_player_id');
    if (!id || id.length < 10) {
      id = 'user_' + Math.random().toString(36).substring(2, 10) + '_' + Date.now().toString(36);
      localStorage.setItem('shape_player_id', id);
    }
    return id;
  }

  // Format Large Numbers
  function formatNum(num) {
    if (num === undefined || num === null || isNaN(num)) return '0';
    if (num >= 1e9) return (num / 1e9).toFixed(2) + 'B';
    if (num >= 1e6) return (num / 1e6).toFixed(2) + 'M';
    if (num >= 1e3) return (num / 1e3).toFixed(1) + 'k';
    return Math.floor(num).toLocaleString();
  }

  // High-DPI Responsive Canvas Resizing
  function resizeCanvas() {
    const rect = canvasWrapper.getBoundingClientRect();
    canvasRect.width = Math.max(300, rect.width);
    canvasRect.height = Math.max(300, rect.height);
    dpr = window.devicePixelRatio || 1;

    canvas.width = canvasRect.width * dpr;
    canvas.height = canvasRect.height * dpr;
    ctx.resetTransform();
    ctx.scale(dpr, dpr);
  }

  // Calculation Helpers
  function getEffectiveMultiplier() {
    return serverInfo.prestigeEnabled ? (state.prestige.globalMultiplier || 1.0) : 1.0;
  }

  function getBlastRadius() {
    const lvl = state.upgrades.blastRadius || 0;
    return 35 + (lvl * 12);
  }

  function getClickDamage() {
    const lvl = state.upgrades.clickDamage || 0;
    const base = 1 + lvl;
    return Math.max(1, Math.floor(base * getEffectiveMultiplier()));
  }

  function getHoldClickInterval() {
    const lvl = state.upgrades.rapidPulse || 0;
    const clicksPerSec = 1.0 + (lvl * 0.5); // base: 1.0 click/s (1000ms), up to 5.0 clicks/s
    return Math.max(150, Math.round(1000 / clicksPerSec));
  }

  function getSpawnConfig() {
    const rateLvl = state.upgrades.spawnRate || 0;
    const batchLvl = state.upgrades.clusterSpawn || 0;
    return {
      cap: Math.min(40, 6 + Math.round((rateLvl / 10) * 34)),
      intervalMs: Math.max(400, 1600 - (rateLvl * 120)),
      batchSize: Math.min(5, 1 + batchLvl)
    };
  }

  function getTurretConfig() {
    const lvl = state.upgrades.autoTurret || 0;
    if (!serverInfo.prestigeEnabled || lvl <= 0) {
      return { count: 0, damage: 0, intervalMs: 1200 };
    }
    return {
      count: Math.min(4, Math.ceil(lvl / 2)),
      damage: Math.max(1, Math.floor(lvl * 2 * getEffectiveMultiplier())),
      intervalMs: Math.max(500, 1200 - (lvl * 60))
    };
  }

  // Shape Selection: Without upgrades (tierAffinity == 0), ONLY Triangles appear!
  function pickShapeDefinition() {
    const shapes = serverInfo.shapes && serverInfo.shapes.length > 0 ? serverInfo.shapes : [
      { tier: 1, sides: 3, name: 'Triangle', baseHp: 6, baseReward: 2, radius: 18, color: '#ffffff', fillColor: 'rgba(255, 255, 255, 0.08)' }
    ];

    const affinityLvl = state.upgrades.tierAffinity || 0;
    // Without any upgrades, ONLY Tier 1 (Triangles) spawn!
    if (affinityLvl === 0) {
      return shapes[0];
    }

    // Maximum tier unlocked: Tier 1 + affinityLvl
    const maxTier = Math.min(shapes.length, 1 + affinityLvl);
    const availableShapes = shapes.filter(s => s.tier <= maxTier);

    const weights = availableShapes.map((shape) => {
      if (shape.tier === 1) return 60;
      return Math.max(10, 25 * (affinityLvl - shape.tier + 2));
    });

    const totalWeight = weights.reduce((acc, w) => acc + w, 0);
    let rand = Math.random() * totalWeight;

    for (let i = 0; i < availableShapes.length; i++) {
      if (rand < weights[i]) return availableShapes[i];
      rand -= weights[i];
    }
    return availableShapes[0];
  }

  // Spawn New Shape on Field
  function spawnShape() {
    const def = pickShapeDefinition();
    const margin = 55;
    let x, y;
    let attempts = 0;
    do {
      x = margin + Math.random() * (canvasRect.width - margin * 2);
      y = margin + Math.random() * (canvasRect.height - margin * 2);
      attempts++;
    } while (attempts < 12 && shapesOnField.some(s => Math.hypot(s.baseX - x, s.baseY - y) < 48));

    const shape = {
      id: 'shape_' + Math.random().toString(36).substr(2, 9),
      tier: def.tier,
      sides: def.sides,
      name: def.name,
      maxHp: def.baseHp,
      hp: def.baseHp,
      reward: def.baseReward,
      radius: def.radius || 20,
      color: def.color || '#ffffff',
      fillColor: def.fillColor || 'rgba(255, 255, 255, 0.08)',
      baseX: x,
      baseY: y,
      x: x,
      y: y,
      angle: Math.random() * Math.PI * 2,
      rotSpeed: (Math.random() * 0.6 + 0.2) * (Math.random() > 0.5 ? 1 : -1),
      floatPhaseX: Math.random() * Math.PI * 2,
      floatPhaseY: Math.random() * Math.PI * 2,
      floatSpeedX: 0.8 + Math.random() * 0.6,
      floatSpeedY: 0.7 + Math.random() * 0.5,
      floatDist: 8 + Math.random() * 8, // Stays near its spawn
      hitFlash: 0,
      spawnScale: 0.1
    };

    shapesOnField.push(shape);
    updateHudStats();
  }

  // Ensure map is filled up to capacity
  function fillFieldToCap() {
    const spawnCfg = getSpawnConfig();
    while (shapesOnField.length < spawnCfg.cap) {
      spawnShape();
    }
  }

  // Floating text in effects overlay
  function createDamageText(amount, x, y, isChain = false) {
    const el = document.createElement('div');
    el.className = `floating-dmg ${isChain ? 'chain' : ''}`;
    el.textContent = `-${amount}`;
    el.style.left = `${Math.round(x + (Math.random() * 16 - 8))}px`;
    el.style.top = `${Math.round(y - 10 + (Math.random() * 10 - 5))}px`;

    els.effectsOverlay.appendChild(el);
    setTimeout(() => {
      if (el.parentNode) el.parentNode.removeChild(el);
    }, 700);
  }

  function createRewardText(amount, x, y) {
    const el = document.createElement('div');
    el.className = 'floating-reward';
    el.textContent = `+${amount} ⬡`;
    el.style.left = `${Math.round(x - 14)}px`;
    el.style.top = `${Math.round(y - 20)}px`;

    els.effectsOverlay.appendChild(el);
    setTimeout(() => {
      if (el.parentNode) el.parentNode.removeChild(el);
    }, 800);
  }

  // Spawn Particle Debris on shape destruction
  function spawnDebris(x, y, color, sides, radius) {
    const count = Math.min(16, sides * 2 + 4);
    for (let i = 0; i < count; i++) {
      const angle = (Math.PI * 2 / count) * i + (Math.random() * 0.4 - 0.2);
      const speed = 40 + Math.random() * 80;
      particles.push({
        x,
        y,
        vx: Math.cos(angle) * speed,
        vy: Math.sin(angle) * speed,
        size: 2.5 + Math.random() * 3.5,
        color: color || '#ffffff',
        alpha: 1.0,
        decay: 1.8 + Math.random() * 1.2
      });
    }
  }

  // Handle Field Click / Blast Strike
  function dischargeBlast(clickX, clickY) {
    state.stats.totalClicks++;
    const radius = getBlastRadius();
    const damage = getClickDamage();

    // Spawn visual shockwave
    shockwaves.push({
      x: clickX,
      y: clickY,
      radius: 5,
      maxRadius: radius,
      alpha: 0.9,
      color: serverInfo.color === 'green' ? '#4ade80' : '#60a5fa'
    });

    // Detect struck shapes within blast radius
    const hitShapes = [];
    for (let i = shapesOnField.length - 1; i >= 0; i--) {
      const s = shapesOnField[i];
      const dist = Math.hypot(s.x - clickX, s.y - clickY);
      if (dist <= radius + s.radius) {
        hitShapes.push(s);
      }
    }

    // Apply direct damage to struck shapes
    hitShapes.forEach(shape => {
      applyDamageToShape(shape, damage, false);
    });

    // Handle Chain Lightning if upgrade purchased
    const chainLvl = state.upgrades.chainLightning || 0;
    if (chainLvl > 0 && hitShapes.length > 0) {
      triggerChainLightning(hitShapes, chainLvl, damage);
    }

    isDirty = true;
    updateUI();
  }

  // Chain Lightning between nearby shapes
  function triggerChainLightning(primaryTargets, maxJumps, directDamage) {
    const chainDamage = Math.max(1, Math.floor(directDamage * 0.50));
    const hitSet = new Set(primaryTargets.map(s => s.id));
    let currentSource = primaryTargets[0];

    for (let j = 0; j < maxJumps; j++) {
      // Find closest shape on field not yet hit in this chain
      let closest = null;
      let minDistance = 260; // Max jump radius in px

      for (const candidate of shapesOnField) {
        if (hitSet.has(candidate.id)) continue;
        const dist = Math.hypot(candidate.x - currentSource.x, candidate.y - currentSource.y);
        if (dist < minDistance) {
          minDistance = dist;
          closest = candidate;
        }
      }

      if (closest) {
        hitSet.add(closest.id);

        // Generate jagged lightning line segments
        const segments = generateLightningPath(currentSource.x, currentSource.y, closest.x, closest.y);
        lightningArcs.push({
          segments,
          alpha: 1.0,
          color: '#93c5fd'
        });

        applyDamageToShape(closest, chainDamage, true);
        currentSource = closest;
      } else {
        break; // No more shapes within jump range
      }
    }
  }

  // Generate jagged points for lightning
  function generateLightningPath(x1, y1, x2, y2) {
    const points = [{ x: x1, y: y1 }];
    const dist = Math.hypot(x2 - x1, y2 - y1);
    const steps = Math.max(3, Math.floor(dist / 25));

    for (let i = 1; i < steps; i++) {
      const t = i / steps;
      const nx = x1 + (x2 - x1) * t;
      const ny = y1 + (y2 - y1) * t;
      // Perpendicular displacement
      const perpAngle = Math.atan2(y2 - y1, x2 - x1) + Math.PI / 2;
      const disp = (Math.random() - 0.5) * 18;
      points.push({
        x: nx + Math.cos(perpAngle) * disp,
        y: ny + Math.sin(perpAngle) * disp
      });
    }

    points.push({ x: x2, y: y2 });
    return points;
  }

  // Apply damage to individual shape and check for death
  function applyDamageToShape(shape, damage, isChain = false) {
    shape.hp -= damage;
    shape.hitFlash = 0.15; // Flash white for 150ms
    createDamageText(damage, shape.x, shape.y, isChain);

    if (shape.hp <= 0) {
      destroyShape(shape);
    }
  }

  // Destroy shape & grant rewards
  function destroyShape(shape) {
    const idx = shapesOnField.indexOf(shape);
    if (idx !== -1) {
      shapesOnField.splice(idx, 1);
    }

    spawnDebris(shape.x, shape.y, shape.color, shape.sides, shape.radius);

    // Calculate Point Reward
    const pointMultBonus = 1 + ((state.upgrades.pointMultiplier || 0) * 0.15);
    const earned = Math.floor(shape.reward * pointMultBonus * getEffectiveMultiplier());

    state.points += earned;
    state.currentRunPoints = (state.currentRunPoints || 0) + earned;
    state.lifetimePoints += earned;
    state.currentRunPops = (state.currentRunPops || 0) + 1;
    state.lifetimePops++;
    state.stats.totalPops++;

    createRewardText(earned, shape.x, shape.y);
    isDirty = true;
    updateHudStats();
  }

  // Sentry Defense Turrets firing logic (v2 Green Exclusive)
  function processTurrets(now) {
    const config = getTurretConfig();
    if (config.count <= 0 || shapesOnField.length === 0) return;

    if (now - lastTurretFireTime >= config.intervalMs) {
      lastTurretFireTime = now;

      // Positions of the 4 corner sentries
      const pad = 24;
      const turretPositions = [
        { x: pad, y: pad }, // Top-Left
        { x: canvasRect.width - pad, y: pad }, // Top-Right
        { x: canvasRect.width - pad, y: canvasRect.height - pad }, // Bottom-Right
        { x: pad, y: canvasRect.height - pad } // Bottom-Left
      ];

      for (let t = 0; t < config.count; t++) {
        if (shapesOnField.length === 0) break;
        const turretPos = turretPositions[t];

        // Find shape with lowest HP or closest shape
        let target = shapesOnField[0];
        let minHp = target.hp;
        for (let s = 1; s < shapesOnField.length; s++) {
          if (shapesOnField[s].hp < minHp) {
            minHp = shapesOnField[s].hp;
            target = shapesOnField[s];
          }
        }

        // Fire Laser Beam
        laserBeams.push({
          startX: turretPos.x,
          startY: turretPos.y,
          endX: target.x,
          endY: target.y,
          alpha: 1.0,
          color: '#4ade80'
        });

        applyDamageToShape(target, config.damage, false);
      }

      isDirty = true;
      updateUI();
    }
  }

  // Render Corner Turrets (v2)
  function renderTurrets(ctx) {
    const config = getTurretConfig();
    if (config.count <= 0) return;

    const pad = 24;
    const turretPositions = [
      { x: pad, y: pad },
      { x: canvasRect.width - pad, y: pad },
      { x: canvasRect.width - pad, y: canvasRect.height - pad },
      { x: pad, y: canvasRect.height - pad }
    ];

    ctx.save();
    for (let t = 0; t < config.count; t++) {
      const pos = turretPositions[t];

      // Outer mount ring
      ctx.beginPath();
      ctx.arc(pos.x, pos.y, 14, 0, Math.PI * 2);
      ctx.fillStyle = '#16171d';
      ctx.fill();
      ctx.lineWidth = 1.5;
      ctx.strokeStyle = '#4ade80';
      ctx.stroke();

      // Find angle towards closest shape (or center if none)
      let aimAngle = 0;
      if (shapesOnField.length > 0) {
        aimAngle = Math.atan2(shapesOnField[0].y - pos.y, shapesOnField[0].x - pos.x);
      } else {
        aimAngle = Math.atan2(canvasRect.height / 2 - pos.y, canvasRect.width / 2 - pos.x);
      }

      // Barrel
      ctx.save();
      ctx.translate(pos.x, pos.y);
      ctx.rotate(aimAngle);

      ctx.fillStyle = '#4ade80';
      ctx.fillRect(0, -2.5, 14, 5);

      // Core pivot
      ctx.beginPath();
      ctx.arc(0, 0, 5, 0, Math.PI * 2);
      ctx.fillStyle = '#ffffff';
      ctx.fill();

      ctx.restore();
    }
    ctx.restore();
  }

  // Main Canvas Rendering Loop
  function render(now) {
    const delta = Math.min((now - lastFrameTime) / 1000, 0.1);
    lastFrameTime = now;

    // 0. Hold-down click auto-strike (~1 click/s base, improved with upgrades)
    if (pointer.isDown && pointer.isHovering && pointer.x >= 0 && pointer.y >= 0) {
      const holdInterval = getHoldClickInterval();
      if (now - lastHoldClickTime >= holdInterval) {
        lastHoldClickTime = now;
        dischargeBlast(pointer.x, pointer.y);
      }
    }

    // 1. Spawner Tick (keep field populated with batch support)
    const spawnCfg = getSpawnConfig();
    if (shapesOnField.length < spawnCfg.cap && (now - lastSpawnTime >= spawnCfg.intervalMs)) {
      const toSpawn = Math.min(spawnCfg.batchSize, spawnCfg.cap - shapesOnField.length);
      for (let b = 0; b < toSpawn; b++) {
        spawnShape();
      }
      lastSpawnTime = now;
    }

    // 2. Turrets Tick (v2)
    processTurrets(now);

    // 3. Clear Canvas
    ctx.clearRect(0, 0, canvasRect.width, canvasRect.height);

    // 4. Draw Corner Turrets
    renderTurrets(ctx);

    // 5. Update & Draw Shapes
    for (let i = 0; i < shapesOnField.length; i++) {
      const s = shapesOnField[i];

      // Smooth hovering oscillation around spawn point
      s.x = s.baseX + Math.sin(now * 0.001 * s.floatSpeedX + s.floatPhaseX) * s.floatDist;
      s.y = s.baseY + Math.cos(now * 0.001 * s.floatSpeedY + s.floatPhaseY) * s.floatDist;
      s.angle += s.rotSpeed * delta;

      if (s.spawnScale < 1.0) {
        s.spawnScale = Math.min(1.0, s.spawnScale + delta * 4);
      }

      if (s.hitFlash > 0) {
        s.hitFlash = Math.max(0, s.hitFlash - delta);
      }

      ctx.save();
      ctx.translate(s.x, s.y);
      ctx.scale(s.spawnScale, s.spawnScale);
      ctx.rotate(s.angle);

      // Draw Polygon
      ctx.beginPath();
      const angleStep = (Math.PI * 2) / s.sides;
      const startAngle = -Math.PI / 2;
      for (let p = 0; p < s.sides; p++) {
        const a = startAngle + p * angleStep;
        const px = Math.cos(a) * s.radius;
        const py = Math.sin(a) * s.radius;
        if (p === 0) ctx.moveTo(px, py);
        else ctx.lineTo(px, py);
      }
      ctx.closePath();

      // Fill & Stroke
      ctx.fillStyle = s.hitFlash > 0 ? 'rgba(255, 255, 255, 0.4)' : s.fillColor;
      ctx.fill();

      ctx.strokeStyle = s.hitFlash > 0 ? '#ffffff' : s.color;
      ctx.lineWidth = s.hitFlash > 0 ? 3 : 2;
      ctx.stroke();

      // Inner Core Dot
      ctx.beginPath();
      ctx.arc(0, 0, 3, 0, Math.PI * 2);
      ctx.fillStyle = s.hitFlash > 0 ? '#ffffff' : s.color;
      ctx.fill();

      ctx.restore();

      // Mini Health Bar above the shape
      const barW = Math.max(28, s.radius * 2);
      const barH = 3.5;
      const barX = s.x - barW / 2;
      const barY = s.y - s.radius - 10;

      ctx.fillStyle = 'rgba(18, 19, 24, 0.85)';
      ctx.fillRect(barX, barY, barW, barH);
      ctx.strokeStyle = '#363742';
      ctx.lineWidth = 1;
      ctx.strokeRect(barX, barY, barW, barH);

      const hpRatio = Math.max(0, Math.min(1, s.hp / s.maxHp));
      ctx.fillStyle = s.hitFlash > 0 ? '#ffffff' : (serverInfo.color === 'green' ? '#4ade80' : '#60a5fa');
      ctx.fillRect(barX, barY, barW * hpRatio, barH);
    }

    // 6. Draw Laser Beams (v2 Turrets)
    for (let i = laserBeams.length - 1; i >= 0; i--) {
      const beam = laserBeams[i];
      ctx.save();
      ctx.strokeStyle = beam.color;
      ctx.globalAlpha = beam.alpha;
      ctx.lineWidth = 2.5;
      ctx.beginPath();
      ctx.moveTo(beam.startX, beam.startY);
      ctx.lineTo(beam.endX, beam.endY);
      ctx.stroke();

      // Impact glow dot
      ctx.beginPath();
      ctx.arc(beam.endX, beam.endY, 4, 0, Math.PI * 2);
      ctx.fillStyle = '#ffffff';
      ctx.fill();
      ctx.restore();

      beam.alpha -= delta * 5;
      if (beam.alpha <= 0) laserBeams.splice(i, 1);
    }

    // 7. Draw Lightning Arcs
    for (let i = lightningArcs.length - 1; i >= 0; i--) {
      const arc = lightningArcs[i];
      ctx.save();
      ctx.strokeStyle = arc.color;
      ctx.globalAlpha = arc.alpha;
      ctx.lineWidth = 2;
      ctx.shadowColor = arc.color;
      ctx.shadowBlur = 6;

      ctx.beginPath();
      for (let p = 0; p < arc.segments.length; p++) {
        const pt = arc.segments[p];
        if (p === 0) ctx.moveTo(pt.x, pt.y);
        else ctx.lineTo(pt.x, pt.y);
      }
      ctx.stroke();
      ctx.restore();

      arc.alpha -= delta * 5;
      if (arc.alpha <= 0) lightningArcs.splice(i, 1);
    }

    // 8. Draw Expanding Shockwaves
    for (let i = shockwaves.length - 1; i >= 0; i--) {
      const sw = shockwaves[i];
      sw.radius += (sw.maxRadius - sw.radius) * delta * 12 + 2;
      sw.alpha -= delta * 2.4;

      if (sw.alpha <= 0 || sw.radius >= sw.maxRadius) {
        shockwaves.splice(i, 1);
        continue;
      }

      ctx.save();
      ctx.beginPath();
      ctx.arc(sw.x, sw.y, sw.radius, 0, Math.PI * 2);
      ctx.strokeStyle = sw.color;
      ctx.globalAlpha = Math.max(0, sw.alpha);
      ctx.lineWidth = 2;
      ctx.stroke();
      ctx.restore();
    }

    // 9. Draw Particle Debris
    for (let i = particles.length - 1; i >= 0; i--) {
      const p = particles[i];
      p.x += p.vx * delta;
      p.y += p.vy * delta;
      p.vx *= 0.95;
      p.vy *= 0.95;
      p.alpha -= delta * p.decay;

      if (p.alpha <= 0) {
        particles.splice(i, 1);
        continue;
      }

      ctx.save();
      ctx.globalAlpha = p.alpha;
      ctx.fillStyle = p.color;
      ctx.fillRect(p.x, p.y, p.size, p.size);
      ctx.restore();
    }

    // 10. Draw Custom Interactive Reticle at cursor
    if (pointer.isHovering && pointer.x >= 0 && pointer.y >= 0) {
      const blastRad = getBlastRadius();

      ctx.save();
      ctx.beginPath();
      ctx.arc(pointer.x, pointer.y, blastRad, 0, Math.PI * 2);
      ctx.strokeStyle = pointer.isDown ? '#ffffff' : (serverInfo.color === 'green' ? 'rgba(74, 222, 128, 0.45)' : 'rgba(96, 165, 250, 0.45)');
      ctx.lineWidth = pointer.isDown ? 2 : 1.2;
      ctx.setLineDash([4, 4]);
      ctx.stroke();

      // Center crosshair
      ctx.setLineDash([]);
      ctx.strokeStyle = '#ffffff';
      ctx.lineWidth = 1;
      const crossSize = 6;
      ctx.beginPath();
      ctx.moveTo(pointer.x - crossSize, pointer.y);
      ctx.lineTo(pointer.x + crossSize, pointer.y);
      ctx.moveTo(pointer.x, pointer.y - crossSize);
      ctx.lineTo(pointer.x, pointer.y + crossSize);
      ctx.stroke();

      ctx.restore();
    }

    requestAnimationFrame(render);
  }

  // Update HUD Display
  function updateHudStats() {
    const spawnCfg = getSpawnConfig();
    const blastRad = getBlastRadius();
    const chainLvl = state.upgrades.chainLightning || 0;
    const turretCfg = getTurretConfig();

    els.pointsDisplay.textContent = formatNum(state.points);
    els.fieldCountDisplay.textContent = `${shapesOnField.length} / ${spawnCfg.cap}`;
    els.blastRadiusDisplay.textContent = `${blastRad}px`;
    els.chainDisplay.textContent = `${chainLvl} jumps`;

    if (serverInfo.prestigeEnabled && turretCfg.count > 0) {
      els.turretChip.style.display = 'flex';
      els.turretsDisplay.textContent = `${turretCfg.count}`;
    } else {
      els.turretChip.style.display = 'none';
    }

    // Footer stats
    els.statLifetimePoints.textContent = formatNum(state.lifetimePoints);
    els.statLifetimePops.textContent = formatNum(state.lifetimePops);
    els.statTotalClicks.textContent = formatNum(state.stats.totalClicks);
  }

  // Full UI Update
  function updateUI() {
    updateHudStats();

    // Multiplier banner (only if v2 and multiplier > 1)
    const mult = getEffectiveMultiplier();
    if (serverInfo.prestigeEnabled && mult > 1.0) {
      els.prestigeMultiplierBanner.classList.remove('hidden');
      els.globalMultiplierText.textContent = `x${mult.toFixed(2)}`;
    } else {
      els.prestigeMultiplierBanner.classList.add('hidden');
    }

    // Prestige Portal Stats (v2)
    if (serverInfo.prestigeEnabled) {
      const shards = state.prestige.shards || 0;
      els.currentShardsDisplay.textContent = `${shards} 💎`;
      els.currentMultiplierDisplay.textContent = `+${shards * 10}%`;

      const pending = calculatePendingShards(state.currentRunPoints || 0, state.currentRunPops || 0);
      els.pendingShardsDisplay.textContent = `+${pending} 💎`;

      if (pending > 0) {
        els.ascendBtn.disabled = false;
        els.ascendReqMsg.textContent = `Ascend for +${pending} 💎 (+${pending * 10}% power)`;
        els.ascendReqMsg.style.color = '#4ade80';
      } else {
        els.ascendBtn.disabled = true;
        els.ascendReqMsg.textContent = 'Needs 500+ energy & 30+ pops.';
        els.ascendReqMsg.style.color = '#f87171';
      }
    }

    updateUpgradesShop();
  }

  function calculatePendingShards(currentRunPoints, currentRunPops) {
    if (currentRunPoints < 500 || currentRunPops < 30) return 0;
    return Math.max(1, Math.floor(Math.sqrt(currentRunPoints / 500)));
  }

  // Escapa texto antes de insertarlo como HTML (evita XSS si los datos que
  // vienen del servidor alguna vez incluyeran contenido no confiable)
  function escapeHtml(value) {
    return String(value)
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;')
      .replace(/'/g, '&#39;');
  }

  // Render & Update Upgrades List in DOM
  function updateUpgradesShop() {
    if (!serverInfo.upgradesDef || Object.keys(serverInfo.upgradesDef).length === 0) return;

    if (!upgradesListRendered) {
      let html = '';
      for (const [rawKey, def] of Object.entries(serverInfo.upgradesDef)) {
        const key = escapeHtml(rawKey);
        const isV2 = def.isV2Only ? 'v2-feature' : '';
        html += `
          <div class="upgrade-item ${isV2}" id="upgrade-item-${key}">
            <div class="upgrade-info">
              <div class="upgrade-title-row">
                <span class="upgrade-name">${escapeHtml(def.name)}</span>
                <span class="upgrade-lvl" id="upgrade-lvl-${key}">Lvl 0</span>
              </div>
              <div class="upgrade-desc">${escapeHtml(def.desc)}</div>
            </div>
            <button class="buy-btn" id="upgrade-btn-${key}" data-key="${key}">
              --
            </button>
          </div>
        `;
      }
      els.upgradesContainer.innerHTML = html;

      // Event delegation for upgrades
      els.upgradesContainer.querySelectorAll('.buy-btn').forEach(btn => {
        btn.addEventListener('click', (e) => {
          e.stopPropagation();
          const key = btn.dataset.key;
          if (key) buyUpgrade(key);
        });
      });

      upgradesListRendered = true;
    }

    // Update in-place
    for (const [key, def] of Object.entries(serverInfo.upgradesDef)) {
      const lvlEl = document.getElementById(`upgrade-lvl-${key}`);
      const btnEl = document.getElementById(`upgrade-btn-${key}`);
      if (!lvlEl || !btnEl) continue;

      const currentLvl = state.upgrades[key] || 0;
      const isMax = def.maxLevel && currentLvl >= def.maxLevel;
      const cost = isMax ? Infinity : Math.floor(def.baseCost * Math.pow(def.costMultiplier, currentLvl));
      const canAfford = state.points >= cost && !isMax;

      const ascensions = (state.prestige && state.prestige.ascensions) || 0;
      const isLockedByPrestige = def.requiresPrestige && ascensions < def.requiresPrestige;

      if (isLockedByPrestige) {
        lvlEl.textContent = 'Req: 1 Prestige';
        btnEl.textContent = 'LOCKED';
        btnEl.disabled = true;
      } else {
        lvlEl.textContent = `Lvl ${currentLvl}${def.maxLevel ? ` / ${def.maxLevel}` : ''}`;
        btnEl.textContent = isMax ? 'MAXED' : `${formatNum(cost)} ⬡`;
        btnEl.disabled = !canAfford;
      }
    }
  }

  // Buy Upgrade Action
  async function buyUpgrade(key) {
    const def = serverInfo.upgradesDef[key];
    if (!def) return;

    const ascensions = (state.prestige && state.prestige.ascensions) || 0;
    if (def.requiresPrestige && ascensions < def.requiresPrestige) {
      alert('This upgrade unlocks after your first Prestige Ascension!');
      return;
    }

    const currentLvl = state.upgrades[key] || 0;
    const cost = Math.floor(def.baseCost * Math.pow(def.costMultiplier, currentLvl));

    if (state.points < cost) return;

    // 1) Guardar primero el saldo actual: el auto-guardado corre cada 3 s y,
    //    sin esto, el servidor podía tener menos puntos y responder 400
    //    ("Not enough points") aunque en pantalla alcanzaran.
    // 2) La compra la hace el servidor, que es la única fuente de verdad:
    //    no se descuenta localmente antes, así un auto-guardado intermedio no
    //    puede cobrar la mejora dos veces.
    isDirty = true;
    await saveState();

    try {
      const res = await fetch('/api/upgrade', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ playerId: state.playerId, upgradeKey: key })
      });
      const data = await res.json();
      if (data.success && data.state) {
        state = data.state;
        updateUI();
      } else if (data.error) {
        console.warn('[Upgrade] Rejected by server:', data.error);
      }
    } catch (err) {
      console.warn('[Upgrade] Request failed, upgrade not applied:', err.message);
    }
  }

  // Prestige Ascension Action (v2)
  async function performAscend() {
    if (!serverInfo.prestigeEnabled) return;
    if (!confirm('Ascend now? Resets run for permanent Shards.')) {
      return;
    }

    try {
      const res = await fetch('/api/prestige', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ playerId: state.playerId })
      });
      const data = await res.json();
      if (data.success && data.state) {
        state = data.state;
        state.points = 0;
        state.currentRunPoints = 0;
        state.currentRunPops = 0;
        shapesOnField = [];
        fillFieldToCap();
        updateUI();
        alert(data.message || 'Ascended successfully!');
      } else {
        alert(data.error || 'Failed to ascend');
      }
    } catch (err) {
      alert('Network error while communicating with server.');
    }
  }

  // Network Sync: Load State from Server/Redis
  async function fetchServerInfoAndState() {
    try {
      const versionRes = await fetch('/api/version');
      serverInfo = await versionRes.json();

      // Configure Theme & UI
      if (serverInfo.color === 'green') {
        document.body.className = 'theme-green';
        els.versionBadge.className = 'badge badge-green';
        els.versionLabel.textContent = `GREEN EDITION ${serverInfo.version}`;
        els.tabPrestigeBtn.disabled = false;
        els.prestigeLockPill.style.display = 'none';
      } else {
        document.body.className = 'theme-blue';
        els.versionBadge.className = 'badge badge-blue';
        els.versionLabel.textContent = `BLUE EDITION ${serverInfo.version}`;
        els.tabPrestigeBtn.disabled = true;
        els.prestigeLockPill.style.display = 'inline-block';
      }

      els.podHostname.textContent = serverInfo.podName || 'k8s-pod';

      // Load Player State
      const stateRes = await fetch(`/api/state/${state.playerId}`);
      const stateData = await stateRes.json();

      if (stateData.success && stateData.state) {
        state = stateData.state;
        els.syncIndicator.className = 'sync-dot ok';
        els.syncText.textContent = 'Redis Synced';
      }

      updateUI();
    } catch (err) {
      console.error('[App] Failed to load server data:', err);
      els.syncIndicator.className = 'sync-dot';
      els.syncText.textContent = 'Offline Mode';
    }
  }

  // Auto-Save State to Backend/Redis
  async function saveState() {
    if (!isDirty && !serverInfo.redisConnected) return;

    try {
      els.syncIndicator.className = 'sync-dot';
      els.syncText.textContent = 'Saving...';

      const res = await fetch('/api/save', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ playerId: state.playerId, state })
      });

      const data = await res.json();
      if (data.success) {
        isDirty = false;
        els.syncIndicator.className = 'sync-dot ok';
        els.syncText.textContent = 'Redis Synced';
      }
    } catch (err) {
      els.syncIndicator.className = 'sync-dot';
      els.syncText.textContent = 'Save Queued';
    }
  }

  // Event Listeners
  function initListeners() {
    window.addEventListener('resize', resizeCanvas);

    // Pointer Events on Canvas for Instant Response
    canvas.addEventListener('pointermove', (e) => {
      const rect = canvas.getBoundingClientRect();
      pointer.x = e.clientX - rect.left;
      pointer.y = e.clientY - rect.top;
      pointer.isHovering = true;
    });

    canvas.addEventListener('pointerenter', () => {
      pointer.isHovering = true;
    });

    canvas.addEventListener('pointerleave', () => {
      pointer.isHovering = false;
      pointer.isDown = false;
      pointer.x = -999;
      pointer.y = -999;
    });

    canvas.addEventListener('pointerdown', (e) => {
      if (e.button !== 0 && e.pointerType === 'mouse') return; // only left click
      e.preventDefault();
      const rect = canvas.getBoundingClientRect();
      pointer.x = e.clientX - rect.left;
      pointer.y = e.clientY - rect.top;
      pointer.isDown = true;
      lastHoldClickTime = performance.now();
      dischargeBlast(pointer.x, pointer.y);
    });

    window.addEventListener('pointerup', () => {
      pointer.isDown = false;
    });

    // Tab Switching
    els.tabUpgradesBtn.addEventListener('click', () => {
      els.tabUpgradesBtn.classList.add('active');
      els.tabPrestigeBtn.classList.remove('active');
      els.tabUpgrades.classList.add('active');
      els.tabPrestige.classList.remove('active');
    });

    els.tabPrestigeBtn.addEventListener('click', () => {
      if (els.tabPrestigeBtn.disabled) return;
      els.tabPrestigeBtn.classList.add('active');
      els.tabUpgradesBtn.classList.remove('active');
      els.tabPrestige.classList.add('active');
      els.tabUpgrades.classList.remove('active');
    });

    els.ascendBtn.addEventListener('click', performAscend);

    els.saveBtn.addEventListener('click', () => {
      isDirty = true;
      saveState();
    });

    els.resetBtn.addEventListener('click', () => {
      if (confirm('Reset all progress?')) {
        localStorage.removeItem('shape_player_id');
        window.location.reload();
      }
    });

    // Periodic auto-save every 3 seconds
    setInterval(saveState, 3000);

    // Periodic telemetry check every 5 seconds to detect live Blue/Green deployment switches
    setInterval(async () => {
      try {
        const res = await fetch('/api/version');
        const info = await res.json();
        if (info.podName !== serverInfo.podName || info.color !== serverInfo.color) {
          console.log(`[Telemetry] Switched to new Pod: ${info.podName} (${info.color})`);
          await fetchServerInfoAndState();
        }
      } catch {}
    }, 5000);
  }

  // Initialization
  async function init() {
    state.playerId = getOrCreatePlayerId();
    resizeCanvas();
    initListeners();
    await fetchServerInfoAndState();
    fillFieldToCap();
    requestAnimationFrame(render);
  }

  init();
})();
