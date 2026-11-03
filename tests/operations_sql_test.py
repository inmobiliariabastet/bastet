"""Pruebas de supabase/operations.sql (fase 3): protección de propiedades con conexiones, cierre de operaciones con confirmación del interesado,
comisiones congeladas en Bs, casos en revisión sin atribución automática, pago de la comisión y desistimiento con declaración jurada.
Requiere:  pip install pgserver psycopg2-binary   y se ejecuta con:  python tests/operations_sql_test.py
Levanta un Postgres local desechable: NO toca Supabase ni producción."""
import pgserver, psycopg2, sys, tempfile, pathlib, datetime
ROOT = pathlib.Path(__file__).resolve().parent.parent
srv = pgserver.get_server(tempfile.mkdtemp(prefix='uno-pg-'), cleanup_mode='delete')
uri = srv.get_uri()
R_ = str(ROOT / "supabase") + "/"
sch = open(R_ + "schema.sql", encoding='utf-8').read()
ops = open(R_ + "operations.sql", encoding="utf-8").read()
assert ops.strip().replace('\r', '') in sch.replace('\r', ''), "operations.sql no está igual a su bloque en schema.sql"
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
su("update public.profiles set display_name='Olga Owner', interest='agente', registered_at=now() where id=%s", (own,))
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
def row(sql, a=None):
    su(sql, a); return cur.fetchone()
su("set session_replication_role = replica")
def mkprop(owner, title, price='100000', cur_='USD', op='venta'):
    cur.execute("reset role; insert into properties (title, location, area, rooms, baths, description, price, currency, owner_id, operation, status, property_type) values (%s,'La Paz','80','2','1','x',%s,%s,%s,%s,'available','casa') returning id", (title, price, cur_, owner, op))
    return cur.fetchone()[0]
pV = mkprop(own, 'Casa en venta'); pA = mkprop(own, 'Depto en alquiler', '2000', 'BOB', 'alquiler'); pC = mkprop(own, 'Anticrético', '30000', 'USD', 'anticretico')
pF = mkprop(own, 'Sin conexiones'); pS = mkprop(own, 'Otra venta'); pO = mkprop(other, 'De Otto'); pR = mkprop(own, 'Para revisar'); pX = mkprop(own, 'Para desistir')
su("set session_replication_role = origin")
today = one("select public.bo_today()")
D = lambda n: today + datetime.timedelta(days=n)
YEAR = datetime.datetime.now().year

def verified_conn(prop, phone, holder=own):
    code = as_(None, "select request_connection(%s,'Gaby Huésped',%s,null,null,true)", (prop, phone))[1][0][0]
    cid = one("select id from connections where code=%s", (code,))
    as_(holder, "select respond_connection(%s, true)", (cid,))
    su("update connections set status='conexion_generada', verified_at=now() where id=%s", (cid,))
    return cid
FW = 'CONTRATO MARCO DE PRUEBA. ' + 'Texto. ' * 30
su("update connection_settings set enabled=true, pay_instructions='Banco X cuenta 123456789', framework_text=%s where id=1", (FW,))
su("insert into framework_acceptances(user_id, version) select %s, framework_version from connection_settings", (own,))
su("insert into framework_acceptances(user_id, version) select %s, framework_version from connection_settings", (other,))

# --- sin conexiones activas todo sigue como siempre
su("update connection_settings set enabled=false where id=1")
cV = None
chk("con las conexiones apagadas el titular marca vendida a mano", as_(own, "update properties set status='sold' where id=%s", (pF,)), False)
su("update properties set status='available' where id=%s", (pF,))
su("update connection_settings set enabled=true where id=1")

# --- una propiedad con conexiones queda protegida
cV = verified_conn(pV, '+591 70000001')
chk("propiedad con conexión: el titular NO la marca vendida a mano", as_(own, "update properties set status='sold' where id=%s", (pV,)), True)
r = as_(own, "update properties set status='sold' where id=%s", (pV,))
eq("el mensaje indica «Cerrar operación»", 'Cerrar operación' in r[1], True)
chk("…ni la borra", as_(own, "delete from properties where id=%s", (pV,)), True)
eq("…la propiedad sigue ahí", one("select status from properties where id=%s", (pV,)), 'available')
chk("una propiedad SIN conexiones sí se marca vendida", as_(own, "update properties set status='sold' where id=%s", (pF,)), False)
su("update properties set status='available' where id=%s", (pF,))
chk("editar otros datos de la propiedad protegida sí se puede", as_(own, "update properties set title='Casa renovada' where id=%s", (pV,)), False)
chk("el admin sí puede", as_(adm, "update properties set status='sold' where id=%s", (pV,)), False)
su("update properties set status='available' where id=%s", (pV,))
cs = as_(own, "select closure_state(%s)", (pV,))[1][0][0]
eq("estado del cierre: protegida, con la conexión verificada", (cs['protected'], [x['name'] for x in cs['connections']], cs['desist_ready']), (True, ['Gaby H.'], False))
chk("otra cuenta no consulta el cierre ajeno", as_(other, "select closure_state(%s)", (pV,)), True)

# --- inicio del cierre: validaciones
S = "select start_property_closure(%s,%s,%s,%s,%s,%s,%s)"
chk("anónimo no cierra", as_(None, S, (pV, 'venta', cV, 'Gaby Huésped', 100000, 'USD', D(0))), True)
chk("otra cuenta no cierra propiedades ajenas", as_(other, S, (pV, 'venta', cV, 'Gaby Huésped', 100000, 'USD', D(0))), True)
chk("el tipo debe coincidir con la propiedad", as_(own, S, (pV, 'alquiler', cV, 'Gaby Huésped', 100000, 'USD', D(0))), True)
chk("monto obligatorio", as_(own, S, (pV, 'venta', cV, 'Gaby Huésped', 0, 'USD', D(0))), True)
chk("moneda válida", as_(own, S, (pV, 'venta', cV, 'Gaby Huésped', 1000, 'EUR', D(0))), True)
chk("fecha futura no vale", as_(own, S, (pV, 'venta', cV, 'Gaby Huésped', 1000, 'USD', D(3))), True)
chk("fecha muy antigua no vale", as_(own, S, (pV, 'venta', cV, 'Gaby Huésped', 1000, 'USD', D(-200))), True)
chk("nombre obligatorio", as_(own, S, (pV, 'venta', cV, 'A', 1000, 'USD', D(0))), True)
chk("la conexión debe ser de esta propiedad", as_(own, S, (pV, 'venta', verified_conn(pS, '+591 70000099'), 'Gaby Huésped', 1000, 'USD', D(0))), True)

# --- venta a la persona de la conexión: confirma por su enlace
r = as_(own, S, (pV, 'venta', cV, 'Gaby Huésped', 100000, 'USD', D(-1))); chk("el titular inicia el cierre con la conexión", r, False)
op = r[1][0][0]
eq("queda pendiente de la confirmación del interesado", op['status'], 'pendiente_interesado')
eq("la propiedad sigue disponible mientras tanto", one("select status from properties where id=%s", (pV,)), 'available')
chk("no se inicia otro cierre mientras hay uno en curso", as_(own, S, (pV, 'venta', cV, 'Gaby Huésped', 100000, 'USD', D(-1))), True)
g = as_(None, "select get_operation_confirmation(%s)", (op['token'],))[1][0][0]
eq("el interesado ve qué confirma (sin datos personales)", (g['valid'], g['kind'], g['title'], float(g['amount']), g['currency']), (True, 'venta', 'Casa renovada', 100000.0, 'USD'))
eq("token inválido", as_(None, "select get_operation_confirmation('nada')")[1][0][0], {'valid': False})
chk("token inválido no confirma", as_(None, "select respond_operation_confirmation('nada', true)"), True)
chk("el interesado confirma sin cuenta", as_(None, "select respond_operation_confirmation(%s, true)", (op['token'],)), False)
su("select status, number, commission_status, commission_percent, commission_amount, commission_bs, bob_per_usd_used from operations where id=%s", (op['id'],))
st, num, cs_, pct, amt, bs_, rate = cur.fetchone()
eq("operación confirmada con constancia numerada", (st, num), ('confirmada', 'BST-OP-%d-0001' % YEAR))
eq("comisión de venta 0,75 % de 100.000 USD = 750 USD = Bs 5.220 (tipo de cambio interno 6,96), exigible", (cs_, float(pct), float(amt), float(bs_), float(rate)), ('exigible', 0.75, 750.0, 5220.0, 6.96))
eq("la propiedad se cerró", one("select status from properties where id=%s", (pV,)), 'sold')
chk("el enlace sirve una sola vez", as_(None, "select respond_operation_confirmation(%s, true)", (op['token'],)), True)
su("update stay_settings set bob_per_usd = 7.50 where id=1")
eq("cambiar el tipo de cambio después NO modifica la comisión ya congelada", float(one("select commission_bs from operations where id=%s", (op['id'],))), 5220.0)
su("update stay_settings set bob_per_usd = 6.96 where id=1")

# --- alquiler y anticrético
cA = verified_conn(pA, '+591 70000002')
oa = as_(own, S, (pA, 'alquiler', cA, 'Rita Inquilina', 2000, 'BOB', D(0)))[1][0][0]
as_(None, "select respond_operation_confirmation(%s, true)", (oa['token'],))
eq("alquiler: un mes de canon (Bs 2.000)", (float(one("select commission_bs from operations where id=%s", (oa['id'],))), one("select commission_percent from operations where id=%s", (oa['id'],))), (2000.0, None))
cC = verified_conn(pC, '+591 70000003')
oc = as_(own, S, (pC, 'anticretico', cC, 'Ana Anticresista', 30000, 'USD', D(0)))[1][0][0]
as_(None, "select respond_operation_confirmation(%s, true)", (oc['token'],))
eq("anticrético: 2 % de 30.000 USD = 600 USD = Bs 4.176", float(one("select commission_bs from operations where id=%s", (oc['id'],))), 4176.0)
eq("constancias correlativas", sorted(r[0] for r in (su("select number from operations where number is not null") or cur.fetchall())), ['BST-OP-%d-000%d' % (YEAR, k) for k in (1, 2, 3)])

# --- el interesado NO confirma → revisión, sin atribución automática
pN = mkprop(own, 'Disputada'); cN = verified_conn(pN, '+591 70000004')
on = as_(own, S, (pN, 'venta', cN, 'Gaby Huésped', 50000, 'USD', D(0)))[1][0][0]
eq("el interesado niega: pasa a revisión", as_(None, "select respond_operation_confirmation(%s, false)", (on['token'],))[1][0][0]['status'], 'en_revision')
eq("la propiedad sigue activa", one("select status from properties where id=%s", (pN,)), 'available')
chk("y sigue protegida: el titular no la cierra a mano", as_(own, "update properties set status='sold' where id=%s", (pN,)), True)
chk("el titular no resuelve la revisión", as_(own, "select admin_resolve_operation(%s,'sin_comision','x')", (on['id'],)), True)
chk("el admin debe explicar su decisión", as_(adm, "select admin_resolve_operation(%s,'confirmar','')", (on['id'],)), True)
chk("decisión inválida", as_(adm, "select admin_resolve_operation(%s,'borrar','nota')", (on['id'],)), True)
chk("el admin confirma tras analizar el caso", as_(adm, "select admin_resolve_operation(%s,'confirmar','Se verificó la relación con el interesado por chat')", (on['id'],)), False)
eq("quedó confirmada con comisión (0,75 % de 50.000 USD = Bs 2.610)", (one("select status from operations where id=%s", (on['id'],)), float(one("select commission_bs from operations where id=%s", (on['id'],)))), ('confirmada', 2610.0))
eq("y la propiedad se cerró", one("select status from properties where id=%s", (pN,)), 'sold')

# --- vendió a OTRA persona: sin atribución automática
cR = verified_conn(pR, '+591 70000005')
orr = as_(own, S, (pR, 'venta', None, 'Pedro Pérez', 80000, 'USD', D(0)))[1][0][0]
eq("a otra persona: va directo a revisión", orr['status'], 'en_revision')
eq("sin token (no hay a quién pedir confirmación)", orr['token'], None)
eq("la propiedad sigue activa hasta resolver", one("select status from properties where id=%s", (pR,)), 'available')
chk("el titular puede cancelar su solicitud", as_(own, "select cancel_property_closure(%s)", (orr['id'],)), False)
orr = as_(own, S, (pR, 'venta', None, 'Pedro Pérez', 80000, 'USD', D(0)))[1][0][0]
chk("el admin cierra sin comisión si no hay relación", as_(adm, "select admin_resolve_operation(%s,'sin_comision','No hay relación con el interesado de la conexión')", (orr['id'],)), False)
eq("confirmada sin comisión", row("select status, commission_status, commission_bs from operations where id=%s", (orr['id'],)), ('confirmada', 'no_aplica', None))
pR2 = mkprop(own, 'Rechazo'); verified_conn(pR2, '+591 70000006')
o2 = as_(own, S, (pR2, 'venta', None, 'Otra Persona', 60000, 'USD', D(0)))[1][0][0]
chk("el admin puede rechazar", as_(adm, "select admin_resolve_operation(%s,'rechazar','El titular no presentó pruebas')", (o2['id'],)), False)
eq("rechazada: la propiedad sigue disponible", (one("select status from operations where id=%s", (o2['id'],)), one("select status from properties where id=%s", (pR2,))), ('rechazada', 'available'))

# --- pago de la comisión con comprobante
mine = as_(own, "select my_operations()")[1][0][0]
it = [x for x in mine['items'] if x['id'] == op['id']][0]
eq("el titular ve su comisión exigible y el enlace ya no", (it['commission_status'], float(it['commission_bs']), it['interested_token']), ('exigible', 5220.0, None))
eq("el titular no ve operaciones ajenas", len(as_(other, "select my_operations()")[1][0][0]['items']), 0)
chk("no adjunta a una ruta ajena", as_(own, "select attach_operation_proof(%s, %s)", (op['id'], str(other) + '/x.png')), True)
chk("otra cuenta no adjunta", as_(other, "select attach_operation_proof(%s, %s)", (op['id'], str(other) + '/x.png')), True)
chk("el titular adjunta su comprobante", as_(own, "select attach_operation_proof(%s, %s)", (op['id'], str(own) + '/c.png')), False)
chk("el titular no verifica pagos", as_(own, "select admin_review_operation_proof(%s, true, null)", (op['id'],)), True)
chk("rechazar exige motivo", as_(adm, "select admin_review_operation_proof(%s, false, null)", (op['id'],)), True)
chk("el admin rechaza con motivo", as_(adm, "select admin_review_operation_proof(%s, false, 'Monto incorrecto')", (op['id'],)), False)
eq("vuelve a exigible con el motivo", row("select commission_status, review_note from operations where id=%s", (op['id'],)), ('exigible', 'Monto incorrecto'))
chk("sube otro", as_(own, "select attach_operation_proof(%s, %s)", (op['id'], str(own) + '/c2.png')), False)
chk("el admin verifica", as_(adm, "select admin_review_operation_proof(%s, true, 'OK')", (op['id'],)), False)
eq("comisión pagada", one("select commission_status from operations where id=%s", (op['id'],)), 'pagada')
chk("no se revisa dos veces", as_(adm, "select admin_review_operation_proof(%s, true, null)", (op['id'],)), True)
ev = as_(adm, "select operation_events(%s)", (op['id'],))[1][0][0]
eq("auditoría completa de la operación", [e['event'] for e in ev], ['cierre_iniciado', 'confirmada', 'interesado_confirma', 'comprobante_enviado', 'comprobante_rechazado', 'comprobante_enviado', 'comision_pagada'])
chk("el titular no lee la auditoría", as_(own, "select operation_events(%s)", (op['id'],)), True)

# --- desistimiento con declaración jurada
pD = mkprop(own, 'Desiste'); verified_conn(pD, '+591 70000007')
chk("sin texto de declaración no se puede retirar", as_(own, "select desist_property(%s, true, 'Cambié de opinión')", (pD,)), True)
chk("solo el admin define el texto", as_(own, "select admin_update_desist_text('x')"), True)
chk("el admin fija la declaración jurada (borrador)", as_(adm, "select admin_update_desist_text(%s)", ('DECLARACIÓN JURADA DE DESISTIMIENTO. Declaro que ' * 5,)), False)
eq("versión 2 al fijar el texto", one("select desist_version from connection_settings"), 2)
chk("debe aceptar la declaración", as_(own, "select desist_property(%s, false, 'Cambié de opinión')", (pD,)), True)
chk("debe dar el motivo", as_(own, "select desist_property(%s, true, '')", (pD,)), True)
chk("otra cuenta no retira propiedades ajenas", as_(other, "select desist_property(%s, true, 'x')", (pD,)), True)
r = as_(own, "select desist_property(%s, true, 'Cambié de opinión')", (pD,)); chk("el titular desiste y retira", r, False)
eq("propiedad retirada (no vendida)", one("select status from properties where id=%s", (pD,)), 'withdrawn')
eq("queda guardada la declaración aceptada (versión, texto y fecha)", row("select kind, status, declaration_version, left(declaration_text, 21), declaration_at is not null, reason from operations where id=%s", (r[1][0][0]['id'],)),
   ('desistimiento', 'desistida', 2, 'DECLARACIÓN JURADA DE', True, 'Cambié de opinión'))
eq("una propiedad retirada no es pública", len(as_(None, "select id from properties where id=%s", (pD,))[1]), 0)

# --- límites
n_ok = 0
for k in range(35): n_ok += as_(None, "select get_operation_confirmation('abc')", headers='{"x-forwarded-for":"203.0.113.50"}')[0] == 'ok'
eq("las consultas por enlace se limitan a 30 por minuto por IP", n_ok, 30)
chk("anónimo no ve tablas privadas", as_(None, "select * from operations"), True)
chk("el titular no escribe directo en operaciones", as_(own, "update operations set commission_status='pagada'"), True)

su("select 1")
for _ in range(2): cur.execute(ops)
print("operations.sql re-corrido sin error")
print("FALLAS:", fails); sys.exit(1 if fails else 0)
