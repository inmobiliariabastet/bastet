"""Páginas públicas del blog de Bastet (/blog/ y /blog/<entrada>/), generadas por tools/gen_property_pages.py.

Origen de las entradas:
  1) La tabla blog_posts de Supabase (las que se escriben en el panel: Admin → Blog). Solo las publicadas y con fecha ya cumplida.
  2) Si esa tabla todavía no existe (no se corrió supabase/blog.sql), se usan las 3 entradas iniciales de content/blog/*.md.
Cada entrada lleva su propio título, descripción, canonical, Open Graph, datos estructurados (BlogPosting, BreadcrumbList y FAQPage si tiene
una sección «Preguntas frecuentes»), tabla de contenidos, entradas relacionadas y enlaces a las categorías de inmuebles.
"""
import glob
import html
import json
import re
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

import blog_md as B

ROOT = Path(__file__).resolve().parent.parent
CAT_LABEL = {'compra-segura': 'Compra segura', 'anticretico': 'Anticrético', 'verificacion': 'Verificación de títulos', 'general': 'General'}
MESES = ['enero', 'febrero', 'marzo', 'abril', 'mayo', 'junio', 'julio', 'agosto', 'septiembre', 'octubre', 'noviembre', 'diciembre']
esc = lambda s: html.escape(str(s if s is not None else ''), quote=True)

BLOG_CSS = """
.bl-hero{margin:0 0 6px}.bl-lead{margin-top:12px;max-width:62ch;font-size:clamp(16px,1.6vw,18.5px)}
.bl-grid{display:grid;gap:22px;grid-template-columns:repeat(auto-fill,minmax(300px,1fr));margin-top:26px}
.bl-card{border:1px solid rgba(30,38,41,.12);border-radius:18px;overflow:hidden;background:#fff;display:flex;flex-direction:column}
.bl-card a.l{display:flex;flex-direction:column;height:100%;text-decoration:none;color:inherit}
.bl-card img{width:100%;height:auto;aspect-ratio:1200/630;object-fit:cover;display:block;background:var(--sand)}
.bl-card .t{padding:16px 18px 20px;display:flex;flex-direction:column;gap:8px;flex:1}
.bl-card h2,.bl-card h3{font-size:21px;margin:0;line-height:1.2}.bl-card p{margin:0;color:rgba(30,38,41,.78);font-size:15.5px}
.bl-chip{display:inline-block;align-self:flex-start;padding:3px 12px;border-radius:999px;background:#EFF8E7;color:var(--green);font-size:13px}
.bl-meta{font-size:14px;color:rgba(30,38,41,.62)}
.bl-art{max-width:780px;margin:0 auto}
.bl-art h1{margin-top:6px}
.bl-art .cover{margin:20px 0 8px;border-radius:18px;overflow:hidden}
.bl-art .cover img{width:100%;height:auto;aspect-ratio:1200/630;object-fit:cover;display:block;background:var(--sand)}
.bl-toc{margin:18px 0;padding:14px 20px;background:var(--cloud);border-radius:14px}.bl-toc summary{cursor:pointer;font-weight:600}
.bl-toc ol{margin:10px 0 2px 20px}.bl-toc li{margin:4px 0}
.bl-body{font-size:17.5px;line-height:1.75}
.bl-body h2{margin:38px 0 10px}.bl-body h3{margin:26px 0 6px}
.bl-body p{margin:14px 0;max-width:none}.bl-body ul,.bl-body ol{margin:12px 0 12px 24px}.bl-body li{margin:6px 0}
.bl-body blockquote{margin:18px 0;padding:12px 18px;border-left:4px solid var(--yellow);background:#FFFBEF;border-radius:0 12px 12px 0}.bl-body blockquote p{margin:0}
.bl-body figure{margin:22px 0}.bl-body figure img{width:100%;height:auto;border-radius:14px;display:block}.bl-body figcaption{font-size:14px;color:rgba(30,38,41,.62);margin-top:6px}
.bl-body hr{border:0;border-top:1px solid rgba(30,38,41,.14);margin:30px 0}
.bl-body code{background:var(--cloud);padding:1px 6px;border-radius:6px;font-size:.92em}
.bl-body .tbl{overflow-x:auto;margin:18px 0}.bl-body table{border-collapse:collapse;width:100%;min-width:480px;font-size:16px}
.bl-body th,.bl-body td{border:1px solid rgba(30,38,41,.14);padding:9px 12px;text-align:left;vertical-align:top}.bl-body th{background:var(--cloud)}
.bl-cta{margin:38px 0 10px;padding:22px;border-radius:18px;background:var(--green);color:#fff}
.bl-cta h2{color:#fff;margin:0 0 8px;font-size:24px}.bl-cta p{margin:0 0 14px;max-width:60ch;color:rgba(255,255,255,.92)}
.bl-cta .row{display:flex;flex-wrap:wrap;gap:10px}
.bl-cta a{display:inline-flex;align-items:center;min-height:46px;padding:0 22px;border-radius:999px;background:var(--yellow);color:var(--ink);text-decoration:none;font-family:'Conso',Georgia,serif;font-size:16px;font-weight:500}
.bl-cta a.line{background:transparent;color:#fff;border:1.5px solid #fff}
.bl-cta a:focus-visible{outline:3px solid #fff;outline-offset:3px}
@media(max-width:600px){.bl-body{font-size:17px}.bl-cta a{width:100%;justify-content:center}}
"""


def fmt_date(iso):
    d = datetime.fromisoformat(str(iso).replace('Z', '+00:00')).astimezone(timezone.utc)
    return f'{d.day} de {MESES[d.month - 1]} de {d.year}', d.strftime('%Y-%m-%d')


def seed_posts():
    posts = []
    for f in sorted(glob.glob(str(ROOT / 'content' / 'blog' / '*.md'))):
        meta, body = B.parse_front_matter(Path(f).read_text(encoding='utf-8'))
        posts.append({'slug': meta['slug'], 'title': meta['title'], 'excerpt': meta['excerpt'], 'body_md': body, 'cover_url': meta.get('cover'),
                      'cover_alt': meta.get('cover_alt', ''), 'category': meta.get('category', 'general'), 'author_name': meta.get('author', 'Equipo Bastet'),
                      'published_at': meta['published_at'] + 'T12:00:00-04:00', 'updated_at': meta['published_at'] + 'T12:00:00-04:00'})
    return posts


def fetch_posts(g):
    """Entradas publicadas desde Supabase. Devuelve None si la tabla no existe todavía."""
    now = datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
    cols = 'slug,title,excerpt,body_md,cover_url,cover_alt,category,author_name,published_at,updated_at'
    url = (f'{g.SB_URL}/rest/v1/blog_posts?select={cols}&status=eq.published&published_at=lte.{urllib.parse.quote(now)}&order=published_at.desc')
    req = urllib.request.Request(url, headers={'apikey': g.SB_KEY, 'Authorization': 'Bearer ' + g.SB_KEY})
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return json.load(r)
    except urllib.error.HTTPError:
        return None
    except Exception:
        return None


def load(g):
    posts = fetch_posts(g)
    if posts is None:
        print('Blog: la tabla blog_posts aún no existe; se usan las entradas iniciales de content/blog.')
        return seed_posts()
    return posts


def cover_src(c, w):
    """Ruta de la portada para el HTML (absoluta del sitio) y miniatura si está en Supabase."""
    if not c:
        return ''
    if c.startswith('http'):
        return c.replace('/storage/v1/object/public/', '/storage/v1/render/image/public/') + ('&' if '?' in c else '?') + f'width={w}&quality=75' if '/storage/v1/object/public/' in c else c
    return '/' + c.lstrip('/')


def cover_abs(c, SITE):
    if not c:
        return SITE + '/assets/img/hero-familia.webp'
    return c if c.startswith('http') else SITE + '/' + c.lstrip('/')


def img_fn_factory(g):
    def fn(alt, url):
        src = g.thumb(url, 1000) if url.startswith('http') else url
        if not src.startswith(('http', '/')):
            src = '/' + src
        return f'<img src="{esc(src)}" alt="{esc(alt)}" loading="lazy" decoding="async">'
    return fn


def head(H, SITE, url, title, desc, og_image, og_type='website', extra_meta='', ld=''):
    return f'''<!DOCTYPE html>
<html lang="es">
<head>
<meta charset="utf-8">
{H.GTAG}
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{esc(title)}</title>
<meta name="description" content="{esc(desc)}">
<link rel="canonical" href="{esc(url)}">
<meta property="og:type" content="{og_type}">
<meta property="og:site_name" content="Bastet">
<meta property="og:locale" content="es_BO">
<meta property="og:url" content="{esc(url)}">
<meta property="og:title" content="{esc(title)}">
<meta property="og:description" content="{esc(desc)}">
<meta property="og:image" content="{esc(og_image)}">
{extra_meta}<meta name="twitter:card" content="summary_large_image">
<meta name="twitter:title" content="{esc(title)}">
<meta name="twitter:description" content="{esc(desc)}">
<meta name="twitter:image" content="{esc(og_image)}">
<link rel="icon" type="image/png" sizes="32x32" href="/assets/img/bastet-favicon-32.png?v=20261026">
<link rel="apple-touch-icon" href="/assets/img/bastet-apple-touch.png?v=20261026">
<link rel="manifest" href="/manifest.json">
<meta name="theme-color" content="#FFFFFF">
<link rel="preload" href="/assets/fonts/Conso-Regular.woff2" as="font" type="font/woff2" crossorigin>
<link rel="stylesheet" href="/assets/css/fonts.css?v=20261014b">
{ld}<style>{H.CSS}{BLOG_CSS}</style>
</head>
'''


CHROME_TOP = '''<body>
<header class="top">
  <a href="/" aria-label="Bastet, ir al inicio"><img src="/assets/img/bastet-logo-horizontal-color.webp" srcset="/assets/img/bastet-logo-horizontal-color-480.webp 480w, /assets/img/bastet-logo-horizontal-color.webp 800w" sizes="230px" alt="Bastet · Propiedades · Inmobiliarias" width="1200" height="298"></a>
  <nav aria-label="Principal"><a href="/">Inicio</a><a href="/marketplace.html">Propiedades</a><a href="/estadias.html">Estadías</a><a href="/empresas.html">Empresas</a><a href="/blog/">Blog</a><a href="/sobre-bastet/">Sobre Bastet</a></nav>
</header>
'''
CHROME_BOTTOM = '''<footer>
  <a href="/">Inicio</a><a href="/blog/">Blog</a><a href="/inmueble/">Inmuebles publicados</a><a href="/sobre-bastet/">Sobre Bastet</a><a href="/privacidad.html">Política de privacidad</a><a href="/terminos.html">Términos de uso</a>
  <p style="margin-top:10px">© 2026 Bastet Real State S.R.L. · inmobiliaria@bastet.uno</p>
</footer>
</body>
</html>
'''


def render_post(g, H, SITE, post, posts, hubs):
    slug = post['slug']
    url = f'{SITE}/blog/{slug}/'
    md = post['body_md']
    body_html, toc, faq, words = B.render(md, img_fn_factory(g))
    mins = B.reading_minutes(words)
    pub_txt, pub_iso = fmt_date(post['published_at'])
    mod_txt, mod_iso = fmt_date(post.get('updated_at') or post['published_at'])
    cat = CAT_LABEL.get(post.get('category'), 'General')
    title_tag = post['title'] if len(post['title']) + 9 > 70 else post['title'] + ' · Bastet'
    desc = ' '.join(post['excerpt'].split())
    og_img = cover_abs(post.get('cover_url'), SITE)
    author = post.get('author_name') or 'Equipo Bastet'
    author_ld = {'@type': 'Organization', 'name': 'Bastet', '@id': SITE + '/#org'} if author.strip().lower() in ('equipo bastet', 'bastet') else {'@type': 'Person', 'name': author}
    ld = [{'@context': 'https://schema.org', '@type': 'BlogPosting', '@id': url + '#post', 'mainEntityOfPage': {'@type': 'WebPage', '@id': url}, 'headline': post['title'][:110],
           'description': desc, 'image': [og_img], 'datePublished': post['published_at'], 'dateModified': post.get('updated_at') or post['published_at'], 'inLanguage': 'es',
           'author': author_ld, 'publisher': {'@id': SITE + '/#org'}, 'articleSection': cat, 'wordCount': words, 'isPartOf': {'@type': 'Blog', '@id': SITE + '/blog/', 'name': 'Blog de Bastet'}},
          {'@context': 'https://schema.org', '@type': 'BreadcrumbList', 'itemListElement': [
              {'@type': 'ListItem', 'position': 1, 'name': 'Inicio', 'item': SITE + '/'}, {'@type': 'ListItem', 'position': 2, 'name': 'Blog', 'item': SITE + '/blog/'},
              {'@type': 'ListItem', 'position': 3, 'name': post['title'], 'item': url}]}]
    if faq:
        ld.append({'@context': 'https://schema.org', '@type': 'FAQPage', 'mainEntity': [{'@type': 'Question', 'name': q, 'acceptedAnswer': {'@type': 'Answer', 'text': a}} for q, a in faq]})
    ld_html = ''.join('<script type="application/ld+json">' + json.dumps(x, ensure_ascii=False) + '</script>\n' for x in ld)
    extra = (f'<meta property="article:published_time" content="{esc(post["published_at"])}">\n<meta property="article:modified_time" content="{esc(post.get("updated_at") or post["published_at"])}">\n'
             f'<meta property="article:section" content="{esc(cat)}">\n')
    toc_html = ''
    if len(toc) >= 3:
        toc_html = '<details class="bl-toc" open><summary>En esta guía</summary><ol>' + ''.join(f'<li><a href="#{esc(i)}">{esc(t)}</a></li>' for i, t in toc) + '</ol></details>'
    cover_html = ''
    if post.get('cover_url'):
        cover_html = f'<div class="cover"><img src="{esc(cover_src(post["cover_url"], 1200))}" alt="{esc(post.get("cover_alt") or post["title"])}" width="1200" height="630" fetchpriority="high" decoding="async"></div>'
    others = [p for p in posts if p['slug'] != slug][:3]
    rel_html = ''
    if others:
        rel_html = '<h2>Sigue leyendo</h2><div class="bl-grid">' + ''.join(card(g, p) for p in others) + '</div>'
    ops = [(h, H.scope(h)[0]) for h in hubs if h['kind'] == 'op']
    cta_links = ''.join(f'<a href="/{esc(h["slug"])}/">{esc(t)}</a>' for h, t in ops[:3]) or '<a href="/marketplace.html">Ver propiedades</a>'
    cta = ('<aside class="bl-cta"><h2>¿Quieres comprar o alquilar con respaldo?</h2>'
           '<p>En Bastet encuentras inmuebles en venta, alquiler y anticrético, con revisión documental y verificación registral. Los teléfonos no se publican: se entregan cuando tu solicitud se confirma.</p>'
           f'<div class="row">{cta_links}<a class="line" href="/verificar.html">Verificar un código</a></div></aside>')
    page = (head(H, SITE, url, title_tag, desc, og_img, 'article', extra, ld_html) + CHROME_TOP +
            f'<main>\n<article class="bl-art">\n<p class="crumbs"><a href="/">Inicio</a> › <a href="/blog/">Blog</a> › {esc(post["title"])}</p>\n'
            f'<span class="bl-chip">{esc(cat)}</span>\n<h1>{esc(post["title"])}</h1>\n'
            f'<p class="bl-meta">Por {esc(author)} · <time datetime="{pub_iso}">{pub_txt}</time>' + (f' · Actualizado el <time datetime="{mod_iso}">{mod_txt}</time>' if mod_iso != pub_iso else '') + f' · {mins} min de lectura</p>\n'
            f'{cover_html}\n{toc_html}\n<div class="bl-body">\n{body_html}\n</div>\n{cta}\n{rel_html}\n</article>\n</main>\n' + CHROME_BOTTOM)
    return page


def card(g, p):
    pub_txt, pub_iso = fmt_date(p['published_at'])
    img = ''
    if p.get('cover_url'):
        img = f'<img src="{esc(cover_src(p["cover_url"], 700))}" alt="{esc(p.get("cover_alt") or p["title"])}" width="1200" height="630" loading="lazy" decoding="async">'
    return (f'<article class="bl-card"><a class="l" href="/blog/{esc(p["slug"])}/">{img}<div class="t"><span class="bl-chip">{esc(CAT_LABEL.get(p.get("category"), "General"))}</span>'
            f'<h3>{esc(p["title"])}</h3><p>{esc(p["excerpt"])}</p><span class="bl-meta"><time datetime="{pub_iso}">{pub_txt}</time></span></div></a></article>')


def render_index(g, H, SITE, posts):
    url = SITE + '/blog/'
    title = 'Blog de Bastet: compra segura, anticrético y verificación de títulos'
    desc = 'Guías prácticas para comprar con seguridad en Bolivia, entender el anticrético y verificar el título de un inmueble, escritas por el equipo de Bastet.'
    og = cover_abs(posts[0].get('cover_url') if posts else None, SITE)
    ld = [{'@context': 'https://schema.org', '@type': 'Blog', '@id': url, 'url': url, 'name': 'Blog de Bastet', 'description': desc, 'inLanguage': 'es', 'publisher': {'@id': SITE + '/#org'},
           'blogPost': [{'@type': 'BlogPosting', 'headline': p['title'], 'url': f'{SITE}/blog/{p["slug"]}/', 'datePublished': p['published_at'], 'image': cover_abs(p.get('cover_url'), SITE)} for p in posts]},
          {'@context': 'https://schema.org', '@type': 'BreadcrumbList', 'itemListElement': [{'@type': 'ListItem', 'position': 1, 'name': 'Inicio', 'item': SITE + '/'}, {'@type': 'ListItem', 'position': 2, 'name': 'Blog', 'item': url}]}]
    ld_html = ''.join('<script type="application/ld+json">' + json.dumps(x, ensure_ascii=False) + '</script>\n' for x in ld)
    cards = ''.join(card(g, p) for p in posts) or '<p>Pronto publicaremos nuestras primeras guías.</p>'
    return (head(H, SITE, url, title, desc, og, 'website', '', ld_html) + CHROME_TOP +
            '<main>\n<p class="crumbs"><a href="/">Inicio</a> › Blog</p>\n<div class="bl-hero"><h1>Blog de Bastet</h1>\n'
            '<p class="bl-lead">Guías claras para comprar con seguridad en Bolivia, entender el anticrético y verificar el título de un inmueble. Información general escrita por el equipo de Bastet; no reemplaza la asesoría de un abogado.</p></div>\n'
            f'<div class="bl-grid">{cards}</div>\n</main>\n' + CHROME_BOTTOM)
