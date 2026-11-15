/* Aviso de cookies de medición (Google): «Aceptar» o «Rechazar», con el mismo peso visual.
 *
 * Funciona con el Modo de consentimiento de Google (Consent Mode v2):
 *  · La etiqueta de Google de cada página arranca con analytics_storage = 'denied', salvo que la persona ya haya aceptado antes
 *    (la elección se guarda en este navegador, localStorage «bastet-consent»).
 *  · Al aceptar se envía gtag('consent','update', { analytics_storage: 'granted' }). Al rechazar queda 'denied' y se borran las cookies de Google Analytics.
 *  · Publicidad (ad_storage, ad_user_data, ad_personalization) siempre denegada: Bastet no usa publicidad de Google.
 * La elección se puede cambiar desde la política de privacidad (window.bastetCookiePrefs()). */
(function () {
  'use strict';
  var KEY = 'bastet-consent';
  var gtag = window.gtag || function () { (window.dataLayer = window.dataLayer || []).push(arguments); };

  function stored() { try { return localStorage.getItem(KEY); } catch (e) { return null; } }
  function save(v) { try { localStorage.setItem(KEY, v); } catch (e) { /* sin almacenamiento: se vuelve a preguntar en la próxima visita */ } }

  function clearGaCookies() {
    var host = location.hostname, parts = host.split('.'), domains = [host, '.' + host];
    if (parts.length > 2) domains.push('.' + parts.slice(-2).join('.'));
    document.cookie.split(';').forEach(function (c) {
      var name = c.split('=')[0].trim();
      if (name === '_ga' || name.indexOf('_ga_') === 0 || name === '_gid' || name.indexOf('_gat') === 0) {
        domains.forEach(function (d) { document.cookie = name + '=; expires=Thu, 01 Jan 1970 00:00:00 GMT; path=/; domain=' + d; });
        document.cookie = name + '=; expires=Thu, 01 Jan 1970 00:00:00 GMT; path=/';
      }
    });
  }

  function apply(granted) {
    gtag('consent', 'update', { analytics_storage: granted ? 'granted' : 'denied', ad_storage: 'denied', ad_user_data: 'denied', ad_personalization: 'denied' });
    if (!granted) clearGaCookies();
  }

  var STYLE =
    '.bc{position:fixed;left:16px;right:16px;bottom:16px;z-index:2147483000;max-width:560px;margin:0 auto;background:#fff;color:#1E2629;' +
    'border:1px solid rgba(30,38,41,.18);border-radius:18px;box-shadow:0 18px 44px -18px rgba(30,38,41,.45);padding:18px 20px;' +
    'font:400 15px/1.5 "Cabinet Grotesk","Helvetica Neue",Arial,sans-serif}' +
    '.bc p{margin:0 0 14px}.bc a{color:#3D4C3A;text-decoration:underline}' +
    '.bc-row{display:flex;gap:10px;flex-wrap:wrap}' +
    '.bc button{flex:1 1 140px;min-height:46px;padding:0 20px;border-radius:999px;border:1.5px solid #3D4C3A;font:500 16px/1 "Conso",Georgia,serif;cursor:pointer}' +
    '.bc-ok{background:#3D4C3A;color:#fff}.bc-no{background:#fff;color:#3D4C3A}' +
    '.bc button:hover{filter:brightness(.94)}' +
    '.bc button:focus-visible,.bc a:focus-visible{outline:3px solid #F1BF46;outline-offset:3px}' +
    '@media(min-width:700px){.bc{left:24px;right:auto;bottom:24px;margin:0}}';

  var host = null;
  function hide() { if (host && host.parentNode) host.parentNode.removeChild(host); host = null; }

  function show() {
    if (host) return;
    // El aviso vive en un Shadow DOM: sus estilos no obligan al navegador a recalcular los de toda la página.
    host = document.createElement('div');
    var root = host.attachShadow ? host.attachShadow({ mode: 'open' }) : host;
    root.innerHTML =
      '<style>' + STYLE + '</style>' +
      '<div class="bc" role="region" aria-label="Preferencias de cookies">' +
      '<p>Usamos una etiqueta de Google para medir cómo se usa el sitio y mejorarlo. Si aceptas, permites las cookies de medición. ' +
      'Si rechazas, no las usamos. <a href="/privacidad.html#cookies">Lee la política de privacidad</a></p>' +
      '<div class="bc-row"><button type="button" class="bc-no">Rechazar</button><button type="button" class="bc-ok">Aceptar</button></div></div>';
    root.querySelector('.bc-ok').addEventListener('click', function () { save('granted'); apply(true); hide(); });
    root.querySelector('.bc-no').addEventListener('click', function () { save('denied'); apply(false); hide(); });
    document.body.appendChild(host);
  }

  window.bastetCookiePrefs = show;

  function init() {
    var v = stored();
    if (v === 'granted' || v === 'denied') return;   // ya eligió: la etiqueta arrancó con esa elección
    show();
  }
  // Se muestra cuando la página ya se dibujó, para no competir con la carga de la portada
  if (document.readyState === 'complete') setTimeout(init, 300);
  else window.addEventListener('load', function () { setTimeout(init, 300); });
})();
