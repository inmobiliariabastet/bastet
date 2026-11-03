"""Pruebas de supabase/account-deletion.sql: eliminar la cuenta solo sin pagos pendientes ni disputas; anonimiza y cierra el acceso.
Requiere:  pip install pgserver psycopg2-binary   y se ejecuta con:  python tests/account_deletion_sql_test.py
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

chk("anónimo no puede consultar", as_(None, "select public.my_account_deletion_check()"), True)
chk("anónimo no puede eliminar", as_(None, "select public.delete_my_account('ELIMINAR')"), True)
r = as_(adm, "select public.delete_my_account('ELIMINAR')")
chk("un administrador no puede eliminarse por aquí", r, True)
eq("con el motivo claro", 'administración' in r[1], True)
eq("la función interna no está abierta a usuarios", as_(own, "select public._account_blockers(%s)", (own,))[0], 'ERR')

su("insert into auth.users(email,invited_at) values ('u1@x','2026-01-01') returning id"); clean = cur.fetchone()[0]
su("update public.profiles set display_name='Ana Limpia', full_name='Ana Limpia Perez', whatsapp='77111111', city='La Paz', company='ACME', contact_whatsapp='77111111', interest='agente', registered_at=now() where id=%s", (clean,))
pr = autoins('properties', title='Casa de Ana', owner_id=clean, status='available', operation='venta', price='1000', currency='USD', property_type='casa')[0]
autoins('property_favorites', user_id=clean, property_id=pr)
eq("sin pendientes puede eliminar", check(clean)['can_delete'], True)

def blocked(name, uid, table, **ov):
    row = autoins(table, **ov)
    eq(name + " bloquea", check(uid)['can_delete'], False)
    chk(name + ": eliminar falla", as_(uid, "select public.delete_my_account('ELIMINAR')"), True)
    return row

su("insert into auth.users(email,invited_at) values ('u2@x','2026-01-01') returning id"); u2 = cur.fetchone()[0]
su("update public.profiles set display_name='U2', registered_at=now() where id=%s", (u2,))
p2 = autoins('properties', title='P2', owner_id=u2, status='available', operation='venta', price='1000', currency='USD', property_type='casa')[0]
cx = blocked("conexión con pago pendiente", u2, 'connections', property_id=p2, titular_id=u2, status='aceptada_pendiente_pago', operation='venta', interested_type='comprador')
su("update connections set status='cancelada' where id=%s", (cx[0],))
eq("conexión cancelada ya no bloquea", check(u2)['can_delete'], True)
cx2 = blocked("inmueble con conexión pagada sin cerrar", u2, 'connections', property_id=p2, titular_id=u2, status='conexion_generada', operation='venta', interested_type='comprador')
su("update properties set status='sold' where id=%s", (p2,))
eq("inmueble ya vendido ya no bloquea", check(u2)['can_delete'], True)
op = blocked("comisión por pagar", u2, 'operations', titular_id=u2, status='confirmada', commission_status='exigible', kind='venta')
su("update operations set commission_status='pagada' where id=%s", (op[0],))
eq("comisión pagada ya no bloquea", check(u2)['can_delete'], True)
iv = blocked("investigación abierta", u2, 'investigations', subject_id=u2, status='abierta', kind='otra')
su("update investigations set status='resuelta' where id=%s", (iv[0],))
eq("investigación resuelta sin penalización ya no bloquea", check(u2)['can_delete'], True)
su("update investigations set penalty_status='impuesta' where id=%s", (iv[0],))
eq("penalización impuesta bloquea", check(u2)['can_delete'], False)
su("update investigations set penalty_status='pagada' where id=%s", (iv[0],))
eq("penalización pagada ya no bloquea", check(u2)['can_delete'], True)
sb = blocked("reserva en disputa", u2, 'stay_bookings', host_id=u2, status='en_disputa', property_id=p2, currency='USD', guest_phone='70000000', guests=2, nights=2, check_in=datetime.date.today() + datetime.timedelta(days=30), check_out=datetime.date.today() + datetime.timedelta(days=32))
su("update stay_bookings set status='cancelada' where id=%s", (sb[0],))
eq("reserva cancelada ya no bloquea", check(u2)['can_delete'], True)
co = blocked("cobranza pendiente", u2, 'collections', agent_id=u2, status='pending', operation='venta')
su("update collections set status='paid' where id=%s", (co[0],))
eq("cobranza pagada ya no bloquea", check(u2)['can_delete'], True)

u = clean
chk("confirmación incorrecta falla", as_(u, "select public.delete_my_account('borrar')"), True)
chk("sin confirmar sigue activa", as_(u, "select public.my_account_deletion_check()"), False)
chk("eliminar la cuenta", as_(u, "select public.delete_my_account('eliminar')"), False)
su("select is_active, display_name, full_name, whatsapp, contact_whatsapp, city, company, avatar_url from profiles where id=%s", (u,))
eq("el perfil queda inactivo y anónimo", cur.fetchone(), (False, 'Cuenta eliminada', None, None, None, None, None, None))
eq("el correo de acceso queda anonimizado", one("select email like 'cuenta-eliminada-%%@bastet.invalid' from auth.users where id=%s", (u,)), True)
eq("el acceso queda bloqueado", one("select banned_until = 'infinity' from auth.users where id=%s", (u,)), True)
eq("el ingreso con Google queda libre", one("select count(*) from auth.identities where user_id=%s", (u,)), 0)
eq("su inmueble disponible se retira", one("select status from properties where id=%s", (pr,)), 'withdrawn')
eq("sus favoritos se borran", one("select count(*) from property_favorites where user_id=%s", (u,)), 0)
eq("ya no es un usuario activo", as_(u, "select public.is_active_user()")[1][0][0], False)
eq("no puede consultar de nuevo", as_(u, "select public.my_account_deletion_check()")[0], 'ERR')
eq("las conexiones de otro usuario siguen intactas", one("select count(*) from connections where titular_id=%s", (u2,)), 2)

chk("u2, sin pendientes, elimina su cuenta", as_(u2, "select public.delete_my_account('ELIMINAR')"), False)
eq("los registros de conexión se conservan para prueba", one("select count(*) from connections where titular_id=%s", (u2,)), 2)
eq("la operación confirmada se conserva", one("select count(*) from operations where titular_id=%s", (u2,)), 1)
print("FALLAS:", fails)
sys.exit(1 if fails else 0)
