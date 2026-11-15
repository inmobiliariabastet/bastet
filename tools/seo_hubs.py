"""Páginas de categoría indexables (operación, ciudad, tipo) para Bastet. Las usa tools/gen_property_pages.py.

Reglas (anti «doorway pages»):
  · Una página solo existe si hay inventario real: ≥ MIN_LISTINGS inmuebles (≥ 1 en las tres páginas nacionales de operación,
    que además llevan guía y preguntas útiles).
  · Si dos páginas mostrarían exactamente el mismo conjunto de inmuebles, solo se publica la más general.
  · El texto de introducción sale de datos reales (cantidad, tipos, rango de precios); no se inventan cifras ni datos de mercado.
  · Cada página lleva canonical propio, Open Graph, breadcrumbs, JSON-LD y los inmuebles escritos en el HTML (sin JavaScript).
"""
import html
import json
import re
from collections import Counter

MIN_LISTINGS = 3
OPS = ['venta', 'alquiler', 'anticretico']
OP_PHRASE = {'venta': 'en venta', 'alquiler': 'en alquiler', 'anticretico': 'en anticrético'}
OP_NOUN = {'venta': 'venta', 'alquiler': 'alquiler', 'anticretico': 'anticrético'}
TYPE_PL = {'casa': 'casas', 'departamento': 'departamentos', 'habitacion': 'habitaciones', 'terreno': 'terrenos'}
TYPE_SG = {'casa': 'casa', 'departamento': 'departamento', 'habitacion': 'habitación', 'terreno': 'terreno'}
CITY_ALIAS = {'Santa Cruz de la Sierra': 'santa-cruz'}
CITY_SHORT = {'Santa Cruz de la Sierra': 'Santa Cruz'}

GUIDE = {
    'venta': 'Antes de comprar un inmueble en Bolivia conviene revisar su situación legal: que el propietario figure en Derechos Reales, que el Folio Real esté actualizado y sin gravámenes que impidan la venta, que los impuestos estén al día y que el plano coincida con el terreno. Bastet puede acompañarte con la revisión registral y documental; antes de firmar, consúltalo con tu abogado.',
    'alquiler': 'Al alquilar, pide el contrato por escrito, revisa el estado del inmueble con el anunciante antes de entregar dinero y aclara quién paga los servicios básicos y el mantenimiento. En Bastet, tu solicitud de contacto llega al anunciante y los teléfonos solo se entregan cuando la solicitud se confirma.',
    'anticretico': 'El anticrético es un contrato muy usado en Bolivia: entregas una suma de dinero al propietario y, a cambio, usas el inmueble sin pagar alquiler durante el plazo acordado; al terminar, el propietario te devuelve esa suma. Conviene formalizarlo por escrito y consultar con un abogado cómo se registra y qué garantías tienes.',
}
FAQ = {
    'venta': [
        ('¿Qué documentos debo revisar antes de comprar un inmueble?', 'Como mínimo: el Folio Real actualizado de Derechos Reales, el testimonio o escritura de propiedad, los impuestos al día y el plano o certificado catastral. Bastet puede acompañarte con la revisión registral y documental.'),
        ('¿Cómo contacto al anunciante de un inmueble?', 'Abre la ficha del inmueble y pulsa «Solicitar contacto». Los teléfonos no se publican en el sitio: se entregan cuando la solicitud se confirma.'),
        ('¿Todos los inmuebles de Bastet están verificados?', 'No. Bastet revisa las publicaciones y entrega distintivos de verificación solo a los agentes, propietarios y propiedades que completan el proceso. Busca el distintivo en la ficha y comprueba su código en bastet.uno/verificar.html.'),
    ],
    'alquiler': [
        ('¿Cómo solicito contacto para alquilar un inmueble?', 'Abre la ficha del inmueble y pulsa «Solicitar contacto». El anunciante recibe tu solicitud y, cuando se confirma, se te entrega su contacto.'),
        ('¿Qué conviene revisar antes de alquilar?', 'Pide el contrato por escrito, revisa el estado del inmueble antes de entregar dinero y aclara quién paga los servicios básicos y el mantenimiento.'),
        ('¿Todos los inmuebles de Bastet están verificados?', 'No. Bastet entrega distintivos de verificación solo a los agentes, propietarios y propiedades que completan el proceso. Busca el distintivo en la ficha y comprueba su código en bastet.uno/verificar.html.'),
    ],
    'anticretico': [
        ('¿Qué es el anticrético?', 'Es un contrato propio de Bolivia: entregas una suma de dinero al propietario y usas el inmueble sin pagar alquiler mientras dura el contrato; al terminar, el propietario te devuelve esa suma. Conviene formalizarlo por escrito.'),
        ('¿En qué se diferencia el anticrético del alquiler?', 'En el alquiler pagas una cuota periódica que no se devuelve. En el anticrético entregas una suma al inicio, no pagas cuota mensual por el uso y recuperas la suma al terminar el plazo.'),
        ('¿Todos los inmuebles de Bastet están verificados?', 'No. Bastet entrega distintivos de verificación solo a los agentes, propietarios y propiedades que completan el proceso. Busca el distintivo en la ficha y comprueba su código en bastet.uno/verificar.html.'),
    ],
}

esc = lambda s: html.escape(str(s if s is not None else ''), quote=True)


def slugify(s):
    import unicodedata
    s = unicodedata.normalize('NFKD', s).encode('ascii', 'ignore').decode()
    return re.sub(r'[^a-z0-9]+', '-', s.lower()).strip('-')


def city_slug(c):
    return CITY_ALIAS.get(c) or slugify(c)


def city_name(c):
    return CITY_SHORT.get(c, c)


def join_es(items):
    items = [i for i in items if i]
    if len(items) <= 1:
        return ''.join(items)
    return ', '.join(items[:-1]) + ' y ' + items[-1]


def plan(listings, g):
    """Decide qué páginas de categoría existen. `listings`: inmuebles clasificables (operación, tipo, ciudad, precio, foto)."""
    cands = []   # (prioridad, slug, meta, items)

    def add(prio, slug, meta, items, minimum):
        if len(items) >= minimum:
            cands.append((prio, slug, meta, items))

    for op in OPS:
        its = [p for p in listings if p['operation'] == op]
        add(0, f'propiedades-en-{op}-en-bolivia', {'kind': 'op', 'op': op}, its, 1)
    cities = sorted({g.city_of(p) for p in listings})
    for c in cities:
        its = [p for p in listings if g.city_of(p) == c]
        add(1, f'inmuebles-en-{city_slug(c)}', {'kind': 'city', 'city': c}, its, MIN_LISTINGS)
    for t in TYPE_PL:
        for op in OPS:
            its = [p for p in listings if p['property_type'] == t and p['operation'] == op]
            add(2, f'{TYPE_PL[t]}-en-{OP_NOUN[op]}', {'kind': 'type_op', 'op': op, 'tipo': t}, its, MIN_LISTINGS)
    for c in cities:
        for op in OPS:
            its = [p for p in listings if g.city_of(p) == c and p['operation'] == op]
            add(3, f'propiedades-en-{op}-en-{city_slug(c)}', {'kind': 'city_op', 'op': op, 'city': c}, its, MIN_LISTINGS)
    for c in cities:
        for t in TYPE_PL:
            for op in OPS:
                its = [p for p in listings if g.city_of(p) == c and p['property_type'] == t and p['operation'] == op]
                add(4, f'{TYPE_PL[t]}-en-{OP_NOUN[op]}-en-{city_slug(c)}', {'kind': 'city_type_op', 'op': op, 'city': c, 'tipo': t}, its, MIN_LISTINGS)
    cands.sort(key=lambda x: x[0])
    seen, hubs = {}, []
    for prio, slug, meta, items in cands:
        key = frozenset(p['code_number'] for p in items)
        if key in seen:
            continue   # mismo conjunto que una página más general: no se duplica
        seen[key] = slug
        hubs.append({'slug': slug, 'prio': prio, **meta, 'items': items})
    return hubs


def scope(h):
    """(h1, frase de lugar, etiqueta corta)."""
    k = h['kind']
    c = city_name(h.get('city', '')) if h.get('city') else 'Bolivia'
    if k == 'op':
        return f"Propiedades {OP_PHRASE[h['op']]} en Bolivia", 'en Bolivia'
    if k == 'city':
        return f'Inmuebles en {c}', f'en {c}'
    if k == 'type_op':
        return f"{TYPE_PL[h['tipo']].capitalize()} {OP_PHRASE[h['op']]} en Bolivia", 'en Bolivia'
    if k == 'city_op':
        return f"Propiedades {OP_PHRASE[h['op']]} en {c}", f'en {c}'
    return f"{TYPE_PL[h['tipo']].capitalize()} {OP_PHRASE[h['op']]} en {c}", f'en {c}'


def noun_phrase(h, n):
    t = h.get('tipo')
    if t:
        return TYPE_PL[t] if n != 1 else TYPE_SG[t]
    return 'inmuebles' if n != 1 else 'inmueble'


def prices_sentence(items, g):
    by = {}
    for p in items:
        digits = re.sub(r'[^0-9]', '', str(p.get('price') or ''))
        if digits:
            by.setdefault('BOB' if p.get('currency') == 'BOB' else 'USD', []).append(int(digits))
    parts = []
    for cur, vals in sorted(by.items()):
        f = lambda v, cur=cur: (f'Bs.- {v:,}' if cur == 'BOB' else f'{v:,} USD').replace(',', '.')
        lo, hi = min(vals), max(vals)
        rango = f(lo) if lo == hi else f'de {f(lo)} a {f(hi)}'
        parts.append(rango)
    return ('Precios publicados: ' + '; '.join(parts) + '.') if parts else ''


def breakdown(items):
    c = Counter(p['property_type'] for p in items)
    return join_es([f"{n} {TYPE_PL[t] if n != 1 else TYPE_SG[t]}" for t, n in c.most_common()])


CSS = """
:root{--green:#3D4C3A;--green-dark:#2F3B2D;--yellow:#F1BF46;--ink:#1E2629;--sand:#EEE6E0;--cloud:#F7F9FB}
*{box-sizing:border-box;margin:0;padding:0}
body{font-family:'Cabinet Grotesk','Helvetica Neue',Arial,sans-serif;color:var(--ink);background:#fff;line-height:1.6}
a{color:var(--green)}
header.top{display:flex;align-items:center;justify-content:space-between;gap:16px;flex-wrap:wrap;padding:14px clamp(16px,4vw,48px);border-bottom:1px solid rgba(30,38,41,.12)}
header.top img{height:42px;width:auto;display:block}
header.top nav{display:flex;gap:clamp(14px,2.4vw,30px);flex-wrap:wrap}
header.top nav a{text-decoration:none;font-size:15.5px}
main{max-width:1080px;margin:0 auto;padding:clamp(18px,3vw,40px) clamp(16px,4vw,32px) 56px}
.crumbs{font-size:14px;color:rgba(30,38,41,.66);margin-bottom:14px}
h1{font-family:'Conso',Georgia,serif;font-weight:400;color:var(--green);font-size:clamp(28px,4.4vw,46px);line-height:1.12}
h2{font-family:'Conso',Georgia,serif;font-weight:400;color:var(--green);font-size:clamp(22px,2.6vw,30px);margin:34px 0 12px;line-height:1.15}
h3{font-family:'Conso',Georgia,serif;font-weight:400;color:var(--green-dark);font-size:18px;line-height:1.25}
.intro p,.guide p{margin-top:12px;max-width:68ch}
.filters{display:flex;flex-wrap:wrap;gap:10px;align-items:end;margin:22px 0;padding:16px;background:var(--cloud);border-radius:16px}
.filters label{display:flex;flex-direction:column;gap:4px;font-size:13.5px;color:rgba(30,38,41,.7)}
.filters select{min-height:44px;padding:0 12px;border:1px solid rgba(30,38,41,.2);border-radius:10px;font:inherit;background:#fff;color:var(--ink)}
.btn{display:inline-flex;align-items:center;justify-content:center;min-height:46px;padding:0 24px;border-radius:999px;font-family:'Conso',Georgia,serif;font-size:16px;font-weight:500;text-decoration:none;border:1.5px solid var(--green);background:var(--green);color:#fff;cursor:pointer}
.btn:hover{background:var(--green-dark)}
.btn:focus-visible,a:focus-visible,select:focus-visible{outline:3px solid var(--yellow);outline-offset:3px}
.grid{display:grid;gap:18px;grid-template-columns:repeat(auto-fill,minmax(250px,1fr));margin-top:6px}
.card{border:1px solid rgba(30,38,41,.12);border-radius:16px;overflow:hidden;background:#fff}
.card a.l{display:block;text-decoration:none;color:inherit}
.card img{width:100%;aspect-ratio:4/3;object-fit:cover;display:block;background:var(--sand)}
.card .t{padding:14px 16px 16px}
.card .m{font-size:14px;color:rgba(30,38,41,.66);margin-top:2px}
.card .p{font-weight:600;margin-top:8px;color:var(--green)}
.more{display:flex;flex-wrap:wrap;gap:8px;margin-top:8px}
.more a{padding:7px 14px;border:1px solid rgba(61,76,58,.35);border-radius:999px;text-decoration:none;font-size:14.5px}
.more a:hover{background:var(--green);color:#fff}
.faq h3{margin-top:18px}.faq p{margin-top:6px;max-width:68ch}
footer{border-top:1px solid rgba(30,38,41,.12);padding:24px clamp(16px,4vw,48px);font-size:14.5px;color:rgba(30,38,41,.7)}
footer a{display:inline-block;padding:8px 6px;margin-right:8px}
@media(max-width:600px){.filters{flex-direction:column;align-items:stretch}.btn{width:100%}}
"""


def render(h, hubs, statics, g, SITE, today_mod, SB):
    """Devuelve (html, meta) de una página de categoría. `statics`: {code_number: url_de_ficha_estatica}."""
    items = h['items']
    n = len(items)
    h1, where = scope(h)
    slug = h['slug']
    url = f'{SITE}/{slug}/'
    k = h['kind']
    op = h.get('op')
    city = h.get('city')
    title = f"{h1}: {n} {'disponible' if n == 1 else 'disponibles'} · Bastet"
    noun = noun_phrase(h, n)
    opp = OP_PHRASE[op] if op else 'en venta, alquiler y anticrético'
    desc = f'{n} {noun} {opp} {where} en Bastet, con fotos y precios. Compara opciones y solicita contacto con el anunciante: los teléfonos se entregan al confirmar tu solicitud.'
    if len(desc) > 158:
        desc = desc[:157].rsplit(' ', 1)[0].rstrip(',;:. ') + '…'
    first_photo = next((p['photos'][0] for p in items if p.get('photos')), '')

    # ── Introducción con datos reales ──
    intro = f"Bastet reúne hoy {n} {noun} {opp} {where}"
    bd = breakdown(items) if not h.get('tipo') else ''
    intro += (f': {bd}.' if bd else '.')
    ps = prices_sentence(items, g)
    paras = [intro + (' ' + ps if ps else '')]
    if k == 'city':
        cnt = Counter(p['operation'] for p in items)
        parts = [f"{cnt[o]} {OP_PHRASE[o]}" for o in OPS if cnt.get(o)]
        paras.append(f"Por operación hay {join_es(parts)}. Cada inmueble tiene su ficha con fotos, precio y datos.")
    if op and k == 'op':
        paras.append(GUIDE[op])
    paras.append('Para contactar a un anunciante abre la ficha y pulsa «Solicitar contacto»: los teléfonos no se publican en el sitio.')

    # ── Filtros funcionales (envían a la búsqueda de Propiedades con los criterios) ──
    cities_all = sorted({g.city_of(p) for p in items} | ({city} if city else set()))
    def opt(v, label, sel):
        return f'<option value="{esc(v)}"{" selected" if sel else ""}>{esc(label)}</option>'
    f_op = ''.join([opt('', 'Cualquiera', not op)] + [opt(o, OP_NOUN[o].capitalize(), op == o) for o in OPS])
    f_tipo = ''.join([opt('', 'Cualquiera', not h.get('tipo'))] + [opt(t, TYPE_SG[t].capitalize(), h.get('tipo') == t) for t in TYPE_PL])
    f_city = ''.join([opt('', 'Todas', not city)] + [opt(c, city_name(c), city == c) for c in cities_all])
    form = (f'<form class="filters" action="/marketplace.html" method="get" aria-label="Filtrar inmuebles">'
            f'<label>Operación<select name="op">{f_op}</select></label>'
            f'<label>Tipo<select name="tipo">{f_tipo}</select></label>'
            f'<label>Ciudad<select name="ciudad">{f_city}</select></label>'
            f'<button class="btn" type="submit">Buscar con estos filtros</button></form>')

    cards = ''
    for i, p in enumerate(items):
        code = p['code_number']
        link = statics.get(code) or f"/marketplace.html?p=BST-{code}"
        ph = p['photos'][0]
        thumb = ph.replace('/storage/v1/object/public/', '/storage/v1/render/image/public/') + ('&' if '?' in ph else '?') + 'width=520&quality=72' if '/storage/v1/object/public/' in ph else ph
        alt = f"{clean_title(p)} · {TYPE_SG[p['property_type']]} {OP_PHRASE[p['operation']]} en {city_name(g.city_of(p))}"
        cards += (f'<article class="card"><a class="l" href="{esc(link)}"><img src="{esc(thumb)}" alt="{esc(alt)}" width="520" height="390" loading="{"eager" if i < 2 else "lazy"}"{' fetchpriority="high"' if i == 0 else ''} decoding="async">'
                  f'<div class="t"><h3>{esc(clean_title(p))}</h3><p class="m">{esc(TYPE_SG[p["property_type"]].capitalize())} {OP_PHRASE[p["operation"]]} en {esc(city_name(g.city_of(p)))}</p>'
                  f'<p class="p">{esc(g.price_text(p))}</p></div></a></article>')

    # ── Enlaces internos a otras categorías que sí existen ──
    def label(x):
        return f"{scope(x)[0]} ({len(x['items'])})"
    rel = [x for x in hubs if x['slug'] != slug and x['items'] and (
        (k == 'op' and x['kind'] in ('city', 'type_op') and (x.get('op') in (None, op))) or
        (k == 'city' and x.get('city') == city) or
        (k in ('type_op', 'city_op', 'city_type_op') and (x.get('op') == op or (city and x.get('city') == city))) )]
    rel = sorted(rel, key=lambda x: (x['prio'], x['slug']))[:14]
    more = ''.join(f'<a href="/{esc(x["slug"])}/">{esc(label(x))}</a>' for x in rel)

    # ── Migas de pan ──
    crumbs = [('Inicio', '/')]
    parent_op = next((x for x in hubs if x['kind'] == 'op' and x.get('op') == op), None) if op and k != 'op' else None
    parent_city = next((x for x in hubs if x['kind'] == 'city' and x.get('city') == city), None) if city and k not in ('city',) else None
    if parent_op: crumbs.append((scope(parent_op)[0], f"/{parent_op['slug']}/"))
    elif k in ('type_op',) and False: pass
    if parent_city: crumbs.append((scope(parent_city)[0], f"/{parent_city['slug']}/"))
    crumbs.append((h1, None))
    crumb_html = ' › '.join(f'<a href="{esc(u)}">{esc(t)}</a>' if u else esc(t) for t, u in crumbs)

    guide_link = ''
    if op and k != 'op' and parent_op:
        guide_link = f'<p>Antes de decidir, lee la <a href="/{esc(parent_op["slug"])}/">guía y las preguntas frecuentes sobre {OP_NOUN[op]}</a>.</p>'
    faq_html, faq_ld = '', None
    if k == 'op':
        faq_html = '<section class="faq" aria-labelledby="faq-t"><h2 id="faq-t">Preguntas frecuentes</h2>' + ''.join(f'<h3>{esc(q)}</h3><p>{esc(a)}</p>' for q, a in FAQ[op]) + '</section>'
        faq_ld = {'@context': 'https://schema.org', '@type': 'FAQPage', 'mainEntity': [{'@type': 'Question', 'name': q, 'acceptedAnswer': {'@type': 'Answer', 'text': a}} for q, a in FAQ[op]]}

    item_list = [{'@type': 'ListItem', 'position': i + 1, 'url': (SITE + (statics.get(p['code_number']) or f"/marketplace.html?p=BST-{p['code_number']}")), 'name': clean_title(p)} for i, p in enumerate(items)]
    ld = [
        {'@context': 'https://schema.org', '@type': 'CollectionPage', '@id': url, 'url': url, 'name': h1, 'description': desc, 'inLanguage': 'es',
         'isPartOf': {'@id': SITE + '/#web'}, 'dateModified': today_mod,
         'mainEntity': {'@type': 'ItemList', 'numberOfItems': n, 'itemListElement': item_list}},
        {'@context': 'https://schema.org', '@type': 'BreadcrumbList', 'itemListElement': [
            {'@type': 'ListItem', 'position': i + 1, 'name': t, 'item': SITE + (u if u else f'/{slug}/')} for i, (t, u) in enumerate(crumbs)]},
    ]
    if faq_ld:
        ld.append(faq_ld)
    ld_html = ''.join('<script type="application/ld+json">' + json.dumps(x, ensure_ascii=False) + '</script>\n' for x in ld)

    page = f'''<!DOCTYPE html>
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
<meta property="og:image" content="{esc(first_photo)}">
<meta name="twitter:card" content="summary_large_image">
<meta name="twitter:title" content="{esc(title)}">
<meta name="twitter:description" content="{esc(desc)}">
<meta name="twitter:image" content="{esc(first_photo)}">
<link rel="icon" type="image/png" sizes="32x32" href="/assets/img/bastet-favicon-32.png?v=20261026">
<link rel="apple-touch-icon" href="/assets/img/bastet-apple-touch.png?v=20261026">
<link rel="manifest" href="/manifest.json">
<meta name="theme-color" content="#FFFFFF">
<link rel="preload" href="/assets/fonts/Conso-Regular.woff2" as="font" type="font/woff2" crossorigin>
<link rel="stylesheet" href="/assets/css/fonts.css?v=20261014b">
{ld_html}<style>{CSS}</style>
</head>
<body>
<header class="top">
  <a href="/" aria-label="Bastet, ir al inicio"><img src="/assets/img/bastet-logo-horizontal-color.webp" alt="Bastet · Propiedades · Inmobiliarias" width="1200" height="298"></a>
  <nav aria-label="Principal"><a href="/">Inicio</a><a href="/marketplace.html">Propiedades</a><a href="/estadias.html">Estadías</a><a href="/empresas.html">Empresas</a><a href="/sobre-bastet/">Sobre Bastet</a></nav>
</header>
<main>
  <p class="crumbs">{crumb_html}</p>
  <h1>{esc(h1)}</h1>
  <div class="intro">{''.join(f'<p>{esc(x)}</p>' for x in paras)}{guide_link}</div>
  {form}
  <h2>Inmuebles disponibles</h2>
  <div class="grid">{cards}</div>
  {'<h2>Más búsquedas</h2><div class="more">' + more + '</div>' if more else ''}
  {faq_html}
  <p style="margin-top:28px"><a class="btn" href="/marketplace.html">Ver todas las propiedades</a></p>
</main>
<footer>
  <a href="/">Inicio</a><a href="/inmueble/">Inmuebles publicados</a><a href="/sobre-bastet/">Sobre Bastet</a><a href="/privacidad.html">Política de privacidad</a><a href="/terminos.html">Términos de uso</a>
  <p style="margin-top:10px">© 2026 Bastet Real State S.R.L. · inmobiliaria@bastet.uno</p>
</footer>
</body>
</html>
'''
    return page, {'url': url, 'title': h1, 'n': n}


def clean_title(p):
    return re.sub(r'\s+', ' ', (p.get('title') or '').strip())


def about_page(SITE):
    """Página institucional (/sobre-bastet/): información consistente y verificable sobre la marca, para buscadores y asistentes de IA."""
    url = f'{SITE}/sobre-bastet/'
    title = 'Sobre Bastet: marketplace inmobiliario de Bolivia'
    desc = 'Bastet es un marketplace inmobiliario de Bolivia: compra, alquiler, anticrético y estadías por noche, con revisión documental, verificación y contacto protegido.'
    secciones = [
        ('Qué es Bastet', [
            'Bastet es un marketplace inmobiliario de Bolivia que conecta compradores, vendedores, propietarios y personas que buscan propiedades. En bastet.uno puedes explorar inmuebles, consultar publicaciones y solicitar contacto con los anunciantes.',
            'Su diferencial es complementar la comercialización inmobiliaria con servicios de verificación registral, revisión documental y acompañamiento en operaciones inmobiliarias.']),
        ('Qué puedes hacer en el sitio', [
            'Buscar casas, departamentos, habitaciones y terrenos en venta, alquiler y anticrético; reservar estadías por noche; publicar un inmueble; y, si eres una empresa, pedir alojamiento para tu equipo, alquilar espacios para operar o comprar inmuebles.']),
        ('Cómo funciona el contacto', [
            'Los teléfonos de propietarios y agentes no se publican. Desde la ficha de cada inmueble se pulsa «Solicitar contacto» y, cuando la solicitud se confirma, se entrega el contacto del anunciante.']),
        ('Qué significa «verificado» en Bastet', [
            'Bastet no afirma que todas las propiedades estén verificadas. Entrega distintivos de verificación independientes a agentes, propietarios y propiedades que completan un proceso de revisión de documentos; los demás inmuebles se muestran como publicaciones revisadas. Cualquier distintivo, reserva o solicitud se puede comprobar con su código en bastet.uno/verificar.html.']),
        ('Datos de la empresa', [
            'Razón social: Bastet Real State S.R.L. Dirección: Calle Yanacocha, Edif. Cristal, Piso 7, Of. 706, La Paz, Bolivia. Correo: inmobiliaria@bastet.uno. Teléfono: +591 77666205.']),
    ]
    faq = [
        ('¿Qué es Bastet?', 'Es un marketplace inmobiliario de Bolivia para comprar, alquilar, tomar en anticrético y reservar estadías por noche, con revisión documental y contacto protegido.'),
        ('¿Dónde opera Bastet?', 'El sitio permite publicar y buscar inmuebles de Bolivia. La oficina está en La Paz.'),
        ('¿Todos los inmuebles están verificados?', 'No. Solo los agentes, propietarios y propiedades que completan el proceso de verificación reciben el distintivo.'),
    ]
    ld = [
        {'@context': 'https://schema.org', '@type': 'AboutPage', '@id': url, 'url': url, 'name': title, 'inLanguage': 'es', 'about': {'@id': SITE + '/#org'}, 'isPartOf': {'@id': SITE + '/#web'}},
        {'@context': 'https://schema.org', '@type': 'FAQPage', 'mainEntity': [{'@type': 'Question', 'name': q, 'acceptedAnswer': {'@type': 'Answer', 'text': a}} for q, a in faq]},
        {'@context': 'https://schema.org', '@type': 'BreadcrumbList', 'itemListElement': [
            {'@type': 'ListItem', 'position': 1, 'name': 'Inicio', 'item': SITE + '/'}, {'@type': 'ListItem', 'position': 2, 'name': 'Sobre Bastet', 'item': url}]},
    ]
    ld_html = ''.join('<script type="application/ld+json">' + json.dumps(x, ensure_ascii=False) + '</script>\n' for x in ld)
    body = ''.join(f'<h2>{esc(h)}</h2>' + ''.join(f'<p>{esc(t)}</p>' for t in ps) for h, ps in secciones)
    faq_html = '<section class="faq" aria-labelledby="faq-t"><h2 id="faq-t">Preguntas frecuentes</h2>' + ''.join(f'<h3>{esc(q)}</h3><p>{esc(a)}</p>' for q, a in faq) + '</section>'
    return f'''<!DOCTYPE html>
<html lang="es">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{esc(title)} · Bastet</title>
<meta name="description" content="{esc(desc)}">
<link rel="canonical" href="{url}">
<meta property="og:type" content="website">
<meta property="og:site_name" content="Bastet">
<meta property="og:locale" content="es_BO">
<meta property="og:url" content="{url}">
<meta property="og:title" content="{esc(title)}">
<meta property="og:description" content="{esc(desc)}">
<meta property="og:image" content="{SITE}/assets/img/hero-familia.webp">
<meta name="twitter:card" content="summary_large_image">
<link rel="icon" type="image/png" sizes="32x32" href="/assets/img/bastet-favicon-32.png?v=20261026">
<link rel="apple-touch-icon" href="/assets/img/bastet-apple-touch.png?v=20261026">
<link rel="manifest" href="/manifest.json">
<link rel="preload" href="/assets/fonts/Conso-Regular.woff2" as="font" type="font/woff2" crossorigin>
<link rel="stylesheet" href="/assets/css/fonts.css?v=20261014b">
{ld_html}<style>{CSS}</style>
</head>
<body>
<header class="top">
  <a href="/" aria-label="Bastet, ir al inicio"><img src="/assets/img/bastet-logo-horizontal-color.webp" alt="Bastet · Propiedades · Inmobiliarias" width="1200" height="298"></a>
  <nav aria-label="Principal"><a href="/">Inicio</a><a href="/marketplace.html">Propiedades</a><a href="/estadias.html">Estadías</a><a href="/empresas.html">Empresas</a><a href="/sobre-bastet/">Sobre Bastet</a></nav>
</header>
<main>
  <p class="crumbs"><a href="/">Inicio</a> › Sobre Bastet</p>
  <h1>Sobre Bastet</h1>
  <div class="intro guide">{body}</div>
  {faq_html}
  <p style="margin-top:28px"><a class="btn" href="/marketplace.html">Ver propiedades</a></p>
</main>
<footer>
  <a href="/">Inicio</a><a href="/inmueble/">Inmuebles publicados</a><a href="/privacidad.html">Política de privacidad</a><a href="/terminos.html">Términos de uso</a>
  <p style="margin-top:10px">© 2026 Bastet Real State S.R.L. · inmobiliaria@bastet.uno</p>
</footer>
</body>
</html>
'''
