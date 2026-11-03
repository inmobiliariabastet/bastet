"""Pruebas de supabase/sell-temporal.sql: solicitudes de publicación de estadías temporales sin documentos de propiedad.
Requiere:  pip install pgserver psycopg2-binary   y se ejecuta con:  python tests/sell_temporal_sql_test.py
Levanta un Postgres local desechable: NO toca Supabase ni producción."""
import pgserver, psycopg2, sys, tempfile, pathlib, datetime, json
ROOT = pathlib.Path(__file__).resolve().parent.parent
srv = pgserver.get_server(tempfile.mkdtemp(prefix='uno-pg-'), cleanup_mode='delete')
uri = srv.get_uri()
R_ = str(ROOT / "supabase") + "/"
sch = open(R_ + "schema.sql", encoding='utf-8').read()
ver = open(R_ + "verification.sql", encoding="utf-8").read()
assert ver.strip().replace('\r', '') in sch.replace('\r', ''), "verification.sql no está igual a su bloque en schema.sql"
stub = open(str(ROOT / 'tests' / 'stay_bookings_sql_test.py'), encoding='utf-8').read()
stub = stub[stub.index('stub = """') + 10:]; stub = stub[:stub.index('"""')]
c = psycopg2.connect(uri); c.autocommit = True; cur = c.cursor()
def su(sql, args=None):
    cur.execute("reset role; select set_config('request.jwt.claim.sub','',false); select set_config('request.headers','',false)"); cur.execute(sql, args)
cur.execute(stub); cur.execute(sch)
print("esquema completo aplicado")
cur.execute("insert into auth.users(email,invited_at) values ('admin@x','2026-01-01'),('own@x','2026-01-01'),('other@x','2026-01-01') returning id")
adm, own, other = [r[0] for r in cur.fetchall()]
su("update public.profiles set role='admin' where id=%s", (adm,))
su("update public.profiles set display_name='Olga Owner', full_name='Olga Owner Rojas', interest='agente', registered_at=now() where id=%s", (own,))
su("update public.profiles set display_name='Otto Other', interest='agente', registered_at=now() where id=%s", (other,))
fails = 0
def as_(uid, sql, args=None, headers=None):
    cur.execute("reset role; select set_config('request.jwt.claim.sub',%s,false); select set_config('request.headers',%s,false)", (str(uid) if uid else '', headers or ''))
    cur.execute("set role authenticated" if uid else "set role anon")
    try:
        cur.execute(sql, args)
        rc = cur.rowcount
        try: return ('ok', cur.fetchall())
        except psycopg2.ProgrammingError: return ('ok', rc)
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
def mkprop(owner, title, price='100000', op='venta', addr='Calle 1'):
    cur.execute("reset role; insert into properties (title, location, address, area, rooms, baths, description, price, currency, owner_id, operation, status, property_type) values (%s,'La Paz, Bolivia',%s,'80','2','1','x',%s,'USD',%s,%s,'available','casa') returning id", (title, addr, price, owner, op))
    return cur.fetchone()[0]
pA = mkprop(own, 'De Olga'); pB = mkprop(own, 'Otra de Olga'); pO = mkprop(other, 'De Otto')
su("set session_replication_role = origin")
FW = 'CONTRATO MARCO DE PRUEBA. ' + 'Texto. ' * 30
su("update connection_settings set enabled=true, pay_instructions='Banco X cuenta 123456789', framework_text=%s where id=1", (FW,))
su("insert into framework_acceptances(user_id, version) select u, framework_version from connection_settings, unnest(array[%s::uuid,%s::uuid]) u", (own, other))



cur.execute("alter table auth.users add column if not exists banned_until timestamptz; alter table auth.users add column if not exists phone text")
cur.execute("create table if not exists auth.identities(id serial primary key, user_id uuid); create table if not exists auth.sessions(id serial primary key, user_id uuid)")
cur.execute("insert into auth.identities(user_id) values (%s),(%s)", (own, other)); cur.execute("insert into auth.sessions(user_id) values (%s)", (own,))
import uuid as _uuid

def autoins(table, **ov):
    """Inserta una fila rellenando las columnas obligatorias sin valor por defecto (con los valores dados)."""
    su("select column_name, data_type from information_schema.columns where table_schema='public' and table_name=%s and is_nullable='NO' and column_default is null and is_generated='NEVER' and is_identity='NO'", (table,))
    cols = cur.fetchall(); names, vals = [], []
    for n, t in cols:
        if n in ov: v = ov[n]
        elif t == 'uuid': v = str(_uuid.uuid4())
        elif t in ('numeric', 'integer', 'bigint', 'smallint', 'double precision'): v = 10
        elif t == 'boolean': v = False
        elif t == 'date': v = datetime.date.today() + datetime.timedelta(days=30)
        elif t.startswith('timestamp'): v = datetime.datetime.now(datetime.timezone.utc)
        elif t in ('jsonb', 'json'): v = '{}'
        else: v = 'x' + _uuid.uuid4().hex[:11]
        names.append(n); vals.append(v)
    for k, v in ov.items():
        if k not in names: names.append(k); vals.append(v)
    su("set session_replication_role = replica")
    cur.execute("insert into public.%s (%s) values (%s) returning *" % (table, ','.join(names), ','.join(['%s'] * len(vals))), vals)
    r = cur.fetchone(); su("set session_replication_role = origin"); return r

def check(uid):
    return as_(uid, "select public.my_account_deletion_check()")[1][0][0]



import uuid as _uuid
def payload(op, ds, needs=False, ptype='habitacion'):
    i = str(_uuid.uuid4())
    return json.dumps({'id': i, 'owner_name': 'Persona Prueba', 'owner_phone': '+59170%06d' % (_uuid.uuid4().int % 1000000), 'property_type': ptype, 'operation': op, 'city': 'La Paz',
                       'address': 'Calle Falsa 123', 'doc_status': ds, 'needs_legal_support': needs, 'documents': [], 'consent': True})
def send(p, ip='198.51.100.%d' % (_uuid.uuid4().int % 200 + 1)):
    return as_(None, "select public.submit_sell_request(%s::jsonb)", (p,), headers='{"x-forwarded-for":"%s"}' % ip)
chk("estadía temporal sin documentos de propiedad (no_aplica)", send(payload('temporal', 'no_aplica')), False)
r = send(payload('venta', 'no_aplica'))
chk("una venta no puede declarar «no aplica»", r, True)
chk("una venta con documentos en regla sigue valiendo", send(payload('venta', 'en_regla', ptype='casa')), False)
chk("un alquiler sin documentos exige apoyo legal (se marca solo)", send(payload('alquiler', 'sin_documentos', ptype='departamento')), False)
chk("estado inventado se rechaza", send(payload('temporal', 'quiza')), True)
su("select count(*) from sell_requests where doc_status = 'no_aplica' and operation = 'temporal'")
eq("quedó guardada la estadía temporal con no_aplica", cur.fetchone()[0], 1)
print("FALLAS:", fails)
sys.exit(1 if fails else 0)
