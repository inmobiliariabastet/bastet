"""Prueba del desglose del regalo en el historial al aprobar un pack de créditos.
Requiere:  pip install pgserver psycopg2-binary  ->  python tests/credit_pack_ledger_sql_test.py
Levanta un Postgres local desechable: NO toca Supabase ni producción."""
import pgserver, psycopg2, sys, tempfile, pathlib
ROOT = pathlib.Path(__file__).resolve().parent.parent
srv = pgserver.get_server(tempfile.mkdtemp(prefix='uno-pg-'), cleanup_mode='delete')
R_ = str(ROOT / "supabase") + "/"
sch = open(R_ + "schema.sql", encoding='utf-8').read()
core = sch   # esquema COMPLETO (con políticas de seguridad y permisos), igual que la base real
i = sch.index("-- UNO · Créditos para agentes")
tail = sch[sch.rindex(chr(10), 0, i - 5) + 1:]
stub = """
create role anon nologin; create role authenticated nologin;
create schema auth;
create schema storage; create function storage.foldername(name text) returns text[] language sql immutable as $fn$ select (string_to_array(name,'/'))[1:greatest(array_length(string_to_array(name,'/'),1)-1,0)] $fn$; create table storage.buckets(id text primary key, name text, public boolean, file_size_limit bigint, allowed_mime_types text[]); create table storage.objects(id uuid default gen_random_uuid() primary key, bucket_id text, name text); alter table storage.objects enable row level security;
create table auth.users(id uuid primary key default gen_random_uuid(), email text, invited_at timestamptz, raw_app_meta_data jsonb default '{}', raw_user_meta_data jsonb default '{}');
create function auth.uid() returns uuid language sql stable as $$ select nullif(current_setting('request.jwt.claim.sub', true),'')::uuid $$;
grant usage on schema auth to anon, authenticated; grant usage on schema public to anon, authenticated;
alter default privileges in schema public grant all on tables to anon, authenticated;
alter default privileges in schema public grant execute on functions to anon, authenticated, public;
"""
c = psycopg2.connect(srv.get_uri()); c.autocommit = True; cur = c.cursor()
cur.execute(stub); cur.execute(core)
sql = open(R_ + "credit-pack-ledger.sql", encoding='utf-8').read()
for n in range(2): cur.execute(tail)
print("esquema completo corrido x2")
assert sql.replace('\r\n', '\n').strip() in sch.replace('\r\n', '\n'), "el bloque no está igual al final de schema.sql"
fails = 0
def eq(name, got, want):
    global fails
    ok = got == want; fails += (not ok); print('PASS' if ok else 'FAIL', name, '->', got)
def one(q, a=None): cur.execute(q, a); return cur.fetchone()[0]
cur.execute("insert into auth.users(email,invited_at) values ('adm@x.com','2026-01-01'),('ag@x.com','2026-01-01')")
adm = one("select id from auth.users where email='adm@x.com'"); ag = one("select id from auth.users where email='ag@x.com'")
cur.execute("alter table public.profiles disable trigger protect_profile_privileged"); cur.execute("update public.profiles set role='admin' where id=%s", (adm,))
def buy(code, method='transferencia'):
    # La compra de créditos desde la app se retiró (request_credit_pack lanza error); las solicitudes antiguas aún se pueden resolver.
    cur.execute("reset role"); cur.execute("select set_config('request.jwt.claim.sub','',false)")
    cur.execute("insert into credit_requests(user_id,pack_code,pack_name,credits,price_usd,price_bs,method) select %s, code, name, credits + bonus, 0, credits * 4, %s from credit_packs where code=%s returning id", (ag, method, code)); rid = cur.fetchone()[0]
    cur.execute("select set_config('request.jwt.claim.sub',%s,false)", (adm,)); cur.execute("set role authenticated")
    cur.execute("select admin_resolve_credit_request(%s,true)", (rid,)); cur.execute("reset role")
    return one("select description from credit_ledger where user_id=%s order by id desc limit 1", (ag,))
cur.execute("update credit_packs set price_bs = credits*4 where price_bs is null")
eq("Esencial: sin regalo", buy('esencial'), 'Pack Esencial · 50 créditos · transferencia')
eq("Profesional: 150 + 10", buy('profesional', 'qr'), 'Pack Profesional · 150 + 10 de regalo · qr')
eq("Exclusivo: 400 + 40", buy('exclusivo', 'efectivo'), 'Pack Exclusivo · 400 + 40 de regalo · efectivo')
eq("el saldo suma créditos + regalo", one("select balance from credit_wallets where user_id=%s", (ag,)), 50 + 160 + 440)
eq("montos del historial", [r for r in (lambda: (cur.execute("select amount from credit_ledger where user_id=%s order by id", (ag,)), [x[0] for x in cur.fetchall()])[1])()], [50, 160, 440])
print("\nFALLAS:", fails); sys.exit(1 if fails else 0)
