/* Motor de plantilla de contratos.
   - Lee el texto legal oficial (assets/contracts/<plantilla>.md): es la ÚNICA fuente de verdad, aquí no se reescribe nada.
   - {{campo}} -> dato del formulario o calculado; [[SI condición]] … [[FIN]] -> bloque condicional.
   - Si queda una variable sin resolver (o vacía) lanza un error: nunca se genera un documento con {{…}} visibles.
   - Para agregar otro contrato: sumar su .md y su configuración en buildExclusivityContext (campos y derivados).
   Funciona en el navegador (window.ContractTemplate) y en Node (tests). */
(function (root, factory) {
  if (typeof module === 'object' && module.exports) module.exports = factory(require('./contract-helpers.js'));
  else root.ContractTemplate = factory(root.ContractHelpers);
})(typeof self !== 'undefined' ? self : this, function (H) {
  'use strict';

  const MARK_OPEN = '⟦';  // ⟦ marca el inicio de un dato del agente (vista previa resaltada)
  const MARK_CLOSE = '⟧'; // ⟧

  // Con artículo incluido: "para la venta / el alquiler / el anticrético del inmueble".
  const OPERATION_TEXT = { venta: 'la venta', alquiler: 'el alquiler', anticretico: 'el anticrético' };
  const YES_NO = (v) => (v ? 'Sí' : 'Pendiente');

  const str = (v) => (v == null ? '' : String(v).trim());
  const positive = (v) => { const n = Number(v); return isFinite(n) && n > 0; };
  // Literal / formato que devuelven '' (en vez de lanzar) cuando el dato aún no está: el modo estricto lo detecta después como "Falta el dato".
  const safeLiteral = (v) => { try { return v === '' || v == null ? '' : H.numberToLiteral(v); } catch (e) { return ''; } };
  // 120 días -> " (4 meses)" (solo si son meses completos de 30 días; si no, nada)
  const monthsText = (days) => {
    const n = Number(days);
    if (!isFinite(n) || n < 30 || n % 30 !== 0) return '';
    const m = n / 30;
    return ' (' + m + (m === 1 ? ' mes' : ' meses') + ')';
  };
  const safeQty = (v) => (v === '' || v == null || !isFinite(Number(v)) ? '' : H.formatQty(v));

  /* ── Del formulario a las variables de la plantilla ──
     `form` = datos que escribe el agente; `meta` = { numero_contrato, codigo_verificacion } (los fija el servidor).
     Devuelve un objeto plano: texto/booleanos para las variables y los [[SI …]]. */
  // opts.lenient (vista previa): tolera datos aún sin escribir; el contrato real se genera SIEMPRE en modo estricto.
  function buildExclusivityContext(form, meta, opts) {
    const lenient = !!(opts && opts.lenient);
    const f = form || {};
    const op = f.operacion;
    if (!OPERATION_TEXT[op]) throw new Error('Operación inválida');
    const moneda = f.moneda === 'Bs' ? 'Bs' : 'USD';
    const precio = Number(f.precio);
    if (!positive(precio) && !lenient) throw new Error('El precio debe ser mayor que 0');
    const hasPrice = positive(precio);
    const plazo = Number(f.plazo_dias);
    if ((!isFinite(plazo) || plazo < 1) && !lenient) throw new Error('El plazo debe ser mayor que 0');
    const plazoOk = isFinite(plazo) && plazo >= 1;
    let inicio = str(f.fecha_inicio);
    if (lenient) { try { H.parseISO(inicio); } catch (e) { inicio = H.todayBolivia(); } }
    const fin = H.addDays(inicio, plazoOk ? plazo : 0);
    const precioMin = f.precio_minimo !== '' && f.precio_minimo != null ? Number(f.precio_minimo) : null;
    const tieneCopropietario = !!f.tiene_copropietario;
    const tieneApoderado = !!f.tiene_apoderado;
    const conGravamenes = !!f.con_gravamenes;
    const renovacion = !!f.renovacion_automatica;
    const supConstruida = positive(f.inmueble_sup_construida) && f.inmueble_tipo !== 'Terreno' ? Number(f.inmueble_sup_construida) : null;

    const ctx = {
      numero_contrato: str(meta && meta.numero_contrato),
      codigo_verificacion: str(meta && meta.codigo_verificacion),

      // Partes
      propietario_nombre: str(f.propietario_nombre), propietario_ci: str(f.propietario_ci), propietario_estado_civil: str(f.propietario_estado_civil),
      propietario_domicilio: str(f.propietario_domicilio), propietario_telefono: str(f.propietario_telefono), propietario_email: str(f.propietario_email),
      tiene_apoderado: tieneApoderado,
      apoderado_nombre: str(f.apoderado_nombre), apoderado_ci: str(f.apoderado_ci), poder_numero: str(f.poder_numero),
      poder_fecha: f.poder_fecha ? H.dateToLong(f.poder_fecha) : '', poder_notaria: str(f.poder_notaria),
      tiene_copropietario: tieneCopropietario, copropietario_nombre: str(f.copropietario_nombre), copropietario_ci: str(f.copropietario_ci),
      sin_copropietario: !tieneCopropietario,
      propietario_nombre_upper: str(f.propietario_nombre).toUpperCase(), copropietario_nombre_upper: str(f.copropietario_nombre).toUpperCase(),
      numeral_agente: tieneCopropietario ? '1.3' : '1.2',
      agente_nombre: str(f.agente_nombre), agente_ci: str(f.agente_ci), agente_registro: str(f.agente_registro),
      agencia_nombre: str(f.agencia_nombre), agencia_domicilio: str(f.agencia_domicilio), agente_telefono: str(f.agente_telefono), agente_email: str(f.agente_email),

      // Inmueble
      inmueble_tipo: str(f.inmueble_tipo), inmueble_direccion: str(f.inmueble_direccion), inmueble_zona: str(f.inmueble_zona),
      inmueble_ciudad: str(f.inmueble_ciudad), inmueble_departamento: str(f.inmueble_departamento),
      inmueble_sup_terreno: positive(f.inmueble_sup_terreno) ? H.formatQty(f.inmueble_sup_terreno) : '',
      inmueble_sup_construida: supConstruida ? H.formatQty(supConstruida) : '',
      inmueble_matricula: str(f.inmueble_matricula), inmueble_catastro: str(f.inmueble_catastro),
      sin_gravamenes: !conGravamenes, con_gravamenes: conGravamenes, gravamenes_detalle: str(f.gravamenes_detalle),

      // Operación y precio
      operacion_texto: OPERATION_TEXT[op],
      operacion_venta: op === 'venta', operacion_alquiler: op === 'alquiler', operacion_anticretico: op === 'anticretico',
      moneda_simbolo: moneda,
      precio: hasPrice ? H.formatMoney(precio) : '', precio_literal: hasPrice ? H.moneyToWords(precio, moneda) : '',
      precio_minimo: positive(precioMin) ? H.formatMoney(precioMin) : '',
      precio_minimo_literal: positive(precioMin) ? H.moneyToWords(precioMin, moneda) : '',

      // Plazo
      plazo_meses_texto: plazoOk ? monthsText(plazo) : '', proteccion_meses_texto: monthsText(f.dias_proteccion),
      plazo_dias: plazoOk ? String(plazo) : '', plazo_dias_literal: plazoOk ? H.numberToLiteral(plazo) : '',
      fecha_inicio_literal: H.dateToLiteral(inicio), fecha_fin_literal: H.dateToLiteral(fin), fecha_firma_literal: H.dateToLiteral(inicio),
      renovacion_automatica: renovacion, sin_renovacion_automatica: !renovacion, dias_preaviso: String(f.dias_preaviso ?? ''),

      // Honorarios
      comision_porcentaje: f.comision_porcentaje != null && f.comision_porcentaje !== '' ? H.formatQty(f.comision_porcentaje) : '',
      comision_porcentaje_literal: f.comision_porcentaje != null && f.comision_porcentaje !== '' ? H.numberToLiteral(f.comision_porcentaje) : '',
      comision_meses: f.comision_meses != null && f.comision_meses !== '' ? H.formatQty(f.comision_meses) : '',
      comision_meses_literal: f.comision_meses != null && f.comision_meses !== '' ? H.numberToLiteral(f.comision_meses) : '',
      impuestos_texto: f.impuestos_incluidos
        ? 'incluye los impuestos de ley'
        : 'no incluye los impuestos de ley, que serán facturados adicionalmente',
      forma_pago: str(f.forma_pago),

      // Condiciones
      dias_proteccion: String(f.dias_proteccion ?? ''), dias_proteccion_literal: safeLiteral(f.dias_proteccion),
      penalidad_porcentaje: safeQty(f.penalidad_porcentaje),
      frecuencia_informe: String(f.frecuencia_informe ?? ''), horas_aviso_visita: String(f.horas_aviso_visita ?? ''), dias_subsanacion: String(f.dias_subsanacion ?? ''),
      gastos_extra: !!str(f.gastos_extra_detalle), gastos_extra_detalle: str(f.gastos_extra_detalle),
      autoriza_letrero: !!f.autoriza_letrero,
      ejemplares: String(f.ejemplares ?? ''), ejemplares_literal: safeLiteral(f.ejemplares),
      ciudad_firma: str(f.ciudad_firma), ciudad_jurisdiccion: str(f.ciudad_jurisdiccion),

      // Anexo A
      doc_testimonio: YES_NO(f.doc_testimonio), doc_folio: YES_NO(f.doc_folio), doc_impuestos: YES_NO(f.doc_impuestos),
      doc_plano: YES_NO(f.doc_plano), doc_ci: YES_NO(f.doc_ci), doc_poder: YES_NO(f.doc_poder),
    };
    return ctx;
  }

  /* ── Oferta de colaboración propietario → agente (plantilla colaboracion-v1) ──
     `offer` = fila de owner_offers (property_data, owner_data, agent_data, terms, doc_number, created_at, responded_at, status).
     El documento sale siempre de esta copia: no cambia si después se edita la propiedad. */
  const OFFER_OPERATION_TEXT = { venta: 'la venta', alquiler: 'el alquiler', anticretico: 'el anticrético', temporal: 'el alquiler temporal (por día)' };
  const PROPERTY_TYPE_TEXT = { casa: 'Casa', departamento: 'Departamento', terreno: 'Terreno' };
  const withUnit = (v, unit) => { const t = str(v); return /^\d+([.,]\d+)?$/.test(t) ? t + ' ' + unit : t; };

  function buildCollaborationContext(offer) {
    const o = offer || {};
    const p = o.property_data || {}, ow = o.owner_data || {}, ag = o.agent_data || {}, t = o.terms || {};
    const digits = str(p.price).replace(/[^0-9]/g, '');
    const price = digits ? parseInt(digits, 10) : 0;
    const bob = p.currency === 'BOB';
    const moneda = bob ? 'Bs' : 'USD';
    const created = o.created_at ? H.todayBolivia(new Date(o.created_at)) : H.todayBolivia();
    const accepted = o.status === 'accepted' && o.responded_at;
    const location = str(p.location);
    const ubic = [str(p.address), location].filter(Boolean).join(', ');
    const pct = t.comision_porcentaje;
    return {
      numero_documento: str(o.doc_number),
      fecha_literal: H.dateToLong(created),
      ciudad_jurisdiccion: location.split(',')[0].trim() || 'La Paz',
      propietario_nombre: str(ow.nombre), propietario_ci: str(ow.ci), propietario_telefono: str(ow.telefono), propietario_email: str(ow.email) || 'sin correo registrado',
      agente_nombre: str(ag.nombre) || 'Agente de Bastet',
      agente_ci: str(ag.ci), agente_registro: str(ag.registro), sin_agente_ci: !str(ag.ci),
      agente_ci_firma: str(ag.ci) || '______________',
      inmueble_titulo: str(p.title), inmueble_codigo: p.code_number ? 'BST-' + p.code_number : 'sin código',
      inmueble_ubicacion: ubic || 'ubicación por confirmar',
      inmueble_area: withUnit(p.area, 'm²') || 'superficie por confirmar',
      inmueble_habitaciones: withUnit(p.rooms, 'habitaciones') || 'habitaciones por confirmar',
      inmueble_banos: withUnit(p.baths, 'baños') || 'baños por confirmar',
      operacion_texto: OFFER_OPERATION_TEXT[p.operation] || 'la comercialización',
      moneda_simbolo: moneda,
      precio: price > 0 ? H.formatMoney(price) : '', precio_literal: price > 0 ? H.moneyToWords(price, moneda) : '',
      comision_porcentaje: pct != null ? H.formatQty(pct) : '', comision_porcentaje_literal: pct != null ? H.numberToLiteral(pct) : '',
      plazo_dias: t.plazo_dias != null ? String(t.plazo_dias) : '', plazo_dias_literal: t.plazo_dias != null ? H.numberToLiteral(t.plazo_dias) : '',
      exclusividad: !!t.exclusividad, sin_exclusividad: !t.exclusividad,
      mensaje: str(t.mensaje),
      aceptada: !!accepted, fecha_aceptacion: accepted ? H.dateToLong(H.todayBolivia(new Date(o.responded_at))) : '',
      numeral_validez: str(t.mensaje) ? 'NOVENA' : 'OCTAVA',
    };
  }

  function renderCollaborationBlocks(templateMd, offer, options) {
    const ctx = buildCollaborationContext(offer);
    return parseBlocks(renderText(templateMd, ctx, options));
  }

  /* ── Plantilla -> texto resuelto ── */
  function stripConventions(md) {
    // Las líneas "> …" son notas para quien mantiene la plantilla: nunca se imprimen.
    return md.split('\n').filter((line) => !/^\s*>/.test(line)).join('\n');
  }

  function truthy(v) { return v === true || (typeof v === 'string' && v.trim() !== '') || (typeof v === 'number' && v !== 0); }

  function resolveConditionals(text, ctx) {
    const re = /\[\[SI ([a-z0-9_]+)\]\]([\s\S]*?)\[\[FIN\]\]/g;
    let prev;
    do {
      prev = text;
      text = text.replace(re, (all, name, body) => {
        if (!(name in ctx)) throw new Error('Condición desconocida en la plantilla: ' + name);
        return truthy(ctx[name]) ? body : '';
      });
    } while (text !== prev);
    if (/\[\[(SI|FIN)/.test(text)) throw new Error('Bloque condicional sin cerrar en la plantilla');
    return text;
  }

  // Variables que pueden quedar vacías sin que sea un dato faltante (texto opcional pegado a otra frase).
  const OPTIONAL_VARS = new Set(['plazo_meses_texto', 'proteccion_meses_texto']);

  function resolveVariables(text, ctx, mark, placeholder) {
    return text.replace(/\{\{\s*([a-z0-9_]+)\s*\}\}/g, (all, name) => {
      if (!(name in ctx)) throw new Error('Variable sin resolver: ' + name);
      let v = ctx[name];
      if (OPTIONAL_VARS.has(name)) return v ? (mark ? MARK_OPEN + v + MARK_CLOSE : String(v)) : '';
      if (typeof v === 'boolean') throw new Error('Falta el dato: ' + name);
      if ((v === '' || v == null) && placeholder) v = placeholder;       // vista previa: línea para completar
      if (v === '' || v == null) throw new Error('Falta el dato: ' + name);
      return mark ? MARK_OPEN + v + MARK_CLOSE : String(v);
    });
  }

  function renderText(templateMd, ctx, options) {
    const mark = !!(options && options.mark);
    let text = stripConventions(templateMd);
    text = resolveConditionals(text, ctx);
    text = resolveVariables(text, ctx, mark, options && options.placeholder);
    if (/\{\{|\}\}/.test(text)) throw new Error('Quedaron variables sin resolver en el contrato');
    return text.replace(/\n{3,}/g, '\n\n').trim() + '\n';
  }

  /* ── Texto resuelto -> bloques (para la vista previa HTML y para el PDF) ── */
  function parseInline(s) {
    const segs = [];
    let bold = false;
    let isVar = false;
    let buf = '';
    const flush = () => { if (buf) { segs.push({ t: buf, b: bold, v: isVar }); buf = ''; } };
    for (let i = 0; i < s.length; i++) {
      if (s.startsWith('**', i)) { flush(); bold = !bold; i++; }
      else if (s[i] === MARK_OPEN) { flush(); isVar = true; }
      else if (s[i] === MARK_CLOSE) { flush(); isVar = false; }
      else buf += s[i];
    }
    flush();
    return segs;
  }

  function splitRow(line) {
    let t = line.trim();
    if (t.startsWith('|')) t = t.slice(1);
    if (t.endsWith('|')) t = t.slice(0, -1);
    return t.split('|').map((c) => c.trim());
  }

  function parseBlocks(resolved) {
    const lines = resolved.split('\n');
    const blocks = [];
    for (let i = 0; i < lines.length; i++) {
      const line = lines[i];
      const t = line.trim();
      if (!t || t === '---') continue;
      if (t === '&nbsp;') { blocks.push({ type: 'spacer' }); continue; }
      if (t.startsWith('# ')) { blocks.push({ type: 'title', text: t.slice(2).trim() }); continue; }
      if (t.startsWith('## ')) {
        const text = t.slice(3).trim();
        blocks.push({ type: /^ANEXO\b/i.test(text) ? 'annex' : 'clause', text });
        continue;
      }
      if (t.startsWith('|')) {
        const rows = [];
        while (i < lines.length && lines[i].trim().startsWith('|')) { rows.push(splitRow(lines[i])); i++; }
        i--;
        let align = [];
        let header = null;
        const sepIdx = rows.findIndex((r) => r.every((c) => /^:?-{3,}:?$/.test(c)));
        if (sepIdx > 0) {
          align = rows[sepIdx].map((c) => (c.startsWith(':') && c.endsWith(':') ? 'center' : c.endsWith(':') ? 'right' : 'left'));
          const head = rows[sepIdx - 1];
          header = head.every((c) => c === '') ? null : head.map(parseInline);
          rows.splice(0, sepIdx + 1);
        }
        blocks.push({ type: 'table', header, align, rows: rows.map((r) => r.map(parseInline)) });
        continue;
      }
      if (/^-\s+\S/.test(t)) { blocks.push({ type: 'bullet', segs: parseInline(t.replace(/^-\s+/, '')) }); continue; }
      if (/^\*[^*].*\*$/.test(t)) { blocks.push({ type: 'note', segs: parseInline(t.slice(1, -1)) }); continue; }
      if (/^\*\*Nº .*\*\*$/.test(t)) { blocks.push({ type: 'number', segs: parseInline(t) }); continue; }
      blocks.push({ type: 'para', segs: parseInline(t) });
    }
    return blocks;
  }

  const escapeHtml = (s) => String(s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  const segsHtml = (segs) => segs.map((s) => {
    let h = escapeHtml(s.t);
    if (s.b) h = '<strong>' + h + '</strong>';
    if (s.v) h = '<mark class="cv">' + h + '</mark>';
    return h;
  }).join('');

  // Vista previa en HTML (los datos del agente van resaltados con <mark class="cv">).
  function blocksToHtml(blocks) {
    return blocks.map((b) => {
      switch (b.type) {
        case 'title': return '<h1 class="cdoc-title">' + escapeHtml(b.text) + '</h1>';
        case 'number': return '<p class="cdoc-number">' + segsHtml(b.segs) + '</p>';
        case 'clause': return '<h2 class="cdoc-clause">' + escapeHtml(b.text) + '</h2>';
        case 'annex': return '<h2 class="cdoc-clause cdoc-annex">' + escapeHtml(b.text) + '</h2>';
        case 'spacer': return '<div class="cdoc-spacer"></div>';
        case 'bullet': return '<p class="cdoc-para cdoc-bullet">' + segsHtml(b.segs) + '</p>';
        case 'note': return '<p class="cdoc-note">' + segsHtml(b.segs) + '</p>';
        case 'table': {
          const cell = (tag, c, i) => '<' + tag + ' style="text-align:' + (b.align[i] || 'left') + '">' + segsHtml(c) + '</' + tag + '>';
          return '<table class="cdoc-table">' +
            (b.header ? '<thead><tr>' + b.header.map((c, i) => cell('th', c, i)).join('') + '</tr></thead>' : '') +
            '<tbody>' + b.rows.map((r) => '<tr>' + r.map((c, i) => cell('td', c, i)).join('') + '</tr>').join('') + '</tbody></table>';
        }
        default: return '<p class="cdoc-para">' + segsHtml(b.segs) + '</p>';
      }
    }).join('\n');
  }

  // Atajo: plantilla + formulario -> bloques. `mark` resalta los datos (vista previa); sin mark = limpio (PDF).
  function renderBlocks(templateMd, form, meta, options) {
    const ctx = buildExclusivityContext(form, meta, options);
    const resolved = renderText(templateMd, ctx, options);
    return parseBlocks(resolved);
  }

  // Solo texto plano de los bloques (útil en pruebas y para verificar que no queden marcas).
  function blocksToPlain(blocks) {
    const segsText = (segs) => segs.map((s) => s.t).join('');
    return blocks.map((b) => {
      if (b.text) return b.text;
      if (b.segs) return segsText(b.segs);
      if (b.type === 'table') return (b.header ? [b.header] : []).concat(b.rows).map((r) => r.map(segsText).join(' | ')).join('\n');
      return '';
    }).join('\n');
  }

  return { buildExclusivityContext, buildCollaborationContext, renderCollaborationBlocks, renderText, parseBlocks, renderBlocks, blocksToHtml, blocksToPlain, MARK_OPEN, MARK_CLOSE };
});
