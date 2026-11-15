"""CSS crítico: calcula qué reglas hacen falta para dibujar lo que se ve al abrir la página (menú, portada, buscador)
y las deja en el propio HTML, para que el primer dibujo no espere a descargar el CSS completo.

Cómo decide: lee la página con BeautifulSoup y se queda con las reglas cuyo selector coincide con algún elemento del menú, la
portada o los contenedores de arriba (más html/body y las barras que inyecta el script). No necesita navegador.
"""
import re

import soupsieve
from bs4 import BeautifulSoup

# Zonas de la página que se ven al abrirla; se incluyen sus elementos y todo lo que contienen.
ROOTS = ['nav.navbar', '#hero', '#hm-feed']
# Elementos que el script inyecta después de cargar (no están en el HTML): se incluyen por nombre de clase.
BY_NAME = re.compile(r'\.quick-bar|\.hm-loading|\.hm-feed|\.hm-hero|\.hm-search|\.navbar|\.hm-row|\.hm-card|\.hm-rail|\.hm-heart|\.hm-arrow|\.hm-more|\.hm-badge|\.hm-rate')


def _skip_ws_comments(t, i):
    n = len(t)
    while i < n:
        if t[i].isspace():
            i += 1
        elif t.startswith('/*', i):
            j = t.find('*/', i + 2)
            i = n if j < 0 else j + 2
        else:
            break
    return i


def parse(t):
    """Devuelve una lista de nodos (prelude, cuerpo|hijos). Las reglas @media/@supports tienen hijos."""
    nodes, i, n = [], 0, len(t)
    while True:
        i = _skip_ws_comments(t, i)
        if i >= n:
            break
        j = i
        while j < n and t[j] not in '{;':
            if t.startswith('/*', j):
                k = t.find('*/', j + 2); j = n if k < 0 else k + 2; continue
            if t[j] in '"\'':
                q = t[j]; j += 1
                while j < n and t[j] != q:
                    j += 2 if t[j] == '\\' else 1
            j += 1
        prelude = t[i:j].strip()
        if j >= n or t[j] == ';':
            nodes.append((prelude, None)); i = j + 1; continue
        depth, k = 1, j + 1
        while k < n and depth:
            c = t[k]
            if t.startswith('/*', k):
                e = t.find('*/', k + 2); k = n if e < 0 else e + 2; continue
            if c in '"\'':
                q = c; k += 1
                while k < n and t[k] != q:
                    k += 2 if t[k] == '\\' else 1
            elif c == '{': depth += 1
            elif c == '}': depth -= 1
            k += 1
        body = t[j + 1:k - 1]
        if re.match(r'@(media|supports|layer|container)\b', prelude):
            nodes.append((prelude, parse(body)))
        else:
            nodes.append((prelude, body))
        i = k
    return nodes


def _split_selectors(s):
    out, depth, cur = [], 0, ''
    for c in s:
        if c in '([': depth += 1
        elif c in ')]': depth -= 1
        if c == ',' and depth == 0:
            out.append(cur.strip()); cur = ''
        else:
            cur += c
    if cur.strip(): out.append(cur.strip())
    return out


_PSEUDO_EL = re.compile(r'::?(before|after|first-line|first-letter|placeholder|selection|marker|backdrop|-webkit-[a-z-]+|-moz-[a-z-]+|-ms-[a-z-]+)(\([^)]*\))?')
_DYNAMIC = re.compile(r':(hover|active|focus|focus-visible|focus-within|visited|target|checked|disabled|enabled|placeholder-shown|read-only|read-write|indeterminate|valid|invalid|required|optional|user-invalid|autofill)\b')


def _matches(soup, in_roots, sel):
    if ':hover' in sel:
        return False
    if BY_NAME.search(sel):
        return True
    s = _PSEUDO_EL.sub('', sel)
    s = _DYNAMIC.sub('', s).strip()
    if not s or s.endswith(('>', '+', '~')):
        s = (s + ' *').strip()
    if s in ('*',) or s in ('html', 'body', ':root'):
        return True
    try:
        for el in soup.select(s):
            if id(el) in in_roots:
                return True
        return False
    except Exception:
        return True   # selector que la librería no entiende: mejor incluirlo


def critical(css_text, html_text):
    soup = BeautifulSoup(html_text, 'lxml')
    in_roots = set()
    for r in ROOTS:
        for el in soup.select(r):
            in_roots.add(id(el))
            for d in el.find_all(True):
                in_roots.add(id(d))
    # html, body y los ancestros de las zonas
    for tag in ('html', 'body'):
        for el in soup.select(tag):
            in_roots.add(id(el))
    keep_kf = set()

    def render(nodes):
        out = []
        for prelude, body in nodes:
            if body is None:
                if prelude.startswith('@charset') or prelude.startswith('@import'): continue
                out.append(prelude + ';'); continue
            if isinstance(body, list):
                if re.match(r'@media[^{]*\bprint\b', prelude): continue
                inner = ''.join(x for x in render(body) if isinstance(x, str))
                if inner: out.append(prelude + '{' + inner + '}')
                continue
            if prelude.startswith('@font-face'):
                out.append(prelude + '{' + body + '}'); continue
            if prelude.startswith('@keyframes') or prelude.startswith('@-webkit-keyframes'):
                out.append(('KF', prelude, body)); continue
            if prelude.startswith('@'):
                continue
            sels = _split_selectors(prelude)
            if any(_matches(soup, in_roots, s) for s in sels):
                out.append(prelude + '{' + body + '}')
        return out

    def flat(items):
        return ''.join(x for x in items if isinstance(x, str))

    # primera pasada: reglas; luego se agregan los @keyframes que esas reglas usan
    top = render(parse(css_text))
    rules = [x for x in top if isinstance(x, str)]
    kfs = [x for x in top if not isinstance(x, str)]
    used = ''.join(rules)
    for _, prelude, body in kfs:
        name = prelude.split()[-1]
        if re.search(r'animation[^;}]*\b' + re.escape(name) + r'\b', used):
            rules.append(prelude + '{' + body + '}')
    css = ''.join(rules)
    css = re.sub(r'/\*.*?\*/', '', css, flags=re.S)
    css = re.sub(r'\s+', ' ', css)
    css = re.sub(r'\s*([{};,>])\s*', r'\1', css)
    css = css.replace(';}', '}')
    # El CSS vive en assets/css/, pero se pega en la página (raíz): las rutas relativas cambian.
    css = re.sub(r"url\((['\"]?)\.\./", r"url(\1assets/", css)
    return css
