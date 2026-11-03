"""Pruebas de supabase/property-requests.sql: solicitudes de propiedad (comprador / inquilino).
Requiere:  pip install pgserver psycopg2-binary   y se ejecuta con:  python tests/registration_sql_test.py
Levanta un Postgres local desechable: NO toca Supabase ni producción."""
import pgserver, psycopg2, sys, json, tempfile, pathlib, datetime
ROOT = pathlib.Path(__file__).resolve().parent.parent
srv = pgserver.get_server(tempfile.mkdtemp(prefix='uno-pg-'), cleanup_mode='delete')
uri = srv.get_uri()
R_ = str(ROOT / "supabase") + "/"
sch = open(R_ + "schema.sql", encoding='utf-8').read()
core = sch   # esquema COMPLETO (con políticas de seguridad y permisos), igual que la base real
i = sch.index("-- UNO · Créditos para agentes")
tail = sch[sch.rindex("\n", 0, i - 5) + 1:]
mk = tail.index("-- =====================================================================" + chr(10) + "-- UNO · Registro de nuevos usuarios")
EQ2 = "-- =====================================================================" + chr(10) + "-- UNO · Comprobantes de pago"
end = tail.index(EQ2) if EQ2 in tail else len(tail)
assert tail[mk:end].strip() == open(R_ + "registration.sql", encoding="utf-8").read().strip(), "schema.sql no tiene el mismo bloque que registration.sql"
stub = """
create role anon nologin; create role authenticated nologin;
create schema auth;
create schema storage; create function storage.foldername(name text) returns text[] language sql immutable as $fn$ select (string_to_array(name,'/'))[1:greatest(array_length(string_to_array(name,'/'),1)-1,0)] $fn$; create table storage.buckets(id text primary key, name text, public boolean, file_size_limit bigint, allowed_mime_types text[]); create table storage.objects(id uuid default gen_random_uuid() primary key, bucket_id text, name text); alter table storage.objects enable row level security; grant usage on schema storage to anon, authenticated; grant all on storage.objects to anon, authenticated;
create table auth.users(id uuid primary key default gen_random_uuid(), email text, invited_at timestamptz, raw_app_meta_data jsonb default '{}', raw_user_meta_data jsonb default '{}');
create function auth.uid() returns uuid language sql stable as $$ select nullif(current_setting('request.jwt.claim.sub', true),'')::uuid $$;
grant usage on schema auth to anon, authenticated; grant usage on schema public to anon, authenticated;
alter default privileges in schema public grant all on tables to anon, authenticated;
alter default privileges in schema public grant execute on functions to anon, authenticated, public;
"""
c = psycopg2.connect(uri); c.autocommit = True; cur = c.cursor()
def su(sql, args=None):
    cur.execute("reset role; select set_config('request.jwt.claim.sub','',false)"); cur.execute(sql, args)
cur.execute(stub); cur.execute(core)
su("select 1")
for _ in range(2): cur.execute(tail)
print("esquema completo corrido x2")
import os
if os.environ.get("DROP_CREDITS"):
    su("select 1"); cur.execute(open(R_ + "drop-credits.sql", encoding="utf-8").read()); print("drop-credits.sql aplicado: las pruebas siguientes corren SIN el sistema de créditos")
cur.execute("insert into auth.users(email,invited_at) values ('admin@x','2026-01-01'),('own@x','2026-01-01'),('own2@x','2026-01-01'),('ag1@x','2026-01-01'),('ag2@x','2026-01-01'),('agx@x','2026-01-01'),('emp@x','2026-01-01'),('plain@x','2026-01-01') returning id")
adm, own, own2, ag1, ag2, agx, emp, plain = [r[0] for r in cur.fetchall()]
su("update public.profiles set role='admin' where id=%s", (adm,))
su("update public.profiles set display_name='Ana Agente', avatar_url='http://x/a.png', facebook_url='http://fb/ana' where id=%s", (ag1,))
su("update public.profiles set display_name='Beto Agente' where id=%s", (ag2,))
fails = 0
def as_(uid, sql, args=None):
    cur.execute("reset role; select set_config('request.jwt.claim.sub',%s,false)", (str(uid) if uid else '',))
    cur.execute("set role authenticated" if uid else "set role anon")
    try:
        cur.execute(sql, args)
        try: return ('ok', cur.fetchall())
        except psycopg2.ProgrammingError: return ('ok', cur.rowcount)
    except Exception as e: return ('ERR', str(e).splitlines()[0])
def chk(name, res, expect_err):
    global fails
    good = (res[0] == 'ERR') == expect_err
    if not good: fails += 1
    print(('PASS' if good else 'FAIL'), name, '->', str(res)[:140])
def eq(name, got, want):
    global fails
    good = got == want
    if not good: fails += 1
    print(('PASS' if good else 'FAIL'), name, '->', got)
def one(sql, a=None):
    su(sql, a); return cur.fetchone()[0]
def row(sql, a=None):
    su(sql, a); return cur.fetchone()


# --- el bloque está al final de schema.sql
sav = open(R_ + "property-requests.sql", encoding="utf-8").read()
assert chr(10).join(sav.split(chr(13))).strip() in chr(10).join(open(R_ + "schema.sql", encoding="utf-8").read().split(chr(13))), "property-requests.sql no está igual al final de schema.sql"
import uuid
def P(**kw):
    d = dict(id=str(uuid.uuid4()), operation='venta', property_type='casa', city='La Paz', zone='Calacoto', rooms_min=3, baths_min=2, area_min=100, area_max=300,
             features=['Jardín', 'Garaje'], budget_min=100000, budget_max=250000, currency='USD', description='Busco casa tranquila',
             contact_name='Carla Ríos', contact_phone='+59171234567', contact_email='c@x.com', consent=True)
    d.update(kw); return json.dumps(d)
def sub(uid, **kw): return as_(uid, "select submit_property_request(%s::jsonb)", (P(**kw),))

chk("anónimo no lee la tabla", as_(None, "select * from property_requests"), True)
a1 = P()
r = as_(None, "select submit_property_request(%s::jsonb)", (a1,)); chk("anónimo envía una solicitud", r, False)
rid = r[1][0][0]
eq("el reintento del mismo envío no duplica", as_(None, "select submit_property_request(%s::jsonb)", (a1,))[1][0][0], rid)
eq("queda una sola", one("select count(*) from property_requests"), 1)
chk("sin consentimiento", sub(None, consent=False, contact_phone='+59170000001'), True)
chk("teléfono inválido", sub(None, contact_phone='abc'), True)
chk("operación inválida", sub(None, operation='regalo', contact_phone='+59170000002'), True)
chk("tipo inválido", sub(None, property_type='castillo', contact_phone='+59170000003'), True)
chk("presupuesto máximo menor que el mínimo", sub(None, budget_min=500, budget_max=100, contact_phone='+59170000004'), True)
chk("más de 20 características", sub(None, features=['x%d' % i for i in range(21)], contact_phone='+59170000005'), True)
chk("sin presupuesto ni superficie", sub(None, budget_min=None, budget_max=None, area_min=None, area_max=None, rooms_min=None, baths_min=None, features=[], contact_phone='+59170000006'), False)
# límite por teléfono
sub(None, contact_phone='+59172222222'); sub(None, contact_phone='+59172222222'); sub(None, contact_phone='+59172222222')
chk("máximo 3 por teléfono en 24 h", sub(None, contact_phone='+59172222222'), True)

# estado de mis solicitudes
eq("por id veo la mía", [str(x[0]) for x in as_(None, "select id from my_property_requests(array[%s::uuid])", (rid,))[1]], [rid])
eq("sin ids no veo nada", len(as_(None, "select * from my_property_requests()")[1]), 0)
r2 = sub(own, contact_phone='+59173333333'); rid2 = r2[1][0][0]
eq("con sesión veo las de mi cuenta", [str(x[0]) for x in as_(own, "select id from my_property_requests()")[1]], [rid2])
eq("otro usuario no ve las ajenas", len(as_(own2, "select * from my_property_requests()")[1]), 0)
chk("finalizar la mía", as_(None, "select finish_property_request(%s)", (rid,)), False)
eq("quedó finalizada", as_(None, "select status from my_property_requests(array[%s::uuid])", (rid,))[1][0][0], 'finished')
chk("finalizar una inexistente", as_(None, "select finish_property_request(%s)", (str(uuid.uuid4()),)), True)

# administración
chk("un agente no lista", as_(own, "select * from admin_property_requests()"), True)
chk("anónimo no lista", as_(None, "select * from admin_property_requests()"), True)
eq("el admin ve todas", len(as_(adm, "select * from admin_property_requests()")[1]) >= 6, True)
chk("un agente no cambia estados", as_(own, "select admin_set_property_request_status(%s, 'in_progress', 'x')", (rid2,)), True)
chk("el admin pasa a «en proceso»", as_(adm, "select admin_set_property_request_status(%s, 'in_progress', 'Llamé al cliente')", (rid2,)), False)
eq("el solicitante ve «en proceso»", as_(own, "select status from my_property_requests()")[1][0][0], 'in_progress')
chk("estado inválido", as_(adm, "select admin_set_property_request_status(%s, 'raro', null)", (rid2,)), True)

su("select 1")
for _ in range(2): cur.execute(sav)
print("property-requests.sql re-corrido sin error")
print("FALLAS:", fails); sys.exit(1 if fails else 0)
