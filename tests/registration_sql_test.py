"""Pruebas del registro de usuarios (registration.sql) y del retiro del modelo de suscripción (retire-subscriptions.sql):
registro por tipo de cuenta, publicar libre y sin vencimiento, destacar solo admin, contrato por tipo de cuenta, historial conservado.
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

def acct(u): return as_(u, "select my_account()")[1][0][0]
su("update public.profiles set role='admin' where id=%s", (adm,))
S = acct(own); eq("nuevo: no registrado, sin tipo de cuenta", (S['registered'], S['interest']), (False, None))
eq("sin planes ni pruebas: la cuenta ya trae todo (cuenta agente por defecto)", (S['account']['type'], S['account']['agent_tools']), ('agente', True))
chk("nombre muy corto", as_(own, "select complete_registration('Al','77123456',null,null,null,true,false,true)"), True)
chk("whatsapp inválido", as_(own, "select complete_registration('Ana Pérez','abc',null,null,null,true,false,true)"), True)
chk("sin confirmar la mayoría de edad", as_(own, "select complete_registration('Ana Pérez','77123456','La Paz',null,'propietario',true,false,false)"), True)
chk("sin consentimiento", as_(own, "select complete_registration('Ana Pérez','77123456',null,null,null,false,false,true)"), True)
chk("interés inválido", as_(own, "select complete_registration('Ana Pérez','77123456',null,null,'otro',true,false,true)"), True)
chk("interés obligatorio", as_(own, "select complete_registration('Ana Pérez','77123456',null,null,null,true,false,true)"), True)
chk("anónimo no puede", as_(None, "select complete_registration('Ana Pérez','77123456',null,null,'agente',true,false,true)"), True)
chk("admin no necesita registro", as_(adm, "select complete_registration('Admin Uno','77123456',null,null,'agente',true,false,true)"), True)
chk("la prueba gratuita ya no existe", as_(own, "select start_free_trial()"), True)
chk("el modelo de planes ya no existe", as_(own, "select request_subscription('propietario','qr','T1')"), True)
chk("my_subscription ya no existe", as_(own, "select my_subscription()"), True)
r = as_(own, "select complete_registration('Ana Pérez','+591 77123456','La Paz','Casa Uno','propietario',true,false,true)"); chk("registro de propietario", r, False)
S = r[1][0][0]
eq("registrado como propietario", (S['registered'], S['interest'], S['account']['type'], S['account']['agent_tools']), (True, 'propietario', 'propietario', False))
eq("edad confirmada", row("select age_confirmed_at is not null from profiles where id=%s", (own,)), (True,))
eq("datos guardados", row("select full_name, whatsapp, city, company, interest from profiles where id=%s", (own,)), ('Ana Pérez', '+591 77123456', 'La Paz', 'Casa Uno', 'propietario'))
eq("p_start_trial se ignora: no hay suscripción ni prueba", one("select count(*) from subscriptions where user_id=%s", (own,)), 0)
# no puede falsificar sus datos privilegiados
as_(own, "update profiles set registered_at=null, role='admin', is_active=true where id=%s", (own,))
eq("campos protegidos intactos", row("select registered_at is not null, role from profiles where id=%s", (own,)), (True, 'agent'))
chk("agente: registro", as_(ag1, "select complete_registration('Dario Paz','77555666',null,null,'agente',true,false,true)"), False)
eq("agente con herramientas de agente", (acct(ag1)['account']['type'], acct(ag1)['account']['agent_tools']), ('agente', True))
chk("empresa: registro (incluso pidiendo prueba, que se ignora)", as_(emp, "select complete_registration('Eva Mar','77000111',null,'Casa Mar','empresa',true,true,true)"), False)
eq("empresa guardada", (acct(emp)['interest'], acct(emp)['account']['name']), ('empresa', 'Empresa'))
S = acct(adm); eq("admin: exento y con todas las herramientas", (S['exempt'], S['registered'], S['account']['agent_tools']), (True, True, True))
chk("anónimo no ve my_account", as_(None, "select my_account()"), True)

# ── publicar es libre: sin tope ni vencimiento
INS = "insert into properties(id,title,location,price,area,rooms,baths,owner_id) values (gen_random_uuid(),%s,'La Paz','100000','100','3','2',%s) returning id"
n_ok = sum(as_(own, INS, ('P%d' % k, own))[0] == 'ok' for k in range(20))
eq("un propietario sin plan publica 20 propiedades (sin tope)", n_ok, 20)
eq("ninguna vence", one("select count(*) from properties where owner_id=%s and expires_at is not null", (own,)), 0)
eq("las 20 están disponibles", one("select count(*) from properties where owner_id=%s and status='available'", (own,)), 20)
pid = one("select id from properties where owner_id=%s limit 1", (own,))
su("update properties set status='sold' where id=%s", (pid,))
chk("reactivar una vendida no exige plan ni cupo", as_(own, "update properties set status='available' where id=%s", (pid,)), False)
eq("sigue sin vencimiento tras reactivar", one("select expires_at is null from properties where id=%s", (pid,)), True)
chk("renovar ya no existe", as_(own, "select renew_property(%s)", (pid,)), True)
chk("el usuario no puede ponerse un vencimiento", as_(own, "update properties set expires_at = now() - interval '1 day' where id=%s", (pid,)), False)
eq("…y no se aplica", one("select expires_at is null from properties where id=%s", (pid,)), True)

# ── destacar: solo administración
chk("un usuario no destaca", as_(own, "select feature_property(%s::text, null)", (pid,)), True)
chk("el admin destaca", as_(adm, "select feature_property(%s::text, null)", (pid,)), False)
eq("quedó destacada", one("select featured_until > now() from properties where id=%s", (pid,)), True)
chk("no se destaca dos veces", as_(adm, "select feature_property(%s::text, null)", (pid,)), True)
chk("anónimo no destaca", as_(None, "select feature_property(%s::text, null)", (pid,)), True)

# ── contrato de exclusividad: agentes y empresas sí, propietarios no
DATA = '{}'
chk("un propietario no genera contratos", as_(own, "select create_exclusivity_contract(%s::jsonb,'key-prop-0001')", (DATA,)), True)
r = as_(own, "select create_exclusivity_contract(%s::jsonb,'key-prop-0002')", (DATA,))
eq("el mensaje explica por qué", 'agente o de empresa' in r[1], True)

# ── historial: las tablas de suscripción se conservan, sin funciones que las usen
eq("tablas históricas conservadas", one("select count(*) from information_schema.tables where table_schema='public' and table_name in ('subscriptions','subscription_plans','subscription_requests','subscription_events','featured_activations','trial_claims')"), 6)
eq("sin funciones de planes", one("select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname in ('my_subscription','request_subscription','admin_grant_subscription','_activate_subscription','start_free_trial','renew_property','enforce_plan_on_reactivate')"), 0)

su("select 1")
rs = open(R_ + "retire-subscriptions.sql", encoding="utf-8").read()
for _ in range(2): cur.execute(rs)
print("retire-subscriptions.sql re-corrido sin error (idempotente)")
print("FALLAS:", fails); sys.exit(1 if fails else 0)
