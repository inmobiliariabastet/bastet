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
blog_slugs = state.get('_blog', [])
blog_pages = ['blog/index.html'] + [f'blog/{x}/index.html' for x in blog_slugs]
pages = [f'{h}/index.html' for h in hubs] + ['sobre-bastet/index.html', 'inmueble/index.html'] + sorted(str(p.relative_to(ROOT)).replace('\\', '/') for p in (ROOT / 'inmueble').glob('*-bst-*.html')) + blog_pages
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
    check(s.count('GTM-TRGZLFP3') == 2 and s.count('googletagmanager.com/gtm.js') == 1, f'{f}: debe tener exactamente UNA etiqueta de Google')
    check('/assets/js/consent.js' in s and "gtag('consent','default'" in s, f'{f}: falta el aviso de cookies o el consentimiento por defecto')
    check(re.search(r'<head>\s*<meta charset="[^"]*">\s*<!-- Google tag \(GTM-TRGZLFP3\) -->', s) is not None, f'{f}: la etiqueta de Google debe ir justo después de <head> y del <meta charset>')
    check(s.lower().find('<meta charset') < 1024, f'{f}: el <meta charset> debe estar en los primeros 1024 caracteres')
    check('<meta name="robots"' not in s, f'{f}: no debe llevar meta robots estática (el noindex solo lo agrega el script cuando el inmueble ya no está disponible)')
    if t:
        titles.setdefault(t.group(1), []).append(f)
    if d:
        descs.setdefault(d.group(1), []).append(f)
        if f in [f'{h}/index.html' for h in hubs] + blog_pages:
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

# IndexNow: debe existir exactamente un archivo de clave <32 hex>.txt en la raíz con la clave dentro, y no estar en el sitemap
keys = [f for f in ROOT.glob('*.txt') if re.fullmatch(r'[0-9a-f]{32}', f.stem)]
check(len(keys) == 1, f'IndexNow: debe haber exactamente un archivo de clave (hay {len(keys)})')
for k in keys:
    check(k.read_text(encoding='utf-8').strip() == k.stem, 'IndexNow: el archivo de clave debe contener su propio nombre')
    check(k.name not in sm, 'IndexNow: el archivo de clave no debe estar en el sitemap')

# Blog: cada entrada tiene BlogPosting + BreadcrumbList, portada y fechas; las que traen «Preguntas frecuentes» llevan FAQPage con las mismas preguntas
check(len(blog_slugs) >= 1, 'Blog: no hay entradas generadas')
LD = re.compile(r'ld\+json">(.*?)</script>', re.S)
for x in blog_slugs:
    f = f'blog/{x}/index.html'
    s_ = (ROOT / f).read_text(encoding='utf-8')
    lds = [json.loads(b) for b in LD.findall(s_)]
    types = [d.get('@type') for d in lds]
    check('BlogPosting' in types and 'BreadcrumbList' in types, f'{f}: faltan BlogPosting/BreadcrumbList ({types})')
    check('property="og:image"' in s_ and 'article:published_time' in s_, f'{f}: falta og:image o article:published_time')
    check(len(re.findall(r'<h2[ >]', s_)) >= 2, f'{f}: pocas secciones (H2)')
    if 'Preguntas frecuentes</h2>' in s_:
        check('FAQPage' in types, f'{f}: tiene preguntas frecuentes pero no FAQPage')
        zona = s_.split('Preguntas frecuentes</h2>', 1)[1].split('<aside class="bl-cta">')[0]
        n_vis = len(re.findall(r'<h3 id="[^"]+">', zona))
        faq_ld = next((d for d in lds if d.get('@type') == 'FAQPage'), None)
        check(faq_ld is not None and len(faq_ld['mainEntity']) == n_vis, f'{f}: las preguntas del JSON-LD no coinciden con las visibles ({n_vis})')

print(f'Páginas revisadas: {len(pages)} · URLs en sitemap: {len(locs)}')
if fails:
    print(f'{len(fails)} FALLAS:')
    for m in fails:
        print('  -', m)
    sys.exit(1)
print('0 FALLAS')
