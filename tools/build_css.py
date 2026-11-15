#!/usr/bin/env python3
"""Une las hojas de estilo de cada página pública en un solo archivo (menos peticiones que bloquean el primer dibujo).

Uso (desde la raíz del repo):   python tools/build_css.py

· Las hojas fuente en assets/css/ siguen siendo las que se editan. El archivo unido se genera aparte
  (assets/css/bundle-<pagina>.css) con las mismas hojas en el MISMO orden, así que la cascada no cambia.
· Cada página enlaza su bundle con ?v=<huella del contenido>: el script la actualiza solo.
· Si editas una hoja fuente, vuelve a correr este script y haz commit de assets/css/bundle-*.css y de las páginas.
"""
import hashlib
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from critical_css import critical  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
CSS = ROOT / 'assets/css'

# página -> hojas (en el orden en que la página las cargaba)
BUNDLES = {
    'index': ['fonts', 'style', 'brand', 'sell', 'steps', 'prop-extras', 'home', 'responsive-guard', 'a11y'],
    'marketplace': ['fonts', 'style', 'brand', 'prop-extras', 'steps', 'responsive-guard', 'a11y'],
    'estadias': ['fonts', 'style', 'brand', 'estadias', 'responsive-guard', 'a11y'],
    'empresas': ['fonts', 'style', 'brand', 'empresas', 'responsive-guard', 'a11y'],
}
# Páginas con CSS crítico en línea (el CSS completo se carga sin bloquear el primer dibujo)
CRITICAL = {'index'}


def build(page, sources):
    parts = []
    for s in sources:
        txt = (CSS / f'{s}.css').read_text(encoding='utf-8').replace('\r\n', '\n').strip()
        parts.append(f'/* ===== {s}.css ===== */\n{txt}\n')
    out = f'/* Generado por tools/build_css.py. NO editar: edita las hojas fuente y vuelve a correr el script. */\n' + '\n'.join(parts)
    name = f'bundle-{page}.css'
    (CSS / name).write_text(out, encoding='utf-8', newline='\n')
    return name, hashlib.sha1(out.encode('utf-8')).hexdigest()[:8]


def patch_html(page, sources, bundle, ver):
    path = ROOT / f'{page}.html'
    html = path.read_text(encoding='utf-8')
    nl = '\r\n' if '\r\n' in html else '\n'
    link = f'<link rel="stylesheet" href="assets/css/{bundle}?v={ver}">'
    if f'assets/css/{bundle}' in html:
        html = re.sub(rf'assets/css/{re.escape(bundle)}\?v=[^"]+', f'assets/css/{bundle}?v={ver}', html, 1)
    else:
        first = True
        for s in sources:
            pat = re.compile(rf'<link rel="stylesheet" href="assets/css/{re.escape(s)}\.css\?v=[^"]*">[ \t]*(\r?\n)?')
            m = pat.search(html)
            if not m:
                sys.exit(f'{page}.html no enlaza {s}.css: revisa BUNDLES en tools/build_css.py')
            html = html[:m.start()] + (link + nl if first else '') + html[m.end():]
            first = False
    path.write_text(html, encoding='utf-8', newline='')


for page, sources in BUNDLES.items():
    name, ver = build(page, sources)
    patch_html(page, sources, name, ver)
    size = (CSS / name).stat().st_size
    print(f'{name}: {len(sources)} hojas, {size // 1024} KB, v={ver}')


def inject_critical(page, bundle, ver):
    path = ROOT / f'{page}.html'
    html = path.read_text(encoding='utf-8')
    css = critical((CSS / bundle).read_text(encoding='utf-8'), html)
    href = f'assets/css/{bundle}?v={ver}'
    q = chr(39)   # comilla simple (para el atributo onload)
    nl = chr(10)
    block = ('<!-- critical:start -->' + nl + '<style>' + css + '</style>' + nl
             + f'<link rel="preload" href="{href}" as="style" onload="this.onload=null;this.rel={q}stylesheet{q}">' + nl
             + f'<noscript><link rel="stylesheet" href="{href}"></noscript>' + nl + '<!-- critical:end -->')
    if '<!-- critical:start -->' in html:
        html = re.sub(r'<!-- critical:start -->.*?<!-- critical:end -->', lambda m: block, html, 1, flags=re.S)
    else:
        old = re.search(rf'<link rel="stylesheet" href="assets/css/{re.escape(bundle)}\?v=[^"]+">', html)
        if not old:
            sys.exit(f'{page}.html no enlaza {bundle}')
        html = html[:old.start()] + block + html[old.end():]
    path.write_text(html, encoding='utf-8', newline='')
    print(f'  CSS crítico en {page}.html: {len(css) // 1024} KB ({len(css)} bytes)')


for page in CRITICAL:
    bundle = f'bundle-{page}.css'
    ver = hashlib.sha1((CSS / bundle).read_text(encoding='utf-8').encode('utf-8')).hexdigest()[:8]
    inject_critical(page, bundle, ver)

