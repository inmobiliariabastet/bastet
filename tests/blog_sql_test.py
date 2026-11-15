"""Pruebas de supabase/blog.sql: tabla del blog, permisos (público solo ve lo publicado; solo administración escribe), fechas automáticas,
entradas iniciales sin duplicar al volver a correr el SQL, y bucket de fotos.
Requiere:  pip install pgserver psycopg2-binary   y se ejecuta con:  python tests/blog_sql_test.py
Levanta un Postgres local desechable: NO toca Supabase ni producción."""
import pgserver, psycopg2, sys, tempfile, pathlib
ROOT = pathlib.Path(__file__).resolve().parent.parent
srv = pgserver.get_server(tempfile.mkdtemp(prefix='uno-pg-'), cleanup_mode='delete')
uri = srv.get_uri()
R_ = str(ROOT / "supabase") + "/"
sch = open(R_ + "schema.sql", encoding='utf-8').read()
blog = open(R_ + "blog.sql", encoding="utf-8").read()
assert blog.strip().replace('\r', '') in sch.replace('\r', ''), "blog.sql no está igual a su bloque en schema.sql (correr tools/sync_sql.py blog.sql)"
stub = open(str(ROOT / 'tests' / 'stay_bookings_sql_test.py'), encoding='utf-8').read()
stub = stub[stub.index('stub = """') + 10:]; stub = stub[:stub.index('"""')]
c = psycopg2.connect(uri); c.autocommit = True; cur = c.cursor()
def su(sql, args=None):
    cur.execute("reset role; select set_config('request.jwt.claim.sub','',false); select set_config('request.headers','',false)"); cur.execute(sql, args)
cur.execute(stub); cur.execute(sch)
print("esquema completo aplicado")
cur.execute("insert into auth.users(email,invited_at) values ('admin@x','2026-01-01'),('user@x','2026-01-01') returning id")
adm, usr = [r[0] for r in cur.fetchall()]
su("update public.profiles set role='admin' where id=%s", (adm,))
fails = 0
def as_(uid, sql, args=None):
    cur.execute("reset role; select set_config('request.jwt.claim.sub',%s,false); select set_config('request.headers','',false)", (str(uid) if uid else '',))
    cur.execute("set role authenticated" if uid else "set role anon")
    try:
        cur.execute(sql, args)
        rc = cur.rowcount
        try: return ('ok', cur.fetchall())
        except psycopg2.ProgrammingError: return ('ok', rc)
    except Exception as e: return ('ERR', str(e).splitlines()[0])
def chk(name, res, expect_err):
    global fails
    good = (res[0] == 'ERR') == expect_err
    if not good: fails += 1
    print(('PASS' if good else 'FAIL'), name, '->', str(res)[:150])
def eq(name, got, want):
    global fails
    good = got == want
    if not good: fails += 1
    print(('PASS' if good else 'FAIL'), name, '->', got)

BODY = 'Texto de prueba. ' * 20
# 1) entradas iniciales
eq('hay 3 entradas iniciales publicadas', as_(None, "select count(*) from public.blog_posts")[1][0][0], 3)
eq('las iniciales son de compra segura, anticrético y verificación', sorted(r[0] for r in as_(None, "select category from public.blog_posts")[1]), ['anticretico', 'compra-segura', 'verificacion'])
# 2) el público no ve borradores ni entradas futuras; administración sí
chk('admin crea un borrador', as_(adm, "insert into public.blog_posts (slug, title, excerpt, body_md) values ('borrador-uno', 'Borrador de prueba', %s, %s)", ('E' * 60, BODY)), False)
chk('admin crea una entrada con fecha futura publicada', as_(adm, "insert into public.blog_posts (slug, title, excerpt, body_md, status, published_at) values ('futura-uno', 'Entrada futura de prueba', %s, %s, 'published', now() + interval '2 days')", ('E' * 60, BODY)), False)
eq('el público no ve el borrador ni la futura', as_(None, "select count(*) from public.blog_posts where slug in ('borrador-uno','futura-uno')")[1][0][0], 0)
eq('admin ve todo (3 + 2)', as_(adm, "select count(*) from public.blog_posts")[1][0][0], 5)
eq('un usuario cualquiera no ve borradores', as_(usr, "select count(*) from public.blog_posts where slug = 'borrador-uno'")[1][0][0], 0)
# 3) fecha automática al publicar
chk('admin publica el borrador', as_(adm, "update public.blog_posts set status='published' where slug='borrador-uno'"), False)
eq('al publicar se llena published_at', as_(adm, "select published_at is not null from public.blog_posts where slug='borrador-uno'")[1][0][0], True)
eq('ahora el público lo ve', as_(None, "select count(*) from public.blog_posts where slug='borrador-uno'")[1][0][0], 1)
# 4) solo administración escribe
chk('anónimo no puede insertar', as_(None, "insert into public.blog_posts (slug, title, excerpt, body_md) values ('x-anon', 'Titulo largo', %s, %s)", ('E' * 60, BODY)), True)
chk('usuario normal no puede insertar', as_(usr, "insert into public.blog_posts (slug, title, excerpt, body_md) values ('x-user', 'Titulo largo', %s, %s)", ('E' * 60, BODY)), True)
r = as_(usr, "update public.blog_posts set title='Hackeado por usuario' where slug='borrador-uno'"); eq('usuario normal no modifica nada (0 filas)', r[1] if r[0] == 'ok' else 0, 0)
r = as_(None, "delete from public.blog_posts where slug='borrador-uno'"); eq('anónimo no borra nada', r[1] if r[0] == 'ok' else 0, 0)
r = as_(usr, "delete from public.blog_posts where slug='borrador-uno'"); eq('usuario normal no borra nada', r[1] if r[0] == 'ok' else 0, 0)
# 5) validaciones
chk('slug con mayúsculas o espacios es rechazado', as_(adm, "insert into public.blog_posts (slug, title, excerpt, body_md) values ('Slug Malo', 'Titulo largo', %s, %s)", ('E' * 60, BODY)), True)
chk('slug repetido es rechazado', as_(adm, "insert into public.blog_posts (slug, title, excerpt, body_md) values ('borrador-uno', 'Titulo largo', %s, %s)", ('E' * 60, BODY)), True)
chk('cuerpo muy corto es rechazado', as_(adm, "insert into public.blog_posts (slug, title, excerpt, body_md) values ('corto-uno', 'Titulo largo', %s, 'poco')", ('E' * 60,)), True)
chk('extracto muy corto es rechazado', as_(adm, "insert into public.blog_posts (slug, title, excerpt, body_md) values ('corto-dos', 'Titulo largo', 'corto', %s)", (BODY,)), True)
chk('categoría inventada es rechazada', as_(adm, "insert into public.blog_posts (slug, title, excerpt, body_md, category) values ('cat-mala', 'Titulo largo', %s, %s, 'otra')", ('E' * 60, BODY)), True)
chk('estado inventado es rechazado', as_(adm, "insert into public.blog_posts (slug, title, excerpt, body_md, status) values ('est-malo', 'Titulo largo', %s, %s, 'archivado')", ('E' * 60, BODY)), True)
# 6) updated_at cambia al editar
su("update public.blog_posts set updated_at = now() - interval '5 days' where slug='borrador-uno'")
as_(adm, "update public.blog_posts set title='Borrador de prueba editado' where slug='borrador-uno'")
eq('al editar se actualiza updated_at', as_(adm, "select updated_at > now() - interval '1 minute' from public.blog_posts where slug='borrador-uno'")[1][0][0], True)
# 7) volver a correr el SQL no duplica ni pisa lo editado
su("update public.blog_posts set title='Título editado en el panel' where slug='como-comprar-una-casa-en-bolivia-de-forma-segura'")
cur.execute("reset role"); cur.execute(blog)
eq('al correr blog.sql otra vez siguen siendo 3 iniciales', one := su("select count(*) from public.blog_posts where slug in ('como-comprar-una-casa-en-bolivia-de-forma-segura','que-es-el-anticretico-en-bolivia-guia-para-inquilinos-y-propietarios','como-verificar-el-titulo-de-propiedad-de-un-inmueble-en-bolivia')") or (cur.fetchone()[0]), 3)
su("select title from public.blog_posts where slug='como-comprar-una-casa-en-bolivia-de-forma-segura'")
eq('y no pisa el título editado', cur.fetchone()[0], 'Título editado en el panel')
# 8) bucket y políticas de fotos
su("select public from storage.buckets where id='blog-images'"); eq('existe el bucket público blog-images', cur.fetchone()[0], True)
su("select count(*) from pg_policies where schemaname='storage' and tablename='objects' and policyname in ('public can view blog images','admin can upload blog images','admin can update blog images','admin can delete blog images')")
eq('están las 4 políticas del bucket', cur.fetchone()[0], 4)

print(f"\n{fails} FALLAS" if fails else "\n0 FALLAS")
sys.exit(1 if fails else 0)
