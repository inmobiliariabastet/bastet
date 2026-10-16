/* Página "Instala la app Bastet" (app.html): botones de descarga para Android y iPhone/iPad.
   Bastet es una app web (PWA): en Android el navegador ofrece instalarla con un toque (beforeinstallprompt);
   en iPhone/iPad se instala desde Safari con "Añadir a pantalla de inicio". Si el navegador no permite instalar
   directamente, se muestran las instrucciones exactas en lugar de un botón que no hace nada. */
(function () {
  'use strict';

  if ('serviceWorker' in navigator) navigator.serviceWorker.register('sw.js').catch(() => {});

  const ua = navigator.userAgent;
  const isIOS = /iphone|ipad|ipod/i.test(ua) || (/Macintosh/.test(ua) && navigator.maxTouchPoints > 1);
  const isAndroid = /android/i.test(ua);
  // En iPhone/iPad solo Safari puede añadir a la pantalla de inicio (Chrome, Firefox, Edge y las vistas de apps traen "CriOS", "FxiOS", "EdgiOS", "Instagram"…)
  const iosNotSafari = isIOS && /CriOS|FxiOS|EdgiOS|OPiOS|GSA|FBAN|FBAV|Instagram|Line\//i.test(ua);
  const standalone = window.matchMedia('(display-mode: standalone)').matches || window.navigator.standalone === true;

  const tabs = document.querySelectorAll('.ap-tabs [data-os]');
  const panels = document.querySelectorAll('[data-os-panel]');
  const noteAndroid = document.getElementById('ap-note-android');
  const noteIos = document.getElementById('ap-note-ios');

  function selectOS(os, scroll) {
    tabs.forEach((t) => { const on = t.dataset.os === os; t.classList.toggle('is-active', on); t.setAttribute('aria-selected', on ? 'true' : 'false'); });
    panels.forEach((p) => p.classList.toggle('hidden', p.dataset.osPanel !== os));
    if (scroll) document.getElementById('instalar').scrollIntoView({ behavior: 'smooth', block: 'start' });
  }
  tabs.forEach((t) => t.addEventListener('click', () => selectOS(t.dataset.os, false)));
  selectOS(isIOS ? 'ios' : 'android', false);

  function note(el, text) { el.textContent = text; el.hidden = false; }

  function markInstalled() {
    document.getElementById('ap-installed').hidden = false;
    document.querySelectorAll('[data-install]').forEach((b) => { b.hidden = true; });
  }
  if (standalone) { markInstalled(); return; }

  let deferred = null;
  window.addEventListener('beforeinstallprompt', (e) => { e.preventDefault(); deferred = e; });
  window.addEventListener('appinstalled', () => { deferred = null; markInstalled(); });

  async function installAndroid() {
    if (deferred) {
      deferred.prompt();
      const choice = await deferred.userChoice.catch(() => null);
      deferred = null;
      if (choice && choice.outcome === 'dismissed') note(noteAndroid, 'Cancelaste la instalación. Cuando quieras, vuelve a tocar "Descargar para Android".');
      return;
    }
    selectOS('android', true);
    if (isIOS) note(noteAndroid, 'Estás en un iPhone o iPad: usa la pestaña "iOS".');
    else if (isAndroid) note(noteAndroid, 'Si no aparece el aviso de instalación, abre el menú del navegador (⋮) y elige "Instalar aplicación" o "Añadir a pantalla de inicio". Recuerda abrir esta página en Chrome.');
    else note(noteAndroid, 'Para instalarla desde una computadora, usa Chrome o Edge: toca el ícono de instalar en la barra de direcciones o, en el menú (⋮), "Instalar Bastet". Desde tu celular Android abre bastet.uno/app.html.');
  }

  function installIOS() {
    selectOS('ios', true);
    if (iosNotSafari) note(noteIos, 'Abre esta misma página en Safari para poder instalarla: toca el menú de tu navegador y elige "Abrir en Safari", o copia el enlace bastet.uno/app.html en Safari.');
    else if (!isIOS) note(noteIos, 'Esto se hace desde un iPhone o iPad: abre bastet.uno/app.html en Safari y sigue los pasos de arriba.');
    else note(noteIos, 'Sigue los 3 pasos de arriba: Compartir → "Añadir a pantalla de inicio" → "Añadir". Apple no permite instalarla con un solo botón.');
  }

  document.querySelectorAll('[data-install]').forEach((b) => b.addEventListener('click', () => (b.dataset.install === 'ios' ? installIOS() : installAndroid())));
})();
