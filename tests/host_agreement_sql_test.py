"""Pruebas de supabase/host-agreement.sql: acuerdo de anfitrión de estadías temporales (texto, versión, aceptación, exigencia al publicar).
Requiere:  pip install pgserver psycopg2-binary   y se ejecuta con:  python tests/host_agreement_sql_test.py
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



def ins(owner, title, op='temporal'):
    return as_(owner, "insert into properties (title, location, address, area, rooms, baths, description, price, currency, owner_id, operation, status, property_type) values (%s,'La Paz, Bolivia','Calle 1','20','1','1','x','50','USD',%s,%s,'available','habitacion')", (title, owner, op))
su("update connection_settings set enabled=false where id=1")
su("delete from framework_acceptances"); su("delete from host_agreement_acceptances")
AG = 'ACUERDO DE ANFITRION DE PRUEBA. ' + 'Texto del acuerdo. ' * 20

r = as_(own, "select public.my_host_agreement()")
eq("sin texto no se exige el acuerdo", r[1][0][0]['required'], False)
chk("sin texto se puede publicar una estadía", ins(own, 'Estadia 1'), False)

chk("un usuario no puede guardar el acuerdo", as_(own, "select public.admin_update_host_agreement(%s)", (AG,)), True)
chk("un usuario no puede leer el panel del acuerdo", as_(own, "select public.admin_get_host_agreement()"), True)
chk("anónimo no puede ver el acuerdo", as_(None, "select public.my_host_agreement()"), True)
chk("el administrador no puede guardar un texto demasiado corto", as_(adm, "select public.admin_update_host_agreement('corto')"), True)
chk("el administrador guarda el acuerdo", as_(adm, "select public.admin_update_host_agreement(%s)", (AG,)), False)
eq("la versión sube a 2", as_(adm, "select public.admin_get_host_agreement()")[1][0][0]['version'], 2)

r = as_(own, "select public.my_host_agreement()")[1][0][0]
eq("el anfitrión debe aceptar y ve el texto", (r['required'], r['accepted'], r['text'] == AG.strip()), (True, False, True))
r = ins(own, 'Estadia 2')
chk("sin aceptar, publicar una estadía se bloquea", r, True)
eq("…con el aviso del acuerdo", 'acuerdo de anfitrión' in r[1], True)
chk("sin aceptar, publicar una venta no pide este acuerdo", ins(own, 'Venta 1', 'venta'), False)
chk("aceptar una versión equivocada falla", as_(own, "select public.accept_host_agreement(99)"), True)
chk("aceptar la versión vigente", as_(own, "select public.accept_host_agreement(2)"), False)
chk("aceptado, publica la estadía", ins(own, 'Estadia 3'), False)
eq("el administrador no necesita aceptar", as_(adm, "select public.my_host_agreement()")[1][0][0]['required'], False)
chk("el administrador publica sin aceptar", ins(adm, 'Estadia admin'), False)

# convertir una propiedad existente a estadía también exige el acuerdo
su("set session_replication_role = replica")
cur.execute("reset role; insert into properties (title, location, address, area, rooms, baths, description, price, currency, owner_id, operation, status, property_type) values ('Venta de Otto','La Paz','Calle','80','2','1','x','90000','USD',%s,'venta','available','casa') returning id", (other,)); pOt = cur.fetchone()[0]
su("set session_replication_role = origin")
chk("convertir a estadía sin aceptar se bloquea", as_(other, "update properties set operation='temporal' where id=%s", (pOt,)), True)
chk("editar otro campo de una venta no pide el acuerdo", as_(other, "update properties set title='Casa de Otto' where id=%s", (pOt,)), False)

eq("hay una aceptación de la versión 2", as_(adm, "select public.admin_get_host_agreement()")[1][0][0]['accepted_count'], 1)
as_(adm, "select public.admin_update_host_agreement(%s)", (AG + ' Cambio.',))
eq("al cambiar el texto sube a la versión 3", as_(adm, "select public.admin_get_host_agreement()")[1][0][0]['version'], 3)
chk("debe volver a aceptar: la estadía se bloquea", ins(own, 'Estadia 4'), True)
as_(own, "select public.accept_host_agreement(3)")
chk("acepta la 3 y publica", ins(own, 'Estadia 5'), False)
as_(adm, "select public.admin_update_host_agreement('')")
eq("texto vacío lo apaga sin subir la versión", as_(adm, "select public.admin_get_host_agreement()")[1][0][0]['version'], 3)
chk("apagado, publica sin aceptar", ins(other, 'Estadia 6'), False)
print("FALLAS:", fails)
sys.exit(1 if fails else 0)
