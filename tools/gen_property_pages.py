#!/usr/bin/env python3
"""Genera páginas estáticas indexables para cada inmueble publicado (SEO/AEO).

Uso (desde la raíz del repo):   python tools/gen_property_pages.py

Qué hace
  · Lee con la clave pública (la misma del sitio) los inmuebles `status = available` y vigentes.
  · Crea inmueble/<tipo>-<operacion>-<ciudad>-bst-<n>.html SOLO para fichas completas (reglas anti «doorway pages»):
      - tiene operación, tipo, ciudad, precio, al menos 1 foto y una descripción propia de ≥ 100 caracteres;
      - la descripción no se repite en otra ficha (se indexa solo la primera);
      - nunca se genera texto de relleno: el contenido es el que escribió quien publicó + los datos de la ficha.
  · Borra las páginas de inmuebles que ya no cumplen (vendidos, retirados, vencidos o incompletos).
  · Reescribe el bloque de inmuebles de sitemap.xml y la página índice inmueble/index.html.
  · Cada página comprueba en vivo si el inmueble sigue disponible; si no, avisa y se marca noindex.
  · No publica la dirección exacta ni teléfonos: solo ciudad. El contacto se pide en la ficha interactiva.

Volver a correrlo cada vez que se publiquen o retiren inmuebles, y luego commit + push.
"""
import html
import json
import re
import sys
import unicodedata
import urllib.request
from datetime import date, datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / 'inmueble'
SITE = 'https://bastet.uno'
MIN_DESC = 100

cfg = (ROOT / 'assets/js/supabase-config.js').read_text(encoding='utf-8')
SB_URL = re.search(r"SUPABASE_URL\s*=\s*'([^']+)'", cfg).group(1)
SB_KEY = re.search(r"SUPABASE_ANON_KEY\s*=\s*'([^']+)'", cfg).group(1)

TYPE = {'casa': 'Casa', 'departamento': 'Departamento', 'habitacion': 'Habitación', 'terreno': 'Terreno'}
TYPE_LD = {'casa': 'House', 'departamento': 'Apartment', 'habitacion': 'Room', 'terreno': 'Landform'}
OP_TITLE = {'venta': 'en venta', 'alquiler': 'en alquiler', 'anticretico': 'en anticrético', 'temporal': 'para estadía'}
OP_SLUG = {'venta': 'en-venta', 'alquiler': 'en-alquiler', 'anticretico': 'en-anticretico', 'temporal': 'estadia'}
OP_NAME = {'venta': 'Venta', 'alquiler': 'Alquiler', 'anticretico': 'Anticrético', 'temporal': 'Estadías por noche'}
esc = lambda s: html.escape(str(s if s is not None else ''), quote=True)


def slug(s):
    s = unicodedata.normalize('NFKD', s).encode('ascii', 'ignore').decode()
    return re.sub(r'[^a-z0-9]+', '-', s.lower()).strip('-')


def fetch():
    cols = ('id,title,location,price,currency,area,rooms,baths,description,photos,verified,created_at,code_number,'
            'property_type,operation,floors,has_garage,garage_spots,has_storage,pets_allowed,kids_allowed,expires_at')
    url = f'{SB_URL}/rest/v1/properties?select={cols}&status=eq.available&order=sort_order'
    req = urllib.request.Request(url, headers={'apikey': SB_KEY, 'Authorization': 'Bearer ' + SB_KEY})
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.load(r)


def price_text(p):
    digits = re.sub(r'[^0-9]', '', str(p.get('price') or ''))
    if not digits:
        return ''
    n = f'{int(digits):,}'.replace(',', '.')
    base = f'Bs.- {n}' if p.get('currency') == 'BOB' else f'{n} USD'
    return base + (' por día' if p.get('operation') == 'temporal' else '')


def clean(s):
    return re.sub(r'\s+', ' ', (s or '').strip())


def city_of(p):
    return clean((p.get('location') or '').split(',')[0])


def complete(p):
    return bool(p.get('operation') in OP_SLUG and p.get('property_type') in TYPE and city_of(p) and price_text(p)
                and p.get('photos') and len(clean(p.get('description'))) >= MIN_DESC)


def expired(p):
    e = p.get('expires_at')
    return bool(e) and datetime.fromisoformat(e.replace('Z', '+00:00')) <= datetime.now(timezone.utc)


def facts(p):
    f = []
    if p.get('area'): f.append(('Superficie', f"{p['area']} m²"))
    if p.get('rooms') is not None and p['property_type'] in ('casa', 'departamento', 'habitacion'): f.append(('Dormitorios', p['rooms']))
    if p.get('baths') is not None and p['property_type'] != 'terreno': f.append(('Baños', p['baths']))
    if p.get('floors'): f.append(('Pisos', p['floors']))
    if p.get('has_garage'): f.append(('Garaje', f"{p.get('garage_spots') or 1} lugar(es)" if p.get('garage_spots') else 'Sí'))
    if p.get('has_storage'): f.append(('Baulera', 'Sí'))
    if p.get('pets_allowed') is not None and p['operation'] in ('alquiler', 'anticretico', 'temporal'): f.append(('Mascotas', 'Se aceptan' if p['pets_allowed'] else 'No se aceptan'))
    if p.get('kids_allowed') is not None and p['operation'] == 'alquiler': f.append(('Niños', 'Se aceptan' if p['kids_allowed'] else 'No se aceptan'))
    return f


def fname(p):
    return f"{p['property_type']}-{OP_SLUG[p['operation']]}-{slug(city_of(p))}-bst-{p['code_number']}.html"


def meta_desc(p, fl):
    bits = [f"{TYPE[p['property_type']]} {OP_TITLE[p['operation']]} en {city_of(p)}"]
    short = [f'{v} {k.lower()}' if k in ('Dormitorios', 'Baños') else f'{v}' for k, v in fl if k in ('Superficie', 'Dormitorios', 'Baños')]
    d = bits[0] + (': ' + ', '.join(short) + '. ' if short else '. ') + clean(p['description'])
    if len(d) < 140:
        d += ' Mira las fotos y solicita contacto en Bastet.'
    if len(d) > 158:
        d = d[:157].rsplit(' ', 1)[0].rstrip(',;:. ') + '…'
    return d


def page(p, others):
    code = f"BST-{p['code_number']}"
    typ, op, city = TYPE[p['property_type']], p['operation'], city_of(p)
    pr = price_text(p)
    fl = facts(p)
    url = f"{SITE}/inmueble/{fname(p)}"
    title = f"{typ} {OP_TITLE[op]} en {city} · {pr} · Bastet"
    desc = meta_desc(p, fl)
    photos = p['photos'][:6]
    name = clean(p['title'])
    app = ('estadias.html' if op == 'temporal' else 'marketplace.html') + f"?p={code}"
    lead = f"{name}: {typ.lower()} {OP_TITLE[op]} en {city}, Bolivia, por {pr}."
    ld_type = TYPE_LD[p['property_type']]
    about = {'@type': ld_type, 'name': name, 'address': {'@type': 'PostalAddress', 'addressLocality': city, 'addressCountry': 'BO'}}
    if p.get('rooms') is not None and p['property_type'] != 'terreno': about['numberOfRooms'] = p['rooms']
    if p.get('area'): about['floorSize'] = {'@type': 'QuantitativeValue', 'value': p['area'], 'unitCode': 'MTK'}
    offer = {'@type': 'Offer', 'price': re.sub(r'[^0-9]', '', str(p['price'])), 'priceCurrency': 'BOB' if p.get('currency') == 'BOB' else 'USD',
             'availability': 'https://schema.org/InStock', 'url': url}
    if op == 'temporal':
        offer['priceSpecification'] = {'@type': 'UnitPriceSpecification', 'price': offer['price'], 'priceCurrency': offer['priceCurrency'], 'unitText': 'DAY'}
    ld = [
        {'@context': 'https://schema.org', '@type': 'RealEstateListing', 'name': name, 'description': clean(p['description']), 'url': url,
         'image': photos, 'datePosted': (p.get('created_at') or '')[:10] or None, 'inLanguage': 'es', 'offers': offer, 'about': about,
         'provider': {'@id': SITE + '/#org'}},
        {'@context': 'https://schema.org', '@type': 'BreadcrumbList', 'itemListElement': [
            {'@type': 'ListItem', 'position': 1, 'name': 'Inicio', 'item': SITE + '/'},
            {'@type': 'ListItem', 'position': 2, 'name': 'Inmuebles publicados', 'item': SITE + '/inmueble/'},
            {'@type': 'ListItem', 'position': 3, 'name': name, 'item': url}]},
    ]
    ld[0] = {k: v for k, v in ld[0].items() if v is not None}
    figs = ''.join(
        f'<img src="{esc(u)}" alt="{esc(name)} · foto {i + 1} de {len(photos)}" loading="{"eager" if i == 0 else "lazy"}"'
        f'{" fetchpriority=\"high\"" if i == 0 else ""} decoding="async">' for i, u in enumerate(photos))
    dl = ''.join(f'<div><dt>{esc(k)}</dt><dd>{esc(v)}</dd></div>' for k, v in
                 [('Operación', OP_NAME[op]), ('Tipo', typ), ('Ciudad', city), ('Precio', pr), ('Código', code)] + fl)
    ver = '<p class="badge">Inmueble con verificación de Bastet</p>' if p.get('verified') else ''
    desc_html = ''.join(f'<p>{esc(x)}</p>' for x in re.split(r'\n{2,}', (p['description'] or '').strip()) if x.strip())
    return f'''<!DOCTYPE html>
<html lang="es">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{esc(title)}</title>
<meta name="description" content="{esc(desc)}">
<link rel="canonical" href="{esc(url)}">
<meta property="og:type" content="website">
<meta property="og:site_name" content="Bastet">
<meta property="og:locale" content="es_BO">
<meta property="og:url" content="{esc(url)}">
<meta property="og:title" content="{esc(title)}">
<meta property="og:description" content="{esc(desc)}">
<meta property="og:image" content="{esc(photos[0])}">
<meta property="og:image:alt" content="{esc(name)}">
<meta name="twitter:card" content="summary_large_image">
<meta name="twitter:title" content="{esc(title)}">
<meta name="twitter:description" content="{esc(desc)}">
<meta name="twitter:image" content="{esc(photos[0])}">
<link rel="icon" type="image/png" sizes="32x32" href="/assets/img/bastet-favicon-32.png?v=20261026">
<link rel="icon" type="image/png" sizes="192x192" href="/assets/img/bastet-favicon-192.png?v=20261026">
<link rel="apple-touch-icon" href="/assets/img/bastet-apple-touch.png?v=20261026">
<link rel="manifest" href="/manifest.json">
<meta name="theme-color" content="#FFFFFF">
<link rel="preload" href="/assets/fonts/Conso-Regular.woff2" as="font" type="font/woff2" crossorigin>
<link rel="stylesheet" href="/assets/css/fonts.css?v=20261014b">
<script type="application/ld+json">{json.dumps(ld[0], ensure_ascii=False)}</script>
<script type="application/ld+json">{json.dumps(ld[1], ensure_ascii=False)}</script>
<style>
  :root {{ --green:#3D4C3A; --green-dark:#2F3B2D; --yellow:#F1BF46; --ink:#1E2629; --sand:#EEE6E0; --cloud:#F7F9FB; }}
  * {{ box-sizing:border-box; margin:0; padding:0; }}
  body {{ font-family:'Cabinet Grotesk','Helvetica Neue',Arial,sans-serif; color:var(--ink); background:#fff; line-height:1.6; }}
  a {{ color:var(--green); }}
  header.top {{ display:flex; align-items:center; justify-content:space-between; gap:16px; flex-wrap:wrap; padding:14px clamp(16px,4vw,48px); border-bottom:1px solid rgba(30,38,41,.12); }}
  header.top img {{ height:42px; width:auto; display:block; }}
  header.top nav {{ display:flex; gap:clamp(14px,2.4vw,30px); flex-wrap:wrap; }}
  header.top nav a {{ text-decoration:none; font-size:15.5px; }}
  main {{ max-width:1080px; margin:0 auto; padding:clamp(18px,3vw,40px) clamp(16px,4vw,32px) 56px; }}
  .crumbs {{ font-size:14px; color:rgba(30,38,41,.66); margin-bottom:14px; }}
  h1 {{ font-family:'Conso',Georgia,serif; font-weight:400; color:var(--green); font-size:clamp(28px,4.4vw,46px); line-height:1.12; }}
  .lead {{ margin-top:12px; font-size:clamp(16px,1.6vw,18.5px); max-width:62ch; }}
  .badge {{ display:inline-block; margin-top:12px; padding:5px 14px; border-radius:999px; background:#EFF8E7; color:var(--green); font-size:14px; }}
  .gallery {{ display:grid; gap:10px; margin:22px 0; grid-template-columns:repeat(3,1fr); }}
  .gallery img {{ width:100%; aspect-ratio:4/3; object-fit:cover; border-radius:14px; display:block; background:var(--sand); }}
  .gallery img:first-child {{ grid-column:1/-1; aspect-ratio:16/9; }}
  .cols {{ display:grid; grid-template-columns:minmax(0,1.4fr) minmax(0,1fr); gap:clamp(20px,4vw,48px); align-items:start; }}
  h2 {{ font-family:'Conso',Georgia,serif; font-weight:400; color:var(--green); font-size:clamp(22px,2.6vw,30px); margin:0 0 10px; }}
  .desc p {{ margin-bottom:12px; max-width:68ch; }}
  dl {{ background:var(--cloud); border-radius:16px; padding:8px 20px; }}
  dl div {{ display:flex; justify-content:space-between; gap:16px; padding:11px 0; border-bottom:1px solid rgba(30,38,41,.1); }}
  dl div:last-child {{ border:0; }} dt {{ color:rgba(30,38,41,.66); }} dd {{ font-weight:500; text-align:right; }}
  .cta {{ margin-top:18px; display:flex; gap:12px; flex-wrap:wrap; }}
  .btn {{ display:inline-flex; align-items:center; justify-content:center; min-height:52px; padding:0 28px; border-radius:999px; font-family:'Conso',Georgia,serif; font-size:17px; font-weight:500; text-decoration:none; border:1.5px solid var(--green); background:var(--green); color:#fff; }}
  .btn:hover {{ background:var(--green-dark); }} .btn.line {{ background:transparent; color:var(--green); }} .btn.line:hover {{ background:var(--green); color:#fff; }}
  .btn:focus-visible, a:focus-visible {{ outline:3px solid var(--yellow); outline-offset:3px; }}
  .note {{ margin-top:14px; font-size:14px; color:rgba(30,38,41,.66); }}
  #gone {{ display:none; margin:18px 0; padding:16px 20px; border-radius:14px; background:#FBE6AB; }}
  footer {{ border-top:1px solid rgba(30,38,41,.12); padding:24px clamp(16px,4vw,48px); font-size:14.5px; color:rgba(30,38,41,.7); }}
  footer a {{ margin-right:14px; }}
  @media (max-width:760px) {{ .cols {{ grid-template-columns:1fr; }} .gallery {{ grid-template-columns:1fr 1fr; }} .btn {{ width:100%; }} }}
</style>
</head>
<body>
<header class="top">
  <a href="/" aria-label="Bastet, ir al inicio"><img src="/assets/img/bastet-logo-horizontal-color.webp" alt="Bastet · Propiedades · Inmobiliarias" width="1200" height="298"></a>
  <nav aria-label="Principal"><a href="/">Inicio</a><a href="/marketplace.html">Propiedades</a><a href="/estadias.html">Estadías</a><a href="/empresas.html">Empresas</a></nav>
</header>
<main>
  <p class="crumbs"><a href="/">Inicio</a> › <a href="/inmueble/">Inmuebles publicados</a> › {esc(code)}</p>
  <h1>{esc(name)}</h1>
  <p class="lead">{esc(lead)}</p>
  {ver}
  <div id="gone" role="status"><strong>Este inmueble ya no está disponible.</strong> Mira otros en <a href="/marketplace.html">Propiedades</a> o <a href="/estadias.html">Estadías</a>.</div>
  <div class="gallery">{figs}</div>
  <div class="cols">
    <section class="desc" aria-labelledby="d-t">
      <h2 id="d-t">Descripción</h2>
      {desc_html}
      <div class="cta" id="cta">
        <a class="btn" href="/{esc(app)}">Ver la ficha y solicitar contacto</a>
        <a class="btn line" href="/verificar.html">Verificar con el código {esc(code)}</a>
      </div>
      <p class="note">Los teléfonos no se publican: se entregan cuando tu solicitud o reserva se confirma.</p>
    </section>
    <section aria-labelledby="f-t">
      <h2 id="f-t">Datos del inmueble</h2>
      <dl>{dl}</dl>
    </section>
  </div>
</main>
<footer>
  <a href="/">Inicio</a><a href="/inmueble/">Inmuebles publicados</a><a href="/privacidad.html">Política de privacidad</a><a href="/terminos.html">Términos de uso</a>
  <p style="margin-top:10px">© 2026 Bastet Real State S.R.L. · inmobiliaria@bastet.uno</p>
</footer>
<script>
/* Si el inmueble se vendió, se retiró o venció desde que se generó esta página, se avisa y se pide que no se indexe. */
(function () {{
  fetch({json.dumps(SB_URL)} + '/rest/v1/properties?select=status,expires_at&code_number=eq.{p['code_number']}', {{ headers: {{ apikey: {json.dumps(SB_KEY)} }} }})
    .then(function (r) {{ return r.ok ? r.json() : null; }})
    .then(function (rows) {{
      if (!rows) return;
      var r = rows[0], gone = !r || r.status !== 'available' || (r.expires_at && new Date(r.expires_at) <= new Date());
      if (!gone) return;
      document.getElementById('gone').style.display = 'block';
      var c = document.getElementById('cta'); if (c) c.style.display = 'none';
      var m = document.createElement('meta'); m.name = 'robots'; m.content = 'noindex'; document.head.appendChild(m);
    }}).catch(function () {{}});
}})();
</script>
</body>
</html>
'''


def index_page(items):
    groups = {}
    for p in items:
        groups.setdefault(p['operation'], []).append(p)
    secs = ''
    for op in ('venta', 'alquiler', 'anticretico', 'temporal'):
        if op not in groups:
            continue
        lis = ''.join(f'<li><a href="/inmueble/{esc(fname(p))}">{esc(clean(p["title"]))}</a> — {esc(TYPE[p["property_type"]])} en {esc(city_of(p))}, {esc(price_text(p))}</li>' for p in groups[op])
        secs += f'<h2>{esc(OP_NAME[op])}</h2><ul>{lis}</ul>'
    return f'''<!DOCTYPE html>
<html lang="es">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Inmuebles y estadías publicados en Bolivia · Bastet</title>
<meta name="description" content="Lista de las casas, departamentos, habitaciones y terrenos publicados en Bastet para comprar, alquilar, tomar en anticrético o reservar por noche en Bolivia.">
<link rel="canonical" href="{SITE}/inmueble/">
<link rel="icon" type="image/png" sizes="32x32" href="/assets/img/bastet-favicon-32.png?v=20261026">
<link rel="manifest" href="/manifest.json">
<link rel="stylesheet" href="/assets/css/fonts.css?v=20261014b">
<style>
  body {{ font-family:'Cabinet Grotesk','Helvetica Neue',Arial,sans-serif; color:#1E2629; margin:0; line-height:1.6; }}
  header {{ padding:14px clamp(16px,4vw,48px); border-bottom:1px solid rgba(30,38,41,.12); }} header img {{ height:42px; display:block; }}
  main {{ max-width:860px; margin:0 auto; padding:clamp(20px,4vw,48px) clamp(16px,4vw,32px) 56px; }}
  h1,h2 {{ font-family:'Conso',Georgia,serif; font-weight:400; color:#3D4C3A; line-height:1.15; }} h1 {{ font-size:clamp(28px,4.2vw,42px); }} h2 {{ margin-top:30px; font-size:clamp(22px,2.6vw,28px); }}
  ul {{ padding-left:20px; }} li {{ margin:8px 0; }} a {{ color:#3D4C3A; }} a:focus-visible {{ outline:3px solid #F1BF46; outline-offset:3px; }}
</style>
</head>
<body>
<header><a href="/" aria-label="Bastet, ir al inicio"><img src="/assets/img/bastet-logo-horizontal-color.webp" alt="Bastet · Propiedades · Inmobiliarias" width="1200" height="298"></a></header>
<main>
  <h1>Inmuebles y estadías publicados en Bastet</h1>
  <p>Estos son los inmuebles publicados hoy con ficha completa. Para filtrar por ciudad o tipo, usa el buscador de <a href="/marketplace.html">Propiedades</a> o de <a href="/estadias.html">Estadías</a>.</p>
  {secs}
</main>
</body>
</html>
'''


def main():
    rows = [p for p in fetch() if not expired(p)]
    seen, keep, skipped = set(), [], []
    for p in rows:
        if not p.get('code_number'):
            skipped.append((p.get('title'), 'sin código')); continue
        if not complete(p):
            skipped.append((p.get('title'), 'ficha incompleta')); continue
        key = re.sub(r'\W+', ' ', clean(p['description']).lower())
        if key in seen:
            skipped.append((p.get('title'), 'descripción repetida')); continue
        seen.add(key); keep.append(p)
    OUT.mkdir(exist_ok=True)
    want = {fname(p) for p in keep} | {'index.html'}
    for f in OUT.glob('*.html'):
        if f.name not in want:
            f.unlink(); print('borrada', f.name)
    sm = (ROOT / 'sitemap.xml').read_text(encoding='utf-8')
    old_mod = dict(re.findall(r'<loc>([^<]+)</loc><lastmod>([^<]+)</lastmod>', sm))
    today = date.today().isoformat()
    mods = {}

    def write(path, text, loc):
        # El lastmod del sitemap solo cambia si el contenido de la página cambió de verdad (así no hay commits diarios vacíos).
        same = path.exists() and path.read_text(encoding='utf-8').replace('\r\n', '\n') == text
        path.write_text(text, encoding='utf-8', newline='\n')
        mods[loc] = old_mod.get(loc, today) if same else today

    for p in keep:
        write(OUT / fname(p), page(p, keep), f'{SITE}/inmueble/{fname(p)}')
    write(OUT / 'index.html', index_page(keep), f'{SITE}/inmueble/')
    block = '<!-- inmuebles:start -->\n' + f'  <url><loc>{SITE}/inmueble/</loc><lastmod>{mods[SITE + "/inmueble/"]}</lastmod><changefreq>daily</changefreq><priority>0.7</priority></url>\n' + ''.join(
        f'  <url><loc>{SITE}/inmueble/{fname(p)}</loc><lastmod>{mods[SITE + "/inmueble/" + fname(p)]}</lastmod><changefreq>weekly</changefreq><priority>0.6</priority></url>\n' for p in keep) + '  <!-- inmuebles:end -->'
    nl = '\r\n' if '\r\n' in sm else '\n'
    sm = sm.replace('\r\n', '\n')
    if '<!-- inmuebles:start -->' in sm:
        sm = re.sub(r'<!-- inmuebles:start -->.*?<!-- inmuebles:end -->', lambda m: block, sm, flags=re.S)
    else:
        sm = sm.replace('</urlset>', '  ' + block + '\n</urlset>')
    (ROOT / 'sitemap.xml').write_text(sm.replace('\n', nl), encoding='utf-8', newline='')
    print(f'Páginas generadas: {len(keep)} · omitidas: {len(skipped)}')
    for t, why in skipped:
        print('  omitida:', t, '→', why)


if __name__ == '__main__':
    sys.exit(main())
