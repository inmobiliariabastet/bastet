/* Pruebas del motor de contratos: helpers en español y plantilla.  Ejecutar:  node --test tests/ */
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const H = require('../assets/js/contracts/contract-helpers.js');
const T = require('../assets/js/contracts/contract-template.js');

const TEMPLATE = fs.readFileSync(path.join(__dirname, '..', 'assets', 'contracts', 'exclusividad-v1.md'), 'utf8');

/* ───────── Helpers ───────── */
test('enteros en letras', () => {
  const cases = [[0, 'cero'], [1, 'uno'], [15, 'quince'], [16, 'dieciséis'], [21, 'veintiuno'], [30, 'treinta'], [31, 'treinta y uno'],
    [99, 'noventa y nueve'], [100, 'cien'], [101, 'ciento uno'], [115, 'ciento quince'], [500, 'quinientos'], [999, 'novecientos noventa y nueve'],
    [1000, 'mil'], [1001, 'mil uno'], [1100, 'mil cien'], [2026, 'dos mil veintiséis'], [21000, 'veintiún mil'], [100000, 'cien mil'],
    [450000, 'cuatrocientos cincuenta mil'], [1000000, 'un millón'], [1000001, 'un millón uno'], [2000000, 'dos millones'],
    [21000000, 'veintiún millones'], [1500000, 'un millón quinientos mil'], [999999999, 'novecientos noventa y nueve millones novecientos noventa y nueve mil novecientos noventa y nueve']];
  for (const [n, w] of cases) assert.equal(H.integerToWords(n), w, String(n));
  assert.throws(() => H.integerToWords(-1)); assert.throws(() => H.integerToWords(1e12));
});

test('enteros con apócope (antes de sustantivos)', () => {
  assert.equal(H.integerToWords(1, { apocope: true }), 'un');
  assert.equal(H.integerToWords(21, { apocope: true }), 'veintiún');
  assert.equal(H.integerToWords(31, { apocope: true }), 'treinta y un');
  assert.equal(H.integerToWords(101, { apocope: true }), 'ciento un');
});

test('montos en letras (convención boliviana)', () => {
  assert.equal(H.moneyToWords(450000, 'Bs'), 'CUATROCIENTOS CINCUENTA MIL 00/100 BOLIVIANOS');
  assert.equal(H.moneyToWords(450000.5, 'Bs'), 'CUATROCIENTOS CINCUENTA MIL 50/100 BOLIVIANOS');
  assert.equal(H.moneyToWords(120000, 'USD'), 'CIENTO VEINTE MIL 00/100 DÓLARES ESTADOUNIDENSES');
  assert.equal(H.moneyToWords(0, 'Bs'), 'CERO 00/100 BOLIVIANOS');
  assert.equal(H.moneyToWords(1, 'Bs'), 'UN 00/100 BOLIVIANOS');
  assert.equal(H.moneyToWords(15, 'Bs'), 'QUINCE 00/100 BOLIVIANOS');
  assert.equal(H.moneyToWords(100, 'USD'), 'CIEN 00/100 DÓLARES ESTADOUNIDENSES');
  assert.equal(H.moneyToWords(1000, 'Bs'), 'MIL 00/100 BOLIVIANOS');
  assert.equal(H.moneyToWords(21000, 'Bs'), 'VEINTIÚN MIL 00/100 BOLIVIANOS');
  assert.equal(H.moneyToWords(1000000, 'USD'), 'UN MILLÓN 00/100 DÓLARES ESTADUNIDENSES'.replace('ESTADUNIDENSES', 'ESTADOUNIDENSES'));
  assert.equal(H.moneyToWords(2500000.99, 'Bs'), 'DOS MILLONES QUINIENTOS MIL 99/100 BOLIVIANOS');
  assert.equal(H.moneyToWords(10.999, 'Bs'), 'ONCE 00/100 BOLIVIANOS'); // el redondeo a centavos acarrea al entero
  assert.throws(() => H.moneyToWords(-5, 'Bs'));
});

test('números con y sin decimales (plazos, porcentajes, ejemplares)', () => {
  assert.equal(H.numberToLiteral(90), 'noventa');
  assert.equal(H.numberToLiteral(1), 'un');
  assert.equal(H.numberToLiteral(2), 'dos');
  assert.equal(H.numberToLiteral(21), 'veintiún');
  assert.equal(H.numberToLiteral(3.5), 'tres coma cinco');
  assert.equal(H.numberToLiteral(2.25), 'dos coma veinticinco');
  assert.equal(H.numberToLiteral(2.05), 'dos coma cero cinco');
  assert.equal(H.numberToLiteral(1.5), 'uno coma cinco');
  assert.equal(H.numberToLiteral(0.5), 'cero coma cinco');
});

test('formato numérico: miles con punto y decimales con coma', () => {
  assert.equal(H.formatMoney(450000), '450.000,00');
  assert.equal(H.formatMoney(450000.5), '450.000,50');
  assert.equal(H.formatMoney(0), '0,00');
  assert.equal(H.formatMoney(1234567.891), '1.234.567,89');
  assert.equal(H.formatMoney(999.999), '1.000,00');
  assert.equal(H.formatQty(98), '98');
  assert.equal(H.formatQty(120.5), '120,5');
  assert.equal(H.formatQty(1500.25), '1.500,25');
  assert.equal(H.formatQty(3), '3');
});

test('lectura de montos escritos por personas', () => {
  assert.equal(H.parseAmount('450.000,50'), 450000.5);
  assert.equal(H.parseAmount('450000.5'), 450000.5);
  assert.equal(H.parseAmount('450.000'), 450000);
  assert.equal(H.parseAmount('1.5'), 1.5);
  assert.equal(H.parseAmount('3,5'), 3.5);
  assert.equal(H.parseAmount(' 120 '), 120);
  assert.equal(H.parseAmount('1.000.000'), 1000000);
  assert.equal(H.parseAmount('abc'), null);
  assert.equal(H.parseAmount(''), null);
  assert.equal(H.parseAmount('12,3,4'), null);
});

test('fechas en letras', () => {
  assert.equal(H.dateToLiteral('2026-10-02'), 'dos de octubre de dos mil veintiséis');
  assert.equal(H.dateToLiteral('2026-01-01'), 'primero de enero de dos mil veintiséis');
  assert.equal(H.dateToLiteral('2026-12-31'), 'treinta y uno de diciembre de dos mil veintiséis');
  assert.equal(H.dateToLiteral('2024-02-29'), 'veintinueve de febrero de dos mil veinticuatro');
  assert.equal(H.dateToLiteral('2100-03-21'), 'veintiuno de marzo de dos mil cien');
  assert.equal(H.dateToLong('2026-10-02'), '2 de octubre de 2026');
  assert.throws(() => H.dateToLiteral('2026-02-30')); assert.throws(() => H.dateToLiteral('hoy'));
});

test('fecha de fin = inicio + plazo (fin de mes, años bisiestos, cambio de año)', () => {
  assert.equal(H.addDays('2026-10-02', 90), '2026-12-31');
  assert.equal(H.addDays('2026-01-31', 30), '2026-03-02');
  assert.equal(H.addDays('2024-02-01', 29), '2024-03-01');   // bisiesto
  assert.equal(H.addDays('2025-02-01', 28), '2025-03-01');   // no bisiesto
  assert.equal(H.addDays('2024-02-29', 365), '2025-02-28');
  assert.equal(H.addDays('2026-12-31', 1), '2027-01-01');
  assert.equal(H.addDays('2026-03-08', 180), '2026-09-04');
  assert.equal(H.addDays('2026-10-02', 0), '2026-10-02');
});

test('hoy en Bolivia (UTC-4)', () => {
  assert.equal(H.todayBolivia(new Date('2026-10-02T02:30:00Z')), '2026-10-01'); // todavía es el día anterior en La Paz
  assert.equal(H.todayBolivia(new Date('2026-10-02T04:00:00Z')), '2026-10-02');
});

/* ───────── Plantilla ───────── */
const BASE = {
  operacion: 'venta', moneda: 'USD', precio: 450000, precio_minimo: '', comision_porcentaje: 3, impuestos_incluidos: true,
  propietario_nombre: 'Juan Pérez Mamani', propietario_ci: '4567890 LP', propietario_estado_civil: 'casado',
  propietario_domicilio: 'Calle 21 de Calacoto Nº 100', propietario_telefono: '70012345', propietario_email: 'juan@example.com',
  tiene_copropietario: false, tiene_apoderado: false,
  inmueble_tipo: 'Departamento', inmueble_direccion: 'Av. Ballivián Nº 1234, Edif. Sol, Piso 5', inmueble_zona: 'Calacoto', inmueble_ciudad: 'La Paz',
  inmueble_departamento: 'La Paz', inmueble_sup_terreno: 120.5, inmueble_sup_construida: 98, inmueble_matricula: '2.01.0.99.0012345', inmueble_catastro: '',
  con_gravamenes: false,
  fecha_inicio: '2026-10-02', plazo_dias: 90, renovacion_automatica: false, dias_preaviso: 15, dias_proteccion: 90, penalidad_porcentaje: 50,
  frecuencia_informe: 15, horas_aviso_visita: 24, dias_subsanacion: 10, forma_pago: 'transferencia bancaria o efectivo',
  autoriza_letrero: true, gastos_extra_detalle: '', ejemplares: 2, ciudad_firma: 'La Paz', ciudad_jurisdiccion: 'La Paz',
  agente_nombre: 'Ana Agente', agente_ci: '7654321', agente_registro: '', agente_telefono: '71122334', agente_email: 'ana@bastet.uno',
  agencia_nombre: 'BASTET Propiedades Inmobiliarias', agencia_domicilio: 'Calle Yanacocha, Edif. Cristal Of. 706, La Paz',
  doc_testimonio: true, doc_folio: true, doc_impuestos: false, doc_plano: false, doc_ci: true, doc_poder: false,
};
const META = { numero_contrato: 'BST-CE-2026-0001', codigo_verificacion: 'K7M2QX9A' };
const render = (over, meta) => T.blocksToPlain(T.renderBlocks(TEMPLATE, { ...BASE, ...(over || {}) }, meta || META));

test('contrato de venta típico: sin variables sin resolver ni marcas de plantilla', () => {
  const text = render();
  assert.ok(!/\{\{|\}\}|\[\[|\]\]/.test(text), 'quedaron marcas de plantilla');
  assert.ok(!/[⟦⟧]/.test(text), 'quedaron marcas de resaltado en el PDF');
  assert.ok(!/Convenciones de la plantilla/.test(text), 'se imprimió la nota de convenciones');
  assert.match(text, /Nº BST-CE-2026-0001/);
  assert.match(text, /USD 450\.000,00 \(CUATROCIENTOS CINCUENTA MIL 00\/100 DÓLARES ESTADOUNIDENSES\)/);
  assert.match(text, /vigencia de 90 \(noventa\) días calendario/);
  assert.match(text, /desde el dos de octubre de dos mil veintiséis hasta el treinta y uno de diciembre de dos mil veintiséis/);
  assert.match(text, /3% \(tres por ciento\) sobre el precio final de venta/);
  assert.match(text, /incluye los impuestos de ley/);
  assert.match(text, /en 2 \(dos\) ejemplares/);
  assert.match(text, /Verificación|Código de verificación K7M2QX9A/);
  assert.match(text, /1\.2\. EL AGENTE/);
  assert.doesNotMatch(text, /mensuales/);
  assert.doesNotMatch(text, /EL\/LA COPROPIETARIO/);
});

test('las 3 operaciones usan su propio texto de honorarios y objeto', () => {
  const venta = render({ operacion: 'venta' });
  const alq = render({ operacion: 'alquiler', moneda: 'Bs', precio: 3500, comision_porcentaje: '', comision_meses: 1 });
  const anti = render({ operacion: 'anticretico', precio: 40000, comision_porcentaje: 4 });
  assert.match(venta, /para la venta del inmueble/);
  assert.match(venta, /sobre el precio final de venta efectivamente pactado/);
  assert.match(alq, /para el alquiler del inmueble/);
  assert.match(alq, /Bs 3\.500,00 \(TRES MIL QUINIENTOS 00\/100 BOLIVIANOS\) mensuales/);
  assert.match(alq, /1 \(un\) mes\(es\) del canon de alquiler/);
  assert.doesNotMatch(alq, /precio final de venta/);
  assert.match(anti, /para el anticrético del inmueble/);
  assert.match(anti, /4% \(cuatro por ciento\) sobre el monto de anticrético/);
});

test('copropietario: aparece su bloque, su firma y renumera al agente', () => {
  const sin = render();
  const con = render({ tiene_copropietario: true, copropietario_nombre: 'María Quispe', copropietario_ci: '1234567' });
  assert.match(con, /1\.2\. EL\/LA COPROPIETARIO\(A\) O CÓNYUGE: María Quispe/);
  assert.match(con, /1\.3\. EL AGENTE/);
  assert.match(con, /COPROPIETARIO\(A\) \/ CÓNYUGE/);
  assert.doesNotMatch(sin, /María Quispe/);
  assert.match(sin, /1\.2\. EL AGENTE/);
});

test('apoderado: aparece en la cláusula primera y en el Anexo A', () => {
  const con = render({ tiene_apoderado: true, apoderado_nombre: 'Carlos Ríos', apoderado_ci: '999888', poder_numero: '123/2025', poder_fecha: '2025-06-15', poder_notaria: '45', doc_poder: true });
  assert.match(con, /representado legalmente por Carlos Ríos, con C\.I\. Nº 999888/);
  assert.match(con, /Testimonio de Poder Nº 123\/2025 de fecha 15 de junio de 2025/);
  assert.match(con, /Testimonio de poder \| Sí/);
  assert.doesNotMatch(render(), /Testimonio de poder/);
});

test('gravámenes, renovación, precio mínimo, registro, catastro, superficie construida, gastos y letrero', () => {
  const base = render();
  assert.match(base, /libre de todo gravamen/);
  assert.match(base, /el contrato concluirá de pleno derecho/);
  assert.doesNotMatch(base, /se renovará automáticamente|a partir de USD|código catastral|con registro Nº|gastos extraordinarios/);
  assert.match(base, /una superficie construida de 98 m²/);
  assert.match(base, /una superficie de terreno de 120,5 m²/);
  const full = render({
    con_gravamenes: true, gravamenes_detalle: 'hipoteca a favor del Banco X', renovacion_automatica: true, precio_minimo: 430000,
    agente_registro: 'REG-123', inmueble_catastro: '001-002', gastos_extra_detalle: 'avalúo profesional', autoriza_letrero: true,
  });
  assert.match(full, /pesa el siguiente gravamen: hipoteca a favor del Banco X/);
  assert.match(full, /se renovará automáticamente por períodos iguales/);
  assert.match(full, /con al menos 15 días de anticipación/);
  assert.match(full, /a partir de USD 430\.000,00 \(CUATROCIENTOS TREINTA MIL 00\/100 DÓLARES ESTADOUNIDENSES\)/);
  assert.match(full, /con registro Nº REG-123/);
  assert.match(full, /código catastral Nº 001-002/);
  assert.match(full, /gastos extraordinarios previamente acordados, que serán cubiertos por EL PROPIETARIO: avalúo profesional/);
  assert.match(full, /colocar un letrero de oferta/);
  assert.doesNotMatch(full, /libre de todo gravamen/);
  assert.match(render({ autoriza_letrero: false }), /con fines exclusivamente comerciales\. Por razones de seguridad/);
});

test('terreno: no pide superficie construida', () => {
  const t = render({ inmueble_tipo: 'Terreno', inmueble_sup_construida: 50 });
  assert.doesNotMatch(t, /superficie construida/);
});

test('todas las combinaciones de interruptores generan un contrato completo', () => {
  const ops = [{ operacion: 'venta' }, { operacion: 'alquiler', moneda: 'Bs', precio: 2500, comision_porcentaje: '', comision_meses: 1.5 }, { operacion: 'anticretico', precio: 35000 }];
  let n = 0;
  for (const op of ops) for (const cop of [false, true]) for (const apo of [false, true]) for (const grav of [false, true]) for (const ren of [false, true]) {
    const over = { ...op, tiene_copropietario: cop, tiene_apoderado: apo, con_gravamenes: grav, renovacion_automatica: ren };
    if (cop) Object.assign(over, { copropietario_nombre: 'Copropietaria Test', copropietario_ci: '111222' });
    if (apo) Object.assign(over, { apoderado_nombre: 'Apoderado Test', apoderado_ci: '333444', poder_numero: '9', poder_fecha: '2025-01-31', poder_notaria: '12' });
    if (grav) over.gravamenes_detalle = 'embargo judicial';
    const text = render(over);
    assert.ok(!/\{\{|\}\}|\[\[|\]\]/.test(text), JSON.stringify(over));
    assert.match(text, /Fin|DÉCIMA OCTAVA/);
    n++;
  }
  assert.equal(n, 48);
});

test('nombres y direcciones muy largos no rompen la plantilla', () => {
  const long = 'Nombre ' + 'MuyLargo '.repeat(25);
  const text = render({ propietario_nombre: long.trim(), inmueble_direccion: 'Calle ' + 'Larguísima '.repeat(30) + 'Nº 1', agencia_nombre: 'Agencia ' + 'X'.repeat(80) });
  assert.match(text, /MuyLargo MuyLargo/);
});

test('falla (no genera) si falta un dato o hay una variable desconocida', () => {
  assert.throws(() => T.renderBlocks(TEMPLATE, { ...BASE, propietario_nombre: '' }, META), /Falta el dato: propietario_nombre/);
  assert.throws(() => T.renderBlocks(TEMPLATE, { ...BASE, forma_pago: '   ' }, META), /Falta el dato: forma_pago/);
  assert.throws(() => T.renderBlocks(TEMPLATE, { ...BASE, ciudad_firma: '' }, META), /Falta el dato/);
  assert.throws(() => T.renderBlocks(TEMPLATE, { ...BASE }, { numero_contrato: '', codigo_verificacion: 'X' }), /Falta el dato: numero_contrato/);
  assert.throws(() => T.renderText('Hola {{no_existe}}', T.buildExclusivityContext(BASE, META)), /Variable sin resolver: no_existe/);
  assert.throws(() => T.renderText('[[SI nada_raro]]x[[FIN]]', T.buildExclusivityContext(BASE, META)), /Condición desconocida/);
  assert.throws(() => T.renderText('[[SI tiene_apoderado]]sin cerrar', T.buildExclusivityContext(BASE, META)), /sin cerrar/);
  assert.throws(() => T.renderBlocks(TEMPLATE, { ...BASE, operacion: 'permuta' }, META), /Operación inválida/);
  assert.throws(() => T.renderBlocks(TEMPLATE, { ...BASE, precio: 0 }, META), /precio/);
  assert.throws(() => T.renderBlocks(TEMPLATE, { ...BASE, fecha_inicio: '2026-02-30' }, META));
});

test('vista previa: los datos del agente quedan marcados y el HTML se escapa', () => {
  const blocks = T.renderBlocks(TEMPLATE, { ...BASE, propietario_nombre: 'Juan <b>&</b> Pérez' }, META, { mark: true });
  const html = T.blocksToHtml(blocks);
  assert.match(html, /<mark class="cv">Juan &lt;b&gt;&amp;&lt;\/b&gt; Pérez<\/mark>/);
  assert.doesNotMatch(html, /<b>/);
  assert.match(html, /<h2 class="cdoc-clause">PRIMERA\.- \(DE LAS PARTES\)<\/h2>/);
  assert.match(html, /<table class="cdoc-table">/);
  assert.ok(!/[⟦⟧]/.test(html));
  // sin mark, no hay <mark>
  assert.doesNotMatch(T.blocksToHtml(T.renderBlocks(TEMPLATE, BASE, META)), /<mark/);
});

test('vista previa tolerante: sin datos muestra líneas para completar; el modo estricto sigue fallando', () => {
  const partial = { ...BASE, propietario_nombre: '', propietario_ci: '', precio: '', plazo_dias: '', fecha_inicio: 'mañana', forma_pago: '' };
  const opts = { mark: true, lenient: true, placeholder: '________' };
  const html = T.blocksToHtml(T.renderBlocks(TEMPLATE, partial, { numero_contrato: 'BST-CE-2026-XXXX', codigo_verificacion: 'XXXXXXXX' }, opts));
  assert.match(html, /<mark class="cv">________<\/mark>/);
  assert.ok(!/\{\{|\[\[/.test(html));
  assert.throws(() => T.renderBlocks(TEMPLATE, partial, META), /precio|Falta el dato/);
  // las condiciones no se ven alteradas por los marcadores de posición
  const t = T.blocksToPlain(T.renderBlocks(TEMPLATE, { ...partial, agente_registro: '', inmueble_catastro: '' }, META, opts));
  assert.doesNotMatch(t, /con registro Nº|código catastral/);
});

test('estructura: 18 cláusulas, tabla de firmas y anexo', () => {
  const blocks = T.renderBlocks(TEMPLATE, BASE, META);
  assert.equal(blocks.filter((b) => b.type === 'clause').length, 18);
  assert.equal(blocks.filter((b) => b.type === 'annex').length, 1);
  assert.equal(blocks.filter((b) => b.type === 'table').length, 2); // firmas + anexo (sin copropietario)
  const withCo = T.renderBlocks(TEMPLATE, { ...BASE, tiene_copropietario: true, copropietario_nombre: 'Ana', copropietario_ci: '1' }, META);
  assert.equal(withCo.filter((b) => b.type === 'table').length, 3);
  assert.equal(blocks[0].type, 'title');
  assert.equal(blocks[1].type, 'number');
});
