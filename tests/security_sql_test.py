"""Pruebas de supabase/security-hardening.sql (fase 2, paso B2): contacto protegido, datos privados entre cuentas, fotos y avatares solo del dueño,
límite de intentos por IP y permisos mínimos del visitante. Aplica el esquema COMPLETO (con sus políticas de seguridad por filas).
Requiere:  pip install pgserver psycopg2-binary   y se ejecuta con:  python tests/security_sql_test.py
Levanta un Postgres local desechable: NO toca Supabase ni producción."""
import pgserver, psycopg2, sys, tempfile, pathlib
ROOT = pathlib.Path(__file__).resolve().parent.parent
srv = pgserver.get_server(tempfile.mkdtemp(prefix='uno-pg-'), cleanup_mode='delete')
uri = srv.get_uri()
R_ = str(ROOT / "supabase") + "/"
sch = open(R_ + "schema.sql", encoding='utf-8').read()
sec = open(R_ + "security-hardening.sql", encoding="utf-8").read()
assert sec.strip().replace('\r', '') in sch.replace('\r', ''), "security-hardening.sql no está igual al final de schema.sql"
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
    cur.execute("reset role; select set_config('request.jwt.claim.sub','',false); select set_config('request.headers','',false)"); cur.execute(sql, args)
cur.execute(stub); cur.execute(sch)
print("esquema completo aplicado")
cur.execute("insert into auth.users(email,invited_at) values ('admin@x','2026-01-01'),('own@x','2026-01-01'),('other@x','2026-01-01') returning id")
adm, own, other = [r[0] for r in cur.fetchall()]
su("update public.profiles set role='admin' where id=%s", (adm,))
su("update public.profiles set display_name='Olga Owner', contact_whatsapp='71111111', interest='agente', registered_at=now() where id=%s", (own,))
su("update public.profiles set display_name='Otto Other', contact_whatsapp='72222222', interest='agente', registered_at=now() where id=%s", (other,))
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
def mkprop(owner, title, status='available', op='venta', wa='70000000', owa='79999999'):
    cur.execute("reset role; insert into properties (title, location, area, rooms, baths, description, price, currency, owner_id, operation, status, property_type, whatsapp, owner_whatsapp) values (%s,'La Paz','80','2','1','x','100000','USD',%s,%s,%s,'casa',%s,%s) returning id", (title, owner, op, status, wa, owa))
    return cur.fetchone()[0]
su("set session_replication_role = replica")
pA = mkprop(own, 'De Olga'); pS = mkprop(own, 'Vendida de Olga', 'sold'); pO = mkprop(other, 'De Otto'); pT = mkprop(own, 'Temporal', op='temporal')
su("set session_replication_role = origin")

# ── el visitante anónimo
chk("anónimo lee columnas públicas", as_(None, "select id, title, price, owner_id from properties"), False)
chk("anónimo NO lee el WhatsApp de la propiedad", as_(None, "select whatsapp from properties"), True)
chk("anónimo NO lee el teléfono privado del propietario", as_(None, "select owner_whatsapp from properties"), True)
chk("anónimo NO puede pedir todas las columnas", as_(None, "select * from properties"), True)
chk("anónimo lee el perfil público del agente", as_(None, "select id, display_name, avatar_url from profiles"), False)
chk("anónimo NO lee el WhatsApp del agente", as_(None, "select contact_whatsapp from profiles"), True)
chk("anónimo NO lee correos ni datos de registro", as_(None, "select email, full_name from profiles"), True)
eq("el visitante ve solo los perfiles de agentes con propiedades disponibles", sorted(r[0] for r in as_(None, "select display_name from profiles")[1]), ['Olga Owner', 'Otto Other'])
su("update properties set status='sold' where owner_id=%s", (other,))
eq("un agente sin propiedades disponibles deja de ser público", [r[0] for r in as_(None, "select display_name from profiles")[1]], ['Olga Owner'])
su("update properties set status='available' where owner_id=%s", (other,))
chk("anónimo no puede modificar propiedades", as_(None, "update properties set status='sold'"), True)
chk("anónimo no puede borrar propiedades", as_(None, "delete from properties"), True)
chk("anónimo no puede editar perfiles (ni hacerse admin)", as_(None, "update profiles set role='admin'"), True)
chk("anónimo no puede borrar perfiles", as_(None, "delete from profiles"), True)
chk("anónimo no puede vaciar tablas", as_(None, "truncate properties"), True)
chk("anónimo sí registra analítica", as_(None, "insert into property_events(property_id, event_type) values (%s, 'view')", (pA,)), False)
chk("anónimo no lee los planes retirados", as_(None, "select * from subscription_plans"), True)
chk("anónimo no ve tablas privadas", as_(None, "select * from connections"), True)

# ── una persona con sesión (otra cuenta)
chk("otra cuenta lee columnas públicas de propiedades disponibles", as_(other, "select id, title from properties where id=%s", (pA,)), False)
chk("otra cuenta NO lee el teléfono privado del propietario", as_(other, "select owner_whatsapp from properties"), True)
chk("otra cuenta NO lee el WhatsApp de una propiedad", as_(other, "select whatsapp from properties"), True)
chk("otra cuenta NO puede pedir todas las columnas", as_(other, "select * from properties"), True)
eq("otra cuenta no ve propiedades no disponibles ajenas", len(as_(other, "select id from properties where id=%s", (pS,))[1]), 0)
eq("el dueño sí ve las suyas aunque no estén disponibles", len(as_(own, "select id from properties where id=%s", (pS,))[1]), 1)
eq("el admin ve todas", len(as_(adm, "select id from properties")[1]), 4)
eq("my_property_contacts: el dueño recibe solo los suyos", sorted(r[0] for r in as_(own, "select owner_whatsapp from my_property_contacts()")[1]), ['79999999'] * 3)
eq("otra cuenta no recibe teléfonos ajenos", sorted(r[0] for r in as_(other, "select property_id from my_property_contacts()")[1]), [pO])
eq("el admin recibe todos", len(as_(adm, "select * from my_property_contacts()")[1]), 4)
chk("anónimo no usa my_property_contacts", as_(None, "select * from my_property_contacts()"), True)
chk("el dueño actualiza su propiedad (incluido el teléfono)", as_(own, "update properties set whatsapp='71234567', owner_whatsapp='78888888' where id=%s", (pA,)), False)
eq("…y el cambio quedó", as_(own, "select whatsapp, owner_whatsapp from my_property_contacts() where property_id=%s", (pA,))[1][0], ('71234567', '78888888'))
eq("otra cuenta no puede editar propiedades ajenas", as_(other, "update properties set title='hack' where id=%s", (pA,))[1], 0)
eq("otra cuenta no puede borrar propiedades ajenas", as_(other, "delete from properties where id=%s", (pA,))[1], 0)
chk("una cuenta no puede hacerse administradora", as_(other, "update profiles set role='admin' where id=%s", (other,)), False)
eq("…el rol no cambió", one("select role from profiles where id=%s", (other,)), 'agent')
chk("una cuenta no lee el perfil privado de otra", as_(other, "select email from profiles where id=%s", (own,)), False)
eq("…no devuelve filas ajenas", len(as_(other, "select email from profiles where id=%s", (own,))[1]), 0)
INSP = "insert into properties(id,title,location,price,area,rooms,baths,owner_id,operation,whatsapp,owner_whatsapp) values (gen_random_uuid(),'Nueva','La Paz','1000','100','3','2',%s,'venta','70000001','70000002') returning id"
chk("crear una propiedad sigue funcionando", as_(own, INSP, (own,)), False)
chk("no se crea una propiedad a nombre de otro", as_(other, INSP, (own,)), True)

# ── contacto público por función
eq("conexiones apagadas: se entrega el teléfono del agente", as_(None, "select public_property_contact(%s)", (pA,))[1][0][0], {'allowed': True, 'phone': '71111111'})
su("update profiles set contact_whatsapp=null where id=%s", (own,))
eq("sin teléfono de agente: el de la propiedad", as_(None, "select public_property_contact(%s)", (pA,))[1][0][0]['phone'], '71234567')
su("update profiles set contact_whatsapp='71111111' where id=%s", (own,))
eq("propiedad no disponible: nada", as_(None, "select public_property_contact(%s)", (pS,))[1][0][0], {'allowed': False})
eq("propiedad inexistente: nada", as_(None, "select public_property_contact('00000000-0000-0000-0000-000000000000')")[1][0][0], {'allowed': False})
eq("agente: se entrega su teléfono", as_(None, "select public_agent_contact(%s)", (own,))[1][0][0], {'allowed': True, 'phone': '71111111'})
su("update connection_settings set enabled=true, pay_instructions='Banco X cuenta 123456789', framework_text=repeat('x', 200) where id=1")
eq("conexiones activas: la propiedad ya no entrega el teléfono", as_(None, "select public_property_contact(%s)", (pA,))[1][0][0], {'allowed': False, 'via': 'solicitud'})
eq("conexiones activas: el agente tampoco", as_(None, "select public_agent_contact(%s)", (own,))[1][0][0], {'allowed': False, 'via': 'solicitud'})
eq("una estadía sigue entregándolo mientras no haya reservas con pago", as_(None, "select public_property_contact(%s)", (pT,))[1][0][0]['allowed'], True)
su("update stay_settings set enabled=true, pay_instructions='Banco X cuenta 123456789' where id=1")
eq("con reservas activas la estadía tampoco lo entrega", as_(None, "select public_property_contact(%s)", (pT,))[1][0][0], {'allowed': False, 'via': 'reserva'})
su("update connection_settings set enabled=false where id=1"); su("update stay_settings set enabled=false where id=1")

# ── límite de intentos por IP
H = lambda ip: '{"x-forwarded-for":"%s"}' % ip
n_ok = 0
for k in range(45): n_ok += as_(None, "select public_property_contact(%s)", (pA,), headers=H('203.0.113.7'))[0] == 'ok'
eq("40 consultas por minuto desde una IP; luego se corta", n_ok, 40)
chk("otra IP no se ve afectada", as_(None, "select public_property_contact(%s)", (pA,), headers=H('203.0.113.8')), False)
chk("el último elemento de x-forwarded-for manda (no el que escribe el cliente)", as_(None, "select public_property_contact(%s)", (pA,), headers='{"x-forwarded-for":"1.1.1.1, 203.0.113.9"}'), False)
r = as_(None, "select public_property_contact(%s)", (pA,), headers=H('203.0.113.7'))
eq("el mensaje pide esperar", 'Espera' in r[1], True)
chk("sin cabeceras (SQL Editor, pruebas internas) no se limita", as_(None, "select public_property_contact(%s)", (pA,)), False)
n_ok = 0
for k in range(12): n_ok += as_(None, "select get_review_invite(%s)", ('X' * 12,), headers=H('198.51.100.1'))[0] == 'ok'
eq("get_review_invite (antes STABLE) ahora limita: 30 por minuto, aquí 12 pasan", n_ok, 12)
n_ok = 0
for k in range(35): n_ok += as_(None, "select * from verify_exclusivity_contract(%s)", ('AAAAAAAA',), headers=H('198.51.100.2'))[0] == 'ok'
eq("la verificación de contratos limita a 30 por minuto (fuerza bruta)", n_ok, 30)
n_ok = 0
for k in range(10): n_ok += as_(None, "select request_connection(%s,'Gaby Test','+591 7000000%s',null,null,true)", (pA, k), headers=H('198.51.100.3'))[0] == 'ok'
eq("las solicitudes públicas se detienen sin bloquear a nadie más (conexiones apagadas: todas fallan por otro motivo, pero el límite no rompe)", n_ok, 0)
su("update connection_settings set enabled=true, pay_instructions='Banco X cuenta 123456789', framework_text=repeat('x', 200) where id=1")
n_ok = 0
for k in range(10): n_ok += as_(None, "select request_connection(%s,'Gaby Test','+591 7000010%s',null,null,true)", (pA, k), headers=H('198.51.100.4'))[0] == 'ok'
eq("solicitud de contacto: 8 por 10 minutos desde una IP", n_ok, 8)
chk("otra IP sí puede", as_(None, "select request_connection(%s,'Rita Real','+591 70000199',null,null,true)", (pO,), headers=H('198.51.100.5')), False)
su("update connection_settings set enabled=false where id=1")
eq("el contador de intentos no se puede leer ni borrar desde fuera", as_(None, "select * from rate_limits")[0], 'ERR')

# ── fotos y avatares: solo su dueño
def put(uid, bucket, name): return as_(uid, "insert into storage.objects(bucket_id,name) values (%s,%s)", (bucket, name))
def rm(uid, bucket, name): return as_(uid, "delete from storage.objects where bucket_id=%s and name=%s", (bucket, name))
def upd(uid, bucket, name): return as_(uid, "update storage.objects set name=name where bucket_id=%s and name=%s", (bucket, name))
chk("el dueño sube fotos a la carpeta de su propiedad", put(own, 'property-photos', str(pA) + '/1.jpg'), False)
chk("otra cuenta NO sube fotos a una propiedad ajena", put(other, 'property-photos', str(pA) + '/2.jpg'), True)
eq("otra cuenta NO borra fotos ajenas", rm(other, 'property-photos', str(pA) + '/1.jpg')[1], 0)
eq("otra cuenta NO reemplaza fotos ajenas", upd(other, 'property-photos', str(pA) + '/1.jpg')[1], 0)
eq("el dueño sí borra las suyas", rm(own, 'property-photos', str(pA) + '/1.jpg')[1], 1)
newid = '11111111-2222-3333-4444-555555555555'
chk("se pueden subir fotos de una propiedad que aún no se guarda", put(own, 'property-photos', newid + '/1.jpg'), False)
chk("el admin gestiona fotos de cualquiera", put(adm, 'property-photos', str(pA) + '/3.jpg'), False)
chk("anónimo no sube fotos", put(None, 'property-photos', str(pA) + '/4.jpg'), True)
chk("cada quien sube su avatar", put(own, 'agent-avatars', str(own) + '/a.jpg'), False)
chk("NO se sube a la carpeta de otra persona", put(other, 'agent-avatars', str(own) + '/b.jpg'), True)
eq("NO se borra el avatar ajeno", rm(other, 'agent-avatars', str(own) + '/a.jpg')[1], 0)
eq("el avatar propio sí", rm(own, 'agent-avatars', str(own) + '/a.jpg')[1], 1)
chk("anónimo no sube avatares", put(None, 'agent-avatars', str(own) + '/c.jpg'), True)

# ── lo que ya funcionaba sigue funcionando
chk("la verificación de contratos responde", as_(None, "select * from verify_exclusivity_contract('ZZZZZZZZ')"), False)
chk("estado de conexiones", as_(None, "select connections_enabled()"), False)
chk("fechas ocupadas públicas", as_(None, "select * from stay_booked_ranges(array[%s::uuid])", (pT,)), False)

su("select 1")
for _ in range(2): cur.execute(sec)
print("security-hardening.sql re-corrido sin error (idempotente)")
print("FALLAS:", fails); sys.exit(1 if fails else 0)
