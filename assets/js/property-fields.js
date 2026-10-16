// Campos de propiedad compartidos entre el landing (main.js) y el panel (admin.js):
// código de referencia, tipo, operación y características (plantas, garaje, baulera,
// mascotas, niños). Columnas en supabase/schema.sql (tabla properties).

const PROPERTY_TYPE_LABELS = { casa: 'Casa', departamento: 'Departamento', terreno: 'Terreno' };
const PROPERTY_OPERATION_LABELS = { venta: 'Venta', alquiler: 'Alquiler', anticretico: 'Anticrético', temporal: 'Temporal' };

// Código visible de la propiedad: "BST-1001". code_number lo asigna la base de datos.
function formatPropertyCode(property) {
  return property && property.code_number ? 'BST-' + property.code_number : '';
}

function yesNoLabel(value) {
  if (value === true) return 'Sí';
  if (value === false) return 'No';
  return '';
}

// Lista [{ label, value }] con las características que la propiedad tiene cargadas
// (las vacías se omiten, así las propiedades antiguas no muestran huecos).
function propertyFeatureList(p) {
  const items = [];
  const add = (label, value) => { if (value) items.push({ label, value }); };
  add('Tipo', PROPERTY_TYPE_LABELS[p.property_type]);
  add('Operación', PROPERTY_OPERATION_LABELS[p.operation]);
  if (p.property_type !== 'terreno') {
    if (p.floors) add('Plantas', p.floors === 1 ? '1 planta' : p.floors + ' plantas');
    if (p.has_garage === true) {
      add('Garaje', p.garage_spots ? 'Sí, ' + p.garage_spots + (p.garage_spots === 1 ? ' auto' : ' autos') : 'Sí');
    } else {
      add('Garaje', yesNoLabel(p.has_garage));
    }
    add('Baulera', yesNoLabel(p.has_storage));
    add('Mascotas', p.pets_allowed === true ? 'Se aceptan' : p.pets_allowed === false ? 'No se aceptan' : '');
    add('Niños', p.kids_allowed === true ? 'Se aceptan' : p.kids_allowed === false ? 'No se aceptan' : '');
  }
  return items;
}
