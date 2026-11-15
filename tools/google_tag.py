"""Etiqueta de Google (GTM-TRGZLFP3) + aviso de cookies: se insertan al inicio del <head> de las páginas públicas del sitio.

Uso:  python tools/google_tag.py         (idempotente: si la etiqueta ya está, la actualiza; nunca la repite)

La etiqueta de Google va UNA sola vez por página, justo después de <head> y del <meta charset> (que debe estar en los primeros
1024 bytes del documento). Lleva delante el consentimiento por defecto (Modo de consentimiento de Google) y detrás el script del aviso de
cookies (assets/js/consent.js). Las páginas generadas (fichas, categorías, institucional) la traen desde sus plantillas en
tools/seo_hubs.py y gen_property_pages.py (constante GTAG).
NO se agrega a admin/, descargos.html ni confirmar.html: llevan datos privados o enlaces con un token secreto en la dirección (?t=...)
y no deben enviarse a una herramienta de medición externa.
"""
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from seo_hubs import GTAG  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
PAGES = ['index.html', 'marketplace.html', 'estadias.html', 'empresas.html', 'app.html', 'privacidad.html', 'terminos.html',
         'dmca.html', 'verificar.html', '404.html', 'agente/index.html']
START = '<!-- Google tag (GTM-TRGZLFP3) -->'
END = '<!-- End Google tag -->'
CONSENT = '<script defer src="/assets/js/consent.js'
CHARSET = re.compile(r'<meta charset="[^"]*">[ \t]*\r?\n?', re.I)
META = '<meta charset="utf-8">\n'


def build(html):
    """Devuelve el HTML con: <head>, <meta charset>, bloque de la etiqueta de Google, resto (sin duplicados)."""
    # 1) quitar el bloque anterior (y su línea de consentimiento) si existe
    i = html.find(START)
    if i >= 0:
        j = html.find(END, i) + len(END)
        tail = html[j:].lstrip('\r\n')
        if tail.startswith(CONSENT):
            tail = tail[tail.find('</script>') + len('</script>'):].lstrip('\r\n')
        html = html[:i] + tail
    # 2) quitar el <meta charset> actual (se vuelve a poner primero)
    html = CHARSET.sub('', html, count=1)
    # 3) insertar charset + etiqueta justo después de <head>
    m = re.search(r'<head[^>]*>[ \t]*\r?\n?', html)
    if not m:
        sys.exit('no se encontró <head>')
    return html[:m.end()] + META + GTAG + '\n' + html[m.end():]


for rel in PAGES:
    path = ROOT / rel
    html = path.read_text(encoding='utf-8')
    new_html = build(html)
    if new_html == html:
        print('sin cambios:', rel)
    else:
        path.write_text(new_html, encoding='utf-8', newline='')
        print('etiqueta actualizada:' if START in html else 'etiqueta agregada:', rel)
