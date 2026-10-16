function escapeHtml(str) {
  const div = document.createElement('div');
  div.textContent = str ?? '';
  return div.innerHTML;
}

// Precio con su moneda: "185.000 USD" o "Bs.- 1.200.000" (propiedades en bolivianos)
function formatPrice(price, currency, operation) {
  const base = formatPriceBase(price, currency);
  return operation === 'temporal' && base ? base + ' por día' : base;
}
function formatPriceBase(price, currency) {
  const digits = (price || '').toString().replace(/[^0-9]/g, '');
  if (!digits) return escapeHtml(price || '');
  const n = digits.replace(/\B(?=(\d{3})+(?!\d))/g, '.');
  return currency === 'BOB' ? 'Bs.- ' + n : n + ' USD';
}

const citySelectEl = document.getElementById('field-city');
BOLIVIA_CITIES.forEach((city) => {
  const opt = document.createElement('option');
  opt.value = city;
  opt.textContent = city;
  citySelectEl.appendChild(opt);
});

function normalizeCityName(str) {
  return (str || '').toLowerCase().normalize('NFD').replace(/[̀-ͯ]/g, '').trim();
}

function matchBoliviaCity(name) {
  const target = normalizeCityName(name);
  if (!target) return null;
  return BOLIVIA_CITIES.find((c) => {
    const nc = normalizeCityName(c);
    return nc === target || target.includes(nc) || nc.includes(target);
  }) || null;
}

// Supabase devuelve los fallos del inicio con Google en la URL (?error=... o #error=...).
// Se muestran en el login y se limpia la URL para que no reaparezcan al recargar.
function readOAuthRedirectError() {
  const params = new URLSearchParams(window.location.search);
  const hash = new URLSearchParams(window.location.hash.replace(/^#/, ''));
  const code = params.get('error_code') || hash.get('error_code');
  const error = params.get('error') || hash.get('error');
  if (!error && !code) return null;
  const description = params.get('error_description') || hash.get('error_description') || '';
  history.replaceState(null, '', window.location.pathname);
  if (/signup|not allowed|database error saving new user/i.test(code + ' ' + description)) {
    return 'No se pudo crear tu cuenta con Google. Avisa al administrador (inmobiliaria@bastet.uno).';
  }
  if (error === 'access_denied' && !/expired/i.test(code + description)) {
    return 'Cancelaste el inicio de sesión con Google.';
  }
  if (/otp_expired|expired/i.test(code + ' ' + description)) {
    return 'El enlace venció o ya fue usado. Vuelve a intentarlo.';
  }
  if (/exchange external code|unexpected_failure/i.test(code + ' ' + description)) {
    return 'No se pudo completar el ingreso con Google por un problema de configuración. Avisa al administrador.';
  }
  return 'No se pudo iniciar sesión con Google' + (description ? ': ' + description : '.');
}
const oauthRedirectError = readOAuthRedirectError();

/* ── View switching ── */
const views = {
  login: document.getElementById('view-login'),
  dashboard: document.getElementById('view-dashboard'),
};
function showView(name) {
  Object.entries(views).forEach(([key, el]) => el.classList.toggle('hidden', key !== name));
}

/* ── Auth ── */
const loginError = document.getElementById('login-error');
if (oauthRedirectError) { loginError.textContent = oauthRedirectError; loginError.classList.remove('hidden'); }
document.getElementById('google-login').addEventListener('click', async () => {
  loginError.classList.add('hidden');
  const btn = document.getElementById('google-login');
  btn.disabled = true;
  const { error } = await supabaseClient.auth.signInWithOAuth({
    provider: 'google',
    options: { redirectTo: window.location.origin + window.location.pathname },
  });
  if (error) {
    btn.disabled = false;
    loginError.textContent = 'No se pudo iniciar con Google: ' + error.message;
    loginError.classList.remove('hidden');
  }
});

document.getElementById('logout-btn').addEventListener('click', () => supabaseClient.auth.signOut());

async function init() {
  const { data: { session } } = await supabaseClient.auth.getSession();
  handleSession(session);
  supabaseClient.auth.onAuthStateChange((event, newSession) => {
    handleSession(newSession);
  });
}

let currentSession = null;
let currentProfile = null; // { role: 'admin'|'agent', is_active: boolean }

async function handleSession(session) {
  const wasSignedIn = !!currentSession;
  currentSession = session;
  if (!session) {
    currentProfile = null;
    showView('login');
    return;
  }

  const { data: profile, error } = await supabaseClient
    .from('profiles')
    .select('role, is_active, display_name, avatar_url, contact_whatsapp, facebook_url, instagram_url, tiktok_url')
    .eq('id', session.user.id)
    .maybeSingle();

  if (error || !profile) {
    await supabaseClient.auth.signOut();
    loginError.textContent = 'No se pudo verificar tu cuenta. Contacta al administrador.';
    loginError.classList.remove('hidden');
    showView('login');
    return;
  }

  if (!profile.is_active) {
    await supabaseClient.auth.signOut();
    loginError.textContent = 'Tu cuenta fue desactivada por un administrador. Si crees que es un error, escribe a inmobiliaria@bastet.uno.';
    loginError.classList.remove('hidden');
    showView('login');
    return;
  }

  currentProfile = profile;
  document.getElementById('admin-user-email').textContent = session.user.email;
  const avatarEl = document.getElementById('admin-avatar');
  if (avatarEl) avatarEl.textContent = ((profile.display_name || session.user.email || '?').trim()[0] || '?').toUpperCase();
  applyRoleUI();
  populateProfileForm();
  showView('dashboard');
  if (!wasSignedIn) {
    loadProperties();
  }
}

function applyRoleUI() {
  const isAdmin = currentProfile && currentProfile.role === 'admin';
  document.getElementById('admin-role-badge').textContent = isAdmin ? 'Administrador' : 'Agente';
  document.querySelectorAll('.admin-only-tab').forEach((el) => el.classList.toggle('hidden', !isAdmin));
  document.getElementById('field-featured-wrap').classList.toggle('hidden', !isAdmin);
  document.getElementById('properties-panel-title').textContent = isAdmin ? 'Propiedades' : 'Mis propiedades';
  document.getElementById('properties-panel-hint').textContent = isAdmin
    ? 'Arrastra las tarjetas por el ícono ⠿ para reordenar cómo aparecen en el landing.'
    : 'Aquí solo ves y editas las propiedades que tú creaste.';
  // Si el agente estaba parado en una pestaña que ya no le corresponde, vuelve a Propiedades.
  const activeTab = document.querySelector('.admin-tab.is-active');
  if (!isAdmin && activeTab && activeTab.classList.contains('admin-only-tab')) {
    document.querySelector('.admin-tab[data-tab="properties"]').click();
  }
}

/* ── Property list ── */
let properties = [];
const propertyListEl = document.getElementById('property-list');

async function loadProperties() {
  propertyListEl.innerHTML = '<p class="property-empty">Cargando propiedades…</p>';
  let query = supabaseClient.from('properties').select('*').order('sort_order', { ascending: true });
  if (!currentProfile || currentProfile.role !== 'admin') {
    query = query.eq('owner_id', currentSession.user.id);
  }
  const { data, error } = await query;

  if (error) {
    propertyListEl.innerHTML = '<p class="property-empty">Error al cargar propiedades: ' + escapeHtml(error.message) + '</p>';
    return;
  }
  properties = data || [];
  renderPropertyList();
}

const TRASH_ICON = '<svg viewBox="0 0 24 24" width="17" height="17" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M3 6h18"/><path d="M8 6V4h8v2"/><path d="M19 6l-1 14H6L5 6"/><path d="M10 11v6M14 11v6"/></svg>';

const CHECK_ICON = '<svg viewBox="0 0 24 24" width="16" height="16" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M5 12.5l4.5 4.5L19 7.5"/></svg>';

const MINUS_ICON = '<svg viewBox="0 0 24 24" width="16" height="16" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" aria-hidden="true"><path d="M6 12h12"/></svg>';

function propertyStatusLabel(property) {
  if (property.status !== 'sold') return 'Disponible';
  return { alquiler: 'Alquilada', anticretico: 'En anticrético', temporal: 'Ocupado' }[property.operation] || 'Vendida';
}

function isPropertyFeatured(property) {
  return !!property.featured || (!!property.featured_until && new Date(property.featured_until) > new Date());
}

function renderPropertyList() {
  if (!properties.length) {
    propertyListEl.innerHTML = '<p class="property-empty">Aún no hay propiedades. Crea la primera con "+ Nueva propiedad".</p>';
    return;
  }

  const isAdmin = currentProfile && currentProfile.role === 'admin';

  propertyListEl.innerHTML = '';
  properties.forEach((property) => {
    const card = document.createElement('article');
    card.className = 'prop-card';
    card.draggable = isAdmin;
    card.dataset.id = property.id;

    // El reordenar por drag&drop reescribe sort_order del subconjunto visible;
    // solo tiene sentido para el admin, que ve la lista completa. Si un agente
    // reordenara su propio subconjunto filtrado, pisaría sort_order de otros.
    const photo = (property.photos && property.photos[0])
      ? '<img class="prop-photo" src="' + escapeHtml(property.photos[0]) + '" alt="" loading="lazy">'
      : '';
    let badge;
    if (property.status === 'sold') badge = '<span class="badge b-mute">' + propertyStatusLabel(property) + '</span>';
    else if (isPropertyFeatured(property)) badge = '<span class="badge b-gold">Destacada</span>';
    else badge = '<span class="badge b-ok">Disponible</span>';
    const code = formatPropertyCode(property);
    const facts = [property.area, property.rooms, property.baths].filter(Boolean).map(escapeHtml).join(' · ');

    card.innerHTML =
      '<div class="prop-ph">' + photo + badge +
        (isAdmin ? '<span class="property-drag-handle" title="Arrastra para reordenar">⠿</span>' : '') +
      '</div>' +
      '<div class="prop-bd">' +
        '<span class="prop-eyebrow">' + [PROPERTY_TYPE_LABELS[property.property_type], PROPERTY_OPERATION_LABELS[property.operation], property.location].filter(Boolean).map(escapeHtml).join(' · ') + '</span>' +
        '<h3 class="prop-title">' + (isPropertyFeatured(property) ? '<img class="property-featured-icon" src="../assets/img/bastet-isotipo.png" alt="Destacada">' : '') + escapeHtml(property.title) + '</h3>' +
        (code ? '<span><span class="property-code-tag">' + code + '</span></span>' : '') +
        '<div class="prop-price">' + formatPrice(property.price, property.currency, property.operation) + '</div>' +
        (facts ? '<p class="prop-facts">' + facts + '</p>' : '') +
        '<div class="prop-row-actions">' +
          '<button class="btn btn-primary btn-sm" data-action="view">Ver detalle</button>' +
          '<button class="btn btn-ghost btn-sm" data-action="edit">Editar</button>' +
          '<button class="btn btn-sm btn-icon btn-trash-gold" data-action="delete" title="Eliminar propiedad" aria-label="Eliminar propiedad">' + TRASH_ICON + '</button>' +
        '</div>' +
      '</div>';

    card.querySelector('[data-action="view"]').addEventListener('click', (e) => { e.stopPropagation(); openPropertyDetail(property); });
    card.querySelector('[data-action="edit"]').addEventListener('click', (e) => { e.stopPropagation(); openPropertyForm(property); });
    card.querySelector('[data-action="delete"]').addEventListener('click', (e) => { e.stopPropagation(); deleteProperty(property); });
    card.addEventListener('click', (e) => {
      if (e.target.closest('[data-action]') || e.target.closest('.property-drag-handle')) return;
      openPropertyDetail(property);
    });

    card.addEventListener('dragstart', (e) => {
      dragSrcId = property.id;
      card.classList.add('is-dragging');
      e.dataTransfer.effectAllowed = 'move';
    });
    card.addEventListener('dragend', () => card.classList.remove('is-dragging'));
    card.addEventListener('dragover', (e) => { e.preventDefault(); card.classList.add('drag-over'); });
    card.addEventListener('dragleave', () => card.classList.remove('drag-over'));
    card.addEventListener('drop', (e) => {
      e.preventDefault();
      card.classList.remove('drag-over');
      if (dragSrcId && dragSrcId !== property.id) reorderProperties(dragSrcId, property.id);
    });

    if (window.UnoPublications) window.UnoPublications.decorateCard(card, property);
    propertyListEl.appendChild(card);
  });
}

let dragSrcId = null;

async function reorderProperties(srcId, targetId) {
  const srcIndex = properties.findIndex((p) => p.id === srcId);
  const targetIndex = properties.findIndex((p) => p.id === targetId);
  if (srcIndex === -1 || targetIndex === -1) return;

  const [moved] = properties.splice(srcIndex, 1);
  properties.splice(targetIndex, 0, moved);
  properties.forEach((p, i) => { p.sort_order = i; });
  renderPropertyList();

  await Promise.all(properties.map((p) =>
    supabaseClient.from('properties').update({ sort_order: p.sort_order }).eq('id', p.id)
  ));
}

async function deleteProperty(property) {
  if (!confirm('¿Eliminar "' + property.title + '"? Esta acción no se puede deshacer.')) return;
  if (property.photos && property.photos.length) {
    await Promise.all(property.photos.map((url) => removePhotoFromStorage(url)));
  }
  const { error } = await supabaseClient.from('properties').delete().eq('id', property.id);
  if (error) { alert('Error al eliminar: ' + error.message); return; }
  loadProperties();
}

/* ── Detalle de propiedad (solo lectura, clic en la fila) ── */
const GENERAL_WHATSAPP_PHONE = '59177666205';
const detailModal = document.getElementById('property-detail-modal');
const detailTitleEl = document.getElementById('detail-title');
const detailBodyEl = document.getElementById('property-detail-body');
let profilesEmailById = null;

function normalizePhoneDigits(str) {
  return (str || '').replace(/[^0-9]/g, '');
}

async function getProfilesEmailMap() {
  if (profilesEmailById) return profilesEmailById;
  profilesEmailById = {};
  if (!currentProfile || currentProfile.role !== 'admin') return profilesEmailById;
  const { data, error } = await supabaseClient.from('profiles').select('id, email');
  if (!error && data) data.forEach((p) => { profilesEmailById[p.id] = p.email; });
  return profilesEmailById;
}

async function openPropertyDetail(property) {
  const isAdmin = currentProfile && currentProfile.role === 'admin';
  const isOwnProperty = currentSession && property.owner_id === currentSession.user.id;
  detailTitleEl.innerHTML = (property.featured ? '<img class="property-featured-icon" src="../assets/img/bastet-isotipo.png" alt="Destacada">' : '') + escapeHtml(property.title);

  const photos = (property.photos || []).map((url) =>
    '<img src="' + escapeHtml(url) + '" alt="">'
  ).join('');

  const whatsappDigits = normalizePhoneDigits(property.whatsapp) || GENERAL_WHATSAPP_PHONE;
  const whatsappLabel = property.whatsapp ? property.whatsapp : GENERAL_WHATSAPP_PHONE + ' (número general de la firma)';

  let ownerRow = '';
  if (isAdmin) {
    const emailMap = await getProfilesEmailMap();
    const ownerEmail = property.owner_id ? (emailMap[property.owner_id] || 'Usuario eliminado') : 'Sin asignar';
    ownerRow = '<div><p class="detail-label">Agente responsable</p><p class="detail-value">' + escapeHtml(ownerEmail) + '</p></div>';
  }

  detailBodyEl.innerHTML =
    (photos ? '<div class="detail-photos">' + photos + '</div>' : '') +
    '<div class="detail-grid">' +
      (formatPropertyCode(property) ? '<div><p class="detail-label">Código</p><p class="detail-value">' + formatPropertyCode(property) + '</p></div>' : '') +
      '<div><p class="detail-label">Estado</p><p class="detail-value">' + propertyStatusLabel(property) + '</p></div>' +
      '<div><p class="detail-label">Precio</p><p class="detail-value">' + formatPrice(property.price, property.currency, property.operation) + '</p></div>' +
      (property.exchange_rate && property.currency !== 'BOB' ? '<div><p class="detail-label">Tipo de cambio aceptado</p><p class="detail-value">' + escapeHtml(property.exchange_rate) + '</p></div>' : '') +
      '<div><p class="detail-label">Ciudad</p><p class="detail-value">' + escapeHtml(property.location) + '</p></div>' +
      (property.address ? '<div><p class="detail-label">Dirección</p><p class="detail-value">' + escapeHtml(property.address) + '</p></div>' : '') +
      '<div><p class="detail-label">Área</p><p class="detail-value">' + escapeHtml(property.area) + '</p></div>' +
      '<div><p class="detail-label">Ambientes</p><p class="detail-value">' + escapeHtml(property.rooms) + '</p></div>' +
      '<div><p class="detail-label">Baños</p><p class="detail-value">' + escapeHtml(property.baths) + '</p></div>' +
      propertyFeatureList(property).map((f) => '<div><p class="detail-label">' + f.label + '</p><p class="detail-value">' + escapeHtml(f.value) + '</p></div>').join('') +
      ownerRow +
    '</div>' +
    (property.description ? '<p class="detail-label">Descripción</p><p class="detail-desc">' + escapeHtml(property.description) + '</p>' : '') +
    (isOwnProperty
      ? ''
      : '<div class="detail-contact">' +
          '<p class="detail-label" style="margin:0;">WhatsApp del agente</p>' +
          '<span class="detail-value">' + escapeHtml(whatsappLabel) + '</span>' +
          '<a href="https://wa.me/' + whatsappDigits + '" target="_blank" rel="noopener" class="btn btn-accent btn-sm">Abrir WhatsApp</a>' +
        '</div>') +
    (property.owner_whatsapp
      ? '<div class="detail-contact" style="margin-top:10px;">' +
          '<p class="detail-label" style="margin:0;">WhatsApp del propietario <span style="text-transform:none;font-weight:400;">(privado)</span></p>' +
          '<span class="detail-value">' + escapeHtml(property.owner_whatsapp) + '</span>' +
          '<a href="https://wa.me/' + normalizePhoneDigits(property.owner_whatsapp) + '" target="_blank" rel="noopener" class="btn btn-ghost btn-sm">Abrir WhatsApp</a>' +
        '</div>'
      : '');

  detailModal.classList.remove('hidden');
}

function closePropertyDetail() { detailModal.classList.add('hidden'); }

document.getElementById('property-detail-close').addEventListener('click', closePropertyDetail);
detailModal.addEventListener('click', (e) => { if (e.target === detailModal) closePropertyDetail(); });

/* ── Property form (create/edit) ── */
const formModal = document.getElementById('property-form-modal');
const propertyForm = document.getElementById('property-form');
const formError = document.getElementById('property-form-error');
const photoGrid = document.getElementById('photo-grid');
const photoInput = document.getElementById('photo-input');
const photoDropzone = document.getElementById('photo-dropzone');

let formState = null;
let isNewProperty = true;

function ensureOptionExists(selectEl, value) {
  if (!value) return;
  const exists = Array.from(selectEl.options).some((o) => o.value === value);
  if (!exists) {
    const opt = document.createElement('option');
    opt.value = value;
    opt.textContent = value + ' (personalizado)';
    selectEl.appendChild(opt);
  }
}

function openPropertyForm(property) {
  formError.classList.add('hidden');
  if (property) {
    isNewProperty = false;
    formState = { ...property, photos: [...(property.photos || [])] };
    document.getElementById('property-form-title-heading').textContent = 'Editar propiedad';
  } else {
    isNewProperty = true;
    formState = {
      id: crypto.randomUUID(),
      title: '', location: '', address: '', price: '', currency: 'USD', exchange_rate: '', area: '', rooms: '', baths: '',
      description: '', whatsapp: '', owner_whatsapp: '', photos: [], status: 'available', featured: false,
      property_type: '', operation: '', floors: null, has_garage: null, garage_spots: null,
      has_storage: null, pets_allowed: null, kids_allowed: null,
    };
    document.getElementById('property-form-title-heading').textContent = 'Nueva propiedad';
  }

  const roomsSelect = document.getElementById('field-rooms');
  const bathsSelect = document.getElementById('field-baths');
  ensureOptionExists(roomsSelect, formState.rooms);
  ensureOptionExists(bathsSelect, formState.baths);

  const currentCity = (formState.location || '').split(',')[0].trim();
  ensureOptionExists(citySelectEl, currentCity);

  document.getElementById('field-title').value = formState.title;
  citySelectEl.value = currentCity;
  document.getElementById('field-price').value = formState.price;
  document.getElementById('field-exchange-rate').value = formState.exchange_rate || '';
  setPropertyCurrency(formState.currency === 'BOB' ? 'BOB' : 'USD');
  document.getElementById('field-area').value = formState.area;
  roomsSelect.value = formState.rooms;
  bathsSelect.value = formState.baths;
  document.getElementById('field-description').value = formState.description || '';
  document.getElementById('field-whatsapp').value = formState.whatsapp || '';
  document.getElementById('field-owner-whatsapp').value = formState.owner_whatsapp || '';
  document.getElementById('field-status').value = formState.status;
  document.getElementById('field-featured').checked = !!formState.featured;
  document.getElementById('field-type').value = formState.property_type || '';
  document.getElementById('field-operation').value = formState.operation || '';
  document.getElementById('field-floors').value = formState.floors ? String(Math.min(formState.floors, 5)) : '';
  document.getElementById('field-garage').value = boolToSelect(formState.has_garage);
  document.getElementById('field-garage-spots').value = formState.garage_spots ? String(Math.min(formState.garage_spots, 5)) : '';
  document.getElementById('field-storage').value = boolToSelect(formState.has_storage);
  document.getElementById('field-pets').value = boolToSelect(formState.pets_allowed);
  document.getElementById('field-kids').value = boolToSelect(formState.kids_allowed);
  const codeEl = document.getElementById('property-form-code');
  codeEl.textContent = isNewProperty ? '' : 'Código: ' + (formatPropertyCode(formState) || 'se asigna al guardar');
  codeEl.classList.toggle('hidden', isNewProperty);
  updatePropertyTypeFields();

  renderPhotoGrid();
  setUpLocationPicker(currentCity, formState.address);
  formModal.classList.remove('hidden');
  setTimeout(() => { if (locationMap) locationMap.invalidateSize(); }, 50);
}

function closePropertyForm() {
  formModal.classList.add('hidden');
  formState = null;
}

document.getElementById('new-property-btn').addEventListener('click', () => openPropertyForm(null));
document.getElementById('property-form-cancel').addEventListener('click', closePropertyForm);
formModal.addEventListener('click', (e) => { if (e.target === formModal) closePropertyForm(); });

function renderPhotoGrid() {
  photoGrid.innerHTML = '';
  formState.photos.forEach((url) => {
    const thumb = document.createElement('div');
    thumb.className = 'photo-thumb';
    thumb.innerHTML =
      '<img src="' + escapeHtml(url) + '" alt="">' +
      '<button type="button" class="photo-remove" aria-label="Quitar foto">×</button>';
    thumb.querySelector('.photo-remove').addEventListener('click', () => removePhoto(url));
    photoGrid.appendChild(thumb);
  });
}

function storagePathFromUrl(url) {
  const marker = '/object/public/' + PROPERTY_PHOTOS_BUCKET + '/';
  const idx = url.indexOf(marker);
  if (idx === -1) return null;
  return decodeURIComponent(url.slice(idx + marker.length));
}

async function removePhotoFromStorage(url) {
  const path = storagePathFromUrl(url);
  if (!path) return;
  try { await supabaseClient.storage.from(PROPERTY_PHOTOS_BUCKET).remove([path]); } catch (err) { /* best effort */ }
}

function removePhoto(url) {
  formState.photos = formState.photos.filter((p) => p !== url);
  renderPhotoGrid();
  removePhotoFromStorage(url);
}

function sanitizeFilename(name) {
  return name.replace(/[^a-zA-Z0-9._-]/g, '-');
}

async function uploadPhotos(fileList) {
  const files = Array.from(fileList).filter((f) => f.type.startsWith('image/'));
  const noteEl = document.getElementById('photo-note');
  const smallOnes = [];
  noteEl.classList.add('hidden');
  for (const original of files) {
    const placeholder = document.createElement('div');
    placeholder.className = 'photo-thumb is-uploading';
    photoGrid.appendChild(placeholder);

    // Se redimensiona (máx. 2000 px) y comprime antes de subir: fotos de celular de 5–10 MB quedan en unos cientos de KB
    const opt = await UnoImage.optimize(original, { maxSide: 2000, quality: 0.82, kind: 'photo' });
    const file = opt.file;
    if (opt.small) smallOnes.push(original.name);
    const path = formState.id + '/' + Date.now() + '-' + sanitizeFilename(file.name);
    const { error: uploadError } = await supabaseClient.storage.from(PROPERTY_PHOTOS_BUCKET).upload(path, file, { contentType: file.type });
    if (uploadError) {
      placeholder.remove();
      alert('Error al subir ' + file.name + ': ' + uploadError.message);
      continue;
    }
    const { data } = supabaseClient.storage.from(PROPERTY_PHOTOS_BUCKET).getPublicUrl(path);
    formState.photos.push(data.publicUrl);
    placeholder.remove();
    renderPhotoGrid();
  }
  if (smallOnes.length) {
    noteEl.textContent = (smallOnes.length === 1 ? 'Una foto tiene' : smallOnes.length + ' fotos tienen') + ' poca resolución (menos de 1200 px) y se verá borrosa en pantalla grande: ' + smallOnes.join(', ') + '. Si puedes, sube la versión original.';
    noteEl.classList.remove('hidden');
  }
}

photoDropzone.addEventListener('click', () => photoInput.click());
photoInput.addEventListener('change', () => { uploadPhotos(photoInput.files); photoInput.value = ''; });
photoDropzone.addEventListener('dragover', (e) => { e.preventDefault(); photoDropzone.classList.add('is-dragover'); });
photoDropzone.addEventListener('dragleave', () => photoDropzone.classList.remove('is-dragover'));
photoDropzone.addEventListener('drop', (e) => {
  e.preventDefault();
  photoDropzone.classList.remove('is-dragover');
  if (e.dataTransfer.files.length) uploadPhotos(e.dataTransfer.files);
});

// Selects "Sí / No / Sin especificar" <-> true / false / null
function boolToSelect(value) { return value === true ? 'true' : value === false ? 'false' : ''; }
function selectToBool(value) { return value === 'true' ? true : value === 'false' ? false : null; }

// Un terreno no tiene plantas, garaje, baulera, ni reglas de mascotas/niños: se ocultan esos campos.
// "¿Para cuántos autos?" solo aparece si tiene garaje.
function updatePropertyTypeFields() {
  const isLand = document.getElementById('field-type').value === 'terreno';
  document.querySelectorAll('#property-form .not-terreno').forEach((el) => el.classList.toggle('hidden', isLand));
  const hasGarage = document.getElementById('field-garage').value === 'true';
  document.getElementById('field-garage-spots-wrap').classList.toggle('invisible', !hasGarage);
}
document.getElementById('field-type').addEventListener('change', updatePropertyTypeFields);
document.getElementById('field-garage').addEventListener('change', updatePropertyTypeFields);

// Moneda del precio: en bolivianos no hay tipo de cambio que indicar y el símbolo es Bs.-
function currentCurrency() {
  const r = document.querySelector('input[name="field-currency"]:checked');
  return r && r.value === 'BOB' ? 'BOB' : 'USD';
}
function setPropertyCurrency(cur) {
  const radio = document.querySelector('input[name="field-currency"][value="' + cur + '"]');
  if (radio) radio.checked = true;
  const bob = cur === 'BOB';
  const perDay = document.getElementById('field-operation').value === 'temporal' ? ' por día' : '';
  document.getElementById('field-price-label').textContent = (bob ? 'Precio (en Bs.-)' : 'Precio (en USD)') + perDay;
  document.getElementById('field-price').placeholder = bob ? 'Ej: 1,200,000' : 'Ej: 185,000';
  document.getElementById('field-exchange-rate-wrap').classList.toggle('hidden', bob);
}
document.querySelectorAll('input[name="field-currency"]').forEach((r) => r.addEventListener('change', () => setPropertyCurrency(currentCurrency())));
document.getElementById('field-operation').addEventListener('change', () => setPropertyCurrency(currentCurrency())); // el rótulo del precio dice "por día" en temporales

propertyForm.addEventListener('submit', async (e) => {
  e.preventDefault();
  formError.classList.add('hidden');

  const cityValue = citySelectEl.value.trim();
  const payload = {
    title: document.getElementById('field-title').value.trim(),
    location: cityValue ? cityValue + ', Bolivia' : '',
    address: document.getElementById('location-search').value.trim() || null,
    price: document.getElementById('field-price').value.trim(),
    exchange_rate: currentCurrency() === 'BOB' ? null : (document.getElementById('field-exchange-rate').value.trim() || null),
    area: document.getElementById('field-area').value.trim(),
    rooms: document.getElementById('field-rooms').value.trim(),
    baths: document.getElementById('field-baths').value.trim(),
    description: document.getElementById('field-description').value.trim(),
    whatsapp: document.getElementById('field-whatsapp').value.trim() || null,
    owner_whatsapp: document.getElementById('field-owner-whatsapp').value.trim() || null,
    status: document.getElementById('field-status').value,
    featured: document.getElementById('field-featured').checked,
    photos: formState.photos,
    property_type: document.getElementById('field-type').value || null,
    operation: document.getElementById('field-operation').value || null,
  };
  payload.currency = currentCurrency();
  const isLand = payload.property_type === 'terreno';
  const hasGarage = !isLand && selectToBool(document.getElementById('field-garage').value);
  Object.assign(payload, {
    floors: isLand ? null : (parseInt(document.getElementById('field-floors').value, 10) || null),
    has_garage: isLand ? null : hasGarage,
    garage_spots: hasGarage ? (parseInt(document.getElementById('field-garage-spots').value, 10) || null) : null,
    has_storage: isLand ? null : selectToBool(document.getElementById('field-storage').value),
    pets_allowed: isLand ? null : selectToBool(document.getElementById('field-pets').value),
    kids_allowed: isLand ? null : selectToBool(document.getElementById('field-kids').value),
  });

  if (!payload.title || !payload.location || !payload.price || !payload.area || !payload.rooms || !payload.baths || !payload.property_type || !payload.operation) {
    formError.textContent = 'Completa todos los campos obligatorios.';
    formError.classList.remove('hidden');
    return;
  }

  // Propiedad nueva: hace falta un plan vigente y cupo (la base de datos lo exige igual; aquí se avisa antes de guardar)
  if (isNewProperty && window.UnoPublications && !(await window.UnoPublications.confirmPublish(payload.title))) return;

  const submitBtn = document.getElementById('property-form-submit');
  submitBtn.disabled = true;

  const save = (body) => {
    if (isNewProperty) {
      const sortOrder = properties.length ? Math.max(...properties.map((p) => p.sort_order)) + 1 : 0;
      return supabaseClient.from('properties').insert({ id: formState.id, ...body, owner_id: currentSession.user.id, sort_order: sortOrder });
    }
    return supabaseClient.from('properties').update(body).eq('id', formState.id);
  };
  let { error } = await save(payload);
  // Si el SQL de moneda (supabase/property-currency.sql) aún no se corrió, la columna no existe: los precios en dólares se guardan igual.
  if (error && /currency/i.test(error.message || '')) {
    if (payload.currency === 'BOB') {
      submitBtn.disabled = false;
      formError.textContent = 'Para publicar precios en bolivianos hay que activar la moneda en la base de datos (correr supabase/property-currency.sql). Mientras tanto, usa dólares.';
      formError.classList.remove('hidden');
      return;
    }
    const { currency, ...withoutCurrency } = payload;
    ({ error } = await save(withoutCurrency));
  }

  submitBtn.disabled = false;

  if (error) {
    // Los límites del plan los aplica la base de datos: si no hay plan o el cupo está lleno, la propiedad no se crea
    formError.textContent = 'Error al guardar: ' + error.message;
    formError.classList.remove('hidden');
    if (window.UnoPublications) window.UnoPublications.refresh();
    return;
  }

  closePropertyForm();
  loadProperties();
  if (window.UnoPublications) window.UnoPublications.refresh();
});

/* ── Ubicación: mapa OpenStreetMap + búsqueda Nominatim (gratis, sin API key) ── */
let locationMap = null;
let locationMarker = null;
const DEFAULT_MAP_CENTER = [-16.5, -68.15]; // La Paz, Bolivia

function ensureMapInit() {
  if (locationMap || typeof L === 'undefined') return;
  locationMap = L.map('location-map').setView(DEFAULT_MAP_CENTER, 12);
  L.tileLayer('https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png', {
    attribution: '&copy; OpenStreetMap',
    maxZoom: 19,
  }).addTo(locationMap);
  locationMap.on('click', (e) => {
    placeMarker(e.latlng.lat, e.latlng.lng);
    reverseGeocode(e.latlng.lat, e.latlng.lng);
  });
}

function placeMarker(lat, lng) {
  if (!locationMap) return;
  if (locationMarker) locationMarker.setLatLng([lat, lng]);
  else locationMarker = L.marker([lat, lng]).addTo(locationMap);
  locationMap.setView([lat, lng], 14);
}

function guessCityFromAddress(address) {
  return address.city || address.town || address.village || address.municipality || address.county || address.state || '';
}

function applyGeocodedResult(r, opts) {
  const updateCity = !opts || opts.updateCity !== false;
  const updateAddress = !opts || opts.updateAddress !== false;
  if (updateAddress && r.display_name) document.getElementById('location-search').value = r.display_name;
  if (!updateCity) return;
  const hint = document.getElementById('location-map-hint');
  const cityGuess = guessCityFromAddress(r.address || {});
  const matched = matchBoliviaCity(cityGuess);
  if (matched) {
    citySelectEl.value = matched;
    hint.textContent = 'Ciudad detectada: ' + matched + '.';
  } else if (cityGuess) {
    hint.textContent = 'No reconocemos "' + cityGuess + '" en la lista de ciudades; selecciónala manualmente arriba.';
  } else {
    hint.textContent = 'No se pudo determinar la ciudad; selecciónala manualmente arriba.';
  }
}

async function searchLocation(query, opts) {
  const updateCity = !opts || opts.updateCity !== false;
  if (!query || !query.trim()) return;
  ensureMapInit();
  try {
    const url = 'https://nominatim.openstreetmap.org/search?format=jsonv2&addressdetails=1&limit=1&q=' + encodeURIComponent(query);
    const res = await fetch(url, { headers: { 'Accept-Language': 'es' } });
    const results = await res.json();
    if (!results.length) {
      if (updateCity) alert('No se encontró esa ubicación. Prueba con otro término de búsqueda, o selecciona la ciudad manualmente.');
      return;
    }
    const r = results[0];
    placeMarker(parseFloat(r.lat), parseFloat(r.lon));
    applyGeocodedResult(r, opts);
  } catch (err) {
    if (updateCity) alert('No se pudo buscar la ubicación (revisa tu conexión).');
  }
}

async function reverseGeocode(lat, lng) {
  try {
    const url = 'https://nominatim.openstreetmap.org/reverse?format=jsonv2&addressdetails=1&lat=' + lat + '&lon=' + lng;
    const res = await fetch(url, { headers: { 'Accept-Language': 'es' } });
    const r = await res.json();
    applyGeocodedResult(r);
  } catch (err) {
    document.getElementById('location-map-hint').textContent = 'No se pudo determinar la ciudad; selecciónala manualmente arriba.';
  }
}

function setUpLocationPicker(existingCity, existingAddress) {
  ensureMapInit();
  document.getElementById('location-search').value = existingAddress || '';
  document.getElementById('location-map-hint').textContent = 'Escribe la dirección y presiona Buscar para ubicarla en el mapa, o haz clic directo en el mapa y la dirección se completa sola arriba.';
  if (locationMarker) { locationMap.removeLayer(locationMarker); locationMarker = null; }
  locationMap.setView(DEFAULT_MAP_CENTER, 12);
  const seed = existingAddress || (existingCity ? existingCity + ', Bolivia' : '');
  if (seed) searchLocation(seed, { updateCity: false, updateAddress: false });
}

document.getElementById('location-search-btn').addEventListener('click', () => {
  searchLocation(document.getElementById('location-search').value);
});
document.getElementById('location-search').addEventListener('keydown', (e) => {
  if (e.key === 'Enter') { e.preventDefault(); searchLocation(document.getElementById('location-search').value); }
});

/* ── Descripción: etiquetas rápidas ── */
document.querySelectorAll('.tag-chip').forEach((btn) => {
  btn.addEventListener('click', () => {
    const tag = btn.dataset.tag;
    const textarea = document.getElementById('field-description');
    if (textarea.value.includes(tag)) return;
    const current = textarea.value.trim().replace(/\.+$/, '');
    textarea.value = current ? current + '. ' + tag + '.' : tag + '.';
    textarea.focus();
  });
});

/* ── Tabs ── */
document.querySelectorAll('.admin-tab').forEach((btn) => {
  btn.addEventListener('click', () => {
    document.querySelectorAll('.admin-tab').forEach((b) => b.classList.toggle('is-active', b === btn));
    document.querySelectorAll('.tab-panel').forEach((panel) => {
      panel.classList.toggle('hidden', panel.id !== 'tab-panel-' + btn.dataset.tab);
    });
    if (btn.dataset.tab === 'partners') loadPartners();
    if (btn.dataset.tab === 'testimonials') loadTestimonials();
    if (btn.dataset.tab === 'admins') loadUsers();
    if (btn.dataset.tab === 'analytics') loadAnalytics();
  });
});

/* ── Analítica: vistas y contactos por WhatsApp por propiedad ── */
async function loadAnalytics() {
  const isAdmin = currentProfile && currentProfile.role === 'admin';
  document.getElementById('analytics-panel-hint').textContent = isAdmin
    ? 'Vistas y contactos por WhatsApp de todas las propiedades.'
    : 'Vistas y contactos por WhatsApp de tus propiedades.';

  const statsEl = document.getElementById('analytics-stats');
  const tableEl = document.getElementById('analytics-table');
  statsEl.innerHTML = '';
  tableEl.innerHTML = '<p class="property-empty">Cargando…</p>';

  if (!properties.length) {
    tableEl.innerHTML = '<p class="property-empty">Todavía no hay propiedades para mostrar estadísticas.</p>';
    return;
  }

  const propertyIds = properties.map((p) => p.id);
  const { data, error } = await supabaseClient
    .from('property_events')
    .select('property_id, event_type, created_at')
    .in('property_id', propertyIds);

  if (error) {
    tableEl.innerHTML = '<p class="property-empty">Error al cargar analítica: ' + escapeHtml(error.message) + '</p>';
    return;
  }

  const events = data || [];
  const sevenDaysAgo = Date.now() - 7 * 24 * 60 * 60 * 1000;
  const statsByProperty = {};
  properties.forEach((p) => { statsByProperty[p.id] = { views: 0, contacts: 0 }; });

  let totalViews = 0, totalContacts = 0, views7d = 0, contacts7d = 0;
  events.forEach((e) => {
    const stat = statsByProperty[e.property_id];
    if (!stat) return;
    const isRecent = new Date(e.created_at).getTime() >= sevenDaysAgo;
    if (e.event_type === 'view') {
      stat.views++; totalViews++;
      if (isRecent) views7d++;
    } else if (e.event_type === 'whatsapp_click') {
      stat.contacts++; totalContacts++;
      if (isRecent) contacts7d++;
    }
  });

  const contactRate = totalViews ? Math.round((totalContacts / totalViews) * 100) : 0;

  statsEl.innerHTML = [
    ['Propiedades', properties.length],
    ['Vistas totales', totalViews],
    ['Contactos por WhatsApp', totalContacts],
    ['Tasa de contacto', contactRate + '%'],
    ['Vistas (7 días)', views7d],
    ['Contactos (7 días)', contacts7d],
  ].map(([label, value]) =>
    '<div class="analytics-stat-card"><p class="analytics-stat-value">' + value + '</p><p class="analytics-stat-label">' + label + '</p></div>'
  ).join('');

  const sorted = [...properties].sort((a, b) => statsByProperty[b.id].views - statsByProperty[a.id].views);

  tableEl.innerHTML = '';
  sorted.forEach((property) => {
    const stat = statsByProperty[property.id];
    const rate = stat.views ? Math.round((stat.contacts / stat.views) * 100) : 0;
    const thumb = (property.photos && property.photos[0])
      ? '<img class="property-thumb" src="' + escapeHtml(property.photos[0]) + '" alt="">'
      : '<div class="property-thumb-placeholder">BASTET</div>';
    const row = document.createElement('div');
    row.className = 'property-row property-row-clickable';
    row.innerHTML =
      thumb +
      '<div class="property-info">' +
        '<p class="property-info-title">' + (property.featured ? '<img class="property-featured-icon" src="../assets/img/bastet-isotipo.png" alt="Destacada">' : '') + escapeHtml(property.title) + '</p>' +
        '<p class="property-info-meta">' + escapeHtml(property.location) + '</p>' +
      '</div>' +
      '<div class="analytics-metric"><p class="analytics-metric-value">' + stat.views + '</p><p class="analytics-metric-label">Vistas</p></div>' +
      '<div class="analytics-metric"><p class="analytics-metric-value">' + stat.contacts + '</p><p class="analytics-metric-label">Contactos</p></div>' +
      '<div class="analytics-metric"><p class="analytics-metric-value">' + rate + '%</p><p class="analytics-metric-label">Tasa</p></div>';
    row.addEventListener('click', () => openPropertyDetail(property));
    tableEl.appendChild(row);
  });
}

/* ── Marcas (logos de empresas aliadas) ── */
let partners = [];
let partnerDragSrcId = null;
const partnerListEl = document.getElementById('partner-list');
const partnerNameInput = document.getElementById('partner-name-input');
const partnerDropzone = document.getElementById('partner-dropzone');
const partnerPhotoInput = document.getElementById('partner-photo-input');
const partnerAddError = document.getElementById('partner-add-error');
const PARTNER_LOGOS_BUCKET = 'partner-logos';

async function loadPartners() {
  partnerListEl.innerHTML = '<p class="property-empty">Cargando…</p>';
  const { data, error } = await supabaseClient.from('partners').select('*').order('sort_order', { ascending: true });
  if (error) {
    partnerListEl.innerHTML = '<p class="property-empty">Error al cargar: ' + escapeHtml(error.message) + '</p>';
    return;
  }
  partners = data || [];
  renderPartnerList();
}

function renderPartnerList() {
  if (!partners.length) {
    partnerListEl.innerHTML = '<p class="property-empty">Aún no hay logos. Agrega el primero arriba.</p>';
    return;
  }
  partnerListEl.innerHTML = '';
  partners.forEach((partner) => {
    const row = document.createElement('div');
    row.className = 'partner-row';
    row.draggable = true;
    row.dataset.id = partner.id;
    row.innerHTML =
      '<span class="property-drag-handle" title="Arrastra para reordenar">⠿</span>' +
      '<img class="partner-logo-thumb" src="' + escapeHtml(partner.logo_url) + '" alt="">' +
      '<span class="partner-info">' + escapeHtml(partner.name || '(sin nombre)') +
        (partner.url ? '<br><a href="' + escapeHtml(partner.url) + '" target="_blank" rel="noopener" style="font-size:12px;font-weight:400;">' + escapeHtml(partner.url) + '</a>' : '') +
      '</span>' +
      '<button type="button" class="btn btn-sm btn-icon btn-trash-gold" data-action="delete" title="Eliminar logo" aria-label="Eliminar logo">' + TRASH_ICON + '</button>';

    row.querySelector('[data-action="delete"]').addEventListener('click', () => deletePartner(partner));

    row.addEventListener('dragstart', (e) => {
      partnerDragSrcId = partner.id;
      row.classList.add('is-dragging');
      e.dataTransfer.effectAllowed = 'move';
    });
    row.addEventListener('dragend', () => row.classList.remove('is-dragging'));
    row.addEventListener('dragover', (e) => { e.preventDefault(); row.classList.add('drag-over'); });
    row.addEventListener('dragleave', () => row.classList.remove('drag-over'));
    row.addEventListener('drop', (e) => {
      e.preventDefault();
      row.classList.remove('drag-over');
      if (partnerDragSrcId && partnerDragSrcId !== partner.id) reorderPartners(partnerDragSrcId, partner.id);
    });

    partnerListEl.appendChild(row);
  });
}

async function reorderPartners(srcId, targetId) {
  const srcIndex = partners.findIndex((p) => p.id === srcId);
  const targetIndex = partners.findIndex((p) => p.id === targetId);
  if (srcIndex === -1 || targetIndex === -1) return;
  const [moved] = partners.splice(srcIndex, 1);
  partners.splice(targetIndex, 0, moved);
  partners.forEach((p, i) => { p.sort_order = i; });
  renderPartnerList();
  await Promise.all(partners.map((p) => supabaseClient.from('partners').update({ sort_order: p.sort_order }).eq('id', p.id)));
}

function partnerStoragePathFromUrl(url) {
  const marker = '/object/public/' + PARTNER_LOGOS_BUCKET + '/';
  const idx = url.indexOf(marker);
  if (idx === -1) return null;
  return decodeURIComponent(url.slice(idx + marker.length));
}

async function deletePartner(partner) {
  if (!confirm('¿Eliminar el logo "' + (partner.name || 'sin nombre') + '"?')) return;
  const path = partnerStoragePathFromUrl(partner.logo_url);
  if (path) { try { await supabaseClient.storage.from(PARTNER_LOGOS_BUCKET).remove([path]); } catch (err) { /* best effort */ } }
  const { error } = await supabaseClient.from('partners').delete().eq('id', partner.id);
  if (error) { alert('Error al eliminar: ' + error.message); return; }
  loadPartners();
}

async function addPartner(file) {
  partnerAddError.classList.add('hidden');
  const name = partnerNameInput.value.trim();
  const url = document.getElementById('partner-url-input').value.trim() || null;
  const id = crypto.randomUUID();
  file = (await UnoImage.optimize(file, { maxSide: 800, kind: 'logo' })).file;
  const path = id + '/' + Date.now() + '-' + sanitizeFilename(file.name);

  const placeholder = document.createElement('div');
  placeholder.className = 'photo-thumb is-uploading';
  partnerDropzone.insertAdjacentElement('afterend', placeholder);

  const { error: uploadError } = await supabaseClient.storage.from(PARTNER_LOGOS_BUCKET).upload(path, file, { contentType: file.type });
  placeholder.remove();
  if (uploadError) {
    partnerAddError.textContent = 'Error al subir el logo: ' + uploadError.message;
    partnerAddError.classList.remove('hidden');
    return;
  }
  const { data } = supabaseClient.storage.from(PARTNER_LOGOS_BUCKET).getPublicUrl(path);
  const sortOrder = partners.length ? Math.max(...partners.map((p) => p.sort_order)) + 1 : 0;
  const { error } = await supabaseClient.from('partners').insert({ id, name, logo_url: data.publicUrl, url, sort_order: sortOrder });
  if (error) {
    partnerAddError.textContent = 'Error al guardar: ' + error.message;
    partnerAddError.classList.remove('hidden');
    return;
  }
  partnerNameInput.value = '';
  document.getElementById('partner-url-input').value = '';
  loadPartners();
}

partnerDropzone.addEventListener('click', () => partnerPhotoInput.click());
partnerPhotoInput.addEventListener('change', () => {
  if (partnerPhotoInput.files[0]) addPartner(partnerPhotoInput.files[0]);
  partnerPhotoInput.value = '';
});
partnerDropzone.addEventListener('dragover', (e) => { e.preventDefault(); partnerDropzone.classList.add('is-dragover'); });
partnerDropzone.addEventListener('dragleave', () => partnerDropzone.classList.remove('is-dragover'));
partnerDropzone.addEventListener('drop', (e) => {
  e.preventDefault();
  partnerDropzone.classList.remove('is-dragover');
  if (e.dataTransfer.files[0]) addPartner(e.dataTransfer.files[0]);
});

/* ── Testimonios ── */
let testimonials = [];
let testimonialDragSrcId = null;
let testimonialPhotoUrl = null;
const testimonialListEl = document.getElementById('testimonial-list');
const testimonialAddForm = document.getElementById('testimonial-add-form');
const testimonialAddError = document.getElementById('testimonial-add-error');
const testimonialDropzone = document.getElementById('testimonial-dropzone');
const testimonialPhotoInput = document.getElementById('testimonial-photo-input');
const testimonialPhotoPreview = document.getElementById('testimonial-photo-preview');
const TESTIMONIAL_PHOTOS_BUCKET = 'testimonial-photos';

async function loadTestimonials() {
  testimonialListEl.innerHTML = '<p class="property-empty">Cargando…</p>';
  const { data, error } = await supabaseClient.from('testimonials').select('*').order('sort_order', { ascending: true });
  if (error) {
    testimonialListEl.innerHTML = '<p class="property-empty">Error al cargar: ' + escapeHtml(error.message) + '</p>';
    return;
  }
  testimonials = data || [];
  renderTestimonialList();
}

function renderTestimonialList() {
  if (!testimonials.length) {
    testimonialListEl.innerHTML = '<p class="property-empty">Aún no hay testimonios. Agrega el primero arriba.</p>';
    return;
  }
  testimonialListEl.innerHTML = '';
  testimonials.forEach((testimonial) => {
    const row = document.createElement('div');
    row.className = 'partner-row';
    row.draggable = true;
    row.dataset.id = testimonial.id;

    const initial = (testimonial.name || '?').trim().charAt(0).toUpperCase();
    const photo = testimonial.photo_url
      ? '<img class="testimonial-photo-thumb" src="' + escapeHtml(testimonial.photo_url) + '" alt="">'
      : '<div class="testimonial-photo-thumb-placeholder">' + escapeHtml(initial) + '</div>';

    row.innerHTML =
      '<span class="property-drag-handle" title="Arrastra para reordenar">⠿</span>' +
      photo +
      '<div class="testimonial-info">' +
        '<p class="testimonial-info-name">' + escapeHtml(testimonial.name) + '</p>' +
        '<p class="testimonial-info-role">' + escapeHtml(testimonial.role_label) + '</p>' +
        '<p class="testimonial-info-quote">&ldquo;' + escapeHtml(testimonial.quote) + '&rdquo;</p>' +
      '</div>' +
      '<button type="button" class="btn btn-sm btn-icon btn-trash-gold" data-action="delete" title="Eliminar testimonio" aria-label="Eliminar testimonio">' + TRASH_ICON + '</button>';

    row.querySelector('[data-action="delete"]').addEventListener('click', () => deleteTestimonial(testimonial));

    row.addEventListener('dragstart', (e) => {
      testimonialDragSrcId = testimonial.id;
      row.classList.add('is-dragging');
      e.dataTransfer.effectAllowed = 'move';
    });
    row.addEventListener('dragend', () => row.classList.remove('is-dragging'));
    row.addEventListener('dragover', (e) => { e.preventDefault(); row.classList.add('drag-over'); });
    row.addEventListener('dragleave', () => row.classList.remove('drag-over'));
    row.addEventListener('drop', (e) => {
      e.preventDefault();
      row.classList.remove('drag-over');
      if (testimonialDragSrcId && testimonialDragSrcId !== testimonial.id) reorderTestimonials(testimonialDragSrcId, testimonial.id);
    });

    testimonialListEl.appendChild(row);
  });
}

async function reorderTestimonials(srcId, targetId) {
  const srcIndex = testimonials.findIndex((t) => t.id === srcId);
  const targetIndex = testimonials.findIndex((t) => t.id === targetId);
  if (srcIndex === -1 || targetIndex === -1) return;
  const [moved] = testimonials.splice(srcIndex, 1);
  testimonials.splice(targetIndex, 0, moved);
  testimonials.forEach((t, i) => { t.sort_order = i; });
  renderTestimonialList();
  await Promise.all(testimonials.map((t) => supabaseClient.from('testimonials').update({ sort_order: t.sort_order }).eq('id', t.id)));
}

function testimonialStoragePathFromUrl(url) {
  const marker = '/object/public/' + TESTIMONIAL_PHOTOS_BUCKET + '/';
  const idx = url.indexOf(marker);
  if (idx === -1) return null;
  return decodeURIComponent(url.slice(idx + marker.length));
}

async function deleteTestimonial(testimonial) {
  if (!confirm('¿Eliminar el testimonio de "' + testimonial.name + '"?')) return;
  if (testimonial.photo_url) {
    const path = testimonialStoragePathFromUrl(testimonial.photo_url);
    if (path) { try { await supabaseClient.storage.from(TESTIMONIAL_PHOTOS_BUCKET).remove([path]); } catch (err) { /* best effort */ } }
  }
  const { error } = await supabaseClient.from('testimonials').delete().eq('id', testimonial.id);
  if (error) { alert('Error al eliminar: ' + error.message); return; }
  loadTestimonials();
}

function renderTestimonialPhotoPreview() {
  testimonialPhotoPreview.innerHTML = '';
  if (!testimonialPhotoUrl) return;
  const thumb = document.createElement('div');
  thumb.className = 'photo-thumb';
  thumb.style.marginTop = '10px';
  thumb.innerHTML =
    '<img src="' + escapeHtml(testimonialPhotoUrl) + '" alt="">' +
    '<button type="button" class="photo-remove" aria-label="Quitar foto">×</button>';
  thumb.querySelector('.photo-remove').addEventListener('click', () => { testimonialPhotoUrl = null; renderTestimonialPhotoPreview(); });
  testimonialPhotoPreview.appendChild(thumb);
}

async function uploadTestimonialPhoto(file) {
  const placeholder = document.createElement('div');
  placeholder.className = 'photo-thumb is-uploading';
  placeholder.style.marginTop = '10px';
  testimonialPhotoPreview.appendChild(placeholder);

  file = (await UnoImage.optimize(file, { maxSide: 800, quality: 0.85, kind: 'photo' })).file;
  const path = crypto.randomUUID() + '/' + Date.now() + '-' + sanitizeFilename(file.name);
  const { error: uploadError } = await supabaseClient.storage.from(TESTIMONIAL_PHOTOS_BUCKET).upload(path, file, { contentType: file.type });
  placeholder.remove();
  if (uploadError) {
    testimonialAddError.textContent = 'Error al subir la foto: ' + uploadError.message;
    testimonialAddError.classList.remove('hidden');
    return;
  }
  const { data } = supabaseClient.storage.from(TESTIMONIAL_PHOTOS_BUCKET).getPublicUrl(path);
  testimonialPhotoUrl = data.publicUrl;
  renderTestimonialPhotoPreview();
}

testimonialDropzone.addEventListener('click', () => testimonialPhotoInput.click());
testimonialPhotoInput.addEventListener('change', () => {
  if (testimonialPhotoInput.files[0]) uploadTestimonialPhoto(testimonialPhotoInput.files[0]);
  testimonialPhotoInput.value = '';
});
testimonialDropzone.addEventListener('dragover', (e) => { e.preventDefault(); testimonialDropzone.classList.add('is-dragover'); });
testimonialDropzone.addEventListener('dragleave', () => testimonialDropzone.classList.remove('is-dragover'));
testimonialDropzone.addEventListener('drop', (e) => {
  e.preventDefault();
  testimonialDropzone.classList.remove('is-dragover');
  if (e.dataTransfer.files[0]) uploadTestimonialPhoto(e.dataTransfer.files[0]);
});

testimonialAddForm.addEventListener('submit', async (e) => {
  e.preventDefault();
  testimonialAddError.classList.add('hidden');

  const name = document.getElementById('testimonial-name-input').value.trim();
  const roleLabel = document.getElementById('testimonial-role-input').value.trim();
  const quote = document.getElementById('testimonial-quote-input').value.trim();
  if (!name || !roleLabel || !quote) {
    testimonialAddError.textContent = 'Completa todos los campos obligatorios.';
    testimonialAddError.classList.remove('hidden');
    return;
  }

  const btn = document.getElementById('testimonial-add-submit');
  btn.disabled = true;
  const sortOrder = testimonials.length ? Math.max(...testimonials.map((t) => t.sort_order)) + 1 : 0;
  const { error } = await supabaseClient.from('testimonials').insert({
    name, role_label: roleLabel, quote, photo_url: testimonialPhotoUrl, sort_order: sortOrder,
  });
  btn.disabled = false;

  if (error) {
    testimonialAddError.textContent = 'Error al guardar: ' + error.message;
    testimonialAddError.classList.remove('hidden');
    return;
  }

  testimonialAddForm.reset();
  testimonialPhotoUrl = null;
  renderTestimonialPhotoPreview();
  loadTestimonials();
});

/* ── Administradores: lista de usuarios (activar/desactivar) ── */
const userListEl = document.getElementById('user-list');

async function loadUsers() {
  userListEl.innerHTML = '<p class="property-empty">Cargando…</p>';
  const [{ data, error }, subsRes] = await Promise.all([
    supabaseClient.from('profiles').select('*').order('created_at', { ascending: true }),
    supabaseClient.from('subscriptions').select('user_id,plan_code,current_period_end,source'),
  ]);

  if (error) {
    userListEl.innerHTML = '<p class="property-empty">Error al cargar usuarios: ' + escapeHtml(error.message) + '</p>';
    return;
  }
  const subs = {};
  ((subsRes && subsRes.data) || []).forEach((s) => { subs[s.user_id] = s; });
  renderUserList(data || [], subs);
}

function renderUserList(users, subs) {
  subs = subs || {};
  if (!users.length) {
    userListEl.innerHTML = '<p class="property-empty">No hay usuarios registrados todavía.</p>';
    return;
  }
  userListEl.innerHTML = '';
  users.forEach((user) => {
    const row = document.createElement('div');
    row.className = 'user-row user-row-clickable' + (user.is_active ? '' : ' is-inactive');
    row.title = 'Ver propiedades publicadas por este usuario';
    const isSelf = currentSession && user.id === currentSession.user.id;

    const sub = subs[user.id];
    const planLabel = sub ? ({ propietario: 'Propietario', agente: 'Agente', empresa: 'Empresa' }[sub.plan_code] || sub.plan_code) : null;
    const subOn = sub && new Date(sub.current_period_end) > new Date();
    const planText = !sub ? "Sin plan" : (sub.source === 'trial' ? 'Prueba ' : 'Plan ') + planLabel + (subOn ? ' · hasta ' + new Date(sub.current_period_end).toLocaleDateString('es-BO', { day: '2-digit', month: 'short' }) : ' · vencido');
    const details = [user.full_name, user.whatsapp, user.city, user.company].filter(Boolean).map(escapeHtml).join(' · ');
    const waDigits = (user.whatsapp || '').replace(/[^0-9]/g, '');
    row.innerHTML =
      '<span class="user-row-email">' + escapeHtml(user.email || user.id) + (isSelf ? ' (tú)' : '') +
        '<small class="user-row-meta">' + (user.registered_at ? (details || 'Registrado') : 'Aún no completó el registro') + ' · ' + escapeHtml(planText) + '</small></span>' +
      (waDigits ? '<a class="btn btn-sm btn-ghost" data-action="wa" href="https://wa.me/' + (waDigits.length === 8 ? '591' + waDigits : waDigits) + '" target="_blank" rel="noopener">WhatsApp</a>' : '') +
      '<span class="role-tag ' + (user.role === 'admin' ? 'admin' : 'agent') + '">' + (user.role === 'admin' ? 'Admin' : 'Agente') + '</span>' +
      (user.is_active
        ? '<span class="user-active-check" title="Activo" aria-label="Activo" role="img">' + CHECK_ICON + '</span>'
        : '<span class="user-inactive-mark" title="Desactivado" aria-label="Desactivado" role="img">' + MINUS_ICON + '</span>') +
      (isSelf ? '' : '<button type="button" class="btn btn-sm ' + (user.is_active ? 'btn-accent' : 'btn-ghost') + '" data-action="toggle">' + (user.is_active ? 'Desactivar' : 'Reactivar') + '</button>') +
      (isSelf ? '' : '<button type="button" class="btn btn-sm btn-icon btn-trash-gold" data-action="delete-user" title="Eliminar usuario" aria-label="Eliminar usuario">' + TRASH_ICON + '</button>');

    const waLink = row.querySelector('[data-action="wa"]');
    if (waLink) waLink.addEventListener('click', (e) => e.stopPropagation());

    const toggleBtn = row.querySelector('[data-action="toggle"]');
    if (toggleBtn) toggleBtn.addEventListener('click', (e) => { e.stopPropagation(); toggleUserActive(user); });

    const deleteBtn = row.querySelector('[data-action="delete-user"]');
    if (deleteBtn) deleteBtn.addEventListener('click', (e) => { e.stopPropagation(); deleteUser(user); });

    row.addEventListener('click', () => openUserProperties(user));

    userListEl.appendChild(row);
  });
}

async function toggleUserActive(user) {
  const nextActive = !user.is_active;
  const verb = nextActive ? 'reactivar' : 'desactivar';
  if (!confirm('¿Seguro que quieres ' + verb + ' a ' + (user.email || user.id) + '?')) return;
  const { error } = await supabaseClient.from('profiles').update({ is_active: nextActive }).eq('id', user.id);
  if (error) { alert('Error: ' + error.message); return; }
  loadUsers();
}

async function deleteUser(user) {
  const who = user.email || user.id;
  const { count } = await supabaseClient
    .from('properties')
    .select('id', { count: 'exact', head: true })
    .eq('owner_id', user.id);
  const propsNote = count
    ? '\n\nTiene ' + count + (count === 1 ? ' propiedad publicada: no se borrará, quedará "Sin asignar".' : ' propiedades publicadas: no se borrarán, quedarán "Sin asignar".')
    : '';
  if (!confirm('¿Eliminar definitivamente la cuenta de ' + who + '?\n\nYa no podrá iniciar sesión y esta acción no se puede deshacer (si vuelve a entrar con Google, se creará una cuenta nueva).' + propsNote)) return;
  const { error } = await supabaseClient.rpc('admin_delete_user', { target: user.id });
  if (error) { alert('Error al eliminar: ' + error.message); return; }
  loadUsers();
}

/* ── Administradores: ver las propiedades publicadas por un usuario ── */
const userPropertiesModal = document.getElementById('user-properties-modal');
const userPropertiesTitleEl = document.getElementById('user-properties-title');
const userPropertiesBodyEl = document.getElementById('user-properties-body');

function closeUserProperties() { userPropertiesModal.classList.add('hidden'); }
document.getElementById('user-properties-close').addEventListener('click', closeUserProperties);
userPropertiesModal.addEventListener('click', (e) => { if (e.target === userPropertiesModal) closeUserProperties(); });

async function openUserProperties(user) {
  userPropertiesTitleEl.textContent = 'Propiedades de ' + (user.email || user.id);
  userPropertiesBodyEl.innerHTML = '<p class="property-empty">Cargando…</p>';
  userPropertiesModal.classList.remove('hidden');

  const { data, error } = await supabaseClient
    .from('properties')
    .select('*')
    .eq('owner_id', user.id)
    .order('sort_order', { ascending: true });

  if (error) {
    userPropertiesBodyEl.innerHTML = '<p class="property-empty">Error al cargar: ' + escapeHtml(error.message) + '</p>';
    return;
  }
  if (!data || !data.length) {
    userPropertiesBodyEl.innerHTML = '<p class="property-empty">Este usuario todavía no publicó ninguna propiedad.</p>';
    return;
  }

  userPropertiesBodyEl.innerHTML = '';
  const list = document.createElement('div');
  list.className = 'property-list';
  data.forEach((property) => {
    const row = document.createElement('div');
    row.className = 'property-row property-row-clickable';
    const thumb = (property.photos && property.photos[0])
      ? '<img class="property-thumb" src="' + escapeHtml(property.photos[0]) + '" alt="">'
      : '<div class="property-thumb-placeholder">BASTET</div>';
    row.innerHTML =
      (property.featured ? '<img class="property-featured-icon" src="../assets/img/bastet-isotipo.png" alt="Destacada" style="flex-shrink:0;">' : '<span style="width:18px;flex-shrink:0;"></span>') +
      thumb +
      '<div class="property-info">' +
        '<p class="property-info-title">' + escapeHtml(property.title) + '</p>' +
        '<p class="property-info-meta">' + escapeHtml(property.location) + ' · ' + escapeHtml(property.area) + ' · ' + escapeHtml(property.rooms) + '</p>' +
      '</div>' +
      '<span class="property-price">' + formatPrice(property.price, property.currency, property.operation) + '</span>';
    row.addEventListener('click', () => { closeUserProperties(); openPropertyDetail(property); });
    list.appendChild(row);
  });
  userPropertiesBodyEl.appendChild(list);
}

/* ── Mi cuenta: perfil público (nombre, avatar, redes sociales) ── */
const AGENT_AVATARS_BUCKET = 'agent-avatars';
let profileAvatarUrl = null;
const profileForm = document.getElementById('profile-form');
const profileFormError = document.getElementById('profile-form-error');
const profileFormSuccess = document.getElementById('profile-form-success');
const profileAvatarDropzone = document.getElementById('profile-avatar-dropzone');
const profileAvatarInput = document.getElementById('profile-avatar-input');
const profileAvatarPreview = document.getElementById('profile-avatar-preview');

function populateProfileForm() {
  if (!currentProfile) return;
  document.getElementById('profile-name-input').value = currentProfile.display_name || '';
  document.getElementById('profile-whatsapp-input').value = currentProfile.contact_whatsapp || '';
  document.getElementById('profile-facebook-input').value = currentProfile.facebook_url || '';
  document.getElementById('profile-instagram-input').value = currentProfile.instagram_url || '';
  document.getElementById('profile-tiktok-input').value = currentProfile.tiktok_url || '';
  profileAvatarUrl = currentProfile.avatar_url || null;
  renderProfileAvatarPreview();
}

function renderProfileAvatarPreview() {
  profileAvatarPreview.innerHTML = '';
  if (!profileAvatarUrl) return;
  const img = document.createElement('img');
  img.className = 'profile-avatar-preview-thumb';
  img.src = profileAvatarUrl;
  profileAvatarPreview.appendChild(img);
}

async function uploadProfileAvatar(file) {
  profileFormError.classList.add('hidden');
  const placeholder = document.createElement('div');
  placeholder.className = 'photo-thumb is-uploading';
  placeholder.style.marginTop = '10px';
  profileAvatarPreview.appendChild(placeholder);

  file = (await UnoImage.optimize(file, { maxSide: 600, quality: 0.85, kind: 'photo' })).file;
  const path = currentSession.user.id + '/' + Date.now() + '-' + sanitizeFilename(file.name);
  const { error: uploadError } = await supabaseClient.storage.from(AGENT_AVATARS_BUCKET).upload(path, file, { contentType: file.type });
  placeholder.remove();
  if (uploadError) {
    profileFormError.textContent = 'Error al subir la foto: ' + uploadError.message;
    profileFormError.classList.remove('hidden');
    return;
  }
  const { data } = supabaseClient.storage.from(AGENT_AVATARS_BUCKET).getPublicUrl(path);
  profileAvatarUrl = data.publicUrl;
  renderProfileAvatarPreview();
}

profileAvatarDropzone.addEventListener('click', () => profileAvatarInput.click());
profileAvatarInput.addEventListener('change', () => {
  if (profileAvatarInput.files[0]) uploadProfileAvatar(profileAvatarInput.files[0]);
  profileAvatarInput.value = '';
});
profileAvatarDropzone.addEventListener('dragover', (e) => { e.preventDefault(); profileAvatarDropzone.classList.add('is-dragover'); });
profileAvatarDropzone.addEventListener('dragleave', () => profileAvatarDropzone.classList.remove('is-dragover'));
profileAvatarDropzone.addEventListener('drop', (e) => {
  e.preventDefault();
  profileAvatarDropzone.classList.remove('is-dragover');
  if (e.dataTransfer.files[0]) uploadProfileAvatar(e.dataTransfer.files[0]);
});

profileForm.addEventListener('submit', async (e) => {
  e.preventDefault();
  profileFormError.classList.add('hidden');
  profileFormSuccess.classList.add('hidden');

  const whatsapp = document.getElementById('profile-whatsapp-input').value.trim();
  if (whatsapp && !/^\+?[0-9 ()-]{7,30}$/.test(whatsapp)) {
    profileFormError.textContent = 'Escribe un WhatsApp válido (solo números, con código de país si es de otro país).';
    profileFormError.classList.remove('hidden');
    return;
  }

  const payload = {
    display_name: document.getElementById('profile-name-input').value.trim() || null,
    contact_whatsapp: whatsapp || null,
    avatar_url: profileAvatarUrl,
    facebook_url: document.getElementById('profile-facebook-input').value.trim() || null,
    instagram_url: document.getElementById('profile-instagram-input').value.trim() || null,
    tiktok_url: document.getElementById('profile-tiktok-input').value.trim() || null,
  };

  const btn = document.getElementById('profile-form-submit');
  btn.disabled = true;
  const { error } = await supabaseClient.from('profiles').update(payload).eq('id', currentSession.user.id);
  btn.disabled = false;

  if (error) {
    profileFormError.textContent = 'Error al guardar: ' + error.message;
    profileFormError.classList.remove('hidden');
    return;
  }

  currentProfile = { ...currentProfile, ...payload };
  profileFormSuccess.textContent = 'Perfil actualizado.';
  profileFormSuccess.classList.remove('hidden');
});

init();
