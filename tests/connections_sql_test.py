"""Pruebas de supabase/connections.sql: conexiones y tarifas (solicitud, aceptación, tarifa congelada, pago con comprobante, revelado de datos,
contrato marco, matriz editable con historial). Requiere:  pip install pgserver psycopg2-binary   y se ejecuta con:  python tests/connections_sql_test.py
Levanta un Postgres local desechable: NO toca Supabase ni producción."""
import pgserver, psycopg2, sys, tempfile, pathlib, datetime
ROOT = pathlib.Path(__file__).resolve().parent.parent
srv = pgserver.get_server(tempfile.mkdtemp(prefix='uno-pg-'), cleanup_mode='delete')
uri = srv.get_uri()
R_ = str(ROOT / "supabase") + "/"
sch = open(R_ + "schema.sql", encoding='utf-8').read()
core = sch[:sch.index("-- ── Tabla property_events")]
i = sch.index("-- UNO · Créditos para agentes")
tail = sch[sch.rindex("\n", 0, i - 5) + 1:]
cnx = open(R_ + "connections.sql", encoding="utf-8").read()
assert cnx.strip().replace('\r', '') in sch.replace('\r', ''), "connections.sql no está igual al final de schema.sql"
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
su("update public.profiles set display_name='Hugo Host', interest='agente', registered_at=now() where id=%s", (host,))
su("update public.profiles set display_name='Hilda Host', interest='agente', registered_at=now() where id=%s", (host2,))
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
def mkprop(owner, title, price='100000', cur_='USD', op='venta', ptype='casa'):
    cur.execute("reset role; insert into properties (title, location, area, rooms, baths, description, price, currency, owner_id, operation, status, property_type, whatsapp) values (%s,'La Paz, Bolivia','80','2','1','x',%s,%s,%s,%s,'available',%s,'70000000') returning id", (title, price, cur_, owner, op, ptype))
    return cur.fetchone()[0]
pV = mkprop(host, 'Casa en venta', '100000', 'USD', 'venta')
pA = mkprop(host, 'Depto en alquiler', '2000', 'BOB', 'alquiler', 'departamento')
pC = mkprop(host, 'Anticrético', '30000', 'USD', 'anticretico')
pT = mkprop(host, 'Temporal', '100', 'USD', 'temporal')
pH = mkprop(host2, 'Casa de Hilda', '90000', 'USD', 'venta')
pN = mkprop(host2, 'Listado antiguo sin operación', '80000', 'USD', None)
su("set session_replication_role = origin")
def req(prop, name='Gaby Huésped', phone='+591 76543210', consent=True, who=None):
    return as_(who, "select request_connection(%s,%s,%s,'g@x.com','Quiero verla',%s)", (prop, name, phone, consent))
def code_of(r): return r[1][0][0]
def cid(code): return one("select id from connections where code=%s", (code,))
def st(code): return one("select status from connections where code=%s", (code,))
def item(who, code):
    r = as_(who, "select my_connections()")[1][0][0]['items']
    return [x for x in r if x['code'] == code][0] if any(x['code'] == code for x in r) else None
YEAR = datetime.datetime.now().year

# --- interruptor apagado y activación
eq("apagado por defecto", as_(None, "select connections_enabled()")[1][0][0], False)
chk("sin el interruptor no se solicita contacto", req(pV), True)
chk("anónimo no lee las conexiones", as_(None, "select * from connections"), True)
chk("anónimo no lee las tarifas", as_(None, "select * from fee_rules"), True)
chk("un titular no cambia los ajustes", as_(host, "select admin_update_connection_settings(true, 'Cuenta 12345678', null, %s)", ('x' * 200,)), True)
chk("no se activa sin instrucciones de pago", as_(adm, "select admin_update_connection_settings(true, '', null, %s)", ('x' * 200,)), True)
chk("no se activa sin el texto del contrato marco", as_(adm, "select admin_update_connection_settings(true, 'Banco X cuenta 123456789', null, '')"), True)
FW = 'CONTRATO MARCO DE PRUEBA. ' + 'Texto sujeto a revisión jurídica. ' * 10
chk("la sola edición del texto no activa nada", as_(adm, "select admin_update_connection_settings(false, 'Banco X cuenta 123456789', null, %s)", (FW,)), False)
eq("al fijar el texto, la versión sube a 2", one("select framework_version from connection_settings"), 2)
chk("el admin activa", as_(adm, "select admin_update_connection_settings(true, 'Banco X cuenta 123456789', 'http://x/qr.png', %s)", (FW,)), False)
eq("misma redacción: la versión no cambia", one("select framework_version from connection_settings"), 2)
eq("activo", as_(None, "select connections_enabled()")[1][0][0], True)

# --- contrato marco antes de publicar
f = as_(host, "select my_framework()")[1][0][0]
eq("el titular debe aceptar el contrato marco (versión 2)", (f['required'], f['accepted'], f['version']), (True, False, 2))
eq("el admin está exento", as_(adm, "select my_framework()")[1][0][0]['required'], False)
INS = "insert into properties(id,title,location,price,area,rooms,baths,owner_id,operation) values (gen_random_uuid(),%s,'La Paz','1000','100','3','2',%s,'venta') returning id"
r = as_(host, INS, ('Nueva sin contrato', host))
chk("no publica sin aceptar el contrato marco", r, True)
eq("el mensaje lo explica", 'contrato marco' in r[1], True)
chk("el admin publica sin aceptar", as_(adm, INS, ('Admin', adm)), False)
chk("no se acepta una versión vieja del contrato marco", as_(host, "select accept_framework_contract(1)"), True)
chk("versión equivocada", as_(host, "select accept_framework_contract(99)"), True)
chk("acepta el contrato marco vigente", as_(host, "select accept_framework_contract(2)"), False)
chk("ahora sí publica", as_(host, INS, ('Nueva con contrato', host)), False)
chk("otro titular sigue sin poder publicar", as_(host2, INS, ('Otra', host2)), True)
chk("una nueva redacción del contrato exige aceptarlo otra vez", as_(adm, "select admin_update_connection_settings(true, 'Banco X cuenta 123456789', 'http://x/qr.png', %s)", (FW + ' Cláusula nueva.',)), False)
chk("…y el titular queda bloqueado hasta aceptar la versión 3", as_(host, INS, ('Otra más', host)), True)
chk("acepta la versión 3", as_(host, "select accept_framework_contract(3)"), False)
chk("hilda también acepta", as_(host2, "select accept_framework_contract(3)"), False)

# --- solicitud de contacto
r = req(pV); chk("el interesado solicita contacto sin cuenta", r, False); c1 = code_of(r)
eq("estado inicial y tipo de interesado", (st(c1), one("select interested_type from connections where code=%s", (c1,))), ('solicitada', 'comprador'))
chk("sin consentimiento", req(pV, phone='+591 70000001', consent=False), True)
chk("nombre muy corto", req(pV, name='A', phone='+591 70000002'), True)
chk("teléfono inválido", req(pV, phone='123'), True)
chk("una estadía temporal no genera conexiones", req(pT, phone='+591 70000003'), True)
chk("no repite la misma solicitud para la propiedad", req(pV), True)
eq("el alquiler es «arrendatario»", one("select interested_type from connections where id=%s", (cid(code_of(req(pA, phone='+591 70000004'))),)), 'arrendatario')
eq("el anticrético es «anticresista»", one("select interested_type from connections where id=%s", (cid(code_of(req(pC, phone='+591 70000005'))),)), 'anticresista')
su("set session_replication_role = replica")
extra = [mkprop(host2, 'Extra %d' % k, '50000', 'USD', 'venta') for k in range(6)]
su("set session_replication_role = origin")
n_ok = sum(req(px, name='Tomas Tope', phone='+591 70999999')[0] == 'ok' for px in extra[:5])
eq("un mismo teléfono puede tener hasta 5 solicitudes esperando", n_ok, 5)
chk("tope de 5 solicitudes esperando por teléfono", req(extra[5], name='Tomas Tope', phone='+591 70999999'), True)

cN = code_of(req(pN, name='Nora Nueva', phone='+591 70000077'))
eq("una propiedad sin operación (listado antiguo) cuenta como venta", one("select operation from connections where code=%s", (cN,)), 'venta')
eq("…y su tarifa sale de la regla de venta", float(as_(host2, "select preview_connection_fee(%s)", (pN,))[1][0][0]['fee_bs']), 125.0)

# --- lo que ve el titular antes del pago
it = item(host, c1)
eq("el titular ve «Gaby H.» y no el teléfono ni el correo", (it['interested_name'], it['interested_phone'], it['interested_email']), ('Gaby H.', None, None))
eq("el titular ve el mensaje", it['message'], 'Quiero verla')
eq("otro titular no ve la solicitud ajena", item(host2, c1), None)
a = item(adm, c1)
eq("el admin ve todo", (a['interested_name'], a['interested_phone']), ('Gaby Huésped', '+59176543210'))
chk("otro titular no responde", as_(host2, "select respond_connection(%s, true)", (cid(c1),)), True)
chk("anónimo no responde", as_(None, "select respond_connection(%s, true)", (cid(c1),)), True)

# --- aceptación: tarifa congelada y constancia
r = as_(host, "select respond_connection(%s, true)", (cid(c1),)); chk("el titular acepta", r, False)
res = r[1][0][0]
eq("casa de 100.000 USD (Bs 696.000): regla provisional de venta = Bs 125", (res['status'], float(res['fee_bs'])), ('aceptada_pendiente_pago', 125.0))
eq("constancia numerada", res['number'], 'BST-CX-%d-0001' % YEAR)
su("select framework_version, fee_calc->>'rule_label', fee_calc->>'provisional', property_snapshot->>'title', accepted_at is not null from connections where code=%s", (c1,))
eq("guarda versión del contrato, regla usada y datos del inmueble", cur.fetchone(), (3, 'Venta · valor inicial provisional', 'true', 'Casa en venta', True))
chk("no se responde dos veces", as_(host, "select respond_connection(%s, false)", (cid(c1),)), True)
it = item(host, c1)
eq("tras aceptar los datos siguen ocultos hasta verificar el pago", (it['interested_phone'], float(it['fee_bs'])), (None, 125.0))
eq("el titular no ve el cálculo interno", it['fee_calc'], None)
pv = as_(host, "select preview_connection_fee(%s)", (pV,))[1][0][0]
eq("vista previa de la tarifa para el titular", (float(pv['fee_bs']), pv['operation'], float(pv['min_bs']), float(pv['max_bs'])), (125.0, 'venta', 51.0, 200.0))
chk("otro titular no ve la vista previa de una propiedad ajena", as_(host2, "select preview_connection_fee(%s)", (pV,)), True)
r = as_(host, "select respond_connection(%s, true)", (cid(code_of(req(pA, name='Rita Inquilina', phone='+591 70000011'))),))
eq("alquiler de Bs 2.000: regla provisional Bs 30", float(r[1][0][0]['fee_bs']), 30.0)
c3 = code_of(req(pC, name='Ana Anticresista', phone='+591 70000012')); r = as_(host, "select respond_connection(%s, true)", (cid(c3),))
eq("anticrético: regla provisional Bs 100", float(r[1][0][0]['fee_bs']), 100.0)
c4 = code_of(req(pH, name='Rafa Rechaza', phone='+591 70000013'))
chk("el titular rechaza", as_(host2, "select respond_connection(%s, false)", (cid(c4),)), False)
eq("rechazada", st(c4), 'rechazada')
eq("las constancias son correlativas", [r[0] for r in (su("select number from connections where number is not null order by number") or cur.fetchall())], ['BST-CX-%d-000%d' % (YEAR, k) for k in (1, 2, 3)])

# --- matriz editable: especificidad, rangos, congelado, historial
chk("el titular no edita la matriz", as_(host, "select admin_save_fee_rule(null,'venta',null,null,null,100,0,'x',true)"), True)
chk("la tarifa de venta no puede salir del rango 51–200", as_(adm, "select admin_save_fee_rule(null,'venta',null,null,null,40,0,'x',true)"), True)
chk("la de alquiler no puede pasar de 50", as_(adm, "select admin_save_fee_rule(null,'alquiler',null,null,null,60,0,'x',true)"), True)
chk("mínimo mayor que el máximo", as_(adm, "select admin_save_fee_rule(null,'venta',null,10,5,100,0,'x',true)"), True)
chk("operación inválida", as_(adm, "select admin_save_fee_rule(null,'temporal',null,null,null,100,0,'x',true)"), True)
rid = as_(adm, "select admin_save_fee_rule(null,'venta','casa',500000,null,180,0,'Casas de más de Bs 500.000',true)")[1][0][0]
eq("la regla más específica gana (casa de más de Bs 500.000)", float(as_(adm, "select preview_connection_fee(%s)", (pV,))[1][0][0]['fee_bs']), 180.0)
eq("…pero la tarifa ya aceptada sigue congelada en Bs 125", float(one("select fee_bs from connections where code=%s", (c1,))), 125.0)
as_(adm, "select admin_save_fee_rule(%s,'venta','casa',500000,null,170,0,'Casas de más de Bs 500.000',false)", (rid,))
eq("una regla desactivada no se usa", float(as_(adm, "select preview_connection_fee(%s)", (pV,))[1][0][0]['fee_bs']), 125.0)
su("insert into fee_rules(operation, fee_bs, label) values ('venta', 500, 'fuera de rango a propósito')")
su("update fee_rules set priority = 99 where fee_bs = 500")
pv = as_(adm, "select preview_connection_fee(%s)", (pV,))[1][0][0]
eq("si una regla quedara fuera del rango, se ajusta al límite (200) y se marca", (float(pv['fee_bs']), pv['clamped']), (200.0, True))
su("delete from fee_rules where fee_bs = 500")
chk("el admin elimina una regla", as_(adm, "select admin_delete_fee_rule(%s)", (rid,)), False)
g = as_(adm, "select get_connection_settings()")[1][0][0]
eq("el historial registra creada, editada y eliminada", [h['action'] for h in g['history'] if h['rule_id'] == rid][::-1], ['creada', 'editada', 'eliminada'])
eq("las reglas iniciales siguen marcadas como provisionales", sorted(r['operation'] for r in g['rules'] if r['provisional']), ['alquiler', 'anticretico', 'venta'])
chk("el titular no lee los ajustes", as_(host, "select get_connection_settings()"), True)

# --- pago de la tarifa con comprobante
chk("el titular no sube a la carpeta de otro", as_(host, "select attach_connection_proof(%s, %s)", (cid(c1), str(host2) + '/x.png')), True)
chk("ruta con ..", as_(host, "select attach_connection_proof(%s, %s)", (cid(c1), str(host) + '/../x.png')), True)
chk("el titular sube su archivo a su carpeta", as_(host, "insert into storage.objects(bucket_id,name) values ('connection-proofs', %s)", (str(host) + '/voucher.png',)), False)
chk("no sube a la carpeta de otro titular", as_(host, "insert into storage.objects(bucket_id,name) values ('connection-proofs', %s)", (str(host2) + '/voucher.png',)), True)
chk("anónimo no sube", as_(None, "insert into storage.objects(bucket_id,name) values ('connection-proofs', %s)", (str(host) + '/v.png',)), True)
chk("otro titular no adjunta a una conexión ajena", as_(host2, "select attach_connection_proof(%s, %s)", (cid(c1), str(host2) + '/v.png')), True)
chk("adjunta el comprobante", as_(host, "select attach_connection_proof(%s, %s)", (cid(c1), str(host) + '/voucher.png')), False)
eq("comprobante enviado", st(c1), 'comprobante_enviado')
eq("el titular no ve su propio comprobante en la lista (solo el admin)", item(host, c1)['proof_path'], None)
eq("el admin sí lo ve", item(adm, c1)['proof_path'], str(host) + '/voucher.png')
chk("el titular no verifica pagos", as_(host, "select admin_review_connection_proof(%s, true, null)", (cid(c1),)), True)
chk("rechazar exige motivo", as_(adm, "select admin_review_connection_proof(%s, false, null)", (cid(c1),)), True)
chk("el admin rechaza con motivo", as_(adm, "select admin_review_connection_proof(%s, false, 'Monto incorrecto')", (cid(c1),)), False)
eq("vuelve a pendiente de pago con el motivo visible", (st(c1), item(host, c1)['review_note']), ('aceptada_pendiente_pago', 'Monto incorrecto'))
chk("el titular vuelve a subir", as_(host, "select attach_connection_proof(%s, %s)", (cid(c1), str(host) + '/voucher2.png')), False)
chk("el admin verifica", as_(adm, "select admin_review_connection_proof(%s, true, 'OK')", (cid(c1),)), False)
eq("conexión generada", st(c1), 'conexion_generada')
it = item(host, c1)
eq("ahora el titular ve los datos del interesado", (it['interested_name'], it['interested_phone'], it['interested_email']), ('Gaby Huésped', '+59176543210', 'g@x.com'))
chk("no se revisa dos veces", as_(adm, "select admin_review_connection_proof(%s, true, null)", (cid(c1),)), True)
eq("otro titular sigue sin ver nada", item(host2, c1), None)
chk("el admin cancela con motivo", as_(adm, "select admin_cancel_connection(%s, 'Pedido del titular')", (cid(c3),)), False)
chk("cancelar exige motivo", as_(adm, "select admin_cancel_connection(%s, '')", (cid(c1),)), True)
eq("cancelada", st(c3), 'cancelada')

# --- auditoría
ev = as_(adm, "select connection_events(%s)", (cid(c1),))[1][0][0]
eq("el historial cuenta todo el recorrido", [e['event'] for e in ev], ['solicitada', 'aceptada', 'comprobante_enviado', 'comprobante_rechazado', 'comprobante_enviado', 'pago_verificado_y_conexion'])
chk("el titular no lee el historial", as_(host, "select connection_events(%s)", (cid(c1),)), True)
eq("la constancia guarda el número", one("select number from connections where code=%s", (c1,)), 'BST-CX-%d-0001' % YEAR)

# --- con el interruptor apagado ya no entran solicitudes (las existentes siguen)
as_(adm, "select admin_update_connection_settings(false, 'Banco X cuenta 123456789', null, %s)", (FW + ' Cláusula nueva.',))
chk("apagado de nuevo: no entran solicitudes", req(pH, name='Tardío Tarde', phone='+591 70000099'), True)
eq("el titular ya no necesita aceptar el contrato si está apagado", as_(host2, "select my_framework()")[1][0][0]['required'], False)

su("select 1")
for _ in range(2): cur.execute(cnx)
print("connections.sql re-corrido sin error")
print("FALLAS:", fails); sys.exit(1 if fails else 0)
