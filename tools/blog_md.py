"""Markdown sencillo y seguro para el blog de Bastet (el mismo subconjunto lo entiende la vista previa del panel: assets/js/blog-admin.js).

Soporta: ## títulos, ### subtítulos, párrafos, **negrita**, *cursiva*, `código`, [enlaces](url), ![fotos](url), listas con - o 1.,
> citas, --- línea, y tablas simples con |. NO acepta HTML: todo lo escrito se escapa, y los enlaces solo pueden ser http(s), mailto o del propio sitio.
"""
import html
import math
import re
import unicodedata

SITE_PATH_OK = re.compile(r'^(https?://|mailto:|/|#)[^\s]*$')


def slugify(s):
    s = unicodedata.normalize('NFKD', s).encode('ascii', 'ignore').decode()
    return re.sub(r'[^a-z0-9]+', '-', s.lower()).strip('-')


def parse_front_matter(text):
    text = text.replace('\r\n', '\n')
    if not text.startswith('---\n'):
        return {}, text
    end = text.find('\n---\n', 4)
    meta = {}
    for line in text[4:end].split('\n'):
        if ':' in line:
            k, v = line.split(':', 1)
            meta[k.strip()] = v.strip()
    return meta, text[end + 5:].lstrip('\n')


def _safe_url(u):
    u = u.strip()
    if u.startswith('//'):
        return '#'
    return u if SITE_PATH_OK.match(u) or re.match(r'^[A-Za-z0-9_./-][^\s:]*$', u) else '#'


def inline(s, img_fn=None):
    s = html.escape(s, quote=False)
    s = re.sub(r'`([^`]+)`', r'<code>\1</code>', s)

    def image(m):
        alt, url = html.unescape(m.group(1)), _safe_url(html.unescape(m.group(2)))
        return img_fn(alt, url) if img_fn else f'<img src="{html.escape(url, quote=True)}" alt="{html.escape(alt, quote=True)}" loading="lazy">'
    s = re.sub(r'!\[([^\]]*)\]\(([^)\s]+)\)', image, s)

    def link(m):
        url = _safe_url(html.unescape(m.group(2)))
        ext = url.startswith('http') and 'bastet.uno' not in url
        return f'<a href="{html.escape(url, quote=True)}"' + (' rel="noopener" target="_blank"' if ext else '') + f'>{m.group(1)}</a>'
    s = re.sub(r'\[([^\]]+)\]\(([^)\s]+)\)', link, s)
    s = re.sub(r'\*\*([^*]+)\*\*', r'<strong>\1</strong>', s)
    s = re.sub(r'(?<![*\w])\*([^*\n]+)\*(?![*\w])', r'<em>\1</em>', s)
    return s


def _plain(h):
    return re.sub(r'\s+', ' ', html.unescape(re.sub(r'<[^>]+>', ' ', h))).strip()


def render(md, img_fn=None):
    """Devuelve (html, h2_list[(id, texto)], faq[(pregunta, respuesta)], palabras)."""
    lines = md.replace('\r\n', '\n').split('\n')
    out, toc, i = [], [], 0
    faq, cur_h2, cur_q = [], '', None
    used_ids = set()

    def uid(text):
        base = slugify(text) or 'seccion'
        n, k = base, 2
        while n in used_ids:
            n = f'{base}-{k}'; k += 1
        used_ids.add(n)
        return n

    def flush_faq_answer(buf):
        nonlocal cur_q
        if cur_q is not None and buf:
            faq.append((cur_q, _plain(' '.join(buf))))

    faq_buf = []
    while i < len(lines):
        ln = lines[i]
        if not ln.strip():
            i += 1; continue
        m = re.match(r'^(#{2,4})\s+(.+)$', ln)
        if m:
            level, text = len(m.group(1)), m.group(2).strip()
            if cur_h2.lower().startswith('preguntas frecuentes') and level == 3:
                flush_faq_answer(faq_buf); faq_buf = []; cur_q = text
            elif level == 2:
                flush_faq_answer(faq_buf); faq_buf = []; cur_q = None; cur_h2 = text
            hid = uid(text)
            if level == 2:
                toc.append((hid, text))
            out.append(f'<h{level} id="{hid}">{inline(text, img_fn)}</h{level}>')
            i += 1; continue
        if re.match(r'^-{3,}\s*$', ln):
            out.append('<hr>'); i += 1; continue
        if ln.startswith('>'):
            buf = []
            while i < len(lines) and lines[i].startswith('>'):
                buf.append(lines[i].lstrip('>').strip()); i += 1
            h = f'<blockquote><p>{inline(" ".join(buf), img_fn)}</p></blockquote>'
            out.append(h)
            if cur_q is not None: faq_buf.append(h)
            continue
        if ln.lstrip().startswith('|') and i + 1 < len(lines) and re.match(r'^\s*\|?\s*:?-{2,}', lines[i + 1]):
            rows = []
            while i < len(lines) and lines[i].lstrip().startswith('|'):
                rows.append([c.strip() for c in lines[i].strip().strip('|').split('|')]); i += 1
            head, body = rows[0], rows[2:]
            h = '<div class="tbl"><table><thead><tr>' + ''.join(f'<th>{inline(c, img_fn)}</th>' for c in head) + '</tr></thead><tbody>' + ''.join(
                '<tr>' + ''.join(f'<td>{inline(c, img_fn)}</td>' for c in r) + '</tr>' for r in body) + '</tbody></table></div>'
            out.append(h)
            continue
        if re.match(r'^\s*([-*]|\d+\.)\s+', ln):
            ordered = bool(re.match(r'^\s*\d+\.\s+', ln))
            items = []
            while i < len(lines) and re.match(r'^\s*([-*]|\d+\.)\s+', lines[i]):
                items.append(re.sub(r'^\s*([-*]|\d+\.)\s+', '', lines[i])); i += 1
            tag = 'ol' if ordered else 'ul'
            h = f'<{tag}>' + ''.join(f'<li>{inline(x, img_fn)}</li>' for x in items) + f'</{tag}>'
            out.append(h)
            if cur_q is not None: faq_buf.append(h)
            continue
        im = re.match(r'^!\[([^\]]*)\]\(([^)\s]+)\)\s*$', ln.strip())
        if im:
            alt = im.group(1)
            fig = inline(ln.strip(), img_fn)
            out.append(f'<figure>{fig}' + (f'<figcaption>{html.escape(alt)}</figcaption>' if alt else '') + '</figure>')
            i += 1; continue
        buf = []
        while i < len(lines) and lines[i].strip() and not re.match(r'^(#{2,4}\s|>|-{3,}\s*$|\s*([-*]|\d+\.)\s+|\s*\|)', lines[i]):
            buf.append(lines[i].strip()); i += 1
        if not buf:
            buf = [ln.strip()]; i += 1
        h = f'<p>{inline(" ".join(buf), img_fn)}</p>'
        out.append(h)
        if cur_q is not None: faq_buf.append(h)
    flush_faq_answer(faq_buf)
    words = len(re.findall(r'\w+', _plain(' '.join(out))))
    return '\n'.join(out), toc, faq, words


def reading_minutes(words):
    return max(1, math.ceil(words / 200))
