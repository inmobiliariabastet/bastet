"""Pruebas de supabase/investigations.sql (fase 5): investigaciones y sanciones con garantías. La penalización o la eliminación de la cuenta solo se resuelven
con descargos cumplidos Y revisión jurídica registrada; la suspensión es reversible; nada irreversible se ejecuta solo.
Requiere:  pip install pgserver psycopg2-binary   y se ejecuta con:  python tests/investigations_sql_test.py
Levanta un Postgres local desechable: NO toca Supabase ni producción."""
import pgserver, psycopg2, sys, tempfile, pathlib, datetime
ROOT = pathlib.Path(__file__).resolve().parent.parent
srv = pgserver.get_server(tempfile.mkdtemp(prefix='uno-pg-'), cleanup_mode='delete')
uri = srv.get_uri()
R_ = str(ROOT / "supabase") + "/"
sch = open(R_ + "schema.sql", encoding='utf-8').read()
inv = open(R_ + "investigations.sql", encoding="utf-8").read()
assert inv.strip().replace('\r', '') in sch.replace('\r', ''), "investigations.sql no está igual a su bloque en schema.sql"
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
def row(sql, a=None):
    su(sql, a); return cur.fetchone()
su("set session_replication_role = replica")
def mkprop(owner, title, price='100000', op='venta'):
    cur.execute("reset role; insert into properties (title, location, area, rooms, baths, description, price, currency, owner_id, operation, status, property_type) values (%s,'La Paz','80','2','1','x',%s,'USD',%s,%s,'available','casa') returning id", (title, price, owner, op))
    return cur.fetchone()[0]
pV = mkprop(own, 'Casa vendida a escondidas'); pQ = mkprop(own, 'Otra de Olga')
su("set session_replication_role = origin")
FW = 'CONTRATO MARCO DE PRUEBA. ' + 'Texto. ' * 30
su("update connection_settings set enabled=true, pay_instructions='Banco X cuenta 123456789', framework_text=%s where id=1", (FW,))
su("insert into framework_acceptances(user_id, version) select %s, framework_version from connection_settings", (own,))
today = one("select public.bo_today()")
code = as_(None, "select request_connection(%s,'Gaby Huésped','+591 70000001',null,null,true)", (pV,))[1][0][0]
cid = one("select id from connections where code=%s", (code,))
as_(own, "select respond_connection(%s, true)", (cid,))
su("update connections set status='conexion_generada', verified_at=now() where id=%s", (cid,))
op = as_(own, "select start_property_closure(%s,'venta',%s,'Gaby Huésped',100000,'USD',%s)", (pV, cid, today))[1][0][0]
as_(None, "select respond_operation_confirmation(%s, true)", (op['token'],))
opid = op['id']
SUM = 'El titular marcó la propiedad como vendida a otra persona y la operación coincide con la conexión de Bastet.'

# ── solo administración
chk("el titular no abre investigaciones", as_(own, "select admin_open_investigation('ocultamiento_operacion', null, %s, null, null, null, %s)", (opid, SUM)), True)
chk("anónimo no abre investigaciones", as_(None, "select admin_open_investigation('otra', %s, null, null, null, null, %s)", (own, SUM)), True)
chk("anónimo no lee las tablas", as_(None, "select * from investigations"), True)
chk("el titular no las lee", as_(own, "select * from investigations"), True)
chk("el titular no ve el listado de administración", as_(own, "select admin_investigations()"), True)
chk("los hechos deben describirse", as_(adm, "select admin_open_investigation('otra', %s, null, null, null, null, 'corto')", (own,)), True)
chk("tipo inválido", as_(adm, "select admin_open_investigation('chisme', %s, null, null, null, null, %s)", (own, SUM)), True)
chk("no se investiga a un administrador desde aquí", as_(adm, "select admin_open_investigation('otra', %s, null, null, null, null, %s)", (adm, SUM)), True)

# ── abrir desde una operación: la penalización se calcula sola (2,25 % = 3 veces la comisión de venta)
r = as_(adm, "select admin_open_investigation('ocultamiento_operacion', null, %s, null, null, null, %s)", (opid, SUM)); chk("el admin abre la investigación desde la operación", r, False)
i1 = r[1][0][0]
su("select subject_id, status, basis_amount, basis_currency, penalty_percent, penalty_bs, penalty_status, bob_per_usd_used from investigations where id=%s", (i1['id'],))
subj, st, ba, bc, pp, pbs, ps, rate = cur.fetchone()
eq("la persona investigada se toma de la operación", subj, own)
eq("100.000 USD × 2,25 % = 2.250 USD = Bs 15.660 al tipo de cambio interno 6,96, propuesta", (st, float(ba), bc, float(pp), float(pbs), ps, float(rate)), ('abierta', 100000.0, 'USD', 2.25, 15660.0, 'propuesta', 6.96))
eq("el código es correlativo", i1['code'].startswith('INV-') and i1['code'].endswith('-0001'), True)
eq("es el triple de la comisión de venta (0,75 %)", float(one("select commission_bs from operations where id=%s", (opid,))) * 3, 15660.0)

# ── suspensión: reversible y sin conexiones nuevas
chk("suspender exige motivo", as_(adm, "select admin_set_suspension(%s, true, '')", (i1['id'],)), True)
chk("el titular no suspende", as_(own, "select admin_set_suspension(%s, true, 'x')", (i1['id'],)), True)
chk("el admin suspende la cuenta mientras investiga", as_(adm, "select admin_set_suspension(%s, true, 'Posible ocultamiento de una venta')", (i1['id'],)), False)
eq("la cuenta quedó inactiva", one("select is_active from profiles where id=%s", (own,)), False)
r = as_(None, "select request_connection(%s,'Rita Real','+591 70000002',null,null,true)", (pQ,)); chk("una cuenta suspendida no recibe conexiones nuevas", r, True)
chk("no se suspende dos veces", as_(adm, "select admin_set_suspension(%s, true, 'otra vez')", (i1['id'],)), True)
chk("el admin repone la cuenta", as_(adm, "select admin_set_suspension(%s, false, 'Se aclaró un dato')", (i1['id'],)), False)
eq("la cuenta volvió a estar activa", one("select is_active from profiles where id=%s", (own,)), True)
chk("repuesta: vuelve a recibir conexiones", as_(None, "select request_connection(%s,'Rita Real','+591 70000002',null,null,true)", (pQ,)), False)

# ── resolver sin las garantías NO se puede
chk("sin descargos no se decide una sanción", as_(adm, "select admin_resolve_investigation(%s,'penalizacion','Se confirmó el ocultamiento de la operación.')", (i1['id'],)), True)
r = as_(adm, "select admin_resolve_investigation(%s,'penalizacion','Se confirmó el ocultamiento de la operación.')", (i1['id'],))
eq("el mensaje explica que faltan los descargos", 'descargos' in r[1], True)
chk("la decisión debe estar documentada", as_(adm, "select admin_resolve_investigation(%s,'sin_falta','corto')", (i1['id'],)), True)


# ── descargos: la persona investigada se defiende por su propio enlace
chk("el titular no abre el plazo de descargos", as_(own, "select admin_open_descargos(%s, 5)", (i1['id'],)), True)
chk("el plazo debe ser razonable", as_(adm, "select admin_open_descargos(%s, 90)", (i1['id'],)), True)
r = as_(adm, "select admin_open_descargos(%s, 5)", (i1['id'],)); chk("el admin abre un plazo de 5 días", r, False)
tok = r[1][0][0]['token']
eq("estado «descargos» con enlace propio de 32 caracteres", (one("select status from investigations where id=%s", (i1['id'],)), len(tok)), ('descargos', 32))
g = as_(None, "select get_descargos_public(%s)", (tok,))[1][0][0]
eq("la persona ve de qué se le acusa y que el plazo está abierto (sin evidencia interna)", (g['valid'], g['open'], g['summary'] == SUM, [k for k in g if k in ('penalty_bs', 'legal_concept', 'legal_reviewer', 'decision', 'subject_id')]), (True, True, True, []))
eq("enlace inválido", as_(None, "select get_descargos_public('nada')")[1][0][0], {'valid': False})
chk("un descargo muy corto no vale", as_(None, "select submit_descargo_public(%s, 'no')", (tok,)), True)
chk("enlace inválido no recibe descargos", as_(None, "select submit_descargo_public('nada', 'Texto de descargo suficientemente largo')"), True)
chk("la persona presenta sus descargos aunque su cuenta esté suspendida (sin cuenta, por enlace)", as_(None, "select submit_descargo_public(%s, 'La venta fue a un familiar mío y no tiene relación con la conexión de Bastet.')", (tok,)), False)
eq("el descargo quedó en el expediente", one("select count(*) from investigation_items where investigation_id=%s and kind='descargo'", (i1['id'],)), 1)
for k in range(4): as_(None, "select submit_descargo_public(%s, %s)", (tok, 'Descargo adicional número %d con detalle suficiente.' % k))
chk("máximo 5 descargos", as_(None, "select submit_descargo_public(%s, 'Un sexto descargo con texto suficiente.')", (tok,)), True)
# ── evidencia y revisión jurídica
chk("el titular no agrega evidencia", as_(own, "select admin_add_investigation_item(%s,'evidencia','x',null)", (i1['id'],)), True)
chk("el admin agrega evidencia", as_(adm, "select admin_add_investigation_item(%s,'evidencia','Captura del chat con la persona de la conexión',null)", (i1['id'],)), False)
chk("tipo de ítem inválido", as_(adm, "select admin_add_investigation_item(%s,'descargo','x',null)", (i1['id'],)), True)
chk("sin revisión jurídica no se penaliza (aunque ya hay descargos)", as_(adm, "select admin_resolve_investigation(%s,'penalizacion','Se confirmó el ocultamiento de la operación.')", (i1['id'],)), True)
r = as_(adm, "select admin_resolve_investigation(%s,'eliminacion_cuenta','Se confirmó el ocultamiento de la operación.')", (i1['id'],))
eq("…y el mensaje exige la revisión jurídica", 'revisión jurídica' in r[1], True)
chk("la revisión jurídica pide quién la hizo", as_(adm, "select admin_record_legal_review(%s,'','Concepto suficientemente largo del abogado')", (i1['id'],)), True)
chk("…y su concepto", as_(adm, "select admin_record_legal_review(%s,'Dr. Pérez','corto')", (i1['id'],)), True)
chk("el admin registra la revisión jurídica", as_(adm, "select admin_record_legal_review(%s,'Dr. Luis Pérez (abogado)','Procede la cláusula penal del 2,25 por ciento por ocultamiento; se respetó el derecho a descargos.')", (i1['id'],)), False)
eq("estado «revisión jurídica»", one("select status from investigations where id=%s", (i1['id'],)), 'revision_juridica')

# ── resolución con todas las garantías
chk("el titular no resuelve", as_(own, "select admin_resolve_investigation(%s,'sin_falta','Intento de resolver por mi cuenta, sin permiso.')", (i1['id'],)), True)
chk("el admin impone la penalización documentando su decisión", as_(adm, "select admin_resolve_investigation(%s,'penalizacion','Se confirmó que la venta provino de la conexión; se aplica la cláusula penal del 2,25 por ciento.')", (i1['id'],)), False)
su("select status, decision, penalty_status, penalty_bs, deletion_authorized from investigations where id=%s", (i1['id'],))
st, dec, ps, pbs, da = cur.fetchone()
eq("resuelta con penalización impuesta de Bs 15.660 (congelada) y SIN eliminar la cuenta", (st, dec, ps, float(pbs), da), ('resuelta', 'penalizacion', 'impuesta', 15660.0, False))
su("update stay_settings set bob_per_usd = 7.5 where id=1")
eq("cambiar el tipo de cambio después no modifica la penalización congelada", float(one("select penalty_bs from investigations where id=%s", (i1['id'],))), 15660.0)
su("update stay_settings set bob_per_usd = 6.96 where id=1")
chk("no se resuelve dos veces", as_(adm, "select admin_resolve_investigation(%s,'sin_falta','Intento de cambiar la decisión ya tomada.')", (i1['id'],)), True)
chk("solo el admin marca el pago", as_(own, "select admin_mark_penalty_paid(%s,'x')", (i1['id'],)), True)
chk("el admin registra el pago de la penalización", as_(adm, "select admin_mark_penalty_paid(%s,'Transferencia recibida')", (i1['id'],)), False)
eq("pagada", one("select penalty_status from investigations where id=%s", (i1['id'],)), 'pagada')
chk("no se marca dos veces", as_(adm, "select admin_mark_penalty_paid(%s,'otra')", (i1['id'],)), True)
eq("la cuenta sigue existiendo (nada irreversible se ejecutó)", one("select count(*) from profiles where id=%s", (own,)), 1)

# ── eliminación de la cuenta: solo se AUTORIZA en el registro
i2 = as_(adm, "select admin_open_investigation('otra', %s, null, null, null, null, 'Reiteración de la conducta: segunda operación ocultada, según denuncia del interesado.')", (other,))[1][0][0]
as_(adm, "select admin_open_descargos(%s, 1)", (i2['id'],))
su("update investigations set descargos_until = now() - interval '1 hour' where id=%s", (i2['id'],))
chk("vencido el plazo sin descargos, ya se puede decidir… pero la eliminación exige revisión jurídica", as_(adm, "select admin_resolve_investigation(%s,'eliminacion_cuenta','Reiteración grave tras el plazo de descargos sin respuesta.')", (i2['id'],)), True)
as_(adm, "select admin_record_legal_review(%s,'Dra. Ana Gómez (abogada)','Procede la eliminación por reiteración grave, con descargos vencidos sin respuesta.')", (i2['id'],))
chk("con plazo vencido y revisión jurídica, queda AUTORIZADA la eliminación", as_(adm, "select admin_resolve_investigation(%s,'eliminacion_cuenta','Reiteración grave tras el plazo de descargos sin respuesta.')", (i2['id'],)), False)
eq("autorizada pero NO ejecutada: la cuenta sigue existiendo", (one("select deletion_authorized from investigations where id=%s", (i2['id'],)), one("select count(*) from profiles where id=%s", (other,))), (True, 1))
chk("fuera de plazo ya no se aceptan descargos", as_(None, "select submit_descargo_public((select descargos_token from investigations where id=%s), 'Descargo tardío con texto suficiente.')", (i2['id'],)), True)

# ── «sin falta»: se repone la cuenta y se anula la penalización propuesta; se puede archivar
pX = mkprop(own, 'Operación aclarada'); cX = as_(None, "select request_connection(%s,'Gaby Huésped','+591 70000009',null,null,true)", (pX,))[1][0][0]
i3 = as_(adm, "select admin_open_investigation('otra', %s, null, null, null, %s, 'Denuncia que resultó ser un malentendido entre las partes.')", (own, pX))[1][0][0]
as_(adm, "select admin_set_investigation_basis(%s, 50000, 'USD')", (i3['id'],))
eq("base manual: 50.000 USD × 2,25 % = Bs 7.830", float(one("select penalty_bs from investigations where id=%s", (i3['id'],))), 7830.0)
chk("base manual inválida", as_(adm, "select admin_set_investigation_basis(%s, -5, 'USD')", (i3['id'],)), True)
as_(adm, "select admin_set_suspension(%s, true, 'Mientras se aclara el caso')", (i3['id'],))
chk("«sin falta» no exige descargos ni revisión jurídica y repone la cuenta", as_(adm, "select admin_resolve_investigation(%s,'sin_falta','Las partes aclararon el malentendido; no hubo ocultamiento.')", (i3['id'],)), False)
eq("cuenta repuesta y penalización anulada", (one("select is_active from profiles where id=%s", (own,)), one("select penalty_status from investigations where id=%s", (i3['id'],))), (True, 'anulada'))
i4 = as_(adm, "select admin_open_investigation('falta_anfitrion', %s, null, null, null, null, 'El anfitrión canceló una reserva confirmada sin avisar al huésped.')", (own,))[1][0][0]
chk("el admin archiva con motivo", as_(adm, "select admin_archive_investigation(%s,'El huésped retiró su denuncia')", (i4['id'],)), False)
chk("archivar exige explicación", as_(adm, "select admin_archive_investigation(%s,'x')", (i1['id'],)), True)

# ── auditoría y límites
ev = as_(adm, "select investigation_events(%s)", (i1['id'],))[1][0][0]
eq("la cronología de la investigación queda completa", [e['event'] for e in ev][:4], ['abierta', 'cuenta_suspendida', 'cuenta_repuesta', 'plazo_de_descargos'])
eq("…y termina con la resolución y el pago", [e['event'] for e in ev][-3:], ['revision_juridica', 'resuelta', 'penalizacion_pagada'])
chk("el titular no lee la cronología", as_(own, "select investigation_events(%s)", (i1['id'],)), True)
n_ok = sum(as_(None, "select get_descargos_public('abc')", headers='{"x-forwarded-for":"203.0.113.90"}')[0] == 'ok' for _ in range(35))
eq("las consultas del enlace de descargos se limitan a 30 por minuto por IP", n_ok, 30)
lst = as_(adm, "select admin_investigations()")[1][0][0]
eq("el listado de administración trae porcentaje, plazo y los 4 expedientes", (float(lst['penalty_percent']), lst['descargos_days'], len(lst['items'])), (2.25, 5, 4))

su("select 1")
for _ in range(2): cur.execute(inv)
print("investigations.sql re-corrido sin error")
print("FALLAS:", fails); sys.exit(1 if fails else 0)

