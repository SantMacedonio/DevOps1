#!/usr/bin/env node
// Resume el reporte JSON de Semgrep y decide si el pipeline sigue.
// Uso: node ci/semgrep-gate.js reports/ci/semgrep.json
// Falla (exit 1) si hay hallazgos de severidad ERROR (los de mayor riesgo).
const fs = require('fs');

const file = process.argv[2];
const report = JSON.parse(fs.readFileSync(file, 'utf8'));
const results = report.results || [];
const bySeverity = { ERROR: 0, WARNING: 0, INFO: 0 };
for (const r of results) {
  const sev = (r.extra && r.extra.severity) || 'INFO';
  bySeverity[sev] = (bySeverity[sev] || 0) + 1;
}

console.log('================ Semgrep (SAST) ================');
console.log(`Archivos analizados: ${(report.paths && report.paths.scanned || []).length}`);
console.log(`Hallazgos: ERROR=${bySeverity.ERROR}  WARNING=${bySeverity.WARNING}  INFO=${bySeverity.INFO}`);
for (const r of results) {
  console.log(`  [${r.extra.severity}] ${r.path}:${r.start.line}  ${r.check_id}`);
  console.log(`      ${String(r.extra.message).split('\n')[0]}`);
}
if ((report.errors || []).length) {
  console.log(`Avisos del análisis (archivos que no se pudieron leer): ${report.errors.length}`);
}

if (bySeverity.ERROR > 0) {
  console.error(`\n[X] Semgrep encontró ${bySeverity.ERROR} hallazgo(s) de severidad ERROR: el pipeline se detiene.`);
  process.exit(1);
}
console.log('\n[OK] Sin hallazgos de severidad ERROR');
