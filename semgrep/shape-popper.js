// Casos de prueba de las reglas propias (semgrep --test semgrep/).
// "ruleid: <regla>" = la línea siguiente DEBE detectarse.
// "ok: <regla>"     = la línea siguiente NO debe detectarse.
// Este archivo tiene código inseguro a propósito: los análisis del proyecto
// excluyen la carpeta semgrep/.
const express = require('express');
const helmet = require('helmet');

function appInsegura() {
  // ruleid: express-sin-helmet
  const app = express();
  // ruleid: express-json-sin-limite
  app.use(express.json());
  // ruleid: express-json-sin-limite
  app.use(express.json({ strict: true }));
  return app;
}

function appSegura() {
  // ok: express-sin-helmet
  const app = express();
  app.use(helmet({ contentSecurityPolicy: true }));
  // ok: express-json-sin-limite
  app.use(express.json({ limit: '100kb' }));
  return app;
}

function render(el, nombre) {
  // ruleid: innerhtml-con-contenido-dinamico
  el.innerHTML = `<b>${nombre}</b>`;
  // ok: innerhtml-con-contenido-dinamico
  el.innerHTML = '<b>texto fijo</b>';
  // ok: innerhtml-con-contenido-dinamico
  el.textContent = nombre;
}

module.exports = { appInsegura, appSegura, render };
