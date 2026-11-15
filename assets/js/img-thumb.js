/* Miniaturas: Supabase redimensiona la foto en el servidor (la original puede pesar varios MB).
   Si la miniatura falla, se muestra la original. Uso: '<img ' + window.imgThumbAttrs(url, ancho) + ' ...>' */
(function () {
  var Q = String.fromCharCode(39);   // comilla simple, para el atributo onerror
  window.imgThumb = function (u, w, h) {
    u = String(u || '');
    if (u.indexOf('/storage/v1/object/public/') < 0) return { src: u, orig: u };
    return { src: u.replace('/storage/v1/object/public/', '/storage/v1/render/image/public/') + (u.indexOf('?') < 0 ? '?' : '&') + 'width=' + w + (h ? '&height=' + h + '&resize=cover' : '') + '&quality=72', orig: u };
  };
  window.imgThumbAttrs = function (u, w, h) {
    var t = window.imgThumb(u, w, h);
    var attrs = 'src="' + t.src.replace(/"/g, '&quot;') + '"';
    if (t.src !== t.orig) {
      var orig = t.orig.split(Q).join('%27').split('"').join('%22');
      attrs += ' onerror="this.onerror=null;this.src=' + Q + orig + Q + '"';
    }
    return attrs;
  };
})();
