#!/usr/bin/env python3
"""Prueba de las páginas SEO generadas (fichas, categorías, institucional, sitemap, robots, llms).

Uso:   python tests/seo_pages_test.py        (después de correr tools/gen_property_pages.py)
Comprueba, sin red:
  · cada página tiene title, meta description (140–160 en categorías), un solo H1, canonical que apunta a sí misma, Open Graph y JSON-LD válido;
  · no hay títulos ni descripciones repetidos entre páginas generadas;
  · todos los enlaces internos que empiezan con «/» apuntan a archivos que existen;
  · todas las URLs del sitemap existen en el repositorio y las páginas generadas están en el sitemap;
  · las categorías cumplen el mínimo de inventario y ninguna repite exactamente el conjunto de otra;
  · robots.txt es ASCII y declara el sitemap; llms.txt enlaza páginas que existen.
"""
import json
import os
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
os.chdir(ROOT)
fails = []


def check(cond, msg):
    if not cond:
        fails.append(msg)


def exists(u):
    u = u.split('#')[0].split('?')[0].lstrip('/')
    return (ROOT / (u or 'index.html')).is_file() or (ROOT / u / 'index.html').is_file()


state = json.loads((ROOT / 'tools/seo_state.json').read_text(encoding='utf-8'))
hubs = state.get('_hubs', [])
pages = [f'{h}/index.html' for h in hubs] + ['sobre-bastet/index.html', 'inmueble/index.html'] + sorted(str(p.relative_to(ROOT)).replace('\\', '/') for p in (ROOT / 'inmueble').glob('*-bst-*.html'))
titles, descs, item_sets = {}, {}, {}
for f in pages:
    s = (ROOT / f).read_text(encoding='utf-8')
    t = re.search(r'<title>(.*?)</title>', s, re.S)
    d = re.search(r'name="description" content="([^"]*)"', s)
    check(bool(t and t.group(1).strip()), f'{f}: sin title')
    check(bool(d), f'{f}: sin meta description')
    check(len(re.findall(r'<h1[ >]', s)) == 1, f'{f}: debe tener exactamente un H1')
    canon = re.search(r'rel="canonical" href="([^"]+)"', s)
    check(bool(canon), f'{f}: sin canonical')
    if canon:
        loc = canon.group(1).replace('https://bastet.uno', '')
        check(exists(loc), f'{f}: canonical {loc} no existe')
        if f.endswith('/index.html'):
            check(loc == '/' + f[:-len('index.html')], f'{f}: canonical no apunta a sí misma ({loc})')
        else:
            check(loc == '/' + f, f'{f}: canonical no apunta a sí misma ({loc})')
    for m in ('og:title', 'og:description', 'og:image', 'og:url'):
        check(f'property="{m}"' in s, f'{f}: falta {m}')
    for blob in re.findall(r'ld\+json">(.*?)</script>', s, re.S):
        try:
            json.loads(blob)
        except Exception as e:
            fails.append(f'{f}: JSON-LD inválido ({e})')
    check('@@MOD@@' not in s, f'{f}: quedó el marcador @@MOD@@ sin reemplazar')
    check('<meta name="robots"' not in s, f'{f}: no debe llevar meta robots estática (el noindex solo lo agrega el script cuando el inmueble ya no está disponible)')
    if t:
        titles.setdefault(t.group(1), []).append(f)
    if d:
        descs.setdefault(d.group(1), []).append(f)
        if f in [f'{h}/index.html' for h in hubs]:
            check(140 <= len(d.group(1)) <= 160, f'{f}: description de {len(d.group(1))} caracteres (debe tener 140–160)')
    for u in re.findall(r'href="(/[^"#]*)"', s):
        check(exists(u), f'{f}: enlace roto {u}')
    # categorías: mínimo de inventario y sin conjuntos repetidos
    slug = f[:-len('/index.html')] if f.endswith('/index.html') else None
    if slug in hubs:
        items = frozenset(re.findall(r'href="(/inmueble/[^"]+|/marketplace\.html\?p=BST-\d+)"', s))
        n = len(items)
        nacional = slug.startswith('propiedades-en-') and slug.endswith('-en-bolivia')
        check(n >= (1 if nacional else 3), f'{f}: solo {n} inmuebles (mínimo {1 if nacional else 3})')
        check(items not in item_sets, f'{f}: repite el conjunto de {item_sets.get(items)}')
        item_sets[items] = f

for k, v in titles.items():
    check(len(v) == 1, f'título repetido «{k}»: {v}')
for k, v in descs.items():
    check(len(v) == 1, f'description repetida: {v}')

sm = (ROOT / 'sitemap.xml').read_text(encoding='utf-8')
locs = re.findall(r'<loc>([^<]+)</loc>', sm)
for u in locs:
    check(exists(u.replace('https://bastet.uno', '') or '/'), f'sitemap: {u} no existe')
for f in pages:
    u = 'https://bastet.uno/' + (f[:-len('index.html')] if f.endswith('/index.html') else f)
    check(u in locs, f'sitemap: falta {u}')
check(len(locs) == len(set(locs)), 'sitemap: URLs repetidas')

rb = (ROOT / 'robots.txt').read_text(encoding='utf-8')
check(all(ord(c) < 128 for c in rb), 'robots.txt: debe ser ASCII')
check('Sitemap: https://bastet.uno/sitemap.xml' in rb, 'robots.txt: falta Sitemap')
check('Disallow: /admin/' in rb, 'robots.txt: debe bloquear /admin/')
for u in re.findall(r'\]\((https://bastet\.uno[^)]*)\)', (ROOT / 'llms.txt').read_text(encoding='utf-8')):
    check(exists(u.replace('https://bastet.uno', '') or '/'), f'llms.txt: enlace roto {u}')

print(f'Páginas revisadas: {len(pages)} · URLs en sitemap: {len(locs)}')
if fails:
    print(f'{len(fails)} FALLAS:')
    for m in fails:
        print('  -', m)
    sys.exit(1)
print('0 FALLAS')
