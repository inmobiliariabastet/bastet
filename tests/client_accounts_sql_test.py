"""Pruebas de supabase/client-accounts.sql: cuentas de cliente, contratos solo para agentes, solicitudes y reservas ligadas a la cuenta.
Requiere:  pip install pgserver psycopg2-binary   y se ejecuta con:  python tests/client_accounts_sql_test.py
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


su("update connection_settings set enabled=false where id=1")
def newuser(email):
    su("insert into auth.users(email,invited_at) values (%s,'2026-01-01') returning id", (email,)); return cur.fetchone()[0]
def reg(uid, interest, company='ACME'):
    return as_(uid, "select public.complete_registration('Persona Prueba', '77123456', 'La Paz', %s, %s, true, false, true)", (company, interest))
def acct(uid):
    return as_(uid, "select public.my_account()")[1][0][0]

cli = newuser('cli@x'); own2 = newuser('own2@x'); ag = newuser('ag@x'); em = newuser('em@x'); oth = newuser('oth@x')
# ── registro con el nuevo tipo
chk("tipo inventado se rechaza", reg(cli, 'turista'), True)
chk("registro como cliente", reg(cli, 'cliente'), False)
su("select interest, company from profiles where id=%s", (cli,))
eq("cliente: sin empresa guardada", cur.fetchone(), ('cliente', None))
for u, t in ((own2, 'propietario'), (ag, 'agente'), (em, 'empresa'), (oth, 'cliente')): reg(u, t)
a = acct(cli)
eq("cliente: tipo, sin herramientas de agente", (a['account']['type'], a['account']['agent_tools'], a['account']['client'], a['account']['name']), ('cliente', False, True, 'Cliente'))
eq("propietario: sin herramientas de agente", acct(own2)['account']['agent_tools'], False)
eq("agente: con herramientas de agente", acct(ag)['account']['agent_tools'], True)
eq("empresa: con herramientas de agente", acct(em)['account']['agent_tools'], True)
eq("administrador: con herramientas de agente", acct(adm)['account']['agent_tools'], True)

# ── nadie edita su tipo a mano
as_(cli, "update profiles set interest='agente' where id=%s", (cli,))
eq("el tipo no se cambia con un UPDATE directo", one("select interest from profiles where id=%s", (cli,)), 'cliente')

# ── publicar
def ins(uid, title):
    return as_(uid, "insert into properties (title, location, address, area, rooms, baths, description, price, currency, owner_id, operation, status, property_type) values (%s,'La Paz, Bolivia','Calle 1','80','2','1','x','1000','USD',%s,'venta','available','casa')", (title, uid))
r = ins(cli, 'De cliente')
chk("un cliente no publica inmuebles", r, True)
eq("con un mensaje claro", 'cuentas de cliente' in r[1], True)
chk("un propietario publica", ins(own2, 'De propietario'), False)
chk("un agente publica", ins(ag, 'De agente'), False)

# ── cambiar de tipo: solo desde cliente
chk("un agente no puede cambiar su tipo solo", as_(ag, "select public.change_account_type('propietario')"), True)
chk("un administrador no cambia de tipo", as_(adm, "select public.change_account_type('agente')"), True)
chk("un cliente no puede pasar a un tipo inventado", as_(cli, "select public.change_account_type('cliente')"), True)
chk("un cliente pasa a propietario", as_(cli, "select public.change_account_type('propietario')"), False)
eq("…y queda como propietario", one("select interest from profiles where id=%s", (cli,)), 'propietario')
chk("ya como propietario puede publicar", ins(cli, 'Ahora sí'), False)
chk("y no puede volver a cliente solo", as_(cli, "select public.change_account_type('agente')"), True)

# ── contratos solo para agente / empresa / admin (el disparador usa la sesión simulada)
def as_claim(uid, table, **ov):
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
    su("select set_config('request.jwt.claim.sub', %s, false)", (str(uid) if uid else '',))
    try:
        cur.execute("insert into public.%s (%s) values (%s) returning *" % (table, ','.join(names), ','.join(['%s'] * len(vals))), vals)
        return ('ok', cur.fetchone())
    except Exception as e: return ('ERR', str(e).splitlines()[0])
su("set session_replication_role = origin")
cli2 = newuser('cli2@x'); reg(cli2, 'cliente')
for who, uid, bad in (('cliente', cli2, True), ('propietario', own2, True), ('agente', ag, False), ('empresa', em, False), ('administrador', adm, False)):
    r = as_claim(uid, 'exclusivity_contracts', agent_id=uid, template_version='exclusividad-v2', data='{}', idempotency_key='k' + _uuid.uuid4().hex[:8])
    msg = str(r[1])
    ok_block = (r[0] == 'ERR' and 'solo para cuentas de agente o de empresa' in msg)
    eq("contrato de exclusividad: " + who + (" bloqueado" if bad else " permitido"), ok_block if bad else ('solo para cuentas' not in msg), True)

# ── solicitudes y reservas quedan ligadas a la cuenta
pr = autoins('properties', title='Casa P', owner_id=ag, status='available', operation='venta', price='1000', currency='USD', property_type='casa')[0]
pt = autoins('properties', title='Estadia P', owner_id=ag, status='available', operation='temporal', price='50', currency='USD', property_type='casa')[0]
r1 = as_claim(cli2, 'connections', property_id=pr, titular_id=ag, status='solicitada', operation='venta', interested_type='comprador', code='C000000001')
eq("la solicitud queda ligada a la cuenta", str(one("select interested_user_id from connections where code='C000000001'")), str(cli2))
as_claim(None, 'connections', property_id=pr, titular_id=ag, status='solicitada', operation='venta', interested_type='comprador', code='C000000002')
eq("sin sesión queda sin cuenta", one("select interested_user_id from connections where code='C000000002'"), None)
as_claim(cli2, 'connections', property_id=pr, titular_id=ag, status='conexion_generada', operation='venta', interested_type='comprador', code='C000000003')
as_claim(oth, 'connections', property_id=pr, titular_id=ag, status='solicitada', operation='venta', interested_type='comprador', code='C000000004')
su("update profiles set contact_whatsapp='76543210' where id=%s", (ag,))
reqs = as_(cli2, "select public.my_client_requests()")[1][0][0]
eq("mis solicitudes: solo las mías", sorted(x['code'] for x in reqs), ['C000000001', 'C000000003'])
eq("el contacto solo aparece con la conexión generada", {x['code']: x['contact_phone'] for x in reqs}, {'C000000001': None, 'C000000003': '76543210'})
eq("no trae nombres ni teléfonos de otras personas", any(k in json.dumps(reqs) for k in ('interested_name', 'interested_phone')), False)
chk("anónimo no ve solicitudes", as_(None, "select public.my_client_requests()"), True)
as_claim(cli2, 'stay_bookings', host_id=ag, status='aceptada_pendiente_pago', property_id=pt, currency='USD', guest_phone='70000000', guests=2, nights=2,
         check_in=datetime.date.today() + datetime.timedelta(days=30), check_out=datetime.date.today() + datetime.timedelta(days=32), accepted_at=datetime.datetime.now(datetime.timezone.utc), code='B000000001')
as_claim(oth, 'stay_bookings', host_id=ag, status='pendiente_respuesta_anfitrion', property_id=pt, currency='USD', guest_phone='70000001', guests=2, nights=2,
         check_in=datetime.date.today() + datetime.timedelta(days=40), check_out=datetime.date.today() + datetime.timedelta(days=42), code='B000000002')
bks = as_(cli2, "select public.my_client_bookings()")[1][0][0]
eq("mis reservas: solo las mías", [x['code'] for x in bks], ['B000000001'])
eq("con el plazo de pago", bks[0]['pay_by'] is not None, True)
eq("sin teléfonos de nadie", any(k in json.dumps(bks) for k in ('guest_phone', '70000000', 'guest_name')), False)
chk("anónimo no ve reservas", as_(None, "select public.my_client_bookings()"), True)

# ── precarga de formularios
d = as_(cli2, "select public.my_prefill()")[1][0][0]
eq("precarga con sesión: nombre y WhatsApp", (d['signed_in'], d['name'], d['phone']), (True, 'Persona Prueba', '77123456'))
eq("sin sesión no hay datos", as_(None, "select public.my_prefill()")[1][0][0], {'signed_in': False})

print("FALLAS:", fails)
sys.exit(1 if fails else 0)
