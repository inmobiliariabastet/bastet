/* Verificar (verificar.html): consulta pública de una PROPIEDAD (BST-####), un AGENTE (AG-XXXXXX) o el CERTIFICADO de una operación (OP-XXXXXXXX).
 * Muestra el estado de verificación y datos mínimos; nunca nombres de particulares, montos, direcciones exactas ni datos del contrato.
 * Datos: RPC verify_property_code / verify_agent_code / verify_operation_certificate (supabase/verification.sql).
 * Expone window.VerifyPublic.html(tipo, datos) → { cls, html }. */
(function () {
  'use strict';
  const esc = (s) => String(s == null ? '' : s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  const TYPE = { casa: 'Casa', departamento: 'Departamento', terreno: 'Terreno' };
  const OP = { venta: 'Venta', alquiler: 'Alquiler', anticretico: 'Anticrético', temporal: 'Estadía temporal', desistimiento: 'Retiro' };
  const STATE = { available: 'Disponible', sold: 'Ya no está disponible (vendida, alquilada o anticretada)', withdrawn: 'Retirada por su titular' };
  const MONTHS = ['enero', 'febrero', 'marzo', 'abril', 'mayo', 'junio', 'julio', 'agosto', 'septiembre', 'octubre', 'noviembre', 'diciembre'];
  const row = (k, v) => (v == null || v === '' ? '' : '<div><dt>' + esc(k) + '</dt><dd>' + v + '</dd></div>');
  const badges = (d) => (d.agent_verified || d.owner_verified)
    ? (d.agent_verified ? '✓ Agente verificado por Bastet' : '') + (d.agent_verified && d.owner_verified ? '<br>' : '') + (d.owner_verified ? '✓ Propietario verificado' : '') : 'Sin distintivos de persona';

  function html(kind, d) {
    if (kind === 'property') {
      return { cls: d.verified ? 'is-ok' : 'is-wait', html: (d.verified ? '<h2>✓ Propiedad verificada</h2><p>Bastet revisó la identidad del propietario, la documentación legal y comprobó la existencia física del inmueble.</p>'
          : '<h2>Propiedad pendiente de verificación</h2><p>Esta propiedad está publicada en Bastet, pero <b>todavía no completó la verificación</b> (identidad del propietario, documentación legal y existencia física).</p>') +
        '<dl>' + row('Código', esc(d.code)) + row('Tipo', esc(TYPE[d.property_type] || 'Inmueble')) + row('Operación', esc(OP[d.operation] || '')) + row('Ciudad', esc(d.city)) + row('Estado', esc(STATE[d.status] || d.status)) + row('Quien la publica', badges(d)) + '</dl>' };
    }
    if (kind === 'agent') {
      return { cls: d.agent_verified ? 'is-ok' : 'is-wait', html: (d.agent_verified ? '<h2>✓ Agente verificado por Bastet</h2><p>Bastet verificó su identidad, su teléfono, su documentación profesional y su contrato directo con Bastet.</p>' : '<h2>Perfil sin verificación de agente</h2><p>Este perfil existe en Bastet, pero no tiene el distintivo de agente verificado.</p>') +
        '<dl>' + row('Código', esc(d.code)) + row('Nombre público', esc(d.name)) + row('Distintivos', badges(d)) +
        row('Reseñas verificadas', d.review_count ? '★ ' + String(d.avg_rating).replace('.', ',') + ' · ' + d.review_count + (d.review_count === 1 ? ' reseña' : ' reseñas') : 'Todavía sin reseñas') +
        row('Operaciones verificadas', d.verified_operations ? String(d.verified_operations) : '0') + '</dl><p class="vp-note">Las reseñas solo las escriben personas que concretaron una operación mediante una conexión de Bastet.</p>' };
    }
    const [y, m] = String(d.month || '').split('-').map(Number);
    return { cls: 'is-ok', html: '<h2>✓ Certificado de operación válido</h2><p>Bastet registró esta operación inmobiliaria.</p><dl>' + row('Código del certificado', esc(d.code)) + row('Operación', esc(OP[d.kind] || d.kind)) +
      row('Fecha', y ? esc(MONTHS[m - 1] + ' de ' + y) : '') + row('Propiedad', esc(d.property_code)) + row('Ciudad', esc(d.city)) +
      row('Origen', d.origin === 'conexion_bastet' ? 'Concretada mediante una conexión de Bastet' : 'Registrada tras la revisión administrativa de Bastet') + row('Titular', badges(d)) + '</dl>' +
      '<p class="vp-note">Por privacidad, este certificado no muestra nombres, montos ni datos del contrato.</p>' };
  }
  window.VerifyPublic = { html };
})();
