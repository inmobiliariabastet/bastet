/* Redimensiona y comprime las imágenes ANTES de subirlas (en el navegador, sin servidor).
 * Fotos de celular o cámara de 5–15 MB bajan a unos 300–700 KB sin pérdida visible, y se corrige la orientación (EXIF).
 * No amplía las imágenes pequeñas (eso no agrega calidad): solo avisa que son pequeñas. No toca SVG ni GIF animados.
 * Uso: const r = await UnoImage.optimize(file, { maxSide: 2000, quality: 0.82, kind: 'photo' | 'logo' });
 *      r.file  → el archivo a subir (puede ser el mismo si ya estaba bien)
 *      r.small → true si el original mide menos de `minSide` px por su lado largo (se verá borroso en pantalla grande). */
(function () {
  'use strict';

  const MB = 1024 * 1024;

  async function decode(file) {
    if (window.createImageBitmap) {
      try { return await createImageBitmap(file, { imageOrientation: 'from-image' }); } catch (e) { /* formato no soportado: se prueba con <img> */ }
    }
    return new Promise((resolve, reject) => {
      const url = URL.createObjectURL(file);
      const img = new Image();
      img.onload = () => { URL.revokeObjectURL(url); resolve(img); };
      img.onerror = () => { URL.revokeObjectURL(url); reject(new Error('No se pudo leer la imagen.')); };
      img.src = url;
    });
  }

  const toBlob = (canvas, type, quality) => new Promise((resolve) => canvas.toBlob(resolve, type, quality));
  const baseName = (name) => String(name || 'imagen').replace(/\.[^.]+$/, '');
  const EXT = { 'image/jpeg': 'jpg', 'image/png': 'png', 'image/webp': 'webp' };

  async function optimize(file, opts) {
    const o = Object.assign({ maxSide: 2000, quality: 0.82, kind: 'photo', minSide: 1200, skipBelow: 350 * 1024 }, opts || {});
    const passthrough = { file, resized: false, small: false, width: 0, height: 0, before: file.size, after: file.size };
    if (!file || !/^image\/(jpeg|png|webp)$/i.test(file.type)) return passthrough;   // SVG, GIF, HEIC… se suben tal cual

    let bmp;
    try { bmp = await decode(file); } catch (e) { return passthrough; }
    const w = bmp.width, h = bmp.height, long = Math.max(w, h);
    const small = long < o.minSide;
    const info = Object.assign({}, passthrough, { width: w, height: h, small });

    // Ya está dentro de las medidas y pesa poco: no se vuelve a comprimir (evita perder calidad por nada)
    if (long <= o.maxSide && file.size <= o.skipBelow) { if (bmp.close) bmp.close(); return info; }

    const scale = Math.min(1, o.maxSide / long);
    const tw = Math.max(1, Math.round(w * scale)), th = Math.max(1, Math.round(h * scale));
    const canvas = document.createElement('canvas');
    canvas.width = tw; canvas.height = th;
    const ctx = canvas.getContext('2d');
    ctx.imageSmoothingQuality = 'high';

    const keepAlpha = o.kind === 'logo' && /png|webp/i.test(file.type);
    let blob;
    if (keepAlpha) {
      ctx.drawImage(bmp, 0, 0, tw, th);
      blob = await toBlob(canvas, 'image/webp', 0.9);
      if (!blob || blob.type !== 'image/webp') blob = await toBlob(canvas, 'image/png');      // Safari antiguo: sin WebP
    } else {
      ctx.fillStyle = '#fff'; ctx.fillRect(0, 0, tw, th);                                       // JPEG no tiene transparencia
      ctx.drawImage(bmp, 0, 0, tw, th);
      blob = await toBlob(canvas, 'image/jpeg', o.quality);
    }
    if (bmp.close) bmp.close();
    if (!blob) return info;
    // Si no se redujeron ni las medidas ni el peso, es mejor conservar el original
    if (scale === 1 && blob.size >= file.size) return info;

    const type = blob.type;
    const out = new File([blob], baseName(file.name) + '.' + (EXT[type] || 'jpg'), { type, lastModified: Date.now() });
    return Object.assign({}, info, { file: out, resized: true, after: out.size, width: tw, height: th, originalWidth: w, originalHeight: h });
  }

  window.UnoImage = { optimize, MB };
})();
