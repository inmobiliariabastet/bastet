#!/usr/bin/env python3
"""IndexNow: avisa a Bing (y a los buscadores que lo aceptan: Yandex, Naver, Seznam...) de las páginas nuevas, cambiadas o retiradas.
Google NO usa IndexNow: para Google sirven el sitemap y Search Console.

Uso (desde la raíz del repo):
  python tools/indexnow.py --all                 envía todas las URLs del sitemap (primer envío o reenvío completo)
  python tools/indexnow.py --diff-head ARCHIVO   guarda en ARCHIVO las URLs nuevas, cambiadas o retiradas del sitemap respecto al último commit
  python tools/indexnow.py --submit ARCHIVO      envía las URLs guardadas en ARCHIVO
  python tools/indexnow.py --urls URL [URL...]   envía las URLs indicadas

La clave es pública por diseño: va en un archivo <clave>.txt en la raíz del sitio, que es lo que IndexNow usa para comprobar que el sitio es tuyo.
Lo usa la tarea diaria de GitHub (.github/workflows/inmuebles.yml) después de publicar cambios.
"""
import json
import re
import subprocess
import sys
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
HOST = 'bastet.uno'
SITE = 'https://' + HOST
ENDPOINT = 'https://api.indexnow.org/indexnow'


def find_key():
    for f in ROOT.glob('*.txt'):
        if re.fullmatch(r'[0-9a-f]{32}', f.stem) and f.read_text(encoding='utf-8').strip() == f.stem:
            return f.stem
    sys.exit('No se encontró el archivo de clave IndexNow (<32 hex>.txt) en la raíz.')


def sitemap_map(text):
    return {m[0]: m[1] for m in re.findall(r'<loc>([^<]+)</loc>\s*<lastmod>([^<]+)</lastmod>', text)}


def diff_head():
    new = sitemap_map((ROOT / 'sitemap.xml').read_text(encoding='utf-8'))
    try:
        old_txt = subprocess.check_output(['git', 'show', 'HEAD:sitemap.xml'], cwd=ROOT).decode('utf-8')
    except subprocess.CalledProcessError:
        old_txt = ''
    old = sitemap_map(old_txt)
    changed = [u for u, m in new.items() if old.get(u) != m]
    removed = [u for u in old if u not in new]
    return changed + removed


def submit(urls):
    urls = [u for u in dict.fromkeys(urls) if u.startswith(SITE + '/') or u == SITE + '/']
    if not urls:
        print('IndexNow: no hay URLs que enviar.')
        return 0
    key = find_key()
    body = json.dumps({'host': HOST, 'key': key, 'keyLocation': f'{SITE}/{key}.txt', 'urlList': urls[:10000]}).encode('utf-8')
    req = urllib.request.Request(ENDPOINT, data=body, headers={'Content-Type': 'application/json; charset=utf-8'}, method='POST')
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            print(f'IndexNow: {len(urls)} URLs enviadas (HTTP {r.status}).')
            return 0
    except urllib.error.HTTPError as e:
        # 200/202 = recibido; 403 = clave no verificada todavía; 422 = URLs que no son del sitio; 429 = demasiados envíos
        print(f'IndexNow: respuesta HTTP {e.code}: {e.read().decode("utf-8", "ignore")[:200]}')
        return 0 if e.code in (200, 202) else 1


def main(argv):
    if not argv:
        print(__doc__)
        return 1
    if argv[0] == '--all':
        new = sitemap_map((ROOT / 'sitemap.xml').read_text(encoding='utf-8'))
        return submit(list(new))
    if argv[0] == '--diff-head' and len(argv) > 1:
        urls = diff_head()
        Path(argv[1]).write_text(json.dumps(urls), encoding='utf-8')
        print(f'IndexNow: {len(urls)} URLs nuevas, cambiadas o retiradas.')
        return 0
    if argv[0] == '--submit' and len(argv) > 1:
        return submit(json.loads(Path(argv[1]).read_text(encoding='utf-8')))
    if argv[0] == '--urls':
        return submit(argv[1:])
    print(__doc__)
    return 1


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
