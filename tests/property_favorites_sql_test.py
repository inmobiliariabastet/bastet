"""Pruebas de supabase/property-favorites.sql: favoritos guardados en la cuenta (cada quien solo los suyos, tope, borrado en cascada).
Requiere:  pip install pgserver psycopg2-binary  ->  python tests/property_favorites_sql_test.py
Levanta un Postgres local desechable: NO toca Supabase ni producción."""
import pgserver, psycopg2, sys, tempfile, pathlib
ROOT = pathlib.Path(__file__).resolve().parent.parent
srv = pgserver.get_server(tempfile.mkdtemp(prefix='uno-pg-'), cleanup_mode='delete')
R_ = str(ROOT / "supabase") + "/"
sch = open(R_ + "schema.sql", encoding='utf-8').read()
core = sch[:sch.index("-- ── Tabla property_events")]
stub = """
create role anon nologin; create role authenticated nologin;
create schema auth; create schema storage;
create table auth.users(id uuid primary key default gen_random_uuid(), email text, invited_at timestamptz, raw_app_meta_data jsonb default '{}', raw_user_meta_data jsonb default '{}');
create function auth.uid() returns uuid language sql stable as $$ select nullif(current_setting('request.jwt.claim.sub', true),'')::uuid $$;
grant usage on schema auth to anon, authenticated; grant usage on schema public to anon, authenticated;
alter default privileges in schema public grant all on tables to anon, authenticated;
alter default privileges in schema public grant execute on functions to anon, authenticated, public;
"""
c = psycopg2.connect(srv.get_uri()); c.autocommit = True; cur = c.cursor()
cur.execute(stub); cur.execute(core)
sql = open(R_ + "property-favorites.sql", encoding='utf-8').read()
for _ in range(2): cur.execute(sql)
print("property-favorites.sql corrido x2")
assert sql.replace('\r\n', '\n').strip() in sch.replace('\r\n', '\n'), "property-favorites.sql no está igual al final de schema.sql"
cur.execute("insert into auth.users(email,invited_at) values ('u1@x','2026-01-01'),('u2@x','2026-01-01') returning id")
u1, u2 = [r[0] for r in cur.fetchall()]
cur.execute("alter table public.properties disable trigger user")
ids = []
for i in range(302):
    cur.execute("insert into properties (title, location, area, rooms, baths, description, price, owner_id, operation, status, property_type) values (%s,'La Paz, Bolivia','80','2','1','x','60',%s,'venta','available','casa') returning id", ('P%d' % i, u1))
    ids.append(cur.fetchone()[0])
fails = 0
def as_(uid, q, a=None):
    cur.execute("reset role; select set_config('request.jwt.claim.sub',%s,false)", (str(uid) if uid else '',))
    cur.execute("set role authenticated" if uid else "set role anon")
    try:
        cur.execute(q, a); rc = cur.rowcount
        try: return ('ok', cur.fetchall())
        except psycopg2.ProgrammingError: return ('ok', rc)
    except Exception as e: return ('ERR', str(e).splitlines()[0])
def chk(n, r, err):
    global fails
    g = (r[0] == 'ERR') == err; fails += (not g); print('PASS' if g else 'FAIL', n, '->', str(r)[:120])
def eq(n, got, want):
    global fails
    g = got == want; fails += (not g); print('PASS' if g else 'FAIL', n, '->', got)
ins = "insert into property_favorites(property_id) values (%s)"
chk("usuario guarda un favorito", as_(u1, ins, (ids[0],)), False)
chk("el mismo favorito dos veces", as_(u1, ins, (ids[0],)), True)
chk("anon no puede guardar", as_(None, ins, (ids[1],)), True)
chk("propiedad inexistente", as_(u1, ins, ('00000000-0000-0000-0000-000000000000',)), True)
chk("no guarda a nombre de otro", as_(u1, "insert into property_favorites(user_id,property_id) values (%s,%s)", (u2, ids[1])), True)
chk("u2 guarda el mismo inmueble", as_(u2, ins, (ids[0],)), False)
eq("u1 solo ve los suyos", as_(u1, "select count(*) from property_favorites")[1][0][0], 1)
chk("anon no puede leer la tabla", as_(None, "select count(*) from property_favorites"), True)
eq("u1 no borra los de u2", as_(u1, "delete from property_favorites where user_id=%s", (u2,))[1], 0)
eq("u1 quita el suyo", as_(u1, "delete from property_favorites where property_id=%s", (ids[0],))[1], 1)
chk("no se puede editar", as_(u2, "update property_favorites set created_at = now()"), True)
for i in range(30): as_(u1, ins, (ids[i],))
chk("tope de 30 favoritos", as_(u1, ins, (ids[30],)), True)
cur.execute("reset role"); cur.execute("delete from properties where id=%s", (ids[5],))
eq("al borrar la propiedad se borra el favorito", as_(u1, "select count(*) from property_favorites where property_id=%s", (ids[5],))[1][0][0], 0)
print("\nFALLAS:", fails); sys.exit(1 if fails else 0)
