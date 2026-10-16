/* Herramienta "Contrato de Exclusividad" del panel de agentes.
   - Asistente de 4 pasos + vista previa en vivo (el contrato tal cual saldrá en el PDF).
   - Sin costo adicional: la función SQL create_exclusivity_contract exige un plan vigente (Agente o Empresa), numera y guarda en una
     sola transacción. Antes de cobrar se hace una prueba de generación del PDF; si falla, no se cobra.
   - El PDF se genera siempre desde los datos guardados: volver a descargarlo es gratis.
   Usa el cliente global `supabaseClient` y las bibliotecas de assets/js/contracts/. */
(function () {
  'use strict';

  const H = window.ContractHelpers;
  const T = window.ContractTemplate;
  const P = window.ContractPdf;
  const SCRIPT_V = (() => { try { return new URL(document.currentScript.src).searchParams.get('v') || ''; } catch (e) { return ''; } })();
  const asset = (p) => '../assets/' + p + (SCRIPT_V ? '?v=' + SCRIPT_V : '');
  // Venta usa el contrato base de Bastet (v2); alquiler y anticrético siguen con la plantilla anterior (v1).
  // Cada contrato guardado se vuelve a descargar con la plantilla con la que se generó (template_version).
  const TEMPLATE_VERSIONS = ['exclusividad-v1', 'exclusividad-v2'];
  const templateVersionFor = (op) => (op === 'venta' ? 'exclusividad-v2' : 'exclusividad-v1');
  const TOOL_CODE = 'contrato_exclusividad';
  const CONTRACT_COLS = 'id,agent_id,contract_number,verification_code,template_version,data,created_at,voided_at,void_reason';
  const CONTRACT_COLS_BASE = 'id,agent_id,contract_number,verification_code,template_version,data,created_at';
  // Si el SQL de anulación aún no se corrió, las columnas voided_* no existen (42703): se reintenta sin ellas y la herramienta sigue funcionando.
  async function contractsQuery(own, limit) {
    const run = (cols) => { let q = supabaseClient.from('exclusivity_contracts').select(cols); if (own) q = q.eq('agent_id', state.uid); return q.order('created_at', { ascending: false }).limit(limit); };
    let r = await run(CONTRACT_COLS);
    if (r.error && r.error.code === '42703') r = await run(CONTRACT_COLS_BASE);
    return r;
  }

  const root = () => document.getElementById('contracts-root');
  const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  const num = (v) => { const n = H.parseAmount(v); return n == null ? null : n; };

  const OPS = [['venta', 'Venta'], ['alquiler', 'Alquiler'], ['anticretico', 'Anticrético']];
  const CIVIL = ['soltero(a)', 'casado(a)', 'divorciado(a)', 'viudo(a)', 'en unión libre'];
  const PROP_TYPES = ['Casa', 'Departamento', 'Terreno', 'Oficina', 'Local comercial', 'Galpón', 'Otro'];
  const DEPARTMENTS = ['La Paz', 'Santa Cruz', 'Cochabamba', 'Oruro', 'Potosí', 'Chuquisaca', 'Tarija', 'Beni', 'Pando'];
  const PLAZOS = [60, 90, 120, 180];
  const STEPS = ['Operación', 'Propietario', 'Inmueble', 'Condiciones'];
  const AGENCY = { nombre: 'BASTET Propiedades Inmobiliarias', domicilio: 'Calle Yanacocha, Edif. Cristal Of. 706, La Paz' };
  const CI_RE = /^[0-9]{4,10}([ -]?[0-9A-Za-z]{1,3})?$/;
  const EMAIL_RE = /^[^@\s]+@[^@\s]+\.[^@\s]+$/;

  // Campos que cambian lo que se ve en el paso (al cambiarlos se vuelve a dibujar el paso)
  const REFLOW = new Set(['operacion', 'moneda', 'tiene_copropietario', 'tiene_apoderado', 'con_gravamenes', 'renovacion_automatica', 'inmueble_tipo', 'plazo_dias']);

  // En qué paso vive cada campo (para llevar a la persona al primer error)
  const STEP_OF = {};
  [['operacion', 'moneda', 'precio', 'precio_minimo', 'comision_porcentaje', 'comision_meses'],
    ['propietario_nombre', 'propietario_ci', 'propietario_estado_civil', 'propietario_domicilio', 'propietario_telefono', 'propietario_email',
      'copropietario_nombre', 'copropietario_ci', 'apoderado_nombre', 'apoderado_ci', 'poder_numero', 'poder_fecha', 'poder_notaria'],
    ['inmueble_tipo', 'inmueble_direccion', 'inmueble_zona', 'inmueble_ciudad', 'inmueble_departamento', 'inmueble_sup_terreno', 'inmueble_sup_construida',
      'inmueble_matricula', 'inmueble_catastro', 'gravamenes_detalle'],
    ['fecha_inicio', 'plazo_dias', 'dias_preaviso', 'dias_proteccion', 'penalidad_porcentaje', 'frecuencia_informe', 'horas_aviso_visita', 'dias_subsanacion',
      'forma_pago', 'ejemplares', 'ciudad_firma', 'ciudad_jurisdiccion', 'gastos_extra_detalle']].forEach((keys, i) => keys.forEach((k) => { STEP_OF[k] = i; }));

  const state = {
    uid: null, ready: false, loading: false, view: 'new', step: 0,
    agent: { nombre: '', ci: '', telefono: '', email: '', registro: '', agencia_nombre: AGENCY.nombre, agencia_domicilio: AGENCY.domicilio },
    editAgent: false, sub: null, templates: {}, contracts: [], search: '',
    form: null, errors: {}, touchedMoneda: false, previewOpen: false, draft: null,
    idem: null, busy: false, success: null, previewTimer: null, saveTimer: null,
    isAdmin: false, allContracts: [], people: {}, fa: { q: '', agent: '', op: '', status: '' },
  };

  const draftKey = () => 'uno-contract-draft-v1-' + state.uid;
  const agencyKey = () => 'uno-contract-agency-v1-' + state.uid;
  const idemKey = () => 'uno-contract-idem-v1-' + state.uid;
  // La llave de idempotencia sobrevive a una recarga: si una respuesta se pierde después de cobrar, reintentar con los mismos datos no cobra dos veces.
  const readIdem = () => { try { return JSON.parse(localStorage.getItem(idemKey()) || 'null'); } catch (e) { return null; } };
  const writeIdem = (v) => { try { if (v) localStorage.setItem(idemKey(), JSON.stringify(v)); else localStorage.removeItem(idemKey()); } catch (e) { /* sin almacenamiento */ } };

  /* ───────── Formulario: valores iniciales ───────── */
  function defaultForm() {
    return {
      operacion: 'venta', moneda: 'USD', precio: '', precio_minimo: '', comision_porcentaje: '3', comision_meses: '1', impuestos_incluidos: true,
      propietario_nombre: '', propietario_ci: '', propietario_estado_civil: '', propietario_domicilio: '', propietario_telefono: '', propietario_email: '',
      tiene_copropietario: false, copropietario_nombre: '', copropietario_ci: '',
      tiene_apoderado: false, apoderado_nombre: '', apoderado_ci: '', poder_numero: '', poder_fecha: '', poder_notaria: '',
      inmueble_tipo: 'Departamento', inmueble_direccion: '', inmueble_zona: '', inmueble_ciudad: 'La Paz', inmueble_departamento: 'La Paz',
      inmueble_sup_terreno: '', inmueble_sup_construida: '', inmueble_matricula: '', inmueble_catastro: '', con_gravamenes: false, gravamenes_detalle: '',
      fecha_inicio: H.todayBolivia(), plazo_dias: '90', renovacion_automatica: false, dias_preaviso: '15',
      dias_proteccion: '90', penalidad_porcentaje: '50', frecuencia_informe: '15', horas_aviso_visita: '24', dias_subsanacion: '10',
      forma_pago: 'transferencia bancaria o efectivo', autoriza_letrero: true, gastos_extra_detalle: '', ejemplares: '2',
      ciudad_firma: 'La Paz', ciudad_jurisdiccion: 'La Paz',
      doc_testimonio: false, doc_folio: false, doc_impuestos: false, doc_plano: false, doc_ci: false, doc_poder: false,
    };
  }

  // Datos del formulario (texto) -> datos del contrato (números y booleanos). También es lo que se guarda en el servidor.
  function buildData(f) {
    const n = (v) => { const x = num(v); return x == null ? null : x; };
    const op = f.operacion;
    const data = {
      operacion: op, moneda: f.moneda, precio: n(f.precio), precio_minimo: f.precio_minimo !== '' ? n(f.precio_minimo) : '',
      impuestos_incluidos: !!f.impuestos_incluidos,
      comision_porcentaje: op === 'alquiler' ? '' : n(f.comision_porcentaje), comision_meses: op === 'alquiler' ? n(f.comision_meses) : '',
      propietario_nombre: f.propietario_nombre.trim(), propietario_ci: f.propietario_ci.trim(), propietario_estado_civil: f.propietario_estado_civil,
      propietario_domicilio: f.propietario_domicilio.trim(), propietario_telefono: f.propietario_telefono.trim(), propietario_email: f.propietario_email.trim(),
      tiene_copropietario: !!f.tiene_copropietario, copropietario_nombre: f.tiene_copropietario ? f.copropietario_nombre.trim() : '', copropietario_ci: f.tiene_copropietario ? f.copropietario_ci.trim() : '',
      tiene_apoderado: !!f.tiene_apoderado, apoderado_nombre: f.tiene_apoderado ? f.apoderado_nombre.trim() : '', apoderado_ci: f.tiene_apoderado ? f.apoderado_ci.trim() : '',
      poder_numero: f.tiene_apoderado ? f.poder_numero.trim() : '', poder_fecha: f.tiene_apoderado ? f.poder_fecha : '', poder_notaria: f.tiene_apoderado ? f.poder_notaria.trim() : '',
      inmueble_tipo: f.inmueble_tipo, inmueble_direccion: f.inmueble_direccion.trim(), inmueble_zona: f.inmueble_zona.trim(), inmueble_ciudad: f.inmueble_ciudad.trim(),
      inmueble_departamento: f.inmueble_departamento, inmueble_sup_terreno: n(f.inmueble_sup_terreno),
      inmueble_sup_construida: f.inmueble_tipo === 'Terreno' || f.inmueble_sup_construida === '' ? '' : n(f.inmueble_sup_construida),
      inmueble_matricula: f.inmueble_matricula.trim(), inmueble_catastro: f.inmueble_catastro.trim(),
      con_gravamenes: !!f.con_gravamenes, gravamenes_detalle: f.con_gravamenes ? f.gravamenes_detalle.trim() : '',
      fecha_inicio: f.fecha_inicio, plazo_dias: n(f.plazo_dias), renovacion_automatica: !!f.renovacion_automatica, dias_preaviso: f.renovacion_automatica ? n(f.dias_preaviso) : '',
      dias_proteccion: n(f.dias_proteccion), penalidad_porcentaje: n(f.penalidad_porcentaje), frecuencia_informe: n(f.frecuencia_informe),
      horas_aviso_visita: n(f.horas_aviso_visita), dias_subsanacion: n(f.dias_subsanacion),
      forma_pago: f.forma_pago.trim(), autoriza_letrero: !!f.autoriza_letrero, gastos_extra_detalle: f.gastos_extra_detalle.trim(), ejemplares: n(f.ejemplares),
      ciudad_firma: f.ciudad_firma.trim(), ciudad_jurisdiccion: f.ciudad_jurisdiccion.trim(),
      doc_testimonio: !!f.doc_testimonio, doc_folio: !!f.doc_folio, doc_impuestos: !!f.doc_impuestos, doc_plano: !!f.doc_plano, doc_ci: !!f.doc_ci, doc_poder: !!f.doc_poder,
      agente_nombre: state.agent.nombre.trim(), agente_ci: state.agent.ci.trim(), agente_registro: state.agent.registro.trim(),
      agente_telefono: state.agent.telefono.trim(), agente_email: state.agent.email.trim(),
      agencia_nombre: state.agent.agencia_nombre.trim(), agencia_domicilio: state.agent.agencia_domicilio.trim(),
    };
    return data;
  }

  // Datos guardados -> formulario (para "Duplicar")
  function formFromData(d) {
    const f = defaultForm();
    Object.keys(f).forEach((k) => {
      if (!(k in d)) return;
      const v = d[k];
      f[k] = typeof f[k] === 'boolean' ? !!v : v == null ? '' : typeof v === 'number' ? String(v).replace('.', ',') : String(v);
    });
    f.fecha_inicio = H.todayBolivia();
    return f;
  }

  /* ───────── Validación ───────── */
  function validate(f) {
    const e = {};
    const need = (k, msg) => { if (!String(f[k] ?? '').trim()) e[k] = msg || 'Este dato es obligatorio'; };
    const money = (k, { optional = false, max = 1e11 } = {}) => {
      const raw = String(f[k] ?? '').trim();
      if (!raw) { if (!optional) e[k] = 'Escribe un monto'; return; }
      const v = num(raw);
      if (v == null || v <= 0) e[k] = 'Debe ser un número mayor que 0';
      else if (v > max) e[k] = 'El número es demasiado grande';
    };
    const int = (k, min, max, msg) => { const v = num(f[k]); if (v == null || v !== Math.floor(v) || v < min || v > max) e[k] = msg || ('Debe ser un número entre ' + min + ' y ' + max); };

    if (!OPS.some((o) => o[0] === f.operacion)) e.operacion = 'Elige la operación';
    money('precio'); money('precio_minimo', { optional: true });
    if (f.operacion === 'alquiler') { const v = num(f.comision_meses); if (v == null || v <= 0 || v > 24) e.comision_meses = 'Entre 0,5 y 24 meses'; }
    else { const v = num(f.comision_porcentaje); if (v == null || v <= 0 || v > 100) e.comision_porcentaje = 'Debe estar entre 0 y 100'; }

    need('propietario_nombre'); if (f.propietario_nombre.trim() && f.propietario_nombre.trim().length < 3) e.propietario_nombre = 'Escribe el nombre completo';
    if (!CI_RE.test(f.propietario_ci.trim())) e.propietario_ci = 'C.I. numérica (con complemento opcional, ej. 1234567 LP)';
    need('propietario_estado_civil', 'Elige el estado civil'); need('propietario_domicilio');
    if (f.propietario_telefono.replace(/\D/g, '').length < 7) e.propietario_telefono = 'Escribe un teléfono válido';
    if (!EMAIL_RE.test(f.propietario_email.trim())) e.propietario_email = 'Escribe un correo válido';
    if (f.tiene_copropietario) { need('copropietario_nombre'); if (!CI_RE.test(f.copropietario_ci.trim())) e.copropietario_ci = 'C.I. numérica válida'; }
    if (f.tiene_apoderado) {
      need('apoderado_nombre'); if (!CI_RE.test(f.apoderado_ci.trim())) e.apoderado_ci = 'C.I. numérica válida';
      need('poder_numero'); need('poder_fecha', 'Indica la fecha del poder'); need('poder_notaria');
    }

    need('inmueble_tipo'); need('inmueble_direccion'); need('inmueble_zona'); need('inmueble_ciudad'); need('inmueble_departamento');
    money('inmueble_sup_terreno', { max: 1e8 });
    if (f.inmueble_tipo !== 'Terreno') money('inmueble_sup_construida', { optional: true, max: 1e8 });
    need('inmueble_matricula', 'Escribe la Matrícula Computarizada (Folio Real)');
    if (f.con_gravamenes) need('gravamenes_detalle', 'Describe el gravamen');

    try { H.parseISO(f.fecha_inicio); } catch (err) { e.fecha_inicio = 'Elige una fecha válida'; }
    int('plazo_dias', 15, 730, 'Entre 15 y 730 días');
    if (f.renovacion_automatica) int('dias_preaviso', 1, 365);
    int('dias_proteccion', 1, 730); int('penalidad_porcentaje', 1, 100); int('frecuencia_informe', 1, 365);
    int('horas_aviso_visita', 1, 720); int('dias_subsanacion', 1, 365); int('ejemplares', 1, 10);
    need('forma_pago'); need('ciudad_firma'); need('ciudad_jurisdiccion');

    // Datos del agente
    const a = state.agent;
    if (a.nombre.trim().length < 3) e.agent_nombre = 'Escribe tu nombre completo';
    if (!CI_RE.test(a.ci.trim())) e.agent_ci = 'Escribe tu C.I. (ej. 1234567 LP)';
    if (a.telefono.replace(/\D/g, '').length < 7) e.agent_telefono = 'Escribe tu teléfono';
    if (!EMAIL_RE.test(a.email.trim())) e.agent_email = 'Escribe tu correo';
    return e;
  }

  /* ───────── Piezas de formulario ───────── */
  const errHtml = (k) => (state.errors[k] ? '<p class="ct-error" role="alert">' + esc(state.errors[k]) + '</p>' : '');
  const hasErr = (k) => (state.errors[k] ? ' has-error' : '');

  function fText(key, label, o = {}) {
    const v = state.form[key] ?? '';
    return '<div class="field ct-field' + hasErr(key) + (o.half ? ' ct-half' : '') + '" data-field="' + key + '">' +
      '<label for="ct-' + key + '">' + label + (o.opt ? ' <span class="ct-opt">(opcional)</span>' : '') + '</label>' +
      '<input id="ct-' + key + '" data-f="' + key + '" type="' + (o.type || 'text') + '"' + (o.mode ? ' inputmode="' + o.mode + '"' : '') +
      (o.auto ? ' autocomplete="' + o.auto + '"' : ' autocomplete="off"') + (o.ph ? ' placeholder="' + esc(o.ph) + '"' : '') + ' maxlength="' + (o.max || 200) + '" value="' + esc(v) + '">' +
      (o.hint ? '<p class="field-hint">' + o.hint + '</p>' : '') + errHtml(key) + '</div>';
  }
  function fSelect(key, label, options, o = {}) {
    const v = state.form[key] ?? '';
    return '<div class="field ct-field' + hasErr(key) + (o.half ? ' ct-half' : '') + '" data-field="' + key + '">' +
      '<label for="ct-' + key + '">' + label + '</label><select id="ct-' + key + '" data-f="' + key + '">' +
      (o.placeholder ? '<option value="">' + esc(o.placeholder) + '</option>' : '') +
      options.map((x) => { const val = Array.isArray(x) ? x[0] : x; const lab = Array.isArray(x) ? x[1] : x; return '<option value="' + esc(val) + '"' + (String(val) === String(v) ? ' selected' : '') + '>' + esc(lab) + '</option>'; }).join('') +
      '</select>' + errHtml(key) + '</div>';
  }
  function fToggle(key, label, hint) {
    return '<label class="ct-toggle"><input type="checkbox" data-f="' + key + '"' + (state.form[key] ? ' checked' : '') + '><span class="ct-switch" aria-hidden="true"></span>' +
      '<span class="ct-toggle-text"><b>' + label + '</b>' + (hint ? '<small>' + hint + '</small>' : '') + '</span></label>';
  }
  function fSegment(key, label, options) {
    return '<div class="field ct-field" data-field="' + key + '"><label>' + label + '</label><div class="ct-segment" role="radiogroup" aria-label="' + esc(label) + '">' +
      options.map(([v, l]) => '<button type="button" role="radio" aria-checked="' + (state.form[key] === v) + '" class="ct-seg-btn' + (state.form[key] === v ? ' is-on' : '') + '" data-seg="' + key + '" data-value="' + v + '">' + l + '</button>').join('') +
      '</div>' + errHtml(key) + '</div>';
  }

  /* ───────── Pasos ───────── */
  function stepOperation() {
    const f = state.form;
    const alquiler = f.operacion === 'alquiler';
    const cur = f.moneda === 'Bs' ? 'Bs' : 'USD';
    return fSegment('operacion', 'Tipo de operación', OPS) +
      fSegment('moneda', 'Moneda', [['USD', 'Dólares (USD)'], ['Bs', 'Bolivianos (Bs)']]) +
      '<div class="ct-row">' +
        fText('precio', alquiler ? 'Canon mensual de oferta (' + cur + ')' : 'Precio de oferta (' + cur + ')', { mode: 'decimal', ph: alquiler ? '3.500' : '450.000', half: true, max: 20 }) +
        fText('precio_minimo', alquiler ? 'Canon mínimo aceptable' : 'Precio mínimo aceptable', { mode: 'decimal', opt: true, half: true, max: 20, hint: 'Solo si autorizas ofertas a partir de ese monto.' }) +
      '</div>' +
      '<div class="ct-row">' +
        (alquiler
          ? fText('comision_meses', 'Honorarios (meses de canon)', { mode: 'decimal', half: true, max: 5, hint: 'Por defecto 1 mes.' })
          : fText('comision_porcentaje', 'Honorarios (% sobre el precio)', { mode: 'decimal', half: true, max: 6, hint: 'Por defecto 3%.' })) +
      '</div>' +
      fToggle('impuestos_incluidos', 'Los honorarios incluyen impuestos de ley', 'Si lo desactivas, el contrato dirá que se facturan adicionalmente.');
  }

  function stepOwner() {
    return '<div class="ct-row">' + fText('propietario_nombre', 'Nombre completo del propietario', { auto: 'off', half: true }) +
        fText('propietario_ci', 'C.I. Nº', { mode: 'text', ph: '1234567 LP', half: true, max: 20 }) + '</div>' +
      '<div class="ct-row">' + fSelect('propietario_estado_civil', 'Estado civil', CIVIL, { placeholder: 'Selecciona…', half: true }) +
        fText('propietario_telefono', 'Teléfono', { type: 'tel', mode: 'tel', ph: '70012345', half: true, max: 20 }) + '</div>' +
      fText('propietario_domicilio', 'Domicilio') +
      fText('propietario_email', 'Correo electrónico', { type: 'email', mode: 'email' }) +
      fToggle('tiene_copropietario', 'Tiene copropietario o cónyuge', 'Firmará el contrato en señal de conformidad.') +
      (state.form.tiene_copropietario ? '<div class="ct-sub ct-row">' + fText('copropietario_nombre', 'Nombre del copropietario / cónyuge', { half: true }) + fText('copropietario_ci', 'C.I. Nº', { half: true, max: 20 }) + '</div>' : '') +
      fToggle('tiene_apoderado', 'Actúa mediante apoderado', 'Un representante con poder firma por el propietario.') +
      (state.form.tiene_apoderado
        ? '<div class="ct-sub"><div class="ct-row">' + fText('apoderado_nombre', 'Nombre del apoderado', { half: true }) + fText('apoderado_ci', 'C.I. Nº', { half: true, max: 20 }) + '</div>' +
          '<div class="ct-row">' + fText('poder_numero', 'Nº del Testimonio de Poder', { half: true, max: 40 }) + fText('poder_fecha', 'Fecha del poder', { type: 'date', half: true }) + '</div>' +
          fText('poder_notaria', 'Notaría de Fe Pública Nº', { max: 40 }) + '</div>' : '');
  }

  function stepProperty() {
    const f = state.form;
    return '<div class="ct-row">' + fSelect('inmueble_tipo', 'Tipo de inmueble', PROP_TYPES, { half: true }) + fText('inmueble_zona', 'Zona', { half: true }) + '</div>' +
      fText('inmueble_direccion', 'Dirección', { ph: 'Av. Ballivián Nº 1234, Edif. Sol, Piso 5' }) +
      '<div class="ct-row">' + fText('inmueble_ciudad', 'Ciudad', { half: true }) + fSelect('inmueble_departamento', 'Departamento', DEPARTMENTS, { half: true }) + '</div>' +
      '<div class="ct-row">' + fText('inmueble_sup_terreno', 'Superficie de terreno (m²)', { mode: 'decimal', half: true, max: 14 }) +
        (f.inmueble_tipo !== 'Terreno' ? fText('inmueble_sup_construida', 'Superficie construida (m²)', { mode: 'decimal', opt: true, half: true, max: 14 }) : '') + '</div>' +
      '<div class="ct-row">' + fText('inmueble_matricula', 'Matrícula Computarizada (Folio Real)', { half: true, max: 40, ph: '2.01.0.99.0012345' }) +
        fText('inmueble_catastro', 'Código catastral', { opt: true, half: true, max: 40 }) + '</div>' +
      fToggle('con_gravamenes', 'El inmueble tiene gravamen', 'Por defecto se declara libre de gravámenes.') +
      (f.con_gravamenes ? '<div class="ct-sub">' + fText('gravamenes_detalle', 'Describe el gravamen', { ph: 'Hipoteca a favor de…' }) + '</div>' : '');
  }

  function endDateText() {
    try {
      const d = num(state.form.plazo_dias);
      if (d == null) return '';
      return 'Vence el ' + H.dateToLong(H.addDays(state.form.fecha_inicio, d)) + '.';
    } catch (e) { return ''; }
  }

  function stepConditions() {
    const f = state.form;
    const custom = !PLAZOS.includes(Number(f.plazo_dias));
    const docs = [['doc_testimonio', 'Testimonio de propiedad'], ['doc_folio', 'Folio Real actualizado'], ['doc_impuestos', 'Impuestos al día'], ['doc_plano', 'Plano aprobado'], ['doc_ci', 'Copia de C.I. del propietario']]
      .concat(f.tiene_apoderado ? [['doc_poder', 'Testimonio de poder']] : []);
    return '<div class="ct-row">' + fText('fecha_inicio', 'Fecha de inicio', { type: 'date', half: true }) + '</div>' +
      '<div class="field ct-field' + hasErr('plazo_dias') + '" data-field="plazo_dias"><label>Plazo del contrato</label><div class="ct-chips">' +
        PLAZOS.map((p) => '<button type="button" class="ct-chip' + (Number(f.plazo_dias) === p ? ' is-on' : '') + '" data-chip="' + p + '">' + p + ' días</button>').join('') +
        '<span class="ct-chip-custom"><input type="text" inputmode="numeric" data-f="plazo_dias" maxlength="3" value="' + (custom ? esc(f.plazo_dias) : '') + '" placeholder="Otro" aria-label="Otro plazo en días"></span>' +
      '</div><p class="field-hint ct-end">' + esc(endDateText()) + '</p>' + errHtml('plazo_dias') + '</div>' +
      fToggle('renovacion_automatica', 'Renovación automática', 'Si no se avisa, el contrato se renueva por períodos iguales.') +
      (f.renovacion_automatica ? '<div class="ct-sub">' + fText('dias_preaviso', 'Días de preaviso para no renovar', { mode: 'numeric', half: true, max: 3 }) + '</div>' : '') +
      '<details class="ct-adv"' + (Object.keys(state.errors).some((k) => STEP_OF[k] === 3 && !['fecha_inicio', 'plazo_dias', 'dias_preaviso'].includes(k)) ? ' open' : '') + '><summary>Avanzado <small>(valores por defecto listos para usar)</small></summary>' +
        '<div class="ct-row">' + fText('dias_proteccion', 'Días de protección post-vencimiento', { mode: 'numeric', half: true, max: 3 }) + fText('penalidad_porcentaje', 'Penalidad por revocación (%)', { mode: 'numeric', half: true, max: 3 }) + '</div>' +
        '<div class="ct-row">' + fText('frecuencia_informe', 'Informe al propietario cada (días)', { mode: 'numeric', half: true, max: 3 }) + fText('horas_aviso_visita', 'Horas de aviso para visitas', { mode: 'numeric', half: true, max: 3 }) + '</div>' +
        '<div class="ct-row">' + fText('dias_subsanacion', 'Días para subsanar un incumplimiento', { mode: 'numeric', half: true, max: 3 }) + fText('ejemplares', 'Ejemplares', { mode: 'numeric', half: true, max: 2 }) + '</div>' +
        fText('forma_pago', 'Forma de pago de los honorarios') +
        '<div class="ct-row">' + fText('ciudad_firma', 'Ciudad de firma', { half: true }) + fText('ciudad_jurisdiccion', 'Ciudad de jurisdicción', { half: true }) + '</div>' +
        fToggle('autoriza_letrero', 'Autoriza colocar un letrero de oferta') +
        fText('gastos_extra_detalle', 'Gastos extraordinarios a cargo del propietario', { opt: true, ph: 'Ej. avalúo profesional' }) +
        '<p class="ct-docs-title">Documentación recibida (Anexo A)</p><div class="ct-docs">' +
          docs.map(([k, l]) => '<label class="ct-doc"><input type="checkbox" data-f="' + k + '"' + (f[k] ? ' checked' : '') + '><span>' + l + '</span></label>').join('') + '</div>' +
      '</details>';
  }

  /* ───────── Tarjeta del agente ───────── */
  function agentCard() {
    const a = state.agent;
    const missing = !a.ci.trim() || a.telefono.replace(/\D/g, '').length < 7 || a.nombre.trim().length < 3;
    if (state.editAgent || missing) {
      return '<section class="ct-agent is-edit" aria-label="Datos del agente"><div class="ct-agent-head"><b>Tus datos de agente</b><small>' +
        (missing ? 'Complétalos una vez; quedan guardados para tus próximos contratos.' : 'Se usan en la cláusula primera y en las firmas.') + '</small></div>' +
        '<div class="ct-row"><div class="field ct-field ct-half' + (state.errors.agent_nombre ? ' has-error' : '') + '"><label>Nombre completo</label><input data-a="nombre" value="' + esc(a.nombre) + '" maxlength="120" autocomplete="name">' + (state.errors.agent_nombre ? '<p class="ct-error">' + esc(state.errors.agent_nombre) + '</p>' : '') + '</div>' +
        '<div class="field ct-field ct-half' + (state.errors.agent_ci ? ' has-error' : '') + '"><label>C.I. Nº</label><input data-a="ci" value="' + esc(a.ci) + '" maxlength="20" placeholder="1234567 LP">' + (state.errors.agent_ci ? '<p class="ct-error">' + esc(state.errors.agent_ci) + '</p>' : '') + '</div></div>' +
        '<div class="ct-row"><div class="field ct-field ct-half' + (state.errors.agent_telefono ? ' has-error' : '') + '"><label>Teléfono</label><input data-a="telefono" type="tel" inputmode="tel" value="' + esc(a.telefono) + '" maxlength="20">' + (state.errors.agent_telefono ? '<p class="ct-error">' + esc(state.errors.agent_telefono) + '</p>' : '') + '</div>' +
        '<div class="field ct-field ct-half' + (state.errors.agent_email ? ' has-error' : '') + '"><label>Correo</label><input data-a="email" type="email" inputmode="email" value="' + esc(a.email) + '" maxlength="160">' + (state.errors.agent_email ? '<p class="ct-error">' + esc(state.errors.agent_email) + '</p>' : '') + '</div></div>' +
        '<div class="ct-row"><div class="field ct-field ct-half"><label>Registro Nº <span class="ct-opt">(opcional)</span></label><input data-a="registro" value="' + esc(a.registro) + '" maxlength="60"></div>' +
        '<div class="field ct-field ct-half"><label>Agencia</label><input data-a="agencia_nombre" value="' + esc(a.agencia_nombre) + '" maxlength="160"></div></div>' +
        '<div class="field ct-field"><label>Domicilio comercial</label><input data-a="agencia_domicilio" value="' + esc(a.agencia_domicilio) + '" maxlength="200"></div>' +
        '<div class="ct-agent-actions"><button type="button" class="btn btn-accent btn-sm" data-ct="save-agent">Guardar mis datos</button>' + (missing ? '' : '<button type="button" class="btn btn-ghost btn-sm" data-ct="cancel-agent">Cancelar</button>') + '</div></section>';
    }
    return '<section class="ct-agent" aria-label="Datos del agente"><div class="ct-agent-head"><b>' + esc(a.nombre) + '</b><small>C.I. ' + esc(a.ci) + ' · ' + esc(a.telefono) + ' · ' + esc(a.email) + '<br>' + esc(a.agencia_nombre) + '</small></div>' +
      '<button type="button" class="btn btn-ghost btn-sm" data-ct="edit-agent">Editar</button></section>';
  }

  /* ───────── Vista general ───────── */
  const money = (n) => Number(n).toLocaleString('es-BO');
  // ¿Puede generar contratos? El administrador siempre; los demás con un plan vigente que incluya las herramientas de agente.
  function canGenerate() {
    const sub = state.sub;
    if (!sub) return true;            // sin el SQL de suscripciones no se bloquea nada desde aquí (la base de datos decide)
    if (sub.exempt) return true;
    return (sub.status === 'active' || sub.status === 'canceling') && !!(sub.plan && sub.plan.agent_tools);
  }
  function planMessage() {
    const sub = state.sub;
    if (!sub || sub.exempt) return '';
    if (sub.status === 'none') return 'Necesitas un plan Agente o Empresa para generar contratos.';
    if (sub.status === 'expired') return 'Tu plan venció. Renueva tu suscripción para generar contratos.';
    if (!(sub.plan && sub.plan.agent_tools)) return 'Tu plan ' + sub.plan.name + ' no incluye el contrato de exclusividad (plan Agente o Empresa).';
    return '';
  }
  function balanceChip() {
    const sub = state.sub;
    const label = !sub ? '' : sub.exempt ? 'Administrador' : (sub.plan ? 'Plan ' + sub.plan.name : 'Sin plan');
    return '<div class="ct-balance" title="Tu plan"><i></i><span>' + esc(label) + '</span>' + (canGenerate() ? '<b>Incluido</b>' : '<button type="button" class="btn btn-ghost btn-sm" data-ct="buy">Ver planes</button>') + '</div>';
  }

  function render() {
    const host = root();
    if (!host) return;
    if (state.success) { host.innerHTML = successHtml(); return; }
    const thisMonth = state.contracts.filter((c) => new Date(c.created_at) >= new Date(new Date().getFullYear(), new Date().getMonth(), 1)).length;
    const head = '<div class="ct-bar"><div class="ct-seg" role="tablist">' +
        '<button type="button" role="tab" aria-selected="' + (state.view === 'new') + '" class="ct-seg-btn' + (state.view === 'new' ? ' is-on' : '') + '" data-ct="view-new">Nuevo contrato</button>' +
        '<button type="button" role="tab" aria-selected="' + (state.view === 'history') + '" class="ct-seg-btn' + (state.view === 'history' ? ' is-on' : '') + '" data-ct="view-history">Mis contratos <span class="ct-count">' + state.contracts.length + '</span></button>' +
        (state.isAdmin ? '<button type="button" role="tab" aria-selected="' + (state.view === 'all') + '" class="ct-seg-btn' + (state.view === 'all' ? ' is-on' : '') + '" data-ct="view-all">Todos los contratos <span class="ct-count">' + state.allContracts.length + '</span></button>' : '') +
      '</div>' + balanceChip() + '</div>';
    host.innerHTML = head + (state.view === 'new' ? newViewHtml() : state.view === 'all' && state.isAdmin ? allHtml() : historyHtml(thisMonth));
    if (state.view === 'new') schedulePreview(0);
  }

  function newViewHtml() {
    const draft = state.draft
      ? '<div class="auth-banner ct-draft">Tienes un borrador sin terminar (' + esc(state.draft.when) + '). <button type="button" class="btn btn-accent btn-sm" data-ct="resume-draft">Continuar borrador</button> <button type="button" class="btn btn-ghost btn-sm" data-ct="discard-draft">Descartar</button></div>'
      : '';
    const s = state.step;
    const stepHtml = [stepOperation, stepOwner, stepProperty, stepConditions][s]();
    const progress = '<ol class="ct-progress" aria-label="Pasos">' + STEPS.map((t, i) =>
      '<li class="' + (i === s ? 'is-current' : i < s ? 'is-done' : '') + '"><button type="button" data-ct="go-step" data-step="' + i + '"' + (i > s ? ' tabindex="-1"' : '') + '><span>' + (i < s ? '✓' : i + 1) + '</span><em>' + t + '</em></button></li>').join('') + '</ol>';
    const blocked = !canGenerate();
    const nav = '<div class="ct-nav">' + (s > 0 ? '<button type="button" class="btn btn-ghost" data-ct="prev">← Atrás</button>' : '<span></span>') +
      (s < STEPS.length - 1
        ? '<button type="button" class="btn btn-accent" data-ct="next">Siguiente →</button>'
        : '<button type="button" class="btn btn-accent ct-generate" data-ct="generate">Generar contrato</button>') + '</div>' +
      (s === STEPS.length - 1 ? '<p class="ct-balance-note' + (blocked ? ' is-low' : '') + '">' + (blocked
        ? esc(planMessage()) + ' <button type="button" class="ct-link" data-ct="buy">Ver planes</button>'
        : 'Incluido en tu plan.') + '</p>' : '');
    return draft +
      '<div class="ct-mobile-toggle" role="tablist"><button type="button" class="ct-seg-btn' + (state.previewOpen ? '' : ' is-on') + '" data-ct="show-form">Formulario</button><button type="button" class="ct-seg-btn' + (state.previewOpen ? ' is-on' : '') + '" data-ct="show-preview">Vista previa</button></div>' +
      '<div class="ct-layout' + (state.previewOpen ? ' show-preview' : '') + '">' +
        '<section class="ct-form-col">' + agentCard() + progress + '<div class="ct-step" id="ct-step">' + stepHtml + '</div>' + nav + '</section>' +
        '<aside class="ct-preview-col" aria-label="Vista previa del contrato"><div class="ct-preview-head"><b>Vista previa</b><small>Los datos que escribes se resaltan en dorado. Así saldrá el PDF.</small></div>' +
        '<article class="cdoc" id="ct-preview"></article></aside>' +
      '</div>';
  }

  function successHtml() {
    const s = state.success;
    const canShare = !!(navigator.canShare && s.blob && navigator.canShare({ files: [new File([s.blob], s.fileName, { type: 'application/pdf' })] }));
    return '<div class="ct-success"><div class="ct-check" aria-hidden="true"><svg viewBox="0 0 52 52"><circle cx="26" cy="26" r="24"/><path d="M15 27l8 8 15-17"/></svg></div>' +
      '<h2>¡Contrato listo para firmar!</h2><p class="ct-success-num">' + esc(s.number) + '</p>' +
      '<p class="credits-muted">Incluido en tu plan. Volver a descargarlo desde “Mis contratos” es gratis.</p>' +
      (s.downloadFailed ? '<p class="form-error">La descarga automática no funcionó, pero tu contrato quedó guardado. Descárgalo aquí abajo (gratis).</p>' : '') +
      '<div class="ct-success-actions"><button type="button" class="btn btn-accent" data-ct="download-success">Descargar PDF</button>' +
      (canShare ? '<button type="button" class="btn btn-primary" data-ct="share-success">Compartir por WhatsApp</button>' : '') +
      '<button type="button" class="btn btn-ghost" data-ct="new-another">Crear otro</button><button type="button" class="btn btn-ghost" data-ct="view-history">Mis contratos</button></div></div>';
  }

  /* ───────── Historial ───────── */
  function expiry(c) {
    if (c.voided_at) return { text: 'Anulado', cls: 'b-bad', end: '' };
    try {
      const end = H.addDays(c.data.fecha_inicio, c.data.plazo_dias);
      const days = Math.round((H.parseISO(end) - H.parseISO(H.todayBolivia())) / 86400000);
      if (days < 0) return { text: 'Vencido', cls: 'b-bad', end };
      if (days === 0) return { text: 'Vence hoy', cls: 'b-warn', end };
      return { text: 'Vence en ' + days + (days === 1 ? ' día' : ' días'), cls: days <= 15 ? 'b-warn' : 'b-ok', end };
    } catch (e) { return { text: '—', cls: 'b-mute', end: '' }; }
  }
  const OP_LABEL = { venta: 'Venta', alquiler: 'Alquiler', anticretico: 'Anticrético' };
  const fdate = (d) => new Date(d).toLocaleDateString('es-BO', { day: '2-digit', month: 'short', year: 'numeric' });

  function historyHtml(thisMonth) {
    const q = state.search.trim().toLowerCase();
    const list = state.contracts.filter((c) => !q || [c.contract_number, c.data.propietario_nombre, c.data.inmueble_direccion, c.data.inmueble_zona].join(' ').toLowerCase().includes(q));
    const body = list.length ? '<div class="ct-history">' + list.map((c) => {
      const ex = expiry(c);
      return '<article class="ct-hrow"><div class="ct-hmain"><b>' + esc(c.data.propietario_nombre) + '</b><span class="ct-hnum">' + esc(c.contract_number) + '</span>' +
        '<span class="credits-muted">' + esc(c.data.inmueble_tipo) + ' · ' + esc(c.data.inmueble_direccion) + (c.data.inmueble_zona ? ', ' + esc(c.data.inmueble_zona) : '') + '</span>' +
        (c.voided_at ? '<span class="ct-void-note">Anulado el ' + fdate(c.voided_at) + (c.void_reason ? ' · ' + esc(c.void_reason) : '') + '</span>' : '') + '</div>' +
        '<div class="ct-hmeta"><span class="badge b-gold">' + esc(OP_LABEL[c.data.operacion] || c.data.operacion) + '</span><span class="badge ' + ex.cls + '" title="' + esc(ex.end ? 'Hasta el ' + H.dateToLong(ex.end) : '') + '">' + esc(ex.text) + '</span>' +
        '<span class="credits-muted">' + new Date(c.created_at).toLocaleDateString('es-BO', { day: '2-digit', month: 'short', year: 'numeric' }) + '</span></div>' +
        '<div class="ct-hactions"><button type="button" class="btn btn-accent btn-sm" data-ct="redownload" data-id="' + c.id + '">Descargar PDF</button>' +
        '<button type="button" class="btn btn-ghost btn-sm" data-ct="duplicate" data-id="' + c.id + '">Duplicar</button></div></article>';
    }).join('') + '</div>' : '<p class="property-empty">' + (state.contracts.length ? 'No hay contratos que coincidan con tu búsqueda.' : 'Todavía no has generado contratos. Crea el primero con “Nuevo contrato”.') + '</p>';
    return '<div class="ct-hhead"><p class="credits-muted">Este mes: <b>' + thisMonth + '</b> ' + (thisMonth === 1 ? 'contrato generado' : 'contratos generados') + '. Descargar de nuevo es gratis.</p>' +
      '<input type="search" class="ct-search" id="ct-search" placeholder="Buscar por propietario, dirección o Nº…" value="' + esc(state.search) + '" aria-label="Buscar contratos"></div>' + body;
  }

  /* ───────── Administrador: todos los contratos ───────── */
  const agentLabel = (id) => { const u = state.people[id]; return u ? (u.display_name || u.email) : 'Sin agente'; };

  function adminStatus(c) {
    if (c.voided_at) return 'anulado';
    const ex = expiry(c);
    if (ex.text === 'Vencido') return 'vencido';
    if (ex.cls === 'b-warn') return 'por_vencer';
    return 'vigente';
  }

  function allHtml() {
    const f = state.fa;
    const q = f.q.trim().toLowerCase();
    const list = state.allContracts.filter((c) =>
      (!f.agent || c.agent_id === f.agent) && (!f.op || c.data.operacion === f.op) && (!f.status || adminStatus(c) === f.status) &&
      (!q || [c.contract_number, c.data.propietario_nombre, c.data.inmueble_direccion, c.data.inmueble_zona, agentLabel(c.agent_id)].join(' ').toLowerCase().includes(q)));
    const count = (s) => state.allContracts.filter((c) => adminStatus(c) === s).length;
    const agentIds = [...new Set(state.allContracts.map((c) => c.agent_id))];
    const opt = (v, l, cur) => '<option value="' + esc(v) + '"' + (v === cur ? ' selected' : '') + '>' + esc(l) + '</option>';
    const filters = '<div class="ct-filters">' +
      '<input type="search" class="ct-search" id="ct-asearch" placeholder="Buscar por propietario, dirección, agente o Nº…" value="' + esc(f.q) + '" aria-label="Buscar contratos">' +
      '<select data-fa="agent" aria-label="Agente">' + opt('', 'Todos los agentes', f.agent) + agentIds.map((id) => opt(id || '', agentLabel(id), f.agent)).join('') + '</select>' +
      '<select data-fa="op" aria-label="Operación">' + opt('', 'Todas las operaciones', f.op) + OPS.map((o) => opt(o[0], o[1], f.op)).join('') + '</select>' +
      '<select data-fa="status" aria-label="Estado">' + opt('', 'Todos los estados', f.status) + opt('vigente', 'Vigentes', f.status) + opt('por_vencer', 'Por vencer (15 días)', f.status) + opt('vencido', 'Vencidos', f.status) + opt('anulado', 'Anulados', f.status) + '</select></div>';
    const summary = '<p class="credits-muted ct-asummary"><b>' + state.allContracts.length + '</b> contratos en total · <b>' + count('vigente') + '</b> vigentes · <b>' + count('por_vencer') + '</b> por vencer · <b>' + count('vencido') + '</b> vencidos · <b>' + count('anulado') + '</b> anulados' +
      (list.length !== state.allContracts.length ? ' · mostrando <b>' + list.length + '</b>' : '') + '</p>';
    const body = list.length ? '<div class="ct-history">' + list.map((c) => {
      const ex = expiry(c);
      return '<article class="ct-hrow ct-arow' + (c.voided_at ? ' is-void' : '') + '"><div class="ct-hmain"><b>' + esc(c.data.propietario_nombre) + '</b><span class="ct-hnum">' + esc(c.contract_number) + '</span>' +
        '<span class="credits-muted">' + esc(c.data.inmueble_tipo) + ' · ' + esc(c.data.inmueble_direccion) + (c.data.inmueble_zona ? ', ' + esc(c.data.inmueble_zona) : '') + '</span>' +
        '<span class="ct-agentline">Agente: <b>' + esc(agentLabel(c.agent_id)) + '</b></span>' +
        (c.voided_at ? '<span class="ct-void-note">Anulado el ' + fdate(c.voided_at) + ' · ' + esc(c.void_reason || '') + '</span>' : '') + '</div>' +
        '<div class="ct-hmeta"><span class="badge b-gold">' + esc(OP_LABEL[c.data.operacion] || c.data.operacion) + '</span><span class="badge ' + ex.cls + '" title="' + esc(ex.end ? 'Hasta el ' + H.dateToLong(ex.end) : '') + '">' + esc(ex.text) + '</span>' +
        '<span class="credits-muted">' + fdate(c.created_at) + '</span></div>' +
        '<div class="ct-hactions"><button type="button" class="btn btn-accent btn-sm" data-ct="redownload" data-id="' + c.id + '">Descargar PDF</button>' +
        (c.voided_at ? '' : '<button type="button" class="btn btn-ghost btn-sm ct-btn-void" data-ct="void" data-id="' + c.id + '">Anular</button>') + '</div></article>';
    }).join('') + '</div>' : '<p class="property-empty">No hay contratos que coincidan con los filtros.</p>';
    return '<p class="credits-muted ct-ahint">Contratos de todos los agentes. Descargar es gratis; un contrato anulado sigue existiendo, pero la página de verificación lo muestra como “Anulado” y su PDF sale con la marca ANULADO.</p>' + summary + filters + body;
  }

  function voidModal(id) {
    const c = state.allContracts.find((x) => x.id === id);
    if (!c) return;
    openOverlay('<h2>Anular contrato</h2>' +
      '<p><b>' + esc(c.contract_number) + '</b> · ' + esc(c.data.propietario_nombre) + '<br><span class="credits-muted">Agente: ' + esc(agentLabel(c.agent_id)) + '</span></p>' +
      '<div class="ct-warn">Esto <b>no se puede deshacer</b> desde el panel.  La página de verificación mostrará “Anulado” y el PDF saldrá con la marca ANULADO. El agente verá el motivo.</div>' +
      '<div class="field"><label for="ct-void-reason">Motivo de la anulación</label><textarea id="ct-void-reason" rows="3" maxlength="300" placeholder="Ej: Datos del propietario incorrectos; se emitió uno nuevo"></textarea></div>' +
      '<p id="ct-modal-error" class="form-error hidden"></p>' +
      '<div class="modal-form-actions"><button type="button" class="btn btn-ghost" data-ct="close-overlay">Cancelar</button><button type="button" class="btn btn-danger" id="ct-confirm-void" data-ct="confirm-void" data-id="' + esc(id) + '">Anular contrato</button></div>');
    const ta = document.getElementById('ct-void-reason'); if (ta) ta.focus();
  }

  async function confirmVoid(id) {
    if (state.busy) return;
    const reason = (document.getElementById('ct-void-reason').value || '').trim();
    const err = document.getElementById('ct-modal-error');
    const btn = document.getElementById('ct-confirm-void');
    err.classList.add('hidden');
    if (reason.length < 5) { err.textContent = 'Escribe el motivo de la anulación (mínimo 5 caracteres).'; err.classList.remove('hidden'); return; }
    state.busy = true; btn.disabled = true; btn.innerHTML = '<span class="ct-spin"></span> Anulando…';
    try {
      const { error } = await supabaseClient.rpc('admin_void_exclusivity_contract', { p_id: id, p_reason: reason });
      if (error) throw new Error(error.message || 'No se pudo anular el contrato.');
      closeOverlay();
      await loadContractsOnly();
      render();
      toast('Contrato anulado.');
    } catch (e) {
      err.textContent = (e && e.message) || 'No se pudo anular el contrato.';
      err.classList.remove('hidden');
      btn.disabled = false; btn.textContent = 'Anular contrato';
    } finally { state.busy = false; }
  }

  /* ───────── Vista previa en vivo ───────── */
  function schedulePreview(delay) {
    clearTimeout(state.previewTimer);
    state.previewTimer = setTimeout(renderPreview, delay == null ? 220 : delay);
  }

  function renderPreview() {
    const box = document.getElementById('ct-preview');
    const tpl = state.templates[templateVersionFor(state.form && state.form.operacion)];
    if (!box || !tpl) return;
    try {
      const data = buildData(state.form);
      const year = H.todayBolivia().slice(0, 4);
      const blocks = T.renderBlocks(tpl, data, { numero_contrato: 'BST-CE-' + year + '-XXXX', codigo_verificacion: 'XXXXXXXX' }, { mark: true, lenient: true, placeholder: '________' });
      box.innerHTML = T.blocksToHtml(blocks);
    } catch (e) {
      box.innerHTML = '<p class="credits-muted">La vista previa aparecerá cuando completes los datos del paso 1.</p>';
    }
  }

  /* ───────── Borrador (autoguardado en el navegador) ───────── */
  const isPristine = () => JSON.stringify({ ...state.form, fecha_inicio: '' }) === JSON.stringify({ ...defaultForm(), fecha_inicio: '' });
  function saveDraftSoon() {
    clearTimeout(state.saveTimer);
    state.saveTimer = setTimeout(() => {
      try { if (isPristine()) localStorage.removeItem(draftKey()); else localStorage.setItem(draftKey(), JSON.stringify({ form: state.form, step: state.step, savedAt: Date.now() })); } catch (e) { /* sin almacenamiento */ }
    }, 400);
  }
  function loadDraft() {
    try {
      const raw = JSON.parse(localStorage.getItem(draftKey()) || 'null');
      if (!raw || !raw.form) return null;
      const mins = Math.round((Date.now() - raw.savedAt) / 60000);
      const when = mins < 1 ? 'hace un momento' : mins < 60 ? 'hace ' + mins + ' min' : mins < 1440 ? 'hace ' + Math.round(mins / 60) + ' h' : 'hace ' + Math.round(mins / 1440) + ' d';
      return { form: raw.form, step: raw.step || 0, when };
    } catch (e) { return null; }
  }
  const clearDraft = () => { try { localStorage.removeItem(draftKey()); } catch (e) { /* nada */ } state.draft = null; };

  /* ───────── Carga de datos ───────── */
  async function loadAll() {
    if (state.loading) return;
    state.loading = true;
    const host = root();
    try {
      if (!state.ready) host.innerHTML = '<p class="credits-muted">Cargando…</p>';
      const { data: auth } = await supabaseClient.auth.getUser();
      state.uid = auth && auth.user && auth.user.id;
      if (!state.uid) { host.innerHTML = '<p class="property-empty">Inicia sesión para usar esta herramienta.</p>'; return; }
      const [prof, legal, subRes, list, tpl] = await Promise.all([
        supabaseClient.from('profiles').select('display_name,email,role').eq('id', state.uid).maybeSingle(),
        supabaseClient.from('agent_legal_profiles').select('ci,phone,registration').eq('user_id', state.uid).maybeSingle(),
        supabaseClient.rpc('my_subscription'),
        contractsQuery(true, 300),
        Promise.all(TEMPLATE_VERSIONS.map((v) => (state.templates[v] ? Promise.resolve(null) : fetch(asset('contracts/' + v + '.md')).then((r) => { if (!r.ok) throw new Error('No se pudo cargar la plantilla del contrato'); return r.text(); })))),
      ]);
      if (list.error) throw list.error;
      TEMPLATE_VERSIONS.forEach((v, i) => { if (tpl[i]) state.templates[v] = tpl[i]; });
      state.sub = subRes.error ? null : subRes.data;
      state.contracts = list.data || [];
      state.isAdmin = !!(prof.data && prof.data.role === 'admin');
      if (state.isAdmin) await loadAdminData();
      if (!state.ready) {
        const saved = (() => { try { return JSON.parse(localStorage.getItem(agencyKey()) || 'null') || {}; } catch (e) { return {}; } })();
        state.agent = {
          nombre: (prof.data && prof.data.display_name) || '', email: (prof.data && prof.data.email) || (auth.user && auth.user.email) || '',
          ci: (legal.data && legal.data.ci) || '', telefono: (legal.data && legal.data.phone) || '', registro: (legal.data && legal.data.registration) || '',
          agencia_nombre: saved.agencia_nombre || AGENCY.nombre, agencia_domicilio: saved.agencia_domicilio || AGENCY.domicilio,
        };
        state.form = defaultForm();
        state.draft = loadDraft();
        state.ready = true;
      }
      render();
    } catch (e) {
      host.innerHTML = '<p class="form-error">No se pudo cargar la herramienta. ' + esc((e && e.message) || '') + '</p>';
    } finally { state.loading = false; }
  }

  /* ───────── Mensajes ───────── */
  function toast(msg, isError) {
    let el = document.getElementById('ct-toast');
    if (!el) { el = document.createElement('div'); el.id = 'ct-toast'; el.setAttribute('role', 'status'); document.body.appendChild(el); }
    el.textContent = msg;
    el.className = 'ct-toast show' + (isError ? ' is-error' : '');
    clearTimeout(toast.t);
    toast.t = setTimeout(() => { el.className = 'ct-toast'; }, 4200);
  }

  /* ───────── Pasos: navegación y validación ───────── */
  function goStep(n) {
    state.step = Math.max(0, Math.min(STEPS.length - 1, n));
    render();
    const top = document.getElementById('tab-panel-contracts');
    if (top) top.scrollIntoView({ block: 'start' });
    // Foco al primer campo vacío del paso: se puede escribir sin tocar el ratón
    const first = [...document.querySelectorAll('#ct-step input:not([type="checkbox"]):not([data-f="plazo_dias"]), #ct-step select')].find((el) => !el.value) ||
      document.querySelector('#ct-step input:not([type="checkbox"]), #ct-step select');
    if (first) first.focus({ preventScroll: true });
    saveDraftSoon();
  }

  function stepErrors(step) {
    const all = validate(state.form);
    const out = {};
    Object.keys(all).forEach((k) => { if (STEP_OF[k] === step) out[k] = all[k]; });
    return out;
  }

  function focusFirstError() {
    const first = document.querySelector('#contracts-root .field.has-error input, #contracts-root .field.has-error select');
    if (first) { first.focus({ preventScroll: true }); first.scrollIntoView({ block: 'center', behavior: 'smooth' }); }
  }

  function nextStep() {
    const errs = stepErrors(state.step);
    if (Object.keys(errs).length) { state.errors = errs; render(); focusFirstError(); toast('Revisa los campos marcados.', true); return; }
    state.errors = {};
    goStep(state.step + 1);
  }

  /* ───────── Generación (cobro + PDF) ───────── */
  function openOverlay(html) {
    closeOverlay();
    const o = document.createElement('div');
    o.className = 'modal-overlay ct-overlay';
    o.id = 'ct-overlay';
    o.innerHTML = '<div class="modal-panel ct-modal" role="dialog" aria-modal="true">' + html + '</div>';
    document.body.appendChild(o);
    return o;
  }
  const closeOverlay = () => { const o = document.getElementById('ct-overlay'); if (o) o.remove(); };

  function generate() {
    const errs = validate(state.form);
    if (Object.keys(errs).length) {
      state.errors = errs;
      const keys = Object.keys(errs);
      const agentOnly = keys.every((k) => k.startsWith('agent_'));
      const stepIdx = agentOnly ? state.step : Math.min(...keys.filter((k) => !k.startsWith('agent_')).map((k) => STEP_OF[k]));
      state.step = stepIdx;
      state.editAgent = keys.some((k) => k.startsWith('agent_'));
      render(); focusFirstError();
      toast('Faltan datos: revisa los campos marcados.', true);
      return;
    }
    state.errors = {};
    const data = buildData(state.form);
    const json = JSON.stringify(data);
    if (!state.idem || state.idem.json !== json) {
      const saved = readIdem();
      state.idem = saved && saved.json === json && saved.key ? saved : { key: (crypto.randomUUID ? crypto.randomUUID() : 'k-' + Date.now() + '-' + Math.random().toString(36).slice(2)), json };
    }
    writeIdem(state.idem);
    if (!canGenerate()) { noPlanModal(); return; }
    const o = openOverlay('<h2>Generar contrato</h2>' +
      '<p>El contrato está <b>incluido en tu plan</b>: no se descuenta nada.</p>' +
      '<p class="credits-muted">Descargarás el PDF listo para firmar, con el membrete de Bastet. Volver a descargarlo después es gratis.</p>' +
      '<p id="ct-modal-error" class="form-error hidden"></p>' +
      '<div class="modal-form-actions"><button type="button" class="btn btn-ghost" data-ct="close-overlay">Revisar</button><button type="button" class="btn btn-accent" id="ct-confirm" data-ct="confirm-generate">Generar y descargar</button></div>');
    const btn = o.querySelector('#ct-confirm'); if (btn) btn.focus();
  }

  function noPlanModal() {
    openOverlay('<h2>Necesitas un plan</h2><p>' + esc(planMessage()) + '</p>' +
      '<p class="credits-muted">Tu borrador se conserva: elige un plan y vuelve para generar el contrato.</p>' +
      '<div class="modal-form-actions"><button type="button" class="btn btn-ghost" data-ct="close-overlay">Cerrar</button><button type="button" class="btn btn-accent" data-ct="buy">Ver planes</button></div>');
  }

  async function prepareDoc(data, number, code, voided, version, issuedAt) {
    await P.ensureLibs(asset('js/contracts/contract-fonts.js'));
    const letterhead = await P.fetchDataUrl(asset('img/membrete-bastet.jpg'));
    const tpl = state.templates[version || templateVersionFor(data.operacion)];
    if (!tpl) throw new Error('Plantilla del contrato no disponible');
    const blocks = T.renderBlocks(tpl, data, { numero_contrato: number, codigo_verificacion: code });
    return P.build({ blocks, number, code, agentName: data.agente_nombre, letterheadDataUrl: letterhead, voided: !!voided, issuedAt });
  }

  async function confirmGenerate() {
    if (state.busy) return;
    state.busy = true;
    const btn = document.getElementById('ct-confirm');
    const err = document.getElementById('ct-modal-error');
    const setBtn = (txt, dis) => { if (btn) { btn.disabled = dis; btn.innerHTML = dis ? '<span class="ct-spin"></span> ' + txt : txt; } };
    err.classList.add('hidden');
    try {
      const data = buildData(state.form);
      setBtn('Preparando el PDF…', true);
      // 1) Prueba de generación: si el PDF no se puede armar, no se cobra nada
      const version = templateVersionFor(data.operacion);
      const dry = await prepareDoc(data, 'BST-CE-0000-0000', 'XXXXXXXX', false, version);
      await P.getBlob(dry);
      // 2) Numeración + guardado, todo en el servidor y en una sola transacción (el plan lo cubre; no hay cobro)
      setBtn('Guardando…', true);
      const { data: res, error } = await supabaseClient.rpc('create_exclusivity_contract', { p_data: data, p_idempotency_key: state.idem.key, p_template_version: version });
      if (error) {
        const msg = String(error.message || '');
        if (/suscripci[oó]n|plan .* no incluye/i.test(msg)) { closeOverlay(); noPlanModal(); return; }
        throw new Error(/No autorizado/i.test(msg) ? 'Tu sesión no tiene permiso para generar contratos.' : msg || 'No se pudo generar el contrato.');
      }
      // 3) PDF definitivo con el número y el código reales
      setBtn('Descargando…', true);
      let blob = null; let downloadFailed = false;
      const name = P.fileName(res.contract_number, data.propietario_nombre);
      try {
        const doc = await prepareDoc(data, res.contract_number, res.verification_code, false, version, res.created_at);
        blob = await P.download(doc, name);
      } catch (e) { downloadFailed = true; }
      clearDraft();
      state.idem = null;
      writeIdem(null);
      state.success = { number: res.contract_number, code: res.verification_code, data, blob, fileName: name, downloadFailed };
      closeOverlay();
      await loadContractsOnly();
      render();
    } catch (e) {
      err.textContent = (e && e.message) || 'No se pudo generar el contrato.';
      err.classList.remove('hidden');
      setBtn('Intentar de nuevo', false);
    } finally { state.busy = false; }
  }

  async function loadContractsOnly() {
    const { data } = await contractsQuery(true, 300);
    if (data) state.contracts = data;
    if (state.isAdmin) await loadAdminData();
  }

  // Administrador: todos los contratos de todos los agentes (la base ya lo permite por RLS) y los nombres de los agentes
  async function loadAdminData() {
    const [all, people] = await Promise.all([
      contractsQuery(false, 1000),
      supabaseClient.from('profiles').select('id,display_name,email'),
    ]);
    if (all.data) state.allContracts = all.data;
    state.people = {};
    (people.data || []).forEach((u) => { state.people[u.id] = u; });
  }

  async function redownload(id, btn) {
    const c = state.contracts.find((x) => x.id === id) || state.allContracts.find((x) => x.id === id);
    if (!c || (btn && btn.disabled)) return;
    if (btn) { btn.disabled = true; btn.dataset.label = btn.textContent; btn.innerHTML = '<span class="ct-spin"></span>'; }
    try {
      const doc = await prepareDoc(c.data, c.contract_number, c.verification_code, !!c.voided_at, c.template_version, c.created_at);
      await P.download(doc, P.fileName(c.contract_number, c.data.propietario_nombre));
    } catch (e) { toast('No se pudo preparar el PDF: ' + ((e && e.message) || 'error'), true); }
    finally { if (btn) { btn.disabled = false; btn.textContent = btn.dataset.label || 'Descargar PDF'; } }
  }

  /* ───────── Eventos ───────── */
  function setField(key, value) {
    state.form[key] = value;
    if (state.errors[key]) { delete state.errors[key]; const f = document.querySelector('[data-field="' + key + '"]'); if (f) { f.classList.remove('has-error'); const p = f.querySelector('.ct-error'); if (p) p.remove(); } }
    if (key === 'plazo_dias' || key === 'fecha_inicio') { const e = document.querySelector('.ct-end'); if (e) e.textContent = endDateText(); }
    saveDraftSoon();
    schedulePreview();
  }

  function onInput(e) {
    const t = e.target;
    if (t.dataset.a) { state.agent[t.dataset.a] = t.value; const k = 'agent_' + t.dataset.a; if (state.errors[k]) { delete state.errors[k]; t.closest('.field').classList.remove('has-error'); const p = t.closest('.field').querySelector('.ct-error'); if (p) p.remove(); } schedulePreview(); return; }
    if (t.id === 'ct-asearch') { state.fa.q = t.value; const pos = t.selectionStart; render(); const s = document.getElementById('ct-asearch'); if (s) { s.focus(); s.setSelectionRange(pos, pos); } return; }
    if (t.id === 'ct-search') { state.search = t.value; const pos = t.selectionStart; render(); const s = document.getElementById('ct-search'); if (s) { s.focus(); s.setSelectionRange(pos, pos); } return; }
    const key = t.dataset.f;
    if (!key) return;
    if (t.type === 'checkbox') return; // se maneja en "change"
    setField(key, t.value);
  }

  function onChange(e) {
    const t = e.target;
    if (t.dataset.fa) { state.fa[t.dataset.fa] = t.value; render(); return; }
    const key = t.dataset.f;
    if (!key) return;
    const value = t.type === 'checkbox' ? t.checked : t.value;
    setField(key, value);
    if (key === 'moneda') state.touchedMoneda = true;
    if (REFLOW.has(key)) reflowStep();
  }

  // Vuelve a dibujar solo el paso actual (conserva el scroll)
  function reflowStep() {
    const stepEl = document.getElementById('ct-step');
    if (!stepEl) return;
    stepEl.innerHTML = [stepOperation, stepOwner, stepProperty, stepConditions][state.step]();
    schedulePreview(0);
  }

  async function onClick(e) {
    const seg = e.target.closest('[data-seg]');
    if (seg) {
      const key = seg.dataset.seg; const val = seg.dataset.value;
      state.form[key] = val;
      if (key === 'operacion') {
        if (!state.touchedMoneda) state.form.moneda = val === 'alquiler' ? 'Bs' : 'USD';
        state.errors = {};
      }
      if (key === 'moneda') state.touchedMoneda = true;
      saveDraftSoon(); reflowStep(); return;
    }
    const chip = e.target.closest('[data-chip]');
    if (chip) { setField('plazo_dias', chip.dataset.chip); reflowStep(); return; }

    const b = e.target.closest('[data-ct]');
    if (!b) return;
    const act = b.dataset.ct;
    switch (act) {
      case 'view-new': state.success = null; state.view = 'new'; render(); break;
      case 'view-history': state.success = null; state.view = 'history'; render(); break;
      case 'view-all': if (state.isAdmin) { state.success = null; state.view = 'all'; render(); } break;
      case 'void': voidModal(b.dataset.id); break;
      case 'confirm-void': confirmVoid(b.dataset.id); break;
      case 'next': nextStep(); break;
      case 'prev': goStep(state.step - 1); break;
      case 'go-step': { const n = Number(b.dataset.step); if (n < state.step) goStep(n); break; }
      case 'generate': generate(); break;
      case 'confirm-generate': confirmGenerate(); break;
      case 'close-overlay': closeOverlay(); break;
      case 'buy': closeOverlay(); { const tab = document.querySelector('.admin-tab[data-tab="subscription"]'); if (tab) tab.click(); } break;
      case 'show-preview': state.previewOpen = true; document.querySelector('.ct-layout').classList.add('show-preview'); document.querySelectorAll('.ct-mobile-toggle .ct-seg-btn').forEach((x, i) => x.classList.toggle('is-on', i === 1)); renderPreview(); break;
      case 'show-form': state.previewOpen = false; document.querySelector('.ct-layout').classList.remove('show-preview'); document.querySelectorAll('.ct-mobile-toggle .ct-seg-btn').forEach((x, i) => x.classList.toggle('is-on', i === 0)); break;
      case 'edit-agent': state.editAgent = true; render(); break;
      case 'cancel-agent': state.editAgent = false; state.errors = {}; render(); break;
      case 'save-agent': await saveAgent(); break;
      case 'resume-draft': if (state.draft) { state.form = { ...defaultForm(), ...state.draft.form }; state.step = state.draft.step; state.draft = null; render(); } break;
      case 'discard-draft': clearDraft(); render(); break;
      case 'redownload': redownload(b.dataset.id, b); break;
      case 'duplicate': {
        const c = state.contracts.find((x) => x.id === b.dataset.id);
        if (c) { state.form = formFromData(c.data); state.step = 0; state.view = 'new'; state.errors = {}; state.touchedMoneda = true; render(); toast('Contrato duplicado: cambia solo lo necesario.'); }
        break;
      }
      case 'download-success': if (state.success) { if (state.success.blob) { const a = document.createElement('a'); a.href = URL.createObjectURL(state.success.blob); a.download = state.success.fileName; document.body.appendChild(a); a.click(); a.remove(); } else { const c = state.contracts.find((x) => x.contract_number === state.success.number); if (c) { state.success.downloadFailed = false; await redownload(c.id, b); } } } break;
      case 'share-success': if (state.success && state.success.blob) { try { await navigator.share({ files: [new File([state.success.blob], state.success.fileName, { type: 'application/pdf' })], title: 'Contrato de Exclusividad ' + state.success.number }); } catch (err) { /* cancelado */ } } break;
      case 'new-another': state.success = null; state.form = defaultForm(); state.step = 0; state.errors = {}; state.touchedMoneda = false; state.view = 'new'; render(); break;
      default: break;
    }
  }

  async function saveAgent() {
    const a = state.agent;
    const errs = {};
    if (a.nombre.trim().length < 3) errs.agent_nombre = 'Escribe tu nombre completo';
    if (!CI_RE.test(a.ci.trim())) errs.agent_ci = 'Escribe tu C.I. (ej. 1234567 LP)';
    if (a.telefono.replace(/\D/g, '').length < 7) errs.agent_telefono = 'Escribe tu teléfono';
    if (!EMAIL_RE.test(a.email.trim())) errs.agent_email = 'Escribe tu correo';
    state.errors = { ...state.errors, ...errs };
    ['agent_nombre', 'agent_ci', 'agent_telefono', 'agent_email'].forEach((k) => { if (!errs[k]) delete state.errors[k]; });
    if (Object.keys(errs).length) { render(); return; }
    const [leg, prof] = await Promise.all([
      supabaseClient.from('agent_legal_profiles').upsert({ user_id: state.uid, ci: a.ci.trim(), phone: a.telefono.trim(), registration: a.registro.trim() || null, updated_at: new Date().toISOString() }),
      supabaseClient.from('profiles').update({ display_name: a.nombre.trim() }).eq('id', state.uid),
    ]);
    if (leg.error || prof.error) { toast('No se pudieron guardar tus datos: ' + ((leg.error || prof.error).message || ''), true); return; }
    try { localStorage.setItem(agencyKey(), JSON.stringify({ agencia_nombre: a.agencia_nombre, agencia_domicilio: a.agencia_domicilio })); } catch (e) { /* nada */ }
    state.editAgent = false;
    render();
    toast('Tus datos quedaron guardados.');
  }

  /* ───────── Arranque ───────── */
  document.addEventListener('click', (e) => {
    if (e.target.closest('.admin-tab[data-tab="contracts"]')) { if (state.ready) { state.success = null; loadAll(); } else loadAll(); return; }
    const r = root();
    if (r && (r.contains(e.target) || e.target.closest('#ct-overlay'))) onClick(e);
  });
  document.addEventListener('input', (e) => { const r = root(); if (r && r.contains(e.target)) onInput(e); });
  document.addEventListener('change', (e) => { const r = root(); if (r && r.contains(e.target)) onChange(e); });
  document.addEventListener('keydown', (e) => { if (e.key === 'Escape') closeOverlay(); });
})();
