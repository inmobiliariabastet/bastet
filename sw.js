// Service worker de Bastet: hace la web instalable como app Y la abre más rápido.
//
//  · Páginas y archivos del propio sitio: «stale-while-revalidate». Se muestra al instante lo que ya está guardado en el teléfono y, en segundo
//    plano, se descarga la versión nueva para la próxima vez. Así la pantalla de inicio de Android dura menos.
//  · Nunca se guardan: el panel (/admin/), las páginas con enlace secreto (descargos, confirmar o cualquier dirección con ?t=), peticiones que no sean
//    GET ni las de otros sitios (Supabase, Google, CDN): esas van siempre directo a la red.
//  · Para forzar que todos descarguen todo de nuevo, cambiar VERSION.
const VERSION = 'bastet-v2';
const PAGES = VERSION + '-paginas';
const ASSETS = VERSION + '-archivos';
const MAX_PAGE_AGE_MS = 7 * 24 * 3600 * 1000;   // una página guardada con más de 7 días no se usa sin consultar la red

self.addEventListener('install', () => self.skipWaiting());

self.addEventListener('activate', (e) => {
  e.waitUntil((async () => {
    // Borra los guardados de versiones anteriores
    const names = await caches.keys();
    await Promise.all(names.filter((n) => n.startsWith('bastet-') && n !== PAGES && n !== ASSETS).map((n) => caches.delete(n)));
    // La red empieza a pedir la página mientras el service worker arranca (evita el retraso de arranque)
    if (self.registration.navigationPreload) { try { await self.registration.navigationPreload.enable(); } catch (err) { /* sin soporte */ } }
    await self.clients.claim();
  })());
});

function esPrivada(url) {
  const p = url.pathname;
  return p.startsWith('/admin/') || p.startsWith('/agente/') || p === '/descargos.html' || p === '/confirmar.html' || url.searchParams.has('t');
}

// Clave de caché de una página: sin parámetros (el HTML es el mismo; el JavaScript lee los parámetros)
function clavePagina(url) { return new Request(url.origin + url.pathname); }

async function guardable(res) { return res && res.ok && res.type === 'basic' && !res.redirected; }

async function pagina(e) {
  const url = new URL(e.request.url);
  const cache = await caches.open(PAGES);
  const key = clavePagina(url);
  const guardada = await cache.match(key);
  const red = (async () => {
    const res = (await e.preloadResponse) || (await fetch(e.request));
    if (await guardable(res)) {
      // El cuerpo ya viene descomprimido: se quitan los encabezados de compresión/longitud para que el navegador no intente descomprimirlo otra vez
      const cabeceras = new Headers();
      res.headers.forEach((v, k) => { if (!['content-encoding', 'content-length', 'transfer-encoding'].includes(k)) cabeceras.set(k, v); });
      cabeceras.set('x-bastet-guardada', String(Date.now()));
      await cache.put(key, new Response(await res.clone().blob(), { status: res.status, statusText: res.statusText, headers: cabeceras }));
    }
    return res;
  })();
  if (guardada) {
    const edad = Date.now() - Number(guardada.headers.get('x-bastet-guardada') || 0);
    if (edad < MAX_PAGE_AGE_MS) { e.waitUntil(red.catch(() => {})); return guardada; }
  }
  try { return await red; } catch (err) {
    if (guardada) return guardada;
    throw err;
  }
}

async function archivo(e) {
  const cache = await caches.open(ASSETS);
  const guardado = await cache.match(e.request);
  const red = fetch(e.request).then(async (res) => {
    if (await guardable(res)) await cache.put(e.request, res.clone());
    return res;
  });
  if (guardado) { e.waitUntil(red.catch(() => {})); return guardado; }
  return red;
}

self.addEventListener('fetch', (e) => {
  const req = e.request;
  if (req.method !== 'GET') return;
  const url = new URL(req.url);
  if (url.origin !== self.location.origin) return;
  if (esPrivada(url)) return;
  if (req.mode === 'navigate') { e.respondWith(pagina(e)); return; }
  if (url.pathname.startsWith('/assets/') || /\.(?:webp|avif|png|jpg|svg|woff2|css|js)$/.test(url.pathname)) { e.respondWith(archivo(e)); }
});
