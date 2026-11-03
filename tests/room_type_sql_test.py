"""Pruebas de supabase/room-type.sql: tipo «Habitación» y estadías temporales sin contrato marco ni verificación de propiedad.
Requiere:  pip install pgserver psycopg2-binary   y se ejecuta con:  python tests/room_type_sql_test.py
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


# ── tipo Habitación
def ins(owner, title, ptype, op):
    return as_(owner, "insert into properties (title, location, address, area, rooms, baths, description, price, currency, owner_id, operation, status, property_type) values (%s,'La Paz, Bolivia','Calle 1','20','1','1','x','50','USD',%s,%s,'available',%s)", (title, owner, op, ptype))
chk("se puede publicar una habitación en alquiler", ins(own, 'Hab alquiler', 'habitacion', 'alquiler'), False)
chk("se puede publicar una habitación como estadía temporal", ins(own, 'Hab temporal', 'habitacion', 'temporal'), False)
chk("un tipo inventado se rechaza", ins(own, 'Raro', 'castillo', 'venta'), True)
for t in ('sell_requests', 'property_requests'):
    eq("la restricción de tipo de " + t + " admite habitación", one("select count(*) from pg_constraint where conrelid = 'public.%s'::regclass and contype='c' and pg_get_constraintdef(oid) ilike '%%habitacion%%'" % t) >= 1, True)

# ── estadías temporales: sin contrato marco ni verificación de propiedad
su("update connection_settings set enabled=true, pay_instructions='Banco X cuenta 123456789', framework_text=%s where id=1", ('CONTRATO MARCO DE PRUEBA. ' + 'Texto. ' * 30,))
su("delete from framework_acceptances where user_id=%s", (other,))
chk("sin aceptar el contrato marco, vender se bloquea", ins(other, 'Casa venta', 'casa', 'venta'), True)
chk("sin aceptar el contrato marco, publicar una estadía temporal SÍ se puede", ins(other, 'Casa temporal', 'casa', 'temporal'), False)
su("set session_replication_role = replica")
pT = None
cur.execute("reset role; insert into properties (title, location, address, area, rooms, baths, description, price, currency, owner_id, operation, status, property_type) values ('Estadía X','La Paz','Calle','20','1','1','x','50','USD',%s,'temporal','available','habitacion') returning id", (own,)); pT = cur.fetchone()[0]
cur.execute("insert into properties (title, location, address, area, rooms, baths, description, price, currency, owner_id, operation, status, property_type) values ('Venta X','La Paz','Calle','80','2','1','x','90000','USD',%s,'venta','available','casa') returning id", (own,)); pV = cur.fetchone()[0]
su("set session_replication_role = origin")
r = as_(own, "select public.request_verification('propiedad', %s)", (pT,))
chk("verificar la propiedad de una estadía temporal se rechaza", r, True)
eq("…con un mensaje claro", 'estadías temporales' in r[1], True)
chk("verificar una propiedad en venta sigue funcionando", as_(own, "select public.request_verification('propiedad', %s)", (pV,)), False)
chk("el distintivo de propietario sigue disponible", as_(own, "select public.request_verification('propietario')"), False)
print("FALLAS:", fails)
sys.exit(1 if fails else 0)
