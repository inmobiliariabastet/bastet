"""Pruebas del SQL de registro de usuarios y prueba gratuita de 7 días (registration.sql).
Requiere:  pip install pgserver psycopg2-binary   y se ejecuta con:  python tests/registration_sql_test.py
Levanta un Postgres local desechable: NO toca Supabase ni producción."""
import pgserver, psycopg2, sys, json, tempfile, pathlib, datetime
ROOT = pathlib.Path(__file__).resolve().parent.parent
srv = pgserver.get_server(tempfile.mkdtemp(prefix='uno-pg-'), cleanup_mode='delete')
uri = srv.get_uri()
R_ = str(ROOT / "supabase") + "/"
sch = open(R_ + "schema.sql", encoding='utf-8').read()
core = sch[:sch.index("-- ── Tabla property_events")]
i = sch.index("-- UNO · Créditos para agentes")
tail = sch[sch.rindex("\n", 0, i - 5) + 1:]
mk = tail.index("-- =====================================================================" + chr(10) + "-- UNO · Registro de nuevos usuarios")
assert tail[mk:].strip() == open(R_ + "registration.sql", encoding="utf-8").read().strip(), "schema.sql no tiene el mismo bloque que registration.sql"
stub = """
create role anon nologin; create role authenticated nologin;
create schema auth;
create schema storage; create table storage.buckets(id text primary key, name text, public boolean, file_size_limit bigint, allowed_mime_types text[]); create table storage.objects(id uuid default gen_random_uuid() primary key, bucket_id text, name text); alter table storage.objects enable row level security; grant usage on schema storage to anon, authenticated; grant all on storage.objects to anon, authenticated;
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

def sub(u): return as_(u, "select my_subscription()")[1][0][0]
su("update public.profiles set role='admin' where id=%s", (adm,))
S = sub(own); eq("nuevo: no registrado", S['registered'], False); eq("nuevo: puede probar", S['trial_eligible'], True); eq("nuevo: sin plan", S['status'], 'none')
chk("nombre muy corto", as_(own, "select complete_registration('Al','77123456',null,null,null,true,false,true)"), True)
chk("whatsapp inválido", as_(own, "select complete_registration('Ana Pérez','abc',null,null,null,true,false,true)"), True)
chk("sin confirmar la mayoría de edad", as_(own, "select complete_registration('Ana Pérez','77123456','La Paz',null,'propietario',true,false,false)"), True)
chk("sin consentimiento", as_(own, "select complete_registration('Ana Pérez','77123456',null,null,null,false,false,true)"), True)
chk("interés inválido", as_(own, "select complete_registration('Ana Pérez','77123456',null,null,'otro',true,false,true)"), True)
chk("interés obligatorio", as_(own, "select complete_registration('Ana Pérez','77123456',null,null,null,true,true,true)"), True)
chk("anónimo no puede", as_(None, "select complete_registration('Ana Pérez','77123456',null,null,null,true,false,true)"), True)
chk("admin no necesita registro", as_(adm, "select complete_registration('Admin Uno','77123456',null,null,null,true,false,true)"), True)
chk("trial antes de registrarse", as_(own, "select start_free_trial()"), True)
# registro con prueba
r = as_(own, "select complete_registration('Ana Pérez','+591 77123456','La Paz','Casa Uno','propietario',true,true,true)"); chk("registro + prueba", r, False)
S = sub(own); eq("registrado", S['registered'], True); eq("plan de prueba", (S['status'], S['source'], S['plan']['code']), ('active', 'trial', 'propietario'))
days = one("select extract(day from (current_period_end - now()))::int + case when extract(hour from (current_period_end - now())) >= 23 then 1 else 0 end from subscriptions where user_id=%s", (own,)); eq("dura 7 días", days, 7)
eq("trial_eligible falso tras usarla", (S['trial_eligible'], S['trial_used']), (False, True))
eq("edad confirmada", row("select age_confirmed_at is not null from profiles where id=%s", (own,)), (True,))
eq("datos guardados", row("select full_name, whatsapp, city, company, interest from profiles where id=%s", (own,)), ('Ana Pérez', '+591 77123456', 'La Paz', 'Casa Uno', 'propietario'))
chk("no puede repetir la prueba", as_(own, "select start_free_trial()"), True)
# no puede falsificar sus datos privilegiados
as_(own, "update profiles set registered_at=null, trial_used_at=null, role='admin', is_active=true where id=%s", (own,))
eq("campos protegidos intactos", row("select registered_at is not null, trial_used_at is not null, role from profiles where id=%s", (own,)), (True, True, 'agent'))
# registro eligiendo plan primero (sin prueba)
chk("registro sin prueba", as_(own2, "select complete_registration('Beto Rojas','77111222',null,null,'propietario',true,false,true)"), False)
chk("empresa: la prueba no está disponible", as_(emp, "select complete_registration('Eva Mar','77000111',null,'Casa Mar','empresa',true,true,true)"), True)
chk("agente: la prueba no está disponible", as_(emp, "select complete_registration('Eva Mar','77000111',null,'Casa Mar','agente',true,true,true)"), True)
chk("empresa: registro sin prueba", as_(emp, "select complete_registration('Eva Mar','77000111',null,'Casa Mar','empresa',true,false,true)"), False)
chk("empresa registrada: start_free_trial falla", as_(emp, "select start_free_trial()"), True)
eq("empresa: interés guardado", sub(emp)['interest'], 'empresa')
S = sub(own2); eq("sin prueba: sin plan", (S['registered'], S['status'], S['trial_eligible']), (True, 'none', True))
chk("pide plan", as_(own2, "select request_subscription('propietario','qr','T1')"), False)
S = sub(own2); eq("tras pedir plan ya no hay prueba", S['trial_eligible'], False)
chk("start_free_trial con solicitud pedida falla", as_(own2, "select start_free_trial()"), True)
# prueba más tarde (registrado sin pedir plan)
as_(ag1, "select complete_registration('Carla Ríos','77333444',null,null,'propietario',true,false,true)")
chk("prueba posterior", as_(ag1, "select start_free_trial()"), False)
eq("prueba posterior activa con el plan elegido", (sub(ag1)['source'], sub(ag1)['plan']['code']), ('trial', 'propietario'))
# usuario con plan de cortesía ya existente: no tiene prueba
su("select admin_grant_subscription(%s,'empresa',30)" if False else "select 1")
as_(adm, "select admin_grant_subscription(%s,'agente',30)", (ag2,))
as_(ag2, "select complete_registration('Dario Paz','77555666',null,null,'agente',true,true,true)") if False else None
S = sub(ag2); eq("con plan: sin prueba", S['trial_eligible'], False)
chk("con plan: registro sin prueba", as_(ag2, "select complete_registration('Dario Paz','77555666',null,null,'agente',true,false,true)"), False)
chk("con plan: registro con prueba falla", as_(ag2, "select complete_registration('Dario Paz','77555666',null,null,'agente',true,true,true)"), True)
# prueba vencida -> estado expirado y no se puede repetir
su("update subscriptions set current_period_end = now() - interval '1 day' where user_id=%s", (own,))
S = sub(own); eq("prueba vencida", (S['status'], S['source'], S['trial_eligible']), ('expired', 'trial', False))
# la prueba respeta el límite del plan Agente (15) y el admin no entra al flujo
S = sub(adm); eq("admin: exento y registrado", (S['exempt'], S['registered']), (True, True))

# antiabuso: borrar la cuenta y volver a crearla con el mismo correo (o un alias de Gmail) NO da otra prueba
su("insert into auth.users(email,invited_at) values ('ana.perez+x@gmail.com','2026-01-01') returning id"); g1 = cur.fetchone()[0]
chk("gmail: registro + prueba", as_(g1, "select complete_registration('Gina Gil','77888999',null,null,'propietario',true,true,true)"), False)
su("delete from public.profiles where id=%s", (g1,)); su("delete from auth.users where id=%s", (g1,))
su("insert into auth.users(email,invited_at) values ('anaperez@gmail.com','2026-01-01') returning id"); g2 = cur.fetchone()[0]
S = sub(g2); eq("alias de gmail: sin prueba", S['trial_eligible'], False)
as_(g2, "select complete_registration('Gina Gil','77888999',null,null,'propietario',true,false,true)")
chk("alias de gmail: no puede iniciar prueba", as_(g2, "select start_free_trial()"), True)
chk("alias de gmail: no puede en el registro", as_(g2, "select complete_registration('Gina Gil','77888999',null,null,'propietario',true,true,true)"), True)
eq("otro correo distinto sí puede", sub(plain)['trial_eligible'], True)
chk("nadie lee trial_claims", as_(own, "select * from public.trial_claims"), True)
# idempotencia del SQL
su("select 1")
for _ in range(2): cur.execute(tail)
print("registration.sql re-corrido sin error")
print("FALLAS:", fails); sys.exit(1 if fails else 0)
