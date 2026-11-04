"""Pruebas de supabase/corporate.sql: empresas aliadas (afiliación, trabajadores, solicitudes de alojamiento, cotización).
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



corp = open(R_ + "corporate.sql", encoding="utf-8").read()
su(corp); su(corp)
print("corporate.sql corrido x2")
su("update public.profiles set interest='empresa', registered_at=now(), display_name='Rita RRHH' where id=%s", (host,))
su("update public.profiles set interest='cliente', registered_at=now() where id=%s", (host2,))
AFF = {"company_name": "Pollos Copacabana S.A.", "nit": "1023456029", "contact_name": "Rita Rojas", "contact_role": "RR. HH.", "whatsapp": "+591 71234567", "city": "La Paz", "workers_estimate": 40, "consent": True}
import json
J = lambda d: json.dumps(d)

eq("apagado por defecto", as_(None, "select corporate_public()->>'enabled'")[1][0][0], 'false')
chk("anónimo no ve my_company", as_(None, "select my_company()"), True)
chk("anónimo no lee las tablas", as_(None, "select * from company_accounts"), True)
chk("usuario autenticado no lee las tablas directo", as_(host, "select * from company_accounts"), True)
chk("no se afilia con el interruptor apagado", as_(host, "select request_company_affiliation(%s::jsonb)", (J(AFF),)), True)
chk("un no admin no enciende", as_(host, "select admin_set_corporate_settings(true, 10, '')"), True)
chk("el admin enciende", as_(adm, "select admin_set_corporate_settings(true, 12.5, 'Atención preferencial')"), False)
eq("público ve encendido y el descuento", as_(None, "select corporate_public()->>'discount_default'")[1][0][0], '12.50')

chk("un cliente no se afilia", as_(host2, "select request_company_affiliation(%s::jsonb)", (J(AFF),)), True)
chk("sin consentimiento no", as_(host, "select request_company_affiliation(%s::jsonb)", (J(dict(AFF, consent=False)),)), True)
chk("NIT muy corto no", as_(host, "select request_company_affiliation(%s::jsonb)", (J(dict(AFF, nit="1")),)), True)
chk("WhatsApp inválido no", as_(host, "select request_company_affiliation(%s::jsonb)", (J(dict(AFF, whatsapp="abc")),)), True)
chk("la empresa solicita la afiliación", as_(host, "select request_company_affiliation(%s::jsonb)", (J(AFF),)), False)
chk("no se solicita dos veces", as_(host, "select request_company_affiliation(%s::jsonb)", (J(AFF),)), True)
mc = as_(host, "select my_company()")[1][0][0]
eq("queda como solicitada", mc["company"]["status"], 'solicitada')
eq("la empresa no ve las notas internas", 'admin_notes' in mc["company"], False)
chk("aún no puede registrar trabajadores", as_(host, "select company_add_worker('Juan Pérez')"), True)
chk("ni enviar solicitudes", as_(host, "select company_submit_request(%s::jsonb)", (J({"city": "Santa Cruz", "from_date": str(D(10)), "to_date": str(D(13)), "workers_count": 3}),)), True)

cid = one("select id from company_accounts limit 1")
chk("un no admin no activa", as_(host, "select admin_set_company(%s,'activa',50,null)", (cid,)), True)
chk("estado inventado no", as_(adm, "select admin_set_company(%s,'vip',null,null)", (cid,)), True)
chk("descuento > 100 no", as_(adm, "select admin_set_company(%s,'activa',150,null)", (cid,)), True)
chk("el admin activa (descuento por defecto)", as_(adm, "select admin_set_company(%s,'activa',null,'Convenio firmado')", (cid,)), False)
eq("descuento por defecto aplicado", float(one("select discount_percent from company_accounts where id=%s", (cid,))), 12.5)
eq("approved_at fijado", one("select approved_at is not null from company_accounts where id=%s", (cid,)), True)

chk("agrega un trabajador", as_(host, "select company_add_worker('Juan Pérez Mamani','1234567','+591 70000001','Chofer')"), False)
chk("nombre muy corto no", as_(host, "select company_add_worker('J')"), True)
chk("teléfono inválido no", as_(host, "select company_add_worker('María López','', 'xx')"), True)
chk("otra cuenta (cliente) no agrega", as_(host2, "select company_add_worker('Pedro Pablo')"), True)
code = as_(host, "select company_submit_request(%s::jsonb)", (J({"city": "Santa Cruz", "from_date": str(D(10)), "to_date": str(D(13)), "workers_count": 3, "budget_text": "Bs 200 por noche", "notes": "Técnicos"}),))
chk("envía una solicitud de alojamiento", code, False)
eq("código CORP-", code[1][0][0][:5], 'CORP-')
chk("fecha pasada no", as_(host, "select company_submit_request(%s::jsonb)", (J({"city": "Santa Cruz", "from_date": str(D(-2)), "to_date": str(D(1)), "workers_count": 3}),)), True)
chk("salida antes de llegada no", as_(host, "select company_submit_request(%s::jsonb)", (J({"city": "Santa Cruz", "from_date": str(D(10)), "to_date": str(D(9)), "workers_count": 3}),)), True)
chk("0 trabajadores no", as_(host, "select company_submit_request(%s::jsonb)", (J({"city": "Santa Cruz", "from_date": str(D(10)), "to_date": str(D(12)), "workers_count": 0}),)), True)
rid = one("select id from company_requests limit 1")
chk("un no admin no gestiona solicitudes", as_(host, "select admin_update_company_request(%s,'cotizada','x')", (rid,)), True)
chk("el admin cotiza", as_(adm, "select admin_update_company_request(%s,'cotizada','Bs 180 por noche por persona')", (rid,)), False)
mc = as_(host, "select my_company()")[1][0][0]
eq("la empresa ve la cotización", mc["requests"][0]["admin_quote"], 'Bs 180 por noche por persona')
ov = as_(adm, "select admin_corporate_overview()")[1][0][0]
eq("admin ve 1 empresa con 1 trabajador", (len(ov["companies"]), ov["companies"][0]["workers"], len(ov["requests"])), (1, 1, 1))
chk("un no admin no ve el resumen", as_(host, "select admin_corporate_overview()"), True)
chk("la empresa cancela su solicitud abierta", as_(host, "select company_cancel_request(%s)", (rid,)), False)
eq("quedó cancelada", one("select status from company_requests where id=%s", (rid,)), 'cancelada')
wid = one("select id from company_workers limit 1")
as_(host2, "select company_remove_worker(%s)", (wid,))
eq("otra cuenta no quita trabajadores ajenos", one("select count(*) from company_workers"), 1)
as_(host, "select company_remove_worker(%s)", (wid,))
eq("la empresa quita su trabajador", one("select count(*) from company_workers"), 0)
chk("empresa suspendida no envía", (as_(adm, "select admin_set_company(%s,'suspendida',null,null)", (cid,)), as_(host, "select company_submit_request(%s::jsonb)", (J({"city": "Oruro", "from_date": str(D(10)), "to_date": str(D(12)), "workers_count": 2}),)))[1], True)
print(fails, "FALLAS"); sys.exit(1 if fails else 0)
