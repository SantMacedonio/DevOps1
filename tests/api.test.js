// Tests de la API HTTP (src/app.js) contra un servidor real en un puerto
// aleatorio. Corren sin Redis (REDIS_ENABLED=false): la app usa su modo memoria.
// Ejecutar: npm test
process.env.REDIS_ENABLED = 'false';
process.env.APP_COLOR = 'blue';

const { test, describe, before, after } = require('node:test');
const assert = require('node:assert/strict');
const app = require('../src/app');

let server;
let baseUrl;

before(async () => {
  server = app.listen(0);
  await new Promise((resolve) => server.once('listening', resolve));
  baseUrl = `http://127.0.0.1:${server.address().port}`;
});

after(() => new Promise((resolve) => server.close(resolve)));

const get = (path) => fetch(baseUrl + path);
const post = (path, body) => fetch(baseUrl + path, {
  method: 'POST',
  headers: { 'Content-Type': 'application/json' },
  body: typeof body === 'string' ? body : JSON.stringify(body)
});

describe('probes de Kubernetes', () => {
  test('GET /healthz responde 200 "healthy"', async () => {
    const res = await get('/healthz');
    assert.equal(res.status, 200);
    assert.equal((await res.json()).status, 'healthy');
  });

  test('GET /readyz informa el modo memoria cuando no hay Redis', async () => {
    const body = await (await get('/readyz')).json();
    assert.equal(body.status, 'ready');
    assert.equal(body.redis, 'offline-memory-mode');
  });
});

describe('frontend y headers de seguridad', () => {
  test('GET / sirve el juego', async () => {
    const res = await get('/');
    assert.equal(res.status, 200);
    assert.match(await res.text(), /<title>Shape Popper/);
  });

  test('incluye CSP estricta y no expone X-Powered-By', async () => {
    const res = await get('/');
    const csp = res.headers.get('content-security-policy');
    assert.ok(csp, 'falta el header Content-Security-Policy');
    assert.match(csp, /script-src 'self'/);
    assert.doesNotMatch(csp, /unsafe-inline/);
    assert.equal(res.headers.get('x-content-type-options'), 'nosniff');
    assert.equal(res.headers.get('x-powered-by'), null);
  });
});

describe('API del juego', () => {
  const player = 'user_apitest_01';

  test('GET /api/version: Blue no ofrece mejoras exclusivas de Green', async () => {
    const body = await (await get('/api/version')).json();
    assert.equal(body.color, 'blue');
    assert.equal(body.prestigeEnabled, false);
    for (const def of Object.values(body.upgradesDef)) {
      assert.notEqual(def.isV2Only, true, `${def.id} es exclusiva de Green`);
    }
  });

  test('rechaza playerId inválidos (400)', async () => {
    assert.equal((await get('/api/state/abc')).status, 400);              // muy corto
    assert.equal((await get('/api/state/user%20malo!!')).status, 400);    // caracteres no permitidos
    assert.equal((await post('/api/save', { playerId: '../etc', state: {} })).status, 400);
  });

  test('un jugador nuevo empieza con 0 puntos', async () => {
    const body = await (await get(`/api/state/${player}`)).json();
    assert.equal(body.success, true);
    assert.equal(body.state.points, 0);
  });

  test('no se puede comprar sin puntos suficientes (400)', async () => {
    const res = await post('/api/upgrade', { playerId: player, upgradeKey: 'clickDamage' });
    assert.equal(res.status, 400);
    assert.equal((await res.json()).error, 'Not enough points');
  });

  test('guardar y comprar: descuenta el costo y sube el nivel', async () => {
    assert.equal((await post('/api/save', { playerId: player, state: { points: 100 } })).status, 200);
    const res = await post('/api/upgrade', { playerId: player, upgradeKey: 'clickDamage' });
    assert.equal(res.status, 200);
    const { state } = await res.json();
    assert.equal(state.points, 90);              // 100 - 10 (costo del nivel 0)
    assert.equal(state.upgrades.clickDamage, 1);
  });

  test('rechaza claves heredadas como "constructor" o "__proto__" (400)', async () => {
    for (const key of ['constructor', '__proto__', 'toString']) {
      const res = await post('/api/upgrade', { playerId: player, upgradeKey: key });
      assert.equal(res.status, 400, `upgradeKey=${key}`);
    }
  });

  test('el prestigio está bloqueado en Blue (403)', async () => {
    assert.equal((await post('/api/prestige', { playerId: player })).status, 403);
  });

  test('rechaza bodies de más de 100 KB (413)', async () => {
    const big = JSON.stringify({ playerId: player, state: { x: 'a'.repeat(200 * 1024) } });
    assert.equal((await post('/api/save', big)).status, 413);
  });
});

describe('métricas de Prometheus', () => {
  test('GET /metrics expone métricas HTTP, de proceso y de negocio', async () => {
    const res = await get('/metrics');
    assert.equal(res.status, 200);
    const text = await res.text();
    assert.match(text, /http_requests_total\{/);
    assert.match(text, /http_request_duration_seconds_bucket/);
    assert.match(text, /process_resident_memory_bytes/);
    assert.match(text, /shape_game_upgrades_purchased_total\{.*upgrade="clickDamage"/);
  });
});
