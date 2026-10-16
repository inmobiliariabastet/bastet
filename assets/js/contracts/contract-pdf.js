/* PDF del contrato (pdfmake, en el navegador). Tamaño del membrete de Bastet (210 × 280 mm), que va de fondo en cada página.
   Entrada: bloques de contract-template.js. El PDF se genera siempre desde los datos guardados, así que
   volver a descargarlo es gratis y sale idéntico. Paleta del manual de marca; fuentes embebidas (contract-fonts.js). */
(function (root) {
  'use strict';

  const PDFMAKE_URL = 'https://cdn.jsdelivr.net/npm/pdfmake@0.2.12/build/pdfmake.min.js';
  const VERIFY_BASE = 'https://bastet.uno/verificar.html?c=';
  // Paleta sin verde: ébano para los títulos, oro profundo para los acentos, tonos cálidos para lo secundario.
  const C = { ebony: '#1C160E', warmGrey: '#6B5E49', gold: '#F2B035', neutral: '#F8EBC8', ink: '#1A1A16', night: '#0F0C08', goldLight: '#F8DA8C', deepGold: '#8A5A12' };
  const MM = 72 / 25.4;
  // Medidas del membrete oficial (MEMBRETE BASTET.pdf): 595,276 × 793,701 pt. Su logo ocupa hasta ~99 pt desde arriba
  // y el pie con los datos de contacto empieza en ~745 pt, así que el texto vive entre esas dos franjas.
  const PAGE_W = 595.276;
  const PAGE_H = 793.701;
  const MARGIN_X = 25 * MM; // 2,5 cm
  const MARGIN_TOP = 128;
  const MARGIN_BOTTOM = 116;

  function loadScript(src) {
    return new Promise((resolve, reject) => {
      const s = document.createElement('script');
      s.src = src;
      s.onload = resolve;
      s.onerror = () => reject(new Error('No se pudo cargar ' + src));
      document.head.appendChild(s);
    });
  }

  let libsPromise = null;
  function ensureLibs(fontsUrl) {
    if (!libsPromise) {
      libsPromise = (async () => {
        if (!root.pdfMake) await loadScript(PDFMAKE_URL);
        if (!root.CONTRACT_FONTS_VFS) await loadScript(fontsUrl);
        root.pdfMake.vfs = Object.assign({}, root.pdfMake.vfs || {}, root.CONTRACT_FONTS_VFS);
        root.pdfMake.fonts = {
          Cormorant: { normal: 'Cormorant-SemiBold.ttf', bold: 'Cormorant-Bold.ttf', italics: 'Cormorant-SemiBold.ttf', bolditalics: 'Cormorant-Bold.ttf' },
          Jost: { normal: 'Jost-Regular.ttf', bold: 'Jost-SemiBold.ttf', italics: 'Jost-Regular.ttf', bolditalics: 'Jost-SemiBold.ttf' },
        };
      })().catch((e) => { libsPromise = null; throw e; });
    }
    return libsPromise;
  }

  // Imagen (membrete) -> data URL (para incrustarla en el PDF)
  async function fetchDataUrl(url) {
    const res = await fetch(url);
    if (!res.ok) throw new Error('No se pudo cargar el membrete');
    const blob = await res.blob();
    return new Promise((resolve, reject) => {
      const r = new FileReader();
      r.onload = () => resolve(r.result);
      r.onerror = () => reject(new Error('No se pudo leer el membrete'));
      r.readAsDataURL(blob);
    });
  }

  // pdfmake justifica abriendo huecos también entre tramos de distinto estilo ("exclusiva , la"): la puntuación
  // que sigue pegada a un tramo en negrita se pasa a ese mismo tramo para que no quede un espacio de más.
  const runs = (segs) => {
    const out = segs.map((s) => ({ text: s.t, bold: !!s.b }));
    for (let i = 0; i < out.length - 1; i++) {
      if (!out[i].bold) continue;
      const m = /^[^\s]+/.exec(out[i + 1].text);
      if (m && /^[,.;:)\]"”]+/.test(m[0])) {
        const punct = /^[,.;:)\]"”]+/.exec(m[0])[0];
        out[i].text += punct;
        out[i + 1].text = out[i + 1].text.slice(punct.length);
      }
    }
    return out.filter((r) => r.text !== '').map((r) => (r.bold ? { text: r.text, bold: true } : { text: r.text }));
  };
  const plain = (segs) => segs.map((s) => s.t).join('');

  function blockToContent(b) {
    switch (b.type) {
      case 'title':
        return [
          { text: b.text, style: 'title' },
          { canvas: [{ type: 'line', x1: 0, y1: 0, x2: PAGE_W - 2 * MARGIN_X, y2: 0, lineWidth: 1.2, lineColor: C.gold }], margin: [0, 6, 0, 6] },
        ];
      case 'number':
        return { text: runs(b.segs), style: 'number' };
      case 'clause':
        return { text: b.text, style: 'clause', headlineLevel: 1 };
      case 'annex':
        return { text: b.text, style: 'clause', pageBreak: 'before', margin: [0, 0, 0, 10] };
      case 'spacer':
        return { text: ' ', margin: [0, 16, 0, 0] };
      case 'bullet':
        return { columns: [{ text: '•', width: 10, color: C.deepGold }, { text: runs(b.segs), style: 'body', margin: [0, 0, 0, 0] }], columnGap: 4, margin: [10, 0, 0, 4] };
      case 'note':
        return { text: runs(b.segs), style: 'note', margin: [0, 14, 0, 0] };
      case 'table':
        return tableToContent(b);
      default: {
        const isItem = /^[a-z]\)\s/.test(plain(b.segs));
        return { text: runs(b.segs), style: 'body', margin: isItem ? [14, 0, 0, 5] : [0, 0, 0, 7] };
      }
    }
  }

  function tableToContent(b) {
    const isSignature = !b.header && b.rows.some((r) => r.some((c) => /^_{6,}$/.test(plain(c))));
    const ncols = (b.header || b.rows[0] || []).length;
    const cell = (segs, i, rowIdx, isHead) => {
      const text = plain(segs);
      const o = { text: runs(segs), alignment: b.align[i] || 'left' };
      if (isSignature) {
        o.style = 'sig';
        if (/^_{6,}$/.test(text)) { o.margin = [0, 46, 0, 0]; o.color = C.warmGrey; } // ~1,6 cm de espacio real para firmar
        else if (rowIdx === b.rows.length - 1) { o.bold = true; o.color = C.ebony; o.fontSize = 9.5; }  // cargo: EL PROPIETARIO / EL AGENTE
      } else if (isHead) {
        o.style = 'th';
      } else {
        o.style = 'td';
      }
      return o;
    };
    const body = [];
    if (b.header) body.push(b.header.map((c, i) => cell(c, i, -1, true)));
    b.rows.forEach((r, ri) => body.push(r.map((c, i) => cell(c, i, ri, false))));
    const table = {
      table: { headerRows: b.header ? 1 : 0, widths: isSignature ? Array(ncols).fill('*') : ['*', 80].slice(0, ncols), body },
      margin: [0, 6, 0, 14],
    };
    if (isSignature) {
      table.layout = 'noBorders';
      return { unbreakable: true, stack: [table] };   // las firmas nunca se parten entre páginas
    }
    table.layout = {
      hLineWidth: () => 0.6, vLineWidth: () => 0.6, hLineColor: () => C.neutral, vLineColor: () => C.neutral,
      fillColor: (rowIdx) => (rowIdx === 0 && b.header ? C.neutral : null),
      paddingTop: () => 6, paddingBottom: () => 6, paddingLeft: () => 8, paddingRight: () => 8,
    };
    return table;
  }

  function build(opts) {
    const { blocks, number, code, agentName, letterheadDataUrl, voided } = opts;
    const docTitle = opts.docTitle || 'CONTRATO DE EXCLUSIVIDAD';   // encabezado de las páginas 2 en adelante
    const docSubject = opts.docSubject || 'Contrato de corretaje inmobiliario con exclusividad';
    const verifyUrl = code ? VERIFY_BASE + code : null;                // sin código: el documento no se verifica en la página pública
    const content = [];
    blocks.forEach((b) => {
      const c = blockToContent(b);
      Array.isArray(c) ? content.push(...c) : content.push(c);
    });

    // La cláusula de conformidad viaja junta con la PRIMERA tabla de firmas (nunca una página con solo firmas).
    // Cada tabla de firmas es además irrompible por sí sola. OJO: no agrupar todo en un único bloque irrompible:
    // si no cabe en una página, pdfmake lo omite en silencio y el contrato saldría sin firmas.
    const firstSig = content.findIndex((c) => c && c.unbreakable);
    let merged = content;
    if (firstSig > 0) {
      let start = firstSig;
      while (start > 0 && !(content[start] && content[start].headlineLevel === 1)) start--;
      const group = content.slice(start, firstSig + 1).map((c) => (c.unbreakable ? c.stack : [c])).flat();
      merged = content.slice(0, start).concat([{ unbreakable: true, stack: group }], content.slice(firstSig + 1));
    }

    // Un título de cláusula nunca queda solo al pie de una página: pageBreakBefore (abajo) lo pasa a la siguiente.
    // (No se ata al párrafo entero: con cláusulas largas dejaba media página en blanco.)
    const bound = merged;

    return {
      pageSize: { width: PAGE_W, height: PAGE_H },
      // Un contrato anulado se puede volver a descargar, pero siempre sale marcado
      ...(voided ? { watermark: { text: 'ANULADO', color: '#A63D2F', opacity: 0.16, bold: true, fontSize: 120, font: 'Cormorant' } } : {}),
      pageMargins: [MARGIN_X, MARGIN_TOP, MARGIN_X, MARGIN_BOTTOM],
      info: { title: (opts.docTitle ? opts.docTitle.charAt(0) + opts.docTitle.slice(1).toLowerCase() : 'Contrato de Exclusividad') + ' Nº ' + number, author: agentName, subject: docSubject, creator: 'bastet.uno', producer: 'bastet.uno' },
      defaultStyle: { font: 'Jost', fontSize: 10.3, lineHeight: 1.4, color: C.ink },
      images: { membrete: letterheadDataUrl },
      // Membrete de Bastet como fondo de TODAS las páginas (sello "Verificado por Bastet")
      background: () => ({ chrome: true, image: 'membrete', width: PAGE_W, height: PAGE_H, absolutePosition: { x: 0, y: 0 } }),
      header: (page) => (page === 1 ? { chrome: true, text: '' } : {
        chrome: true,
        text: docTitle + ' · Nº ' + number,
        color: C.warmGrey, fontSize: 8, alignment: 'right', characterSpacing: 0.8,
        margin: [MARGIN_X, 40, MARGIN_X, 0],
      }),
      footer: (page, pages) => ({
        chrome: true,
        margin: [MARGIN_X, 2, MARGIN_X, 0],
        columns: [
          {
            chrome: true,
            width: '*',
            stack: [
              { chrome: true, text: 'Documento generado en bastet.uno · Nº ' + number, fontSize: 7.5, color: C.warmGrey, lineHeight: 1.2 },
              ...(code ? [{ chrome: true, text: 'Verificación: ' + code, fontSize: 7.5, color: C.deepGold, bold: true, lineHeight: 1.2 }] : []),
              { chrome: true, text: 'Página ' + page + ' de ' + pages, fontSize: 8, color: C.ebony, margin: [0, 2, 0, 0] },
            ],
          },
          ...(verifyUrl ? [{ chrome: true, qr: verifyUrl, fit: 32, foreground: C.ebony, alignment: 'right', width: 32 }] : []),
        ],
      }),
      // Un título de cláusula nunca queda solo al final de página. `following` también trae el encabezado, el pie y el fondo
      // (pdfmake no conserva marcas propias en esos nodos): se descartan por su texto y por su posición (el pie comparte la misma altura).
      pageBreakBefore: (node, following) => {
        if (node.headlineLevel !== 1) return false;
        const isText = (n, prefix) => typeof n.text === 'string' && n.text.startsWith(prefix);
        const footerLine = following.find((n) => isText(n, 'Documento generado'));
        const footerTop = footerLine && footerLine.startPosition ? footerLine.startPosition.top : null;
        const body = following.filter((n) => !n.image && !isText(n, 'CONTRATO DE EXCLUSIVIDAD') && !(footerTop != null && n.startPosition && n.startPosition.top === footerTop));
        return body.length === 0;
      },
      content: bound,
      styles: {
        title: { font: 'Cormorant', bold: true, fontSize: 17, color: C.ebony, alignment: 'center', characterSpacing: 1.1, lineHeight: 1.15, margin: [0, 6, 0, 0] },
        number: { fontSize: 10, color: C.deepGold, alignment: 'center', margin: [0, 2, 0, 14] },
        clause: { font: 'Cormorant', bold: true, fontSize: 12.5, color: C.deepGold, margin: [0, 12, 0, 4], characterSpacing: 0.3 },
        body: { alignment: 'justify', lineHeight: 1.4 },
        note: { fontSize: 8.5, color: C.warmGrey, italics: true, alignment: 'center' },
        th: { bold: true, fontSize: 9.5, color: C.deepGold, characterSpacing: 0.8 },
        td: { fontSize: 10.3 },
        sig: { fontSize: 10, alignment: 'center', lineHeight: 1.3 },
      },
    };
  }

  // "Juan Pérez Mamani" -> "Perez" (primer apellido); sin tildes ni símbolos, para el nombre del archivo
  function surnameForFile(fullName) {
    const words = String(fullName || '').trim().split(/\s+/).filter(Boolean);
    const pick = words.length >= 3 ? words[words.length - 2] : words[words.length - 1] || 'Propietario';
    return pick.normalize('NFD').replace(/[̀-ͯ]/g, '').replace(/[^A-Za-z0-9]/g, '') || 'Propietario';
  }
  const fileName = (number, ownerName) => 'Contrato-Exclusividad-' + number + '-' + surnameForFile(ownerName) + '.pdf';

  function getBlob(docDef) {
    return new Promise((resolve, reject) => {
      try { root.pdfMake.createPdf(docDef).getBlob((blob) => resolve(blob)); } catch (e) { reject(e); }
    });
  }

  async function download(docDef, name) {
    const blob = await getBlob(docDef);
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url;
    a.download = name;
    document.body.appendChild(a);
    a.click();
    a.remove();
    setTimeout(() => URL.revokeObjectURL(url), 60000);
    return blob;
  }

  root.ContractPdf = { ensureLibs, fetchDataUrl, build, getBlob, download, fileName, surnameForFile, VERIFY_BASE };
})(typeof self !== 'undefined' ? self : this);
