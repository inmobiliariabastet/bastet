/* PDF del contrato (pdfmake, en el navegador). A4, márgenes 2,5 cm, marca UNO · Bastet.
   Entrada: bloques de contract-template.js. El PDF se genera siempre desde los datos guardados, así que
   volver a descargarlo es gratis y sale idéntico. Paleta del manual de marca; fuentes embebidas (contract-fonts.js). */
(function (root) {
  'use strict';

  const PDFMAKE_URL = 'https://cdn.jsdelivr.net/npm/pdfmake@0.2.12/build/pdfmake.min.js';
  const VERIFY_BASE = 'https://bastet.uno/verificar.html?c=';
  const C = { green: '#2C402D', greenGrey: '#627362', olive: '#8C7F3B', gold: '#F2B035', neutral: '#F2E4DF', ink: '#1A1A16', night: '#0F0C08', goldLight: '#F8DA8C' };
  const MM = 72 / 25.4;
  const PAGE_W = 595.28;
  const MARGIN_X = 25 * MM; // 2,5 cm

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

  // PNG del logo -> data URL (para incrustarlo en el PDF)
  async function fetchDataUrl(url) {
    const res = await fetch(url);
    if (!res.ok) throw new Error('No se pudo cargar el logo');
    const blob = await res.blob();
    return new Promise((resolve, reject) => {
      const r = new FileReader();
      r.onload = () => resolve(r.result);
      r.onerror = () => reject(new Error('No se pudo leer el logo'));
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
        if (/^_{6,}$/.test(text)) { o.margin = [0, 58, 0, 0]; o.color = C.greenGrey; } // ≥ 2,5 cm de espacio real para firmar
        else if (rowIdx === b.rows.length - 1) { o.bold = true; o.color = C.green; o.fontSize = 9.5; }  // cargo: EL PROPIETARIO / EL AGENTE
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
    const { blocks, number, code, agentName, logoDataUrl } = opts;
    const verifyUrl = VERIFY_BASE + code;
    const content = [];
    blocks.forEach((b) => {
      const c = blockToContent(b);
      Array.isArray(c) ? content.push(...c) : content.push(c);
    });

    // Las firmas (y la del copropietario) viajan juntas, y con la cláusula de conformidad que las precede:
    // si no caben en la página, pasa todo el bloque a la siguiente (nunca una página con solo firmas).
    const firstSig = content.findIndex((c) => c && c.unbreakable);
    let merged = content;
    if (firstSig > 0) {
      let lastSig = firstSig;
      while (content[lastSig + 1] && content[lastSig + 1].unbreakable) lastSig++;
      let start = firstSig;
      while (start > 0 && !(content[start] && content[start].headlineLevel === 1)) start--;
      const group = content.slice(start, lastSig + 1).map((c) => (c.unbreakable ? c.stack : [c])).flat();
      merged = content.slice(0, start).concat([{ unbreakable: true, stack: group }], content.slice(lastSig + 1));
    }

    // Un título de cláusula siempre viaja con el primer párrafo que le sigue (nunca queda solo al pie de una página)
    const bound = [];
    for (let i = 0; i < merged.length; i++) {
      const cur = merged[i];
      const next = merged[i + 1];
      if (cur && cur.headlineLevel === 1 && next && !next.unbreakable && !next.pageBreak) { bound.push({ unbreakable: true, stack: [cur, next] }); i++; }
      else bound.push(cur);
    }

    return {
      pageSize: 'A4',
      pageMargins: [MARGIN_X, 86, MARGIN_X, 72],
      info: { title: 'Contrato de Exclusividad Nº ' + number, author: agentName, subject: 'Contrato de corretaje inmobiliario con exclusividad', creator: 'bastet.uno', producer: 'bastet.uno' },
      defaultStyle: { font: 'Jost', fontSize: 10.3, lineHeight: 1.4, color: C.ink },
      background: (page) => ({
        canvas: [
          { type: 'rect', x: 0, y: 0, w: PAGE_W, h: page === 1 ? 70 : 34, color: C.night },
          { type: 'rect', x: 0, y: page === 1 ? 70 : 34, w: PAGE_W, h: 2, color: C.gold },
        ],
      }),
      header: (page) => (page === 1
        ? { image: logoDataUrl, width: 112, absolutePosition: { x: MARGIN_X, y: 10 } }
        : {
          columns: [
            { text: 'CONTRATO DE EXCLUSIVIDAD', color: C.goldLight, fontSize: 8.5, characterSpacing: 1.6, font: 'Cormorant', bold: true },
            { text: 'Nº ' + number, color: C.goldLight, fontSize: 8.5, alignment: 'right', characterSpacing: 0.6 },
          ],
          margin: [MARGIN_X, 11, MARGIN_X, 0],
        }),
      footer: (page, pages) => ({
        margin: [MARGIN_X, 12, MARGIN_X, 0],
        columns: [
          {
            width: '*',
            stack: [
              { text: 'Documento generado en bastet.uno · Nº ' + number, fontSize: 7.5, color: C.greenGrey, lineHeight: 1.25 },
              { text: 'Verificación: ' + code, fontSize: 7.5, color: C.olive, bold: true, lineHeight: 1.25 },
              { text: 'Página ' + page + ' de ' + pages, fontSize: 8, color: C.green, margin: [0, 3, 0, 0] },
            ],
          },
          { qr: verifyUrl, fit: 40, foreground: C.green, alignment: 'right', width: 40 },
        ],
      }),
      pageBreakBefore: (node, following) => node.headlineLevel === 1 && following.length === 0, // un título de cláusula nunca queda solo al final de página
      content: bound,
      styles: {
        title: { font: 'Cormorant', bold: true, fontSize: 17, color: C.green, alignment: 'center', characterSpacing: 1.1, lineHeight: 1.15, margin: [0, 6, 0, 0] },
        number: { fontSize: 10, color: C.olive, alignment: 'center', margin: [0, 2, 0, 14] },
        clause: { font: 'Cormorant', bold: true, fontSize: 12.5, color: C.green, margin: [0, 12, 0, 4], characterSpacing: 0.3 },
        body: { alignment: 'justify', lineHeight: 1.4 },
        note: { fontSize: 8.5, color: C.greenGrey, italics: true, alignment: 'center' },
        th: { bold: true, fontSize: 9.5, color: C.green, characterSpacing: 0.8 },
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
