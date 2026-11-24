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
const order = { critical: 0, high: 1, medium: 2, low: 3 };
for (const v of [...unique.values()].sort((a, b) => (order[a.severity] ?? 9) - (order[b.severity] ?? 9))) {
  const fix = v.fixedIn && v.fixedIn.length ? `corregido en ${v.fixedIn.join(', ')}` : 'sin versión corregida';
  console.log(`  [${v.severity.toUpperCase()}] ${v.packageName}@${v.version}  ${v.id}  ${v.title}  (${fix})`);
  console.log(`      ruta: ${(v.from || []).join(' > ')}`);
  console.log(`      corrección propuesta: ${proposeFix(v)}`);
}
if (unique.size === 0) console.log('  Sin vulnerabilidades conocidas: no hace falta ninguna corrección.');

// Corrección sugerida a partir de los datos de Snyk:
//  - upgradePath: a qué versión subir la dependencia DIRECTA (de package.json)
//    para que la librería vulnerable quede corregida, aunque sea transitiva;
//  - fixedIn: versiones de la librería vulnerable que ya traen el arreglo.
function proposeFix(v) {
  const direct = (v.from || [])[1];
  const target = (v.upgradePath || []).find(Boolean);
  if (v.isUpgradable && target) {
    return `actualizar la dependencia directa ${direct} a ${target} (npm install ${target})`;
  }
  if (v.fixedIn && v.fixedIn.length) {
    return `actualizar ${v.packageName} a ${v.fixedIn[0]} o posterior; si es transitiva, con "overrides" en package.json`;
  }
  return `no hay versión corregida: eliminar ${v.packageName} o reemplazarlo por una alternativa mantenida`;
}
