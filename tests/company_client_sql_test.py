"""Pruebas de supabase/company-client.sql: la cuenta empresa es un cliente corporativo (sin herramientas de agente; solicitudes de estadía, espacio y compra).
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
cc = open(R_ + "company-client.sql", encoding="utf-8").read()
su(corp); su(cc); su(cc)
print("corporate.sql + company-client.sql corridos")
import json
J = lambda d: json.dumps(d)
su("update public.profiles set interest='empresa', registered_at=now(), display_name='Rita RRHH' where id=%s", (host,))
su("update public.profiles set interest='cliente', registered_at=now() where id=%s", (host2,))
su("update public.profiles set interest='agente', registered_at=now() where id=%s", (adm,)) if False else None
ag = one("insert into auth.users(email,invited_at) values ('agente@x','2026-01-01') returning id")
su("update public.profiles set interest='agente', registered_at=now() where id=%s", (ag,))
acc = lambda u: as_(u, "select my_account()")[1][0][0]["account"]
a = acc(host)
eq("empresa: cliente corporativo", (a["type"], a["client"], a["company"], a["agent_tools"]), ('empresa', True, True, False))
a = acc(host2); eq("cliente: sin company", (a["client"], a["company"], a["agent_tools"]), (True, False, False))
a = acc(ag); eq("agente: herramientas, no cliente", (a["client"], a["company"], a["agent_tools"]), (False, False, True))
chk("empresa NO publica inmuebles", as_(host, "insert into properties (title, location, area, rooms, baths, description, price, currency, owner_id, operation, status, property_type, whatsapp) values ('X','La Paz','80','2','1','x','100','USD',%s,'venta','available','casa','70000000')", (host,)), True)
chk("agente sí publica", as_(ag, "insert into properties (title, location, area, rooms, baths, description, price, currency, owner_id, operation, status, property_type, whatsapp) values ('Y','La Paz','80','2','1','x','100','USD',%s,'venta','available','casa','70000000')", (ag,)), False)
chk("empresa NO crea contrato de exclusividad", as_(host, "insert into exclusivity_contracts (agent_id) values (%s)", (host,)), True)
chk("nadie pasa a empresa desde el panel", as_(host2, "select change_account_type('empresa')"), True)
chk("cliente pasa a propietario", as_(host2, "select change_account_type('propietario')"), False)
su("update public.profiles set interest='cliente' where id=%s", (host2,))
chk("agente no cambia por su cuenta", as_(ag, "select change_account_type('propietario')"), True)

as_(adm, "select admin_set_corporate_settings(true, 10, '')")
AFF = {"company_name": "Minera Andina S.A.", "nit": "1023456029", "contact_name": "Rita Rojas", "whatsapp": "+591 71234567", "city": "La Paz", "consent": True}
chk("afiliación", as_(host, "select request_company_affiliation(%s::jsonb)", (J(AFF),)), False)
cid = one("select id from company_accounts limit 1")
as_(adm, "select admin_set_company(%s,'activa',null,null)", (cid,))
as_(host, "select company_add_worker('Juan Pérez Mamani','1234567','+591 70000001','Chofer')")
as_(host, "select company_add_worker('Ana Quispe Rojas','','','Geóloga')")
w = [r[0] for r in as_(host, "select id from company_workers order by full_name")[1]] if False else None
su("select 1"); cur.execute("select id from company_workers order by full_name"); w = [str(r[0]) for r in cur.fetchall()]
r = as_(host, "select company_submit_request(%s::jsonb)", (J({"kind": "estadia", "city": "Santa Cruz", "from_date": str(D(10)), "to_date": str(D(13)), "worker_ids": w + ["00000000-0000-0000-0000-000000000000"]}),))
chk("estadía con trabajadores elegidos", r, False)
eq("workers_count = 2 (el id ajeno se ignora)", one("select workers_count from company_requests where code=%s", (r[1][0][0],)), 2)
eq("worker_ids guardados", one("select cardinality(worker_ids) from company_requests where code=%s", (r[1][0][0],)), 2)
chk("estadía sin fechas no", as_(host, "select company_submit_request(%s::jsonb)", (J({"kind": "estadia", "city": "Oruro", "workers_count": 2}),)), True)
chk("estadía antigua (sin kind) sigue valiendo", as_(host, "select company_submit_request(%s::jsonb)", (J({"city": "Oruro", "from_date": str(D(5)), "to_date": str(D(6)), "workers_count": 2}),)), False)
r = as_(host, "select company_submit_request(%s::jsonb)", (J({"kind": "espacio", "city": "Cochabamba", "operation": "alquiler", "space_type": "Depósito", "size_text": "300 m2", "from_date": str(D(30)), "budget_text": "hasta USD 1500/mes", "notes": "Cerca de la carretera"}),))
chk("espacio para operar", r, False)
su("select 1"); cur.execute("select kind, operation, space_type, to_date, workers_count from company_requests where code=%s", (r[1][0][0],)); eq("espacio guardado", cur.fetchone(), ('espacio', 'alquiler', 'Depósito', None, None))
r = as_(host, "select company_submit_request(%s::jsonb)", (J({"kind": "compra", "city": "Santa Cruz", "space_type": "Oficinas", "operation": "alquiler"}),))
chk("compra de inmueble", r, False)
eq("compra fuerza operación venta", one("select operation from company_requests where code=%s", (r[1][0][0],)), 'venta')
chk("tipo inventado no", as_(host, "select company_submit_request(%s::jsonb)", (J({"kind": "otro", "city": "Oruro"}),)), True)
chk("espacio con inicio pasado no", as_(host, "select company_submit_request(%s::jsonb)", (J({"kind": "espacio", "city": "Oruro", "from_date": str(D(-3))}),)), True)
mc = as_(host, "select my_company()")[1][0][0]
eq("la empresa ve 4 solicitudes", len(mc["requests"]), 4)
ov = as_(adm, "select admin_corporate_overview()")[1][0][0]
eq("el admin ve los tipos", sorted({q["kind"] for q in ov["requests"]}), ['compra', 'espacio', 'estadia'])
su("update public.profiles set interest='empresa' where id=%s", (host2,))
chk("una empresa puede pasar a agente", as_(host2, "select change_account_type('agente')"), False)
print(fails, "FALLAS"); sys.exit(1 if fails else 0)
