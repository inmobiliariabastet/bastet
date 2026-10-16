"""Pruebas del SQL de servicios del plan Propietario: directorio de agentes, ofertas de colaboración a un agente
(validaciones, numeración, respuesta del agente, cancelación, aislamiento) y solicitudes a Maat Fima Legal.
Requiere:  pip install pgserver psycopg2-binary   y se ejecuta con:  python tests/owner_services_sql_test.py
Levanta un Postgres local desechable: NO toca Supabase ni producción."""
import pgserver, psycopg2, sys, json, tempfile, pathlib, datetime
ROOT = pathlib.Path(__file__).resolve().parent.parent
srv = pgserver.get_server(tempfile.mkdtemp(prefix='uno-pg-'), cleanup_mode='delete')
uri = srv.get_uri()
R_ = str(ROOT / "supabase") + "/"
sch = open(R_ + "schema.sql", encoding='utf-8').read()
core = sch[:sch.index("-- ── Tabla property_events")]
i = sch.index("-- UNO · Créditos para agentes")
tail = sch[sch.rindex("\n", 0, i - 5) + 1:]
mk = tail.index("-- =====================================================================\n-- UNO · Servicios del plan Propietario")
EQ = "-- =====================================================================" + chr(10) + "-- UNO · Registro de nuevos usuarios"
end = tail.index(EQ) if EQ in tail else len(tail)
assert tail[mk:end].strip() == open(R_ + "owner-services.sql", encoding="utf-8").read().strip(), "schema.sql no tiene el mismo bloque que owner-services.sql"
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
import os
if os.environ.get("DROP_CREDITS"):
    su("select 1"); cur.execute(open(R_ + "drop-credits.sql", encoding="utf-8").read()); print("drop-credits.sql aplicado: las pruebas siguientes corren SIN el sistema de créditos")
cur.execute("insert into auth.users(email,invited_at) values ('admin@x','2026-01-01'),('own@x','2026-01-01'),('own2@x','2026-01-01'),('ag1@x','2026-01-01'),('ag2@x','2026-01-01'),('agx@x','2026-01-01'),('emp@x','2026-01-01'),('plain@x','2026-01-01') returning id")
adm, own, own2, ag1, ag2, agx, emp, plain = [r[0] for r in cur.fetchall()]
su("alter table public.profiles disable trigger protect_profile_privileged")
su("update public.profiles set role='admin' where id=%s", (adm,))
su("update public.profiles set display_name='Ana Agente', avatar_url='http://x/a.png', facebook_url='http://fb/ana' where id=%s", (ag1,))
su("update public.profiles set display_name='Beto Agente' where id=%s", (ag2,))
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
    print(('PASS' if good else 'FAIL'), name, '->', str(res)[:140])
def eq(name, got, want):
    global fails
    good = got == want
    if not good: fails += 1
    print(('PASS' if good else 'FAIL'), name, '->', got)
def one(sql, a=None):
    su(sql, a); return cur.fetchone()[0]
def row(sql, a=None):
    su(sql, a); return cur.fetchone()
def plan(u, p, days=None): su("select _activate_subscription(%s,%s,'admin',%s,null)", (u, p, days))
plan(own, 'propietario'); plan(own2, 'propietario'); plan(ag1, 'agente'); plan(ag2, 'agente'); plan(emp, 'empresa'); plan(agx, 'agente')
INS = "insert into properties(id,title,location,price,area,rooms,baths,owner_id) values (gen_random_uuid(),%s,'La Paz','100000','100','3','2',%s) returning id"
pid = as_(own, INS, ('Casa de prueba', own))[1][0][0]
pid2 = as_(own, INS, ('Depto de prueba', own))[1][0][0]
pid_other = as_(own2, INS, ('Casa ajena', own2))[1][0][0]
TERMS = {"comision_porcentaje": 3, "plazo_dias": 90, "exclusividad": True, "owner_nombre": "Juan Pérez Mamani", "owner_ci": "4567890 LP", "owner_telefono": "70012345", "mensaje": "Gracias"}
T = lambda **kw: json.dumps({**TERMS, **kw})
OFFER = "select create_owner_offer(%s::uuid, %s::uuid, %s::jsonb)"

# ── directorio de agentes
d = as_(own, "select id, display_name, avatar_url, plan_name from list_agent_directory()")
eq("directorio: agentes con plan Agente/Empresa vigente (sin uno mismo, ni el admin, ni propietarios)", sorted(r[1] for r in d[1]), ['Agente de Bastet', 'Agente de Bastet', 'Ana Agente', 'Beto Agente'])
eq("…incluye a la cuenta Empresa", any(r[3] == 'Empresa' for r in d[1]), True)
su("select * from list_agent_directory() limit 0")
eq("directorio: solo datos públicos (sin correo, teléfono ni rol)", sorted(x.name for x in cur.description),
   sorted(['id', 'display_name', 'avatar_url', 'facebook_url', 'instagram_url', 'tiktok_url', 'plan_name', 'active_properties']))
chk("anon no ve el directorio", as_(None, "select * from list_agent_directory()"), True)
su("update subscriptions set current_period_end = now() - interval '1 day' where user_id=%s", (agx,))
eq("un agente con plan vencido sale del directorio", len(as_(own, "select * from list_agent_directory()")[1]), 3)
su("update subscriptions set current_period_end = now() + interval '20 days' where user_id=%s", (agx,))

# ── ofertas: quién puede crear y qué se valida
chk("un agente no ofrece propiedades como propietario", as_(ag1, OFFER, (pid, ag2, T())), True)
chk("sin plan no puede", as_(plain, OFFER, (pid, ag1, T())), True)
chk("no ofrece una propiedad ajena", as_(own, OFFER, (pid_other, ag1, T())), True)
chk("no se ofrece a sí mismo", as_(own, OFFER, (pid, own, T())), True)
chk("el destinatario debe ser agente con plan (un propietario no sirve)", as_(own, OFFER, (pid, own2, T())), True)
chk("el admin no es destinatario", as_(own, OFFER, (pid, adm, T())), True)
chk("agente inexistente", as_(own, OFFER, (pid, '00000000-0000-0000-0000-000000000000', T())), True)
for nm, kw in [("comisión 0", dict(comision_porcentaje=0)), ("comisión 20 %", dict(comision_porcentaje=20)), ("plazo 5", dict(plazo_dias=5)), ("plazo 400", dict(plazo_dias=400)),
               ("exclusividad no es booleano", dict(exclusividad='si')), ("nombre corto", dict(owner_nombre='Ab')), ("C.I. inválida", dict(owner_ci='abc')),
               ("teléfono corto", dict(owner_telefono='123')), ("mensaje largo", dict(mensaje='x' * 501))]:
    chk("validación: " + nm, as_(own, OFFER, (pid, ag1, T(**kw))), True)
eq("las inválidas no crearon nada", one("select count(*) from owner_offers"), 0)

# ── crear
r = as_(own, OFFER, (pid, ag1, T())); chk("el propietario ofrece su propiedad a un agente", r, False)
o1 = r[1][0][0]
yr = datetime.datetime.now().year
eq("número de documento BST-CO-año-0001", o1['doc_number'], 'BST-CO-%d-0001' % yr)
st, title, com, nombre = row("select status, property_data->>'title', terms->>'comision_porcentaje', owner_data->>'nombre' from owner_offers where id=%s", (o1['id'],))
eq("estado pendiente y datos copiados", (st, title, com, nombre), ('pending', 'Casa de prueba', '3', 'Juan Pérez Mamani'))
chk("la misma propiedad al mismo agente (pendiente): rechazada", as_(own, OFFER, (pid, ag1, T())), True)
r2 = as_(own, OFFER, (pid, ag2, T(exclusividad=False))); chk("la misma propiedad a otro agente: permitida", r2, False)
eq("numeración correlativa 0002", r2[1][0][0]['doc_number'], 'BST-CO-%d-0002' % yr)
su("update properties set price='999' where id=%s", (pid,))
eq("la oferta conserva el precio de cuando se ofreció", one("select property_data->>'price' from owner_offers where id=%s", (o1['id'],)), '100000')
su("update properties set status='sold' where id=%s", (pid2,))
chk("una propiedad vendida no se ofrece", as_(own, OFFER, (pid2, ag1, T())), True)
su("update properties set status='available' where id=%s", (pid2,))

# ── aislamiento
eq("el propietario ve sus ofertas", len(as_(own, "select * from owner_offers")[1]), 2)
eq("el agente ve solo la dirigida a él", [r[0] for r in as_(ag1, "select agent_id from owner_offers")[1]], [ag1])
eq("otro propietario no ve ofertas ajenas", len(as_(own2, "select * from owner_offers")[1]), 0)
eq("un agente no destinatario no la ve", len(as_(agx, "select * from owner_offers")[1]), 0)
eq("el admin ve todas", len(as_(adm, "select * from owner_offers")[1]), 2)
chk("nadie inserta ofertas directo", as_(own, "insert into owner_offers(doc_number,owner_id,agent_id,property_id,property_data,owner_data,terms) values ('X',%s,%s,%s,'{}','{}','{}')", (own, ag1, pid)), True)
chk("el propietario no edita el estado directo", as_(own, "update owner_offers set status='accepted'"), True)
chk("el agente no edita el estado directo", as_(ag1, "update owner_offers set status='accepted'"), True)
chk("anon no lee ofertas", as_(None, "select * from owner_offers"), True)
eq("eventos solo para las partes", (len(as_(own, "select * from owner_offer_events")[1]), len(as_(agx, "select * from owner_offer_events")[1])), (2, 0))

# ── respuestas del agente
chk("el propietario no responde su propia oferta", as_(own, "select respond_owner_offer(%s,true,null)", (o1['id'],)), True)
chk("otro agente no responde la oferta ajena", as_(ag2, "select respond_owner_offer(%s,true,null)", (o1['id'],)), True)
chk("nota demasiado larga", as_(ag1, "select respond_owner_offer(%s,true,%s)", (o1['id'], 'x' * 501)), True)
su("update subscriptions set current_period_end = now() - interval '1 day' where user_id=%s", (ag1,))
chk("sin plan vigente el agente no puede aceptar", as_(ag1, "select respond_owner_offer(%s,true,null)", (o1['id'],)), True)
chk("…pero sí puede rechazar", as_(ag1, "select respond_owner_offer(%s,false,'No tengo disponibilidad')", (o1['id'],)), False)
eq("rechazada con su nota", row("select status, response_note from owner_offers where id=%s", (o1['id'],)), ('rejected', 'No tengo disponibilidad'))
chk("no se responde dos veces", as_(ag1, "select respond_owner_offer(%s,true,null)", (o1['id'],)), True)
chk("sin plan vigente no se puede ofrecer a ese agente", as_(own, OFFER, (pid, ag1, T())), True)
plan(ag1, 'agente')
chk("con el plan renovado se puede volver a ofrecer", as_(own, OFFER, (pid, ag1, T())), False)
oid2 = r2[1][0][0]['id']
su("insert into agent_legal_profiles(user_id,ci,phone,registration) values (%s,'7654321','71122334','REG-9')", (ag2,))
chk("el agente acepta", as_(ag2, "select respond_owner_offer(%s,true,'Con gusto')", (oid2,)), False)
eq("aceptada", one("select status from owner_offers where id=%s", (oid2,)), 'accepted')
eq("al aceptar se suman la C.I. y el registro del agente", row("select agent_data->>'nombre', agent_data->>'ci', agent_data->>'registro' from owner_offers where id=%s", (oid2,)), ('Beto Agente', '7654321', 'REG-9'))
eq("el rechazo no copia datos legales", row("select agent_data->>'ci' from owner_offers where id=%s", (o1['id'],)), (None,))
chk("una aceptada no se cancela", as_(own, "select cancel_owner_offer(%s)", (oid2,)), True)
eq("eventos registrados (creada + aceptada)", one("select count(*) from owner_offer_events where offer_id=%s", (oid2,)), 2)

# ── cancelar
o3 = as_(own, OFFER, (pid2, ag2, T()))[1][0][0]
chk("otro propietario no cancela ofertas ajenas", as_(own2, "select cancel_owner_offer(%s)", (o3['id'],)), True)
chk("el agente no cancela", as_(ag2, "select cancel_owner_offer(%s)", (o3['id'],)), True)
chk("el propietario cancela la pendiente", as_(own, "select cancel_owner_offer(%s)", (o3['id'],)), False)
eq("quedó cancelada", one("select status from owner_offers where id=%s", (o3['id'],)), 'canceled')
chk("no se responde una cancelada", as_(ag2, "select respond_owner_offer(%s,true,null)", (o3['id'],)), True)
# máximo 10 pendientes por propietario (el plan permite 3 propiedades activas: se liberan las ya ofrecidas con otras propiedades)
su("update subscriptions set plan_code='empresa' where user_id=%s", (own,))     # solo para tener propiedades suficientes en la prueba
su("update subscriptions set plan_code='propietario' where user_id=%s", (own,))
su("delete from owner_offers where owner_id=%s", (own,))
props = [as_(own, INS, ('Q%d' % k, own)) for k in range(12)]
ids = [p[1][0][0] for p in props if p[0] == 'ok'] + [pid, pid2]
su("update subscriptions set plan_code='propietario' where user_id=%s", (own,))
n_ok = 0
for pr in [pid, pid2]:
    for ag in (ag1, ag2): n_ok += as_(own, OFFER, (pr, ag, T()))[0] == 'ok'
eq("ofertas distintas permitidas (2 propiedades × 2 agentes)", n_ok, 4)
# 10 pendientes: se fuerzan filas directas para llegar al tope
su("insert into owner_offers(doc_number,owner_id,agent_id,property_id,property_data,owner_data,terms) select 'X'||g, %s, %s, gen_random_uuid(), '{}','{}','{}' from generate_series(1,6) g", (own, agx))
chk("tope de 10 ofertas pendientes", as_(own, OFFER, (pid, agx, T())), True)

# ── solicitudes a Maat Fima Legal
LEG = "select create_legal_request(%s,%s::uuid,%s)"
eq("6 servicios configurados y legibles", as_(own, "select count(*) from legal_service_types where active")[1][0][0], 6)
chk("un agente no solicita (es del plan Propietario)", as_(ag1, LEG, ('tramites', None, 'Necesito ayuda con un trámite')), True)
chk("sin plan no solicita", as_(plain, LEG, ('tramites', None, 'Necesito ayuda con un trámite')), True)
chk("servicio inexistente", as_(own, LEG, ('brujeria', None, 'Necesito ayuda con algo')), True)
chk("descripción corta", as_(own, LEG, ('tramites', None, 'corto')), True)
chk("propiedad ajena", as_(own, LEG, ('saneamiento', pid_other, 'Necesito sanear los documentos')), True)
r = as_(own, LEG, ('saneamiento', pid, 'Necesito sanear los documentos de mi casa')); chk("el propietario solicita un servicio", r, False)
l1 = r[1][0][0]
eq("queda pendiente con el título de la propiedad", row("select status, property_title from legal_requests where id=%s", (l1,)), ('pending', 'Casa de prueba'))
chk("solicitud sin propiedad (asesoramiento general)", as_(own, LEG, ('asesoramiento', None, 'Quiero asesoría para vender mi casa')), False)
eq("cada persona ve solo las suyas", (len(as_(own, "select * from legal_requests")[1]), len(as_(own2, "select * from legal_requests")[1])), (2, 0))
eq("el admin ve todas", len(as_(adm, "select * from legal_requests")[1]), 2)
chk("no se insertan solicitudes directo", as_(own, "insert into legal_requests(user_id,service_code,description) values (%s,'otro','xxxxxxxxxxxx')", (own,)), True)
chk("el usuario no cambia el estado directo", as_(own, "update legal_requests set status='completed'"), True)
chk("el propietario cancela una pendiente", as_(own, "select cancel_legal_request(%s)", (l1,)), False)
chk("no se cancela dos veces", as_(own, "select cancel_legal_request(%s)", (l1,)), True)
chk("otro usuario no cancela solicitudes ajenas", as_(own2, "select cancel_legal_request(%s)", (l1,)), True)
l2 = as_(own, LEG, ('impuestos', None, 'Apoyo con el impuesto a la propiedad'))[1][0][0]
chk("el propietario no actualiza el avance", as_(own, "select admin_update_legal_request(%s,'completed','x')", (l2,)), True)
chk("el admin pasa a 'en gestión'", as_(adm, "select admin_update_legal_request(%s,'in_progress','Estamos revisando')", (l2,)), False)
eq("avance y nota del admin", row("select status, admin_note from legal_requests where id=%s", (l2,)), ('in_progress', 'Estamos revisando'))
chk("estado inválido", as_(adm, "select admin_update_legal_request(%s,'hecho','x')", (l2,)), True)
chk("el admin completa", as_(adm, "select admin_update_legal_request(%s,'completed',null)", (l2,)), False)
chk("una cerrada no se reabre", as_(adm, "select admin_update_legal_request(%s,'pending','x')", (l2,)), True)
chk("una cancelada tampoco", as_(adm, "select admin_update_legal_request(%s,'in_review','x')", (l1,)), True)
su("update legal_service_types set active=false where code='otro'")
chk("un servicio desactivado no se puede solicitar", as_(own, LEG, ('otro', None, 'Otro servicio que necesito')), True)
for k in range(12): as_(own, LEG, ('tramites', None, 'Solicitud numero %d de prueba' % k))
eq("máximo 10 solicitudes abiertas", one("select count(*) from legal_requests where user_id=%s and status in ('pending','in_review','in_progress')", (own,)), 10)
as_(ag1, "update legal_service_types set name='x'")
eq("el agente no edita servicios", one("select count(*) from legal_service_types where name='x'"), 0)
chk("anon no lee solicitudes", as_(None, "select * from legal_requests"), True)

print("\n%s: %d fallo(s)" % ("OK" if fails == 0 else "FALLAS", fails))
sys.exit(1 if fails else 0)
