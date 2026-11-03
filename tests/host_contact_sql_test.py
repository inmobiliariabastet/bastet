"""Pruebas de supabase/host-contact.sql: el huésped ve el WhatsApp del dueño de la publicación al confirmarse la reserva.
Requiere:  pip install pgserver psycopg2-binary   y se ejecuta con:  python tests/stay_bookings_sql_test.py
Levanta un Postgres local desechable: NO toca Supabase ni producción."""
import pgserver, psycopg2, sys, tempfile, pathlib, datetime
ROOT = pathlib.Path(__file__).resolve().parent.parent
srv = pgserver.get_server(tempfile.mkdtemp(prefix='uno-pg-'), cleanup_mode='delete')
uri = srv.get_uri()
R_ = str(ROOT / "supabase") + "/"
sch = open(R_ + "schema.sql", encoding='utf-8').read()
core = sch   # esquema COMPLETO (con políticas de seguridad y permisos), igual que la base real
i = sch.index("-- UNO · Créditos para agentes")
tail = sch[sch.rindex("\n", 0, i - 5) + 1:]
sbk = open(R_ + "stay-bookings.sql", encoding="utf-8").read()
assert sbk.strip().replace('\r', '') in sch.replace('\r', ''), "stay-bookings.sql no está igual al final de schema.sql"
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
for _ in range(2): cur.execute(tail)
print("esquema completo corrido x2")
cur.execute("insert into auth.users(email,invited_at) values ('admin@x','2026-01-01'),('host@x','2026-01-01'),('host2@x','2026-01-01') returning id")
adm, host, host2 = [r[0] for r in cur.fetchall()]
su("update public.profiles set role='admin' where id=%s", (adm,))
su("update public.profiles set display_name='Hugo Host', contact_whatsapp='71234567' where id=%s", (host,))
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
    print(('PASS' if good else 'FAIL'), name, '->', str(res)[:150])
def eq(name, got, want):
    global fails
    good = got == want
    if not good: fails += 1
    print(('PASS' if good else 'FAIL'), name, '->', got)
def one(sql, a=None):
    su(sql, a); return cur.fetchone()[0]
su("set session_replication_role = replica")
def mkprop(owner, title, price='100', cur_='USD', op='temporal'):
    cur.execute("reset role; insert into properties (title, location, area, rooms, baths, description, price, currency, owner_id, operation, status, property_type, whatsapp) values (%s,'La Paz, Bolivia','80','2','1','x',%s,%s,%s,%s,'available','casa','70000000') returning id", (title, price, cur_, owner, op))
    return cur.fetchone()[0]
pU = mkprop(host, 'En dólares', '100', 'USD'); pB = mkprop(host, 'En bolivianos', '300', 'BOB'); pV = mkprop(host, 'Venta', '100', 'USD', 'venta')
su("set session_replication_role = origin")
today = one("select public.bo_today()")
D = lambda n: today + datetime.timedelta(days=n)
def book(prop, a, b, name='Gaby Huésped', phone='+591 76543210', who=None):
    return as_(who, "select create_stay_booking(%s,%s,%s,2,%s,%s,'g@x.com')", (prop, a, b, name, phone))
def code_of(r): return r[1][0][0]
def bid(code): return one("select id from stay_bookings where code=%s", (code,))
def st(code): return one("select status from stay_bookings where code=%s", (code,))
def verified(prop, a, b, phone):
    code = code_of(book(prop, a, b, phone=phone))
    as_(host, "select host_respond_stay_booking(%s, true)", (bid(code),))
    as_(None, "select attach_stay_proof(%s, %s)", (code, code + '/v.png'))
    as_(adm, "select admin_review_stay_proof(%s, true, null)", (bid(code),))
    return code


hc = open(R_ + "host-contact.sql", encoding="utf-8").read()
chk("el admin activa las reservas", as_(adm, "select admin_update_stay_settings(true, 7.00, 'Banco X cuenta 123456789 a nombre de Bastet', 'http://x/qr.png', 12)"), False)
c = verified(pU, D(10), D(13), '+591 76543210')
eq("antes del SQL se ve el contacto del perfil", as_(None, "select get_stay_booking(%s)->>'host_whatsapp'", (c,))[1][0][0], '71234567')
su("update properties set owner_whatsapp='69999999' where id=%s", (pU,))
su(hc); su(hc)
eq("con WhatsApp del dueño, el huésped ve ese número", as_(None, "select get_stay_booking(%s)->>'host_whatsapp'", (c,))[1][0][0], '69999999')
eq("la verificación pública muestra el mismo", as_(None, "select verify_stay_booking(%s)->>'host_whatsapp'", (c,))[1][0][0], '69999999')
eq("el admin ve el mismo para avisar", as_(adm, "select x->>'host_whatsapp' from jsonb_array_elements(my_stay_bookings()) x limit 1")[1][0][0], '69999999')
su("update properties set owner_whatsapp=null where id=%s", (pU,))
eq("sin WhatsApp del dueño vuelve al del perfil", as_(None, "select get_stay_booking(%s)->>'host_whatsapp'", (c,))[1][0][0], '71234567')
c2 = code_of(book(pB, D(20), D(22)))
eq("pendiente: no se entrega ningún contacto", as_(None, "select get_stay_booking(%s)->>'host_whatsapp'", (c2,))[1][0][0], None)
print(fails, "FALLAS"); sys.exit(1 if fails else 0)
