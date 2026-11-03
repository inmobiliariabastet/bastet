"""Pruebas de supabase/stay-availability.sql: calendario de no disponibilidad de las estadías temporales.
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
sav = open(R_ + "stay-availability.sql", encoding="utf-8").read()
assert chr(10).join(sav.split(chr(13))).strip() in chr(10).join(open(R_ + "schema.sql", encoding="utf-8").read().split(chr(13))), "stay-availability.sql no está igual al final de schema.sql"
su("set session_replication_role = replica")
def mkprop(owner, title, op='temporal'):
    cur.execute("reset role; insert into properties (title, location, area, rooms, baths, description, price, owner_id, operation, status, property_type) values (%s,'La Paz, Bolivia','80','2','1','x','60',%s,%s,'available','casa') returning id", (title, owner, op))
    return cur.fetchone()[0]
pT = mkprop(own, 'Temporal'); pV = mkprop(own, 'Venta', 'venta'); pO = mkprop(own2, 'Ajena')
su("set session_replication_role = origin")
today = one("select public.bo_today()")
D = lambda n: today + datetime.timedelta(days=n)

chk("anónimo no lee la tabla directo", as_(None, "select * from stay_blocks"), True)
chk("anónimo no bloquea", as_(None, "select set_stay_block(%s, %s, %s)", (pT, D(1), D(3))), True)
chk("bloquear fechas futuras", as_(own, "select set_stay_block(%s, %s, %s, 'Remodelación')", (pT, D(2), D(5))), False)
chk("bloquear sin fecha de regreso", as_(own, "select set_stay_block(%s, %s, null)", (pT, D(30))), False)
chk("no en propiedad ajena", as_(own2, "select set_stay_block(%s, %s, %s)", (pT, D(1), D(2))), True)
chk("no en propiedad que no es temporal", as_(own, "select set_stay_block(%s, %s, %s)", (pV, D(1), D(2))), True)
chk("fin antes del inicio", as_(own, "select set_stay_block(%s, %s, %s)", (pT, D(5), D(2))), True)
chk("fechas pasadas", as_(own, "select set_stay_block(%s, %s, %s)", (pT, D(-5), D(-2))), True)
chk("el admin también puede", as_(adm, "select set_stay_block(%s, %s, %s)", (pT, D(10), D(11))), False)
r = as_(None, "select property_id, from_date, to_date from stay_blocked_ranges(array[%s::uuid, %s::uuid])", (pT, pO))[1]
eq("el público ve 3 periodos, sin notas", [(x[1], x[2]) for x in r], [(D(2), D(5)), (D(10), D(11)), (D(30), None)])
mine = as_(own, "select id, note from my_stay_blocks()")[1]
eq("el anfitrión ve los suyos con nota", len(mine), 3)
eq("el otro anfitrión no ve los ajenos", as_(own2, "select count(*) from my_stay_blocks()")[1][0][0], 0)
bid = [x[0] for x in mine if x[1] == 'Remodelación'][0]
chk("otro anfitrión no borra", as_(own2, "select delete_stay_block(%s)", (bid,)), True)
chk("el anfitrión reactiva (borra)", as_(own, "select delete_stay_block(%s)", (bid,)), False)
eq("quedan 2 para el público", len(as_(None, "select * from stay_blocked_ranges(array[%s::uuid])", (pT,))[1]), 2)
# un periodo ya terminado deja de aparecer
su("insert into stay_blocks(property_id, from_date, to_date) values (%s, %s, %s)", (pT, D(-9), D(-3)))
eq("el periodo vencido no aparece", len(as_(None, "select * from stay_blocked_ranges(array[%s::uuid])", (pT,))[1]), 2)
su("select 1")
for _ in range(2): cur.execute(sav)
print("stay-availability.sql re-corrido sin error")
print("FALLAS:", fails); sys.exit(1 if fails else 0)
