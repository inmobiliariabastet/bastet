// Service worker mínimo: hace la web instalable como app. No guarda nada en caché
// (así siempre se ve la versión publicada más reciente).
self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', (e) => e.waitUntil(self.clients.claim()));
self.addEventListener('fetch', () => {});
