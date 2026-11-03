"""Pruebas de supabase/verification.sql (fase 4): tres distintivos independientes con comprobaciones obligatorias, propiedad pendiente sin conexiones,
reseñas ligadas a operaciones concretadas, certificado público y acta, consultas públicas sin datos personales.
Requiere:  pip install pgserver psycopg2-binary   y se ejecuta con:  python tests/verification_sql_test.py
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

# ── nadie se concede un distintivo
chk("el usuario no se concede «agente verificado»", as_(own, "update profiles set agent_verified=true, owner_verified=true, public_code='AG-HACK00' where id=%s", (own,)), False)
eq("…y no cambia", su("select agent_verified, owner_verified, public_code from profiles where id=%s", (own,)) or cur.fetchone(), (False, False, None))
chk("el usuario no marca su propiedad como verificada", as_(own, "update properties set verified=true where id=%s", (pA,)), False)
eq("…y no cambia", one("select verified from properties where id=%s", (pA,)), False)
INS = "insert into properties(id,title,location,price,area,rooms,baths,owner_id,operation,verified) values (gen_random_uuid(),'Nueva','La Paz','1000','100','3','2',%s,'venta',true) returning verified"
eq("una propiedad nueva nunca nace verificada", as_(own, INS, (own,))[1][0][0], False)
chk("anónimo no ve tablas de verificación", as_(None, "select * from verification_requests"), True)
eq("el público lee las marcas de verificación", as_(None, "select verified from properties where id=%s", (pA,))[1][0][0], False)

# ── solicitudes
chk("anónimo no solicita", as_(None, "select request_verification('agente')"), True)
chk("tipo inválido", as_(own, "select request_verification('otro')"), True)

chk("propiedad: debe ser tuya", as_(own, "select request_verification('propiedad', %s)", (pO,)), True)
chk("propiedad: hay que elegir una", as_(own, "select request_verification('propiedad')"), True)
rA = as_(own, "select request_verification('agente')"); chk("el agente solicita su verificación", rA, False); rA = rA[1][0][0]
eq("pedirla otra vez devuelve la misma solicitud", as_(own, "select request_verification('agente')")[1][0][0], rA)
chk("enviar sin documentos no vale", as_(own, "select submit_verification(%s)", (rA,)), True)
chk("no se adjunta a una ruta ajena", as_(own, "select attach_verification_doc(%s, %s, 'Cédula')", (rA, str(other) + '/x.pdf')), True)
chk("el documento necesita una descripción", as_(own, "select attach_verification_doc(%s, %s, 'x')", (rA, str(own) + '/x.pdf')), True)
chk("otra cuenta no adjunta a mi solicitud", as_(other, "select attach_verification_doc(%s, %s, 'Cédula de identidad')", (rA, str(other) + '/x.pdf')), True)
chk("el titular sube su documento a su carpeta privada", as_(own, "insert into storage.objects(bucket_id,name) values ('verification-docs', %s)", (str(own) + '/ci.pdf',)), False)
chk("…no a la de otro", as_(own, "insert into storage.objects(bucket_id,name) values ('verification-docs', %s)", (str(other) + '/ci.pdf',)), True)
chk("anónimo no sube", as_(None, "insert into storage.objects(bucket_id,name) values ('verification-docs', %s)", (str(own) + '/z.pdf',)), True)
chk("adjunta la cédula", as_(own, "select attach_verification_doc(%s, %s, 'Cédula de identidad')", (rA, str(own) + '/ci.pdf')), False)
chk("envía a revisión", as_(own, "select submit_verification(%s, 'Agente de La Paz')", (rA,)), False)
chk("no se reenvía", as_(own, "select submit_verification(%s)", (rA,)), True)
mine = as_(own, "select my_verifications()")[1][0][0]
eq("el titular ve su solicitud y lo que se exige para cada distintivo", ([x['status'] for x in mine['items']], mine['required']['agente'], mine['required']['propietario'], mine['required']['propiedad']),
   (['en_revision'], ['identidad', 'telefono', 'documentacion_profesional', 'contrato_bastet'], ['identidad', 'documentacion'], ['identidad_propietario', 'documentacion_legal', 'existencia_fisica']))
eq("otra cuenta no ve solicitudes ajenas", len(as_(other, "select my_verifications()")[1][0][0]['items']), 0)
eq("el admin ve todas (con el nombre del solicitante)", [x['user_name'] for x in as_(adm, "select my_verifications()")[1][0][0]['items']], ['Olga Owner Rojas'])

# ── revisión del administrador: todas las comprobaciones o no hay distintivo
chk("el titular no aprueba su verificación", as_(own, "select admin_review_verification(%s,'aprobar','{}'::jsonb,'x')", (rA,)), True)
C4 = {'identidad': True, 'telefono': True, 'documentacion_profesional': True, 'contrato_bastet': True}
chk("no se aprueba con una comprobación incompleta", as_(adm, "select admin_review_verification(%s,'aprobar',%s::jsonb,'x')", (rA, json.dumps({**C4, 'contrato_bastet': False}))), True)
eq("…y no se concedió nada", one("select agent_verified from profiles where id=%s", (own,)), False)
chk("rechazar exige motivo", as_(adm, "select admin_review_verification(%s,'rechazar','{}'::jsonb,'')", (rA,)), True)
chk("decisión inválida", as_(adm, "select admin_review_verification(%s,'tal vez','{}'::jsonb,'x')", (rA,)), True)

chk("el admin rechaza con motivo", as_(adm, "select admin_review_verification(%s,'rechazar','{}'::jsonb,'La cédula no se lee')", (rA,)), False)
eq("rechazada: la persona ve el motivo", [x['admin_note'] for x in as_(own, "select my_verifications()")[1][0][0]['items']], ['La cédula no se lee'])
chk("no se revisa dos veces", as_(adm, "select admin_review_verification(%s,'rechazar','{}'::jsonb,'otra vez')", (rA,)), True)
rA2 = as_(own, "select request_verification('agente')")[1][0][0]
eq("tras un rechazo puede pedirla de nuevo (solicitud nueva)", rA2 != rA, True)
as_(own, "select attach_verification_doc(%s, %s, 'Cédula de identidad nítida')", (rA2, str(own) + '/ci2.pdf'))
as_(own, "select attach_verification_doc(%s, %s, 'Título profesional')", (rA2, str(own) + '/titulo.pdf'))
as_(own, "select submit_verification(%s)", (rA2,))
chk("el admin aprueba con las 4 comprobaciones", as_(adm, "select admin_review_verification(%s,'aprobar',%s::jsonb,'Todo en regla')", (rA2, json.dumps(C4))), False)
su("select agent_verified, owner_verified, public_code from profiles where id=%s", (own,)); av, ov, code = cur.fetchone()
eq("agente verificado, SIN ser propietario verificado (distintivos independientes)", (av, ov), (True, False))
eq("recibe su código público AG-XXXXXX", bool(code) and code.startswith('AG-') and len(code) == 9, True)
chk("no puede pedir de nuevo lo que ya tiene", as_(own, "select request_verification('agente')"), True)


# ── propietario verificado y propiedad verificada (independientes entre sí)
rP = as_(own, "select request_verification('propiedad', %s)", (pA,))[1][0][0]
as_(own, "select attach_verification_doc(%s, %s, 'Folio real')", (rP, str(own) + '/folio.pdf')); as_(own, "select submit_verification(%s)", (rP,))
CP = {'identidad_propietario': True, 'documentacion_legal': True, 'existencia_fisica': True}
chk("propiedad: falta comprobar la existencia física", as_(adm, "select admin_review_verification(%s,'aprobar',%s::jsonb,'x')", (rP, json.dumps({**CP, 'existencia_fisica': False}))), True)
chk("el admin verifica la propiedad", as_(adm, "select admin_review_verification(%s,'aprobar',%s::jsonb,'Visita realizada')", (rP, json.dumps(CP))), False)
eq("propiedad verificada; el titular sigue sin ser «propietario verificado»", (one("select verified from properties where id=%s", (pA,)), one("select owner_verified from profiles where id=%s", (own,))), (True, False))
chk("cambiar el precio NO quita la verificación", as_(own, "update properties set price='120000' where id=%s", (pA,)), False)
eq("…sigue verificada", one("select verified from properties where id=%s", (pA,)), True)
chk("cambiar la dirección SÍ la quita", as_(own, "update properties set address='Otra calle 99' where id=%s", (pA,)), False)
eq("…vuelve a pendiente", one("select verified from properties where id=%s", (pA,)), False)
rO = as_(own, "select request_verification('propietario')")[1][0][0]
as_(own, "select attach_verification_doc(%s, %s, 'Cédula de identidad')", (rO, str(own) + '/ci3.pdf')); as_(own, "select submit_verification(%s)", (rO,))

chk("el admin verifica al propietario", as_(adm, "select admin_review_verification(%s,'aprobar',%s::jsonb,'Documentos en regla')", (rO, json.dumps({'identidad': True, 'documentacion': True}))), False)
eq("propietario verificado", one("select owner_verified from profiles where id=%s", (own,)), True)
# ── propiedad pendiente: no genera conexiones cuando el ajuste está activo
def req(prop, phone):
    return as_(None, "select request_connection(%s,'Gaby Huésped',%s,null,null,true)", (prop, phone))
chk("con el ajuste apagado, una propiedad sin verificar sí recibe solicitudes", req(pB, '+591 70000001'), False)
chk("solo un admin cambia el ajuste", as_(own, "select admin_set_property_verification_required(true)"), True)
chk("el admin exige verificación", as_(adm, "select admin_set_property_verification_required(true)"), False)
eq("el público sabe que se exige", as_(None, "select verification_required()")[1][0][0], True)
r = req(pB, '+591 70000002'); chk("propiedad PENDIENTE: no recibe solicitudes de contacto", r, True)
eq("el mensaje lo explica", 'pendiente de verificación' in r[1], True)
rP2 = as_(own, "select request_verification('propiedad', %s)", (pA,))[1][0][0]
as_(own, "select attach_verification_doc(%s, %s, 'Folio real actualizado')", (rP2, str(own) + '/folio2.pdf')); as_(own, "select submit_verification(%s)", (rP2,))
as_(adm, "select admin_review_verification(%s,'aprobar',%s::jsonb,'Verificada de nuevo')", (rP2, json.dumps(CP)))
chk("propiedad VERIFICADA: sí recibe solicitudes", req(pA, '+591 70000003'), False)
# ── revocar

chk("el admin revoca con motivo", as_(adm, "select admin_revoke_verification(%s,'Documentación vencida')", (rP2,)), False)
eq("revocada: la propiedad vuelve a pendiente", one("select verified from properties where id=%s", (pA,)), False)
chk("revocar exige motivo", as_(adm, "select admin_revoke_verification(%s,'')", (rA2,)), True)
chk("el titular no revoca", as_(own, "select admin_revoke_verification(%s,'x')", (rA2,)), True)
ev = as_(adm, "select verification_events(%s)", (rP2,))[1][0][0]
eq("historial de la propiedad", [e['event'] for e in ev], ['solicitud_creada', 'documento_agregado', 'enviada_a_revision', 'aprobada', 'revocada'])
chk("el titular no lee el historial", as_(own, "select verification_events(%s)", (rP2,)), True)
as_(adm, "select admin_set_property_verification_required(false)")

# ── reseñas: solo tras una operación concretada con una conexión de Bastet
def verified_conn(prop, phone):
    code = req(prop, phone)[1][0][0]
    cid = one("select id from connections where code=%s", (code,))
    as_(own, "select respond_connection(%s, true)", (cid,))
    su("update connections set status='conexion_generada', verified_at=now() where id=%s", (cid,))
    return cid
today = one("select public.bo_today()")
pV = mkprop(own, 'Casa a reseñar', '100000', 'venta', 'Av. Principal 5')
cV = verified_conn(pV, '+591 70000010')
op = as_(own, "select start_property_closure(%s,'venta',%s,'Gaby Huésped',100000,'USD',%s)", (pV, cV, today))[1][0][0]
eq("antes de confirmar nadie puede reseñar", as_(None, "select get_operation_review(%s)", (op['token'],))[1][0][0]['can_review'], False)
chk("reseñar sin confirmar falla", as_(None, "select submit_operation_review(%s, 5, 'Excelente')", (op['token'],)), True)
as_(None, "select respond_operation_confirmation(%s, true)", (op['token'],))
g = as_(None, "select get_operation_review(%s)", (op['token'],))[1][0][0]
eq("tras confirmar la operación, la persona puede reseñar", (g['can_review'], g['reviewed']), (True, 'Olga'))
chk("las estrellas van de 1 a 5", as_(None, "select submit_operation_review(%s, 6, 'x')", (op['token'],)), True)
chk("token inválido", as_(None, "select submit_operation_review('nada', 5, 'x')"), True)
chk("la persona reseña (sin cuenta)", as_(None, "select submit_operation_review(%s, 5, 'Atención muy profesional')", (op['token'],)), False)
chk("solo una reseña por operación", as_(None, "select submit_operation_review(%s, 1, 'otra')", (op['token'],)), True)
eq("ya no puede volver a reseñar", as_(None, "select get_operation_review(%s)", (op['token'],))[1][0][0]['can_review'], False)
rv = as_(None, "select id, reviewer_name, rating, comment from list_profile_reviews(%s)", (own,))[1]
eq("el público ve la reseña con «Nombre I.»", [(x[1], x[2], x[3]) for x in rv], [('Gaby H.', 5, 'Atención muy profesional')])
rep = as_(None, "select avg_rating, review_count, verified_operations, agent_verified, owner_verified from profile_reputation(array[%s::uuid])", (own,))[1][0]
eq("reputación: promedio, reseñas, operaciones verificadas y distintivos", (float(rep[0]), rep[1], rep[2], rep[3], rep[4]), (5.0, 1, 1, True, True))
chk("el reseñado responde", as_(own, "select reply_profile_review(%s, 'Gracias, fue un gusto')", (rv[0][0],)), False)
chk("otra cuenta no responde", as_(other, "select reply_profile_review(%s, 'x')", (rv[0][0],)), True)
chk("solo el admin oculta reseñas", as_(own, "select admin_set_profile_review_status(%s, 'hidden')", (rv[0][0],)), True)
as_(adm, "select admin_set_profile_review_status(%s, 'hidden')", (rv[0][0],))
eq("oculta: ya no es pública", len(as_(None, "select * from list_profile_reviews(%s)", (own,))[1]), 0)
as_(adm, "select admin_set_profile_review_status(%s, 'published')", (rv[0][0],))
pW = mkprop(own, 'Operación decidida por admin', '50000', 'venta', 'Calle 7'); cW = verified_conn(pW, '+591 70000011')
opw = as_(own, "select start_property_closure(%s,'venta',%s,'Gaby Huésped',50000,'USD',%s)", (pW, cW, today))[1][0][0]
as_(adm, "select admin_resolve_operation(%s,'confirmar','Verificado por chat')", (one("select id from operations where interested_token=%s", (opw['token'],)),))
chk("si la operación la confirmó el admin (sin el interesado), NO hay reseña", as_(None, "select submit_operation_review(%s, 5, 'x')", (opw['token'],)), True)
eq("cada reseña está ligada a su operación", one("select count(*) from profile_reviews where operation_id is not null"), 1)

# ── certificado público y consultas en «Verificar»
cert = one("select cert_code from operations where interested_token=%s", (op['token'],))
eq("la operación confirmada tiene su código de certificado OP-XXXXXXXX", bool(cert) and cert.startswith('OP-') and len(cert) == 11, True)
v = as_(None, "select verify_operation_certificate(%s)", (cert,))[1][0][0]
eq("el certificado público confirma el tipo, el mes, la propiedad, la ciudad y el origen", (v['found'], v['kind'], v['month'] == today.strftime('%Y-%m'), v['property_code'].startswith('BST-'), v['city'], v['origin']), (True, 'venta', True, True, 'La Paz', 'conexion_bastet'))
eq("…y NO expone nombres, montos ni datos del contrato", [k for k in v if k in ('amount', 'currency', 'name', 'titular', 'counterparty', 'commission', 'address', 'phone', 'whatsapp', 'buyer')], [])
eq("código inexistente", as_(None, "select verify_operation_certificate('OP-ZZZZZZZZ')")[1][0][0], {'found': False})
pv = as_(None, "select verify_property_code(%s)", ('BST-' + str(one("select code_number from properties where id=%s", (pA,))),))[1][0][0]
eq("consulta de propiedad: estado, ciudad y distintivos del titular, sin dirección ni dueño", (pv['found'], pv['verified'], pv['city'], pv['agent_verified'], pv['owner_verified'], [k for k in pv if k in ('address', 'owner', 'whatsapp', 'owner_id')]), (True, False, 'La Paz', True, True, []))
eq("propiedad inexistente", as_(None, "select verify_property_code('BST-999999')")[1][0][0], {'found': False})
ag = as_(None, "select verify_agent_code(%s)", (code,))[1][0][0]
eq("consulta de agente: nombre público, distintivos y reputación, sin contacto", (ag['found'], ag['name'], ag['agent_verified'], ag['owner_verified'], ag['review_count'], [k for k in ag if k in ('whatsapp', 'email', 'phone')]), (True, 'Olga Owner', True, True, 1, []))
eq("agente inexistente", as_(None, "select verify_agent_code('AG-ZZZZZZ')")[1][0][0], {'found': False})
n_ok = sum(as_(None, "select verify_agent_code('AG-ZZZZZZ')", headers='{"x-forwarded-for":"203.0.113.77"}')[0] == 'ok' for _ in range(35))
eq("las consultas públicas se limitan a 30 por minuto por IP (fuerza bruta)", n_ok, 30)

# ── acta digital
ac = as_(own, "select get_operation_acta(%s)", (one("select id from operations where interested_token=%s", (op['token'],)),))
chk("el titular obtiene el acta de su operación", ac, False)
a = ac[1][0][0]
eq("el acta incluye partes, propiedad, aceptaciones, conexión y comisión", (a['number'].startswith('BST-OP-'), a['titular']['name'], a['counterparty']['name'], a['counterparty']['confirmed'], a['connection']['number'].startswith('BST-CX-'), float(a['commission']['bs'])), (True, 'Olga Owner Rojas', 'Gaby Huésped', True, True, 5220.0))
chk("otra cuenta no ve el acta ajena", as_(other, "select get_operation_acta(%s)", (one("select id from operations where interested_token=%s", (op['token'],)),)), True)
chk("anónimo no ve actas", as_(None, "select get_operation_acta(%s)", (one("select id from operations where interested_token=%s", (op['token'],)),)), True)
chk("el admin sí", as_(adm, "select get_operation_acta(%s)", (one("select id from operations where interested_token=%s", (op['token'],)),)), False)

su("select 1")
for _ in range(2): cur.execute(ver)
print("verification.sql re-corrido sin error")
print("FALLAS:", fails); sys.exit(1 if fails else 0)

