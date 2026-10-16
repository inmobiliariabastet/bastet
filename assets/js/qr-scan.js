/* Escáner de QR con la cámara para verificar contratos (verificar.html). SOLO celular y tableta: en computadora el botón no aparece.
 * Usa BarcodeDetector del navegador si existe (Chrome/Android) y, si no (iPhone/iPad), la biblioteca jsQR (carga bajo demanda).
 * La cámara se usa solo en este dispositivo: ninguna imagen se envía ni se guarda; lo único que sale es el código leído.
 * Requiere HTTPS (bastet.uno lo es). Depende de window.UnoVerify.verify(código), definido en verificar.html. */
(function () {
  'use strict';

  const JSQR_URL = 'https://cdn.jsdelivr.net/npm/jsqr@1.4.0/dist/jsQR.js';
  const btn = document.getElementById('scan-btn');

  // El QR del contrato es «https://bastet.uno/verificar.html?c=CÓDIGO»; también se acepta el código suelto de 8 caracteres.
  function parse(text) {
    text = String(text || '').trim();
    try {
      const u = new URL(text);
      if (/(^|\.)bastet\.uno$/.test(u.hostname) || u.hostname === 'localhost') {
        const c = u.searchParams.get('c');
        if (c && /^[A-Za-z0-9]{8}$/.test(c)) return c.toUpperCase();
      }
      return null;
    } catch (e) { /* no es una URL */ }
    return /^[A-Za-z0-9]{8}$/.test(text) ? text.toUpperCase() : null;
  }

  let jsqrPromise = null;
  function loadJsQR() {
    if (window.jsQR) return Promise.resolve(window.jsQR);
    if (!jsqrPromise) jsqrPromise = new Promise((resolve, reject) => {
      const s = document.createElement('script');
      s.src = JSQR_URL; s.onload = () => resolve(window.jsQR); s.onerror = () => reject(new Error('No se pudo cargar el lector de QR'));
      document.head.appendChild(s);
    });
    return jsqrPromise;
  }

  window.UnoScan = { parse, loadJsQR };

  const touch = window.matchMedia && window.matchMedia('(hover: none) and (pointer: coarse)').matches;
  const hasCamera = !!(navigator.mediaDevices && navigator.mediaDevices.getUserMedia);
  if (!btn || !touch || !hasCamera) return;          // computadora o navegador sin cámara: no se muestra el botón
  btn.hidden = false;

  let overlay, video, hint, stream = null, raf = 0, running = false, detector = null, canvas, ctx;

  function build() {
    overlay = document.createElement('div');
    overlay.className = 'scan-overlay';
    overlay.setAttribute('role', 'dialog'); overlay.setAttribute('aria-modal', 'true'); overlay.setAttribute('aria-label', 'Escanear código QR');
    overlay.innerHTML =
      '<video class="scan-video" playsinline muted autoplay></video>' +
      '<div class="scan-frame" aria-hidden="true"><i></i><i></i><i></i><i></i></div>' +
      '<p class="scan-hint" role="status" aria-live="polite">Apunta la cámara al código QR del contrato</p>' +
      '<button type="button" class="scan-close">Cancelar</button>';
    document.body.appendChild(overlay);
    video = overlay.querySelector('video'); hint = overlay.querySelector('.scan-hint');
    overlay.querySelector('.scan-close').addEventListener('click', stop);
    canvas = document.createElement('canvas'); ctx = canvas.getContext('2d', { willReadFrequently: true });
  }

  function setHint(msg, bad) { if (hint) { hint.textContent = msg; hint.classList.toggle('is-bad', !!bad); } }

  function stop() {
    running = false; cancelAnimationFrame(raf);
    if (stream) { stream.getTracks().forEach((t) => t.stop()); stream = null; }
    if (video) video.srcObject = null;
    if (overlay) { overlay.remove(); overlay = null; }
    document.body.classList.remove('scan-open');
  }

  async function decode() {
    if (detector) {
      const found = await detector.detect(video);
      return found && found[0] ? found[0].rawValue : null;
    }
    const w = video.videoWidth, h = video.videoHeight; if (!w || !h) return null;
    const scale = Math.min(1, 720 / Math.max(w, h));
    canvas.width = Math.round(w * scale); canvas.height = Math.round(h * scale);
    ctx.drawImage(video, 0, 0, canvas.width, canvas.height);
    const img = ctx.getImageData(0, 0, canvas.width, canvas.height);
    const r = window.jsQR(img.data, img.width, img.height, { inversionAttempts: 'dontInvert' });
    return r ? r.data : null;
  }

  let last = 0, wrongSince = 0;
  async function tick(ts) {
    if (!running) return;
    if (ts - last > 160 && video.readyState >= 2) {
      last = ts;
      try {
        const text = await decode();
        if (text) {
          const code = parse(text);
          if (code) { finish(code); return; }
          setHint('Ese QR no es de un contrato de Bastet. Prueba con el QR al pie del contrato.', true);
          wrongSince = ts;
        } else if (wrongSince && ts - wrongSince > 3500) { setHint('Apunta la cámara al código QR del contrato'); wrongSince = 0; }
      } catch (e) { /* un cuadro que no se pudo leer: se sigue intentando */ }
    }
    raf = requestAnimationFrame(tick);
  }

  function finish(code) {
    if (navigator.vibrate) { try { navigator.vibrate(60); } catch (e) { /* sin vibración */ } }
    stop();
    const input = document.getElementById('verify-code');
    if (input) input.value = code;
    if (window.UnoVerify) window.UnoVerify.verify(code);
    const res = document.getElementById('verify-result');
    if (res) setTimeout(() => res.scrollIntoView({ behavior: 'smooth', block: 'center' }), 250);
  }

  async function start() {
    if (overlay) return;
    build(); document.body.classList.add('scan-open');
    try {
      if ('BarcodeDetector' in window) {
        try { detector = new BarcodeDetector({ formats: ['qr_code'] }); } catch (e) { detector = null; }
      }
      if (!detector) { setHint('Preparando el lector…'); await loadJsQR(); setHint('Apunta la cámara al código QR del contrato'); }
      stream = await navigator.mediaDevices.getUserMedia({ video: { facingMode: { ideal: 'environment' }, width: { ideal: 1280 }, height: { ideal: 720 } }, audio: false });
      video.srcObject = stream;
      await video.play();
      running = true; raf = requestAnimationFrame(tick);
    } catch (e) {
      const denied = e && (e.name === 'NotAllowedError' || e.name === 'SecurityError');
      const none = e && (e.name === 'NotFoundError' || e.name === 'OverconstrainedError');
      setHint(denied ? 'No diste permiso a la cámara. Actívalo en los ajustes del navegador o escribe el código a mano.'
        : none ? 'No encontramos una cámara en este dispositivo. Escribe el código a mano.'
        : 'No se pudo abrir la cámara. Escribe el código a mano.', true);
      if (stream) { stream.getTracks().forEach((t) => t.stop()); stream = null; }
    }
  }

  btn.addEventListener('click', start);
  document.addEventListener('visibilitychange', () => { if (document.hidden && overlay) stop(); });
  window.addEventListener('pagehide', () => { if (overlay) stop(); });
  document.addEventListener('keydown', (e) => { if (e.key === 'Escape' && overlay) stop(); });
})();
