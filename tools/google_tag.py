"""Etiqueta de Google (GTM-TRGZLFP3): se inserta justo después de <head> en las páginas públicas del sitio.

Uso:  python tools/google_tag.py         (idempotente: si la etiqueta ya está, no la repite)

Las páginas generadas (fichas, categorías, institucional) la llevan desde sus plantillas en tools/seo_hubs.py y gen_property_pages.py.
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

for rel in PAGES:
    path = ROOT / rel
    html = path.read_text(encoding='utf-8')
    if 'GTM-TRGZLFP3' in html:
        print('ya tiene la etiqueta:', rel)
        continue
    m = re.search(r'<head[^>]*>[ \t]*\r?\n?', html)
    if not m:
        sys.exit(f'{rel}: no se encontró <head>')
    html = html[:m.end()] + GTAG + '\n' + html[m.end():]
    path.write_text(html, encoding='utf-8', newline='')
    print('etiqueta agregada:', rel)
