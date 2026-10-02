/* Helpers en español boliviano para los contratos: montos, números y fechas en letras, formatos.
   Sin dependencias; funciona en el navegador (window.ContractHelpers) y en Node (tests). */
(function (root, factory) {
  if (typeof module === 'object' && module.exports) module.exports = factory();
  else root.ContractHelpers = factory();
})(typeof self !== 'undefined' ? self : this, function () {
  'use strict';

  const UNITS = ['cero', 'uno', 'dos', 'tres', 'cuatro', 'cinco', 'seis', 'siete', 'ocho', 'nueve', 'diez', 'once', 'doce', 'trece', 'catorce',
    'quince', 'dieciséis', 'diecisiete', 'dieciocho', 'diecinueve', 'veinte', 'veintiuno', 'veintidós', 'veintitrés', 'veinticuatro',
    'veinticinco', 'veintiséis', 'veintisiete', 'veintiocho', 'veintinueve'];
  const TENS = ['', '', '', 'treinta', 'cuarenta', 'cincuenta', 'sesenta', 'setenta', 'ochenta', 'noventa'];
  const HUNDREDS = ['', 'ciento', 'doscientos', 'trescientos', 'cuatrocientos', 'quinientos', 'seiscientos', 'setecientos', 'ochocientos', 'novecientos'];
  const MONTHS = ['enero', 'febrero', 'marzo', 'abril', 'mayo', 'junio', 'julio', 'agosto', 'septiembre', 'octubre', 'noviembre', 'diciembre'];

  // 0..999. apocope: "un"/"veintiún" cuando va antes de un sustantivo o de "mil".
  function below1000(n, apocope) {
    if (n === 100) return 'cien';
    const h = Math.floor(n / 100);
    const r = n % 100;
    const parts = [];
    if (h) parts.push(HUNDREDS[h]);
    if (r) {
      if (r < 30) {
        let w = UNITS[r];
        if (apocope && r === 1) w = 'un';
        if (apocope && r === 21) w = 'veintiún';
        parts.push(w);
      } else {
        const t = Math.floor(r / 10);
        const u = r % 10;
        parts.push(u ? TENS[t] + ' y ' + (apocope && u === 1 ? 'un' : UNITS[u]) : TENS[t]);
      }
    }
    return parts.join(' ');
  }

  // Entero 0 .. 999.999.999.999 en letras (minúsculas).
  function integerToWords(n, opts) {
    const apocope = !!(opts && opts.apocope);
    n = Math.floor(Number(n));
    if (!isFinite(n) || n < 0 || n >= 1e12) throw new RangeError('Número fuera de rango: ' + n);
    if (n === 0) return 'cero';
    const parts = [];
    const millions = Math.floor(n / 1e6);
    const rest = n % 1e6;
    if (millions) parts.push(millions === 1 ? 'un millón' : integerToWords(millions, { apocope: true }) + ' millones');
    const thousands = Math.floor(rest / 1000);
    const units = rest % 1000;
    if (thousands) parts.push(thousands === 1 ? 'mil' : below1000(thousands, true) + ' mil');
    if (units) parts.push(below1000(units, apocope));
    return parts.join(' ');
  }

  // Número con o sin decimales ("90" -> "noventa"; "3,5" -> "tres coma cinco"; "1" -> "un").
  function numberToLiteral(value) {
    const num = Number(value);
    if (!isFinite(num) || num < 0) throw new RangeError('Número inválido: ' + value);
    const text = String(Math.round(num * 100) / 100);
    const [intPart, decPart] = text.split('.');
    if (!decPart) return integerToWords(Number(intPart), { apocope: true });
    let words = integerToWords(Number(intPart), { apocope: false }) + ' coma ';
    const zeros = decPart.match(/^0*/)[0].length;
    words += 'cero '.repeat(zeros) + integerToWords(Number(decPart.slice(zeros)), { apocope: false });
    return words;
  }

  // 450000.5 -> "CUATROCIENTOS CINCUENTA MIL 50/100 BOLIVIANOS"
  function moneyToWords(amount, currency) {
    let cents = Math.round(Number(amount) * 100);
    if (!isFinite(cents) || cents < 0) throw new RangeError('Monto inválido: ' + amount);
    const whole = Math.floor(cents / 100);
    cents = cents % 100;
    const name = currency === 'USD' ? 'DÓLARES ESTADOUNIDENSES' : 'BOLIVIANOS';
    return (integerToWords(whole, { apocope: true }).toUpperCase() + ' ' + String(cents).padStart(2, '0') + '/100 ' + name);
  }

  function groupThousands(intStr) { return intStr.replace(/\B(?=(\d{3})+(?!\d))/g, '.'); }

  // 450000.5 -> "450.000,50" (siempre con 2 decimales: para montos)
  function formatMoney(amount) {
    const fixed = (Math.round(Number(amount) * 100) / 100).toFixed(2);
    const [i, d] = fixed.split('.');
    return groupThousands(i) + ',' + d;
  }

  // 120.5 -> "120,5"; 98 -> "98" (hasta 2 decimales, sin ceros de relleno: para superficies y porcentajes)
  function formatQty(n) {
    const rounded = Math.round(Number(n) * 100) / 100;
    const [i, d] = String(rounded).split('.');
    return groupThousands(i) + (d ? ',' + d : '');
  }

  // Acepta "450.000,50", "450000.5", "450,5", "450.000". Devuelve null si no es un número.
  function parseAmount(text) {
    let s = String(text == null ? '' : text).replace(/[\s ]/g, '');
    if (!s) return null;
    if (s.indexOf(',') !== -1) s = s.replace(/\./g, '').replace(',', '.');
    else if (/^\d{1,3}(\.\d{3})+$/.test(s)) s = s.replace(/\./g, '');
    if (!/^\d+(\.\d+)?$/.test(s)) return null;
    return parseFloat(s);
  }

  function parseISO(iso) {
    const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(String(iso || ''));
    if (!m) throw new RangeError('Fecha inválida: ' + iso);
    const y = +m[1], mo = +m[2], d = +m[3];
    const dt = new Date(Date.UTC(y, mo - 1, d));
    if (dt.getUTCFullYear() !== y || dt.getUTCMonth() !== mo - 1 || dt.getUTCDate() !== d) throw new RangeError('Fecha inválida: ' + iso);
    return dt;
  }

  function toISO(dt) {
    return dt.getUTCFullYear() + '-' + String(dt.getUTCMonth() + 1).padStart(2, '0') + '-' + String(dt.getUTCDate()).padStart(2, '0');
  }

  // Suma días calendario (sin problemas de zona horaria ni de horario de verano).
  function addDays(iso, days) {
    const dt = parseISO(iso);
    dt.setUTCDate(dt.getUTCDate() + Number(days));
    return toISO(dt);
  }

  // "2026-10-02" -> "dos de octubre de dos mil veintiséis"
  function dateToLiteral(iso) {
    const dt = parseISO(iso);
    const day = dt.getUTCDate();
    const dayWords = day === 1 ? 'primero' : integerToWords(day, { apocope: false });
    return dayWords + ' de ' + MONTHS[dt.getUTCMonth()] + ' de ' + integerToWords(dt.getUTCFullYear(), { apocope: false });
  }

  // "2026-10-02" -> "2 de octubre de 2026"
  function dateToLong(iso) {
    const dt = parseISO(iso);
    return dt.getUTCDate() + ' de ' + MONTHS[dt.getUTCMonth()] + ' de ' + dt.getUTCFullYear();
  }

  // Hoy en Bolivia (UTC-4, sin horario de verano), formato ISO.
  function todayBolivia(now) {
    const d = new Date((now ? now.getTime() : Date.now()) - 4 * 3600 * 1000);
    return toISO(d);
  }

  return { integerToWords, numberToLiteral, moneyToWords, formatMoney, formatQty, parseAmount, parseISO, toISO, addDays, dateToLiteral, dateToLong, todayBolivia, MONTHS };
});
