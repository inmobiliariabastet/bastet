"""Pruebas de supabase/stay-bookings.sql: reservas de Estadías (aprobación 2 h, pago 10 %, conexión, cancelaciones, 90 % directo).
Requiere:  pip install pgserver psycopg2-binary   y se ejecuta con:  python tests/stay_bookings_sql_test.py
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
sbk = open(R_ + "stay-bookings.sql", encoding="utf-8").read()
assert sbk.strip().replace('\r', '') in sch.replace('\r', ''), "stay-bookings.sql no está igual al final de schema.sql"
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
su("update public.profiles set display_name='Hugo Host', contact_whatsapp='71234567' where id=%s", (host,))
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
def mkprop(owner, title, price='100', cur_='USD', op='temporal'):
    cur.execute("reset role; insert into properties (title, location, area, rooms, baths, description, price, currency, owner_id, operation, status, property_type, whatsapp) values (%s,'La Paz, Bolivia','80','2','1','x',%s,%s,%s,%s,'available','casa','70000000') returning id", (title, price, cur_, owner, op))
    return cur.fetchone()[0]
pU = mkprop(host, 'En dólares', '100', 'USD'); pB = mkprop(host, 'En bolivianos', '300', 'BOB'); pV = mkprop(host, 'Venta', '100', 'USD', 'venta')
su("set session_replication_role = origin")
today = one("select public.bo_today()")
D = lambda n: today + datetime.timedelta(days=n)
def book(prop, a, b, name='Gaby Huésped', phone='+591 76543210', who=None):
    return as_(who, "select create_stay_booking(%s,%s,%s,2,%s,%s,'g@x.com')", (prop, a, b, name, phone))
def code_of(r): return r[1][0][0]
def bid(code): return one("select id from stay_bookings where code=%s", (code,))
def st(code): return one("select status from stay_bookings where code=%s", (code,))
def verified(prop, a, b, phone):
    code = code_of(book(prop, a, b, phone=phone))
    as_(host, "select host_respond_stay_booking(%s, true)", (bid(code),))
    as_(None, "select attach_stay_proof(%s, %s)", (code, code + '/v.png'))
    as_(adm, "select admin_review_stay_proof(%s, true, null)", (bid(code),))
    return code

# --- interruptor apagado
eq("el público ve el interruptor apagado", as_(None, "select stay_booking_enabled()")[1][0][0], False)
chk("no se puede reservar con el interruptor apagado", book(pU, D(10), D(13)), True)
chk("anónimo no lee las reservas", as_(None, "select * from stay_bookings"), True)
chk("un anfitrión no cambia las reglas", as_(host, "select admin_update_stay_settings(true, 6.96, 'Cuenta 123456789', null)"), True)
chk("el admin no activa sin instrucciones de pago", as_(adm, "select admin_update_stay_settings(true, 6.96, '', null)"), True)
chk("el admin activa con instrucciones", as_(adm, "select admin_update_stay_settings(true, 7.00, 'Banco X cuenta 123456789 a nombre de Bastet', 'http://x/qr.png')"), False)
eq("interruptor encendido", as_(None, "select stay_booking_enabled()")[1][0][0], True)

# --- solicitud y validaciones
r = book(pU, D(10), D(13)); chk("el huésped solicita sin cuenta", r, False); c1 = code_of(r)
su("select nights,total,fee_amount,fee_bs,bob_per_usd_used,status from stay_bookings where code=%s", (c1,)); n, tot, fee, febs, rate, s0 = cur.fetchone()
eq("3 noches x 100 USD = 300 USD", (n, float(tot)), (3, 300.0))
eq("10 % = 30 USD = Bs 210 con el cambio interno 7,00", (float(fee), float(febs), float(rate)), (30.0, 210.0, 7.0))
eq("estado inicial", s0, 'pendiente_respuesta_anfitrion')
cb = code_of(book(pB, D(20), D(22)))
su("select total, fee_amount, fee_bs from stay_bookings where code=%s", (cb,)); t_, f_, fb_ = cur.fetchone()
eq("en bolivianos el 10 % ya está en Bs (60 de 600)", (float(t_), float(f_), float(fb_)), (600.0, 60.0, 60.0))
chk("no en propiedad que no es temporal", book(pV, D(10), D(12)), True)
chk("fecha pasada", book(pU, D(-1), D(2)), True)
chk("salida antes de llegada", book(pU, D(15), D(14)), True)
chk("más de 90 noches", book(pU, D(10), D(105)), True)
chk("teléfono inválido", book(pU, D(30), D(32), phone='123'), True)
chk("nombre muy corto", book(pU, D(30), D(32), name='A'), True)
su("insert into stay_blocks(property_id, from_date, to_date) values (%s,%s,%s)", (pU, D(40), D(45)))
chk("fechas bloqueadas por el anfitrión", book(pU, D(42), D(44)), True)
eq("sin contacto del anfitrión mientras está pendiente", as_(None, "select get_stay_booking(%s)->>'host_whatsapp'", (c1,))[1][0][0], None)
eq("código inexistente", as_(None, "select get_stay_booking('NOEXISTE')->>'found'")[1][0][0], 'false')

# --- respuesta del anfitrión
chk("otro anfitrión no responde", as_(host2, "select host_respond_stay_booking(%s, true)", (bid(c1),)), True)
chk("anónimo no responde", as_(None, "select host_respond_stay_booking(%s, true)", (bid(c1),)), True)
chk("el anfitrión acepta", as_(host, "select host_respond_stay_booking(%s, true)", (bid(c1),)), False)
eq("aceptada, pendiente de pago", st(c1), 'aceptada_pendiente_pago')
chk("no se responde dos veces", as_(host, "select host_respond_stay_booking(%s, false)", (bid(c1),)), True)
g = as_(None, "select get_stay_booking(%s)", (c1,))[1][0][0]
eq("tras aceptar se muestran las instrucciones de pago", g['pay_instructions'].startswith('Banco X'), True)
eq("pero aún no el contacto", g['host_whatsapp'], None)
chk("fechas ya aceptadas no se pueden solicitar otra vez", book(pU, D(11), D(12), phone='+591 70000001'), True)
c2 = code_of(book(pU, D(50), D(52), phone='+591 70000002'))
chk("el anfitrión rechaza", as_(host, "select host_respond_stay_booking(%s, false)", (bid(c2),)), False)
eq("rechazada", st(c2), 'rechazada')
chk("las fechas rechazadas vuelven a quedar libres", book(pU, D(50), D(52), phone='+591 70000003'), False)
c3 = code_of(book(pU, D(60), D(62), phone='+591 70000004'))
su("update stay_bookings set respond_by = now() - interval '1 minute' where code=%s", (c3,))
eq("sin respuesta a tiempo expira", as_(None, "select get_stay_booking(%s)->>'status'", (c3,))[1][0][0], 'expirada')
chk("no se acepta una solicitud expirada", as_(host, "select host_respond_stay_booking(%s, true)", (bid(c3),)), True)

# --- comprobante y verificación
chk("el huésped no adjunta una ruta ajena", as_(None, "select attach_stay_proof(%s, 'OTRO/x.png')", (c1,)), True)
chk("anónimo sube archivo a la carpeta de su reserva", as_(None, "insert into storage.objects(bucket_id,name) values ('stay-proofs', %s)", (c1 + '/voucher.png',)), False)
chk("anónimo no sube a la carpeta de otra reserva", as_(None, "insert into storage.objects(bucket_id,name) values ('stay-proofs', 'ZZZZZZZZZZ/voucher.png')"), True)
chk("anónimo no se hace pasar por el anfitrión", as_(None, "insert into storage.objects(bucket_id,name) values ('stay-proofs', %s)", ('host/' + str(bid(c1)) + '/x.png',)), True)
eq("el anónimo no puede leer los comprobantes", len(as_(None, "select * from storage.objects where bucket_id='stay-proofs'")[1]), 0)
chk("sube el comprobante", as_(None, "select attach_stay_proof(%s, %s)", (c1, c1 + '/voucher.png')), False)
eq("comprobante enviado", st(c1), 'comprobante_enviado')
b1 = [x for x in as_(host, "select my_stay_bookings()")[1][0][0] if x['code'] == c1][0]
eq("el anfitrión no ve el teléfono del huésped antes de verificar", b1['guest_phone'], None)
eq("ni el comprobante", b1['proof_path'], None)
chk("el anfitrión no verifica pagos", as_(host, "select admin_review_stay_proof(%s, true, null)", (bid(c1),)), True)
chk("rechazar exige motivo", as_(adm, "select admin_review_stay_proof(%s, false, null)", (bid(c1),)), True)
chk("el admin rechaza con motivo", as_(adm, "select admin_review_stay_proof(%s, false, 'Monto incorrecto')", (bid(c1),)), False)
eq("vuelve a pendiente de pago con el motivo visible", (st(c1), as_(None, "select get_stay_booking(%s)->>'review_note'", (c1,))[1][0][0]), ('aceptada_pendiente_pago', 'Monto incorrecto'))
chk("sube otro comprobante", as_(None, "select attach_stay_proof(%s, %s)", (c1, c1 + '/voucher2.png')), False)
chk("el admin verifica", as_(adm, "select admin_review_stay_proof(%s, true, 'OK')", (bid(c1),)), False)
eq("conexión generada", st(c1), 'conexion_generada')
g = as_(None, "select get_stay_booking(%s)", (c1,))[1][0][0]
eq("ahora sí se revela el WhatsApp del anfitrión", g['host_whatsapp'], '71234567')
eq("el 90 % se muestra como saldo directo, no cobrado por Bastet", (g['balance'], g['fee_amount']), (270, 30))
b1 = [x for x in as_(host, "select my_stay_bookings()")[1][0][0] if x['code'] == c1][0]
eq("el anfitrión ya ve el contacto del huésped", b1['guest_phone'], '+59176543210')
chk("el admin lee el historial", as_(adm, "select stay_booking_events(%s)", (bid(c1),)), False)
chk("el anfitrión no lee el historial", as_(host, "select stay_booking_events(%s)", (bid(c1),)), True)
eq("la auditoría registró el recorrido", one("select count(*) from stay_booking_events where booking_id=%s", (bid(c1),)) == 6, True)

# --- cancelación del huésped
c4 = verified(pU, D(100), D(103), '+591 70000010')
res = as_(None, "select cancel_stay_booking(%s, 'No puedo viajar')", (c4,))[1][0][0]
eq("a más de 72 h: gratis; Bastet devuelve el 10 % y el anfitrión el 90 %", (res['late_cancel'], res['bastet_refund_bs'], res['host_retention'], res['host_refund_due']), (False, 210, None, 270))
chk("no se cancela dos veces", as_(None, "select cancel_stay_booking(%s)", (c4,)), True)
c5 = verified(pU, D(1), D(3), '+591 70000011')
res = as_(None, "select cancel_stay_booking(%s)", (c5,))[1][0][0]
eq("dentro de 72 h: retiene 20 % (10 Bastet + 10 anfitrión); Bastet no devuelve", (res['late_cancel'], res['bastet_refund_bs'], res['host_retention']), (True, 0, 20))
eq("el anfitrión debe devolver el 80 % al huésped si recibió el 90 %", res['host_refund_due'], 160)
b5 = bid(c5)
eq("el anfitrión debe declarar el 90 %", [x for x in as_(host, "select my_stay_bookings()")[1][0][0] if x['code'] == c5][0]['needs_direct_declaration'], True)
chk("recibido con comprobante exige archivo", as_(host, "select host_declare_direct_payment(%s,'recibido_con_comprobante',180,%s,'QR',null)", (b5, D(0))), True)
chk("importe y fecha obligatorios si recibió", as_(host, "select host_declare_direct_payment(%s,'declarado_sin_comprobante',null,null,null,null)", (b5,)), True)
chk("el comprobante debe estar en su carpeta", as_(host, "select host_declare_direct_payment(%s,'recibido_con_comprobante',180,%s,'QR','host/otro/x.png')", (b5, D(0))), True)
chk("otro anfitrión no declara", as_(host2, "select host_declare_direct_payment(%s,'no_recibido',null,null,null,null)", (b5,)), True)
chk("el anfitrión declara con comprobante", as_(host, "select host_declare_direct_payment(%s,'recibido_con_comprobante',180,%s,'QR',%s)", (b5, D(0), 'host/' + str(b5) + '/c.png')), False)
chk("el anfitrión sube su constancia a su carpeta", as_(host, "insert into storage.objects(bucket_id,name) values ('stay-proofs', %s)", ('host/' + str(b5) + '/c.png',)), False)
chk("otro anfitrión no sube a esa carpeta", as_(host2, "insert into storage.objects(bucket_id,name) values ('stay-proofs', %s)", ('host/' + str(b5) + '/d.png',)), True)
chk("el admin marca la declaración como controvertida", as_(adm, "select admin_review_direct_payment(%s,'controvertido','Monto no coincide')", (b5,)), False)
chk("el admin abre una disputa", as_(adm, "select admin_set_stay_dispute(%s, true, 'Reclamo del huésped')", (b5,)), False)
eq("en disputa", st(c5), 'en_disputa')
chk("el anfitrión no cierra disputas", as_(host, "select admin_set_stay_dispute(%s, false, null)", (b5,)), True)
chk("el admin cierra la disputa", as_(adm, "select admin_set_stay_dispute(%s, false, 'Resuelto')", (b5,)), False)
eq("vuelve a cancelada", st(c5), 'cancelada')

# --- cancelación del anfitrión
c6 = verified(pU, D(120), D(122), '+591 70000012')
chk("el anfitrión debe dar un motivo", as_(host, "select host_cancel_stay_booking(%s, '')", (bid(c6),)), True)
chk("otro anfitrión no cancela", as_(host2, "select host_cancel_stay_booking(%s, 'x')", (bid(c6),)), True)
chk("el anfitrión cancela", as_(host, "select host_cancel_stay_booking(%s, 'Plomería rota')", (bid(c6),)), False)
su("select bastet_refund_bs, host_refund_due, cancelled_by from stay_bookings where code=%s", (c6,)); rf, hd, cb_ = cur.fetchone()
eq("Bastet devuelve el 100 % del 10 % (Bs 140) y el anfitrión el 90 % directo (180 USD)", (float(rf), float(hd), cb_), (140.0, 180.0, 'host'))
chk("las fechas canceladas vuelven a estar libres", book(pU, D(120), D(122), phone='+591 70000013'), False)

# --- cancelar antes de pagar es gratis y sin devoluciones
c7 = code_of(book(pU, D(200), D(202), phone='+591 70000014'))
res = as_(None, "select cancel_stay_booking(%s)", (c7,))[1][0][0]
eq("solicitud sin pagar: cancelación sin costo", (res['paid'], res['bastet_refund_bs']), (False, 0))

# --- tope por teléfono
for k in range(3): book(pU, D(300 + k * 3), D(302 + k * 3), phone='+591 70000099')
chk("máximo 3 solicitudes esperando por teléfono", book(pU, D(320), D(322), phone='+591 70000099'), True)

su("select 1")
for _ in range(2): cur.execute(sbk)
print("stay-bookings.sql re-corrido sin error")
print("FALLAS:", fails); sys.exit(1 if fails else 0)
