// Tests unitarios de la lógica del juego (src/gameLogic.js)
// Ejecutar: npm test
const { test, describe } = require('node:test');
const assert = require('node:assert/strict');
const gameLogic = require('../src/gameLogic');

describe('getUpgradeCost', () => {
  test('el costo base es el del nivel 0', () => {
    assert.equal(gameLogic.getUpgradeCost('clickDamage', 0), 10);
  });

  test('el costo crece con el multiplicador y se redondea hacia abajo', () => {
    // 10 * 1.25^1 = 12.5 -> 12 ; 10 * 1.25^2 = 15.625 -> 15
    assert.equal(gameLogic.getUpgradeCost('clickDamage', 1), 12);
    assert.equal(gameLogic.getUpgradeCost('clickDamage', 2), 15);
  });

  test('una mejora inexistente cuesta Infinity (no se puede comprar)', () => {
    assert.equal(gameLogic.getUpgradeCost('noExiste', 0), Infinity);
  });

  test('al llegar al nivel máximo el costo es Infinity', () => {
    const max = gameLogic.UPGRADES_DEF.blastRadius.maxLevel;
    assert.ok(Number.isFinite(gameLogic.getUpgradeCost('blastRadius', max - 1)));
    assert.equal(gameLogic.getUpgradeCost('blastRadius', max), Infinity);
  });
});

describe('calculatePrestigeShards', () => {
  test('no da fragmentos por debajo de los mínimos (500 de energía y 30 figuras)', () => {
    assert.equal(gameLogic.calculatePrestigeShards(0, 0), 0);
    assert.equal(gameLogic.calculatePrestigeShards(499, 100), 0);
    assert.equal(gameLogic.calculatePrestigeShards(500, 29), 0);
  });

  test('en el mínimo exacto da 1 fragmento', () => {
    assert.equal(gameLogic.calculatePrestigeShards(500, 30), 1);
  });

  test('crece con la raíz cuadrada de la energía', () => {
    // sqrt(2000 / 500) = 2 ; sqrt(4500 / 500) = 3
    assert.equal(gameLogic.calculatePrestigeShards(2000, 30), 2);
    assert.equal(gameLogic.calculatePrestigeShards(4500, 30), 3);
  });
});

describe('createInitialState', () => {
  test('un jugador nuevo empieza sin puntos, en el nivel 0 y sin prestigio', () => {
    const s = gameLogic.createInitialState('user_test_1');
    assert.equal(s.playerId, 'user_test_1');
    assert.equal(s.points, 0);
    assert.equal(s.upgrades.clickDamage, 0);
    assert.equal(s.prestige.ascensions, 0);
    assert.equal(s.prestige.globalMultiplier, 1.0);
  });
});

describe('sanitizeState', () => {
  test('sin estado previo devuelve el estado inicial', () => {
    const s = gameLogic.sanitizeState(null, 'user_test_2', true);
    assert.deepEqual(s.upgrades, gameLogic.createInitialState('user_test_2').upgrades);
  });

  test('conserva los puntos y completa los campos faltantes', () => {
    const s = gameLogic.sanitizeState({ points: 123 }, 'user_test_3', true);
    assert.equal(s.points, 123);
    assert.ok(s.stats && s.prestige && s.upgrades);
  });

  test('migra el nombre viejo de mejora clickPower a clickDamage', () => {
    const s = gameLogic.sanitizeState({ upgrades: { clickPower: 4 } }, 'user_test_4', true);
    assert.equal(s.upgrades.clickDamage, 4);
  });

  test('en Blue (sin prestigio) conserva las torretas y los fragmentos, pero no aplica el multiplicador', () => {
    const raw = { upgrades: { autoTurret: 3 }, prestige: { shards: 5 } };
    const s = gameLogic.sanitizeState(raw, 'user_test_5', false);
    assert.equal(s.upgrades.autoTurret, 3);   // no se borran (compatibilidad al volver atrás)
    assert.equal(s.prestige.shards, 5);
    assert.equal(s.prestige.globalMultiplier, 1.0);
  });

  test('en Green (con prestigio) aplica +10% por fragmento', () => {
    const raw = { upgrades: { autoTurret: 3 }, prestige: { shards: 5 } };
    const s = gameLogic.sanitizeState(raw, 'user_test_6', true);
    assert.equal(s.upgrades.autoTurret, 3);
    assert.equal(s.prestige.globalMultiplier, 1.5);
  });
});
