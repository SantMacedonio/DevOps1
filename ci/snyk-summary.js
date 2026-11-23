#!/usr/bin/env node
// Muestra en el log un resumen legible del reporte JSON de Snyk.
// Uso: node ci/snyk-summary.js reports/ci/snyk.json
// (La decisión de cortar el pipeline la toma el código de salida de "snyk test
// --severity-threshold=critical"; este script solo informa.)
const fs = require('fs');

let report;
try {
  report = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
} catch {
  console.log('Snyk no generó un reporte JSON (ver el error de arriba).');
  process.exit(0);
}
if (report.error) {
  console.log(`Snyk devolvió un error: ${report.error}`);
  process.exit(0);
}

const vulns = report.vulnerabilities || [];
const unique = new Map();
for (const v of vulns) unique.set(`${v.id}|${v.packageName}@${v.version}`, v);
const count = { critical: 0, high: 0, medium: 0, low: 0 };
for (const v of unique.values()) count[v.severity] = (count[v.severity] || 0) + 1;

console.log('============ Snyk (dependencias npm) ============');
console.log(`Proyecto: ${report.projectName || '-'}   Dependencias analizadas: ${report.dependencyCount ?? '-'}`);
console.log(`Umbral de corte: critical`);
console.log(`Vulnerabilidades: critical=${count.critical}  high=${count.high}  medium=${count.medium}  low=${count.low}`);
for (const v of unique.values()) {
  const fix = v.fixedIn && v.fixedIn.length ? `corregido en ${v.fixedIn.join(', ')}` : 'sin versión corregida';
  console.log(`  [${v.severity.toUpperCase()}] ${v.packageName}@${v.version}  ${v.id}  ${v.title}  (${fix})`);
  console.log(`      ruta: ${(v.from || []).join(' > ')}`);
}
