"""Etiqueta de Google (GTM-TRGZLFP3) + aviso de cookies: se insertan justo después de <head> en las páginas públicas del sitio.

Uso:  python tools/google_tag.py         (idempotente: si la etiqueta ya está, la actualiza; nunca la repite)

La etiqueta de Google va UNA sola vez por página. Lleva delante el consentimiento por defecto (Modo de consentimiento de Google) y
detrás el script del aviso de cookies (assets/js/consent.js). Las páginas generadas (fichas, categorías, institucional) la traen desde
sus plantillas en tools/seo_hubs.py y gen_property_pages.py (constante GTAG).
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

for rel in PAGES:
    path = ROOT / rel
    html = path.read_text(encoding='utf-8')
    i = html.find(START)
    if i >= 0:
        j = html.find(END, i) + len(END)
        # también se reemplaza la línea del script de consentimiento que sigue al bloque
        rest = html[j:].lstrip('\r\n')
        if rest.startswith(CONSENT):
            k = rest.find('</script>') + len('</script>')
            rest = rest[k:]
        else:
            rest = html[j:]
        new_html = html[:i] + GTAG + '\n' + rest.lstrip('\r\n')
        print('etiqueta actualizada:' if new_html != html else 'sin cambios:', rel)
        if new_html != html:
            path.write_text(new_html, encoding='utf-8', newline='')
        continue
    m = re.search(r'<head[^>]*>[ \t]*\r?\n?', html)
    if not m:
        sys.exit(f'{rel}: no se encontró <head>')
    html = html[:m.end()] + GTAG + '\n' + html[m.end():]
    path.write_text(html, encoding='utf-8', newline='')
    print('etiqueta agregada:', rel)
