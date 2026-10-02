"""Prueba de la moneda del precio de las propiedades (USD por defecto, BOB opcional, solo esas dos).
Requiere:  pip install pgserver psycopg2-binary  ->  python tests/property_currency_sql_test.py
Levanta un Postgres local desechable: NO toca Supabase ni producción."""
import pgserver, psycopg2, sys, tempfile, pathlib
ROOT = pathlib.Path(__file__).resolve().parent.parent
srv = pgserver.get_server(tempfile.mkdtemp(prefix='uno-pg-'), cleanup_mode='delete')
R_ = str(ROOT / "supabase") + "/"
sch = open(R_ + "schema.sql", encoding='utf-8').read()
core = sch[:sch.index("-- ── Tabla property_events")]
stub = """
create role anon nologin; create role authenticated nologin;
create schema auth;
create table auth.users(id uuid primary key default gen_random_uuid(), email text, invited_at timestamptz);
create function auth.uid() returns uuid language sql stable as $$ select nullif(current_setting('request.jwt.claim.sub', true),'')::uuid $$;
grant usage on schema auth to anon, authenticated; grant usage on schema public to anon, authenticated;
alter default privileges in schema public grant all on tables to anon, authenticated;
"""
c = psycopg2.connect(srv.get_uri()); c.autocommit = True; cur = c.cursor()
cur.execute(stub); cur.execute(core)
# una propiedad "de antes" (sin moneda) debe quedar en USD al activar el SQL
cur.execute("insert into properties(id,title,location,price,area,rooms,baths) values (gen_random_uuid(),'Vieja','LP','100','1','1','1')")
sql = open(R_ + "property-currency.sql", encoding='utf-8').read()
for n in range(2): cur.execute(sql)
print("property-currency.sql corrido x2")
assert sql.replace('\r\n', '\n').strip() in sch.replace('\r\n', '\n'), "el bloque no está igual al final de schema.sql"
fails = 0
def eq(name, got, want):
    global fails
    ok = got == want; fails += (not ok); print('PASS' if ok else 'FAIL', name, '->', got)
def one(q, a=None): cur.execute(q, a); return cur.fetchone()[0]
eq("las propiedades existentes quedan en USD", one("select currency from properties where title='Vieja'"), 'USD')
cur.execute("insert into properties(id,title,location,price,area,rooms,baths,currency) values (gen_random_uuid(),'Bs','LP','1200000','1','1','1','BOB')")
eq("se puede guardar una en bolivianos", one("select currency from properties where title='Bs'"), 'BOB')
cur.execute("insert into properties(id,title,location,price,area,rooms,baths) values (gen_random_uuid(),'Sin moneda','LP','5','1','1','1')")
eq("sin indicar moneda es USD", one("select currency from properties where title='Sin moneda'"), 'USD')
try:
    cur.execute("insert into properties(id,title,location,price,area,rooms,baths,currency) values (gen_random_uuid(),'X','LP','5','1','1','1','EUR')"); fails += 1; print("FAIL acepta EUR")
except Exception: print("PASS rechaza otras monedas")
try:
    cur.execute("insert into properties(id,title,location,price,area,rooms,baths,currency) values (gen_random_uuid(),'Y','LP','5','1','1','1',null)"); fails += 1; print("FAIL acepta nulo")
except Exception: print("PASS rechaza moneda nula")
cur.execute("set role anon"); cur.execute("select currency from properties where title='Bs'"); eq("el público puede leer la moneda", cur.fetchone()[0], 'BOB')
print("\nFALLAS:", fails); sys.exit(1 if fails else 0)
