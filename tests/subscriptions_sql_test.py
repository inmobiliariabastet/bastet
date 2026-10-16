"""Pruebas del SQL de suscripciones: planes y precios, límites de propiedades activas y de destacados (con concurrencia),
pago manual confirmado por el admin (idempotente), vencimientos, cambios de plan, contratos, aislamiento de datos y transición.
Requiere:  pip install pgserver psycopg2-binary   y se ejecuta con:  python tests/subscriptions_sql_test.py
Levanta un Postgres local desechable: NO toca Supabase ni producción."""
import pgserver, psycopg2, sys, threading, json, tempfile, pathlib
ROOT = pathlib.Path(__file__).resolve().parent.parent
srv = pgserver.get_server(tempfile.mkdtemp(prefix='uno-pg-'), cleanup_mode='delete')
uri = srv.get_uri()
R_ = str(ROOT / "supabase") + "/"
sch = open(R_ + "schema.sql", encoding='utf-8').read()
core = sch[:sch.index("-- ── Tabla property_events")]
i = sch.index("-- UNO · Créditos para agentes")
tail = sch[sch.rindex("\n", 0, i - 5) + 1:]
mk = tail.index("-- =====================================================================\n-- UNO · Suscripciones mensuales")
tail_pre, subs_sql = tail[:mk], tail[mk:]
assert subs_sql.strip() == open(R_ + "subscriptions.sql", encoding='utf-8').read().strip(), "schema.sql no tiene el mismo bloque que subscriptions.sql"
stub = """
create role anon nologin; create role authenticated nologin;
create schema auth;
create schema storage; create table storage.buckets(id text primary key, name text, public boolean, file_size_limit bigint, allowed_mime_types text[]); create table storage.objects(id uuid default gen_random_uuid() primary key, bucket_id text, name text); alter table storage.objects enable row level security; grant usage on schema storage to anon, authenticated; grant all on storage.objects to anon, authenticated;
create table auth.users(id uuid primary key default gen_random_uuid(), email text, invited_at timestamptz, raw_app_meta_data jsonb default '{}', raw_user_meta_data jsonb default '{}');
create function auth.uid() returns uuid language sql stable as $$ select nullif(current_setting('request.jwt.claim.sub', true),'')::uuid $$;
grant usage on schema auth to anon, authenticated; grant usage on schema public to anon, authenticated;
alter default privileges in schema public grant all on tables to anon, authenticated;
alter default privileges in schema public grant execute on functions to anon, authenticated, public;
"""
c = psycopg2.connect(uri); c.autocommit = True; cur = c.cursor()
cur.execute(stub); cur.execute(core); cur.execute(tail_pre)
def su(sql, args=None):   # como superusuario y SIN sesión (auth.uid() nulo), como el SQL Editor
    cur.execute("reset role; select set_config('request.jwt.claim.sub','',false)"); cur.execute(sql, args)

# Personas que YA existían antes de las suscripciones (para probar la transición)
cur.execute("insert into auth.users(email,invited_at) values ('admin@x','2026-01-01'),('old@x','2026-01-01'),('oldoff@x','2026-01-01') returning id")
adm, old, oldoff = [r[0] for r in cur.fetchall()]
cur.execute("alter table public.profiles disable trigger protect_profile_privileged")
su("update public.profiles set role='admin' where id=%s", (adm,))
su("update public.profiles set is_active=false where id=%s", (oldoff,))
su("insert into properties(id,title,location,price,area,rooms,baths,owner_id) values (gen_random_uuid(),'Vieja','SC','1','1','1','1',%s)", (old,))
for _ in range(2): cur.execute(subs_sql)           # idempotente
print("SQL de suscripciones corrido x2")

cur.execute("insert into auth.users(email,invited_at) values ('p@x','2026-01-01'),('a@x','2026-01-01'),('e@x','2026-01-01'),('n@x','2026-01-01'),('p2@x','2026-01-01') returning id")
prop, agt, emp, nosub, prop2 = [r[0] for r in cur.fetchall()]
fails = 0

def as_(uid, sql, args=None):
    cur.execute("reset role; select set_config('request.jwt.claim.sub',%s,false)", (str(uid) if uid else '',))
    cur.execute("set role authenticated" if uid else "set role anon")
    try:
        cur.execute(sql, args)
        try: return ('ok', cur.fetchall())
        except psycopg2.ProgrammingError: return ('ok', cur.rowcount)
    except Exception as e:
        return ('ERR', str(e).splitlines()[0])
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
def sub(u): return as_(u, "select my_subscription()")[1][0][0]
INS = "insert into properties(id,title,location,price,area,rooms,baths,owner_id) values (gen_random_uuid(),%s,'SC','1','1','1','1',%s)"
def grant(u, plan, days=None): return as_(adm, "select admin_grant_subscription(%s,%s,%s)", (u, plan, days))
def feat(u, pid): return as_(u, "select feature_property(%s::text, null)", (pid,))
def props_of(u): return [r[0] for r in (lambda: (cur.execute("reset role"), cur.execute("select id from properties where owner_id=%s order by created_at", (u,)), cur.fetchall())[2])()]

# ── planes y precios
su("select code, price_bs, max_active_properties, max_featured_per_period, agent_tools from subscription_plans order by sort_order")
eq("planes: precios y límites", [(r[0], float(r[1]), r[2], r[3], r[4]) for r in cur.fetchall()],
   [('propietario', 150.0, 3, 1, False), ('agente', 350.0, 15, 3, True), ('empresa', 650.0, 50, 3, True)])
eq("anon ve los planes (precios públicos)", len(as_(None, "select * from subscription_plans")[1]), 3)
chk("anon no lee suscripciones", as_(None, "select * from subscriptions"), True)
chk("agente no edita planes", as_(prop, "update subscription_plans set price_bs=1"), False)
eq("…y el precio no cambió", float(one("select price_bs from subscription_plans where code='propietario'")), 150.0)
chk("admin edita un plan", as_(adm, "update subscription_plans set price_bs=150 where code='propietario'"), False)

# ── transición: el agente activo que ya existía recibe cortesía; el inactivo no; el admin tampoco
eq("transición: agente activo antiguo con cortesía del plan Agente", one("select plan_code||':'||source from subscriptions where user_id=%s", (old,)), 'agente:grace')
eq("transición: sin cortesía para inactivos ni admin", one("select count(*) from subscriptions where user_id in (%s,%s)", (oldoff, adm)), 0)
eq("transición: su propiedad antigua sigue vigente", one("select expires_at > now() from properties where owner_id=%s", (old,)), True)
eq("correr dos veces no duplica la cortesía", one("select count(*) from subscriptions where user_id=%s", (old,)), 1)

# ── sin suscripción no se publica; con ella sí
r = as_(nosub, INS, ('X', nosub)); chk("sin suscripción: no publica", r, True); eq("mensaje claro", 'suscripción' in r[1], True)
eq("estado 'none'", sub(nosub)['status'], 'none')
chk("agente no se otorga un plan a sí mismo", as_(nosub, "select admin_grant_subscription(%s,'empresa',30)", (nosub,)), True)
chk("agente no inserta en subscriptions", as_(nosub, "insert into subscriptions(user_id,plan_code,current_period_end) values (%s,'empresa',now()+interval '30 days')", (nosub,)), True)
chk("agente no confirma pagos", as_(nosub, "select admin_resolve_subscription_request(1, true)"), True)

# ── pago manual: solicitud → confirmación del admin
rid = as_(prop, "select request_subscription('propietario','transferencia','TRX-123')")[1][0][0]
eq("solicitud con el precio del plan (150) congelado", float(one("select price_bs from subscription_requests where id=%s", (rid,))), 150.0)
eq("un pago pendiente NO activa el plan", (one("select count(*) from subscriptions where user_id=%s", (prop,)), sub(prop)['status'], sub(prop)['pending_request']['plan_code']), (0, 'none', 'propietario'))
chk("sigue sin poder publicar mientras está pendiente", as_(prop, INS, ('X', prop)), True)
chk("segunda solicitud pendiente: rechazada", as_(prop, "select request_subscription('agente','qr',null)"), True)
chk("plan inexistente: rechazado", as_(prop2, "select request_subscription('vip','qr',null)"), True)
chk("método inválido: rechazado", as_(prop2, "select request_subscription('propietario','bitcoin',null)"), True)
chk("el agente no confirma su propio pago", as_(prop, "select admin_resolve_subscription_request(%s,true)", (rid,)), True)
eq("…sigue pendiente", one("select status from subscription_requests where id=%s", (rid,)), 'pending')
chk("admin confirma el pago", as_(adm, "select admin_resolve_subscription_request(%s,true,null)", (rid,)), False)
s = sub(prop)
eq("plan Propietario activo por ~30 días", (s['status'], s['plan']['code'], 28 < one("select extract(epoch from (current_period_end-now()))/86400 from subscriptions where user_id=%s", (prop,)) <= 30), ('active', 'propietario', True))
chk("confirmar dos veces: rechazado (idempotente)", as_(adm, "select admin_resolve_subscription_request(%s,true,null)", (rid,)), True)
eq("…un solo periodo y un solo evento de pago", (one("select count(*) from subscription_events where user_id=%s and kind='payment_confirmed'", (prop,)), one("select count(*) from subscriptions where user_id=%s", (prop,))), (1, 1))
rid2 = as_(prop2, "select request_subscription('propietario','qr',null)")[1][0][0]
chk("admin rechaza una solicitud", as_(adm, "select admin_resolve_subscription_request(%s,false,'sin comprobante')", (rid2,)), False)
eq("rechazada: no activa el plan", one("select count(*) from subscriptions where user_id=%s", (prop2,)), 0)
chk("tras rechazar puede pedir otra", as_(prop2, "select request_subscription('propietario','efectivo',null)"), False)

# ── Propietario: 3 propiedades activas
for n in range(3): chk("propietario publica %d" % (n + 1), as_(prop, INS, ('P%d' % n, prop)), False)
r = as_(prop, INS, ('P3', prop)); chk("propietario: 4.ª rechazada", r, True); eq("mensaje de límite", '3 propiedades' in r[1], True)
eq("uso: 3 activas", sub(prop)['usage']['active_properties'], 3)
eq("vigencia de la propiedad = fin del periodo", one("select bool_and(abs(extract(epoch from (p.expires_at - s.current_period_end))) < 0.001) from properties p join subscriptions s on s.user_id=p.owner_id where p.owner_id=%s", (prop,)), True)
ids = props_of(prop)
as_(prop, "update properties set status='sold' where id=%s", (ids[0],))
eq("vendida libera cupo", sub(prop)['usage']['active_properties'], 2)
chk("con un cupo libre publica otra", as_(prop, INS, ('P4', prop)), False)
chk("reactivar la vendida con el cupo lleno: rechazado", as_(prop, "update properties set status='available' where id=%s", (ids[0],)), True)
su("delete from properties where id=%s", (ids[1],))
chk("borrar libera cupo: ahora sí reactiva", as_(prop, "update properties set status='available' where id=%s", (ids[0],)), False)
# vencida no ocupa cupo
su("update properties set expires_at = now() - interval '1 day' where id=%s", (ids[2],))
eq("vencida no cuenta", sub(prop)['usage']['active_properties'], 2)
chk("renovar una vencida con cupo libre", as_(prop, "select renew_property(%s)", (ids[2],)), False)
eq("…vuelve a contar", sub(prop)['usage']['active_properties'], 3)

# ── Destacados: Propietario 1 por periodo, una plaza por propiedad
act = [p for p in props_of(prop)]
chk("propietario destaca 1", feat(prop, act[0]), False)
eq("featured_until en el futuro", one("select featured_until > now() from properties where id=%s", (act[0],)), True)
r = feat(prop, act[0]); chk("la misma propiedad no gasta otra plaza", r, True); eq("…porque ya está destacada", 'ya está destacada' in r[1], True)
r = feat(prop, act[1]); chk("2.º destacado: rechazado (tope 1)", r, True); eq("mensaje de límite de destacados", 'destacados' in r[1], True)
eq("uso de destacados: 1", sub(prop)['usage']['featured_used'], 1)
chk("no destaca la propiedad de otro", feat(nosub, act[1]), True)
chk("agente no escribe featured_until directo", as_(prop, "update properties set featured_until = now() + interval '90 days' where id=%s", (act[1],)), False)
eq("…y no cambió", one("select featured_until is null from properties where id=%s", (act[1],)), True)
# nuevo ciclo: se retrocede el inicio del periodo y la activación
cur.execute("reset role")
su("update subscriptions set current_period_start = now() - interval '31 days', current_period_end = now() + interval '5 days' where user_id=%s", (prop,))
eq("mismo ciclo (activación reciente): sigue contando 1", sub(prop)['usage']['featured_used'], 1)
su("update featured_activations set created_at = now() - interval '5 days' where user_id=%s", (prop,))
eq("ciclo nuevo: 0 usados (la activación quedó en el ciclo anterior)", sub(prop)['usage']['featured_used'], 0)
su("select set_config('uno.credit_rpc','1',false)"); su("update properties set featured_until = now() - interval '1 day' where id=%s", (act[0],)); su("select set_config('uno.credit_rpc','',false)")
chk("destacado vencido: puede volver a destacarse en el ciclo nuevo", feat(prop, act[0]), False)
su("update subscriptions set current_period_start = now(), current_period_end = now() + interval '30 days' where user_id=%s", (prop,))

# ── Agente: 15 y 3 destacados
grant(agt, 'agente')
for n in range(15): chk("agente publica %d" % (n + 1), as_(agt, INS, ('A%d' % n, agt)), False) if n in (0, 14) else as_(agt, INS, ('A%d' % n, agt))
eq("agente: 15 activas", sub(agt)['usage']['active_properties'], 15)
chk("agente: la 16.ª se rechaza", as_(agt, INS, ('A15', agt)), True)
ap = props_of(agt)
for n in range(3): chk("agente destaca %d" % (n + 1), feat(agt, ap[n]), False) if n in (0, 2) else feat(agt, ap[n])
chk("agente: el 4.º destacado se rechaza", feat(agt, ap[3]), True)
eq("agente: 3 destacados usados de 3", (sub(agt)['usage']['featured_used'], sub(agt)['plan']['max_featured_per_period']), (3, 3))

# ── Empresa: 50 y 3
grant(emp, 'empresa')
for n in range(50): as_(emp, INS, ('E%d' % n, emp))
eq("empresa: 50 activas", sub(emp)['usage']['active_properties'], 50)
chk("empresa: la 51.ª se rechaza", as_(emp, INS, ('E50', emp)), True)
ep = props_of(emp)
for n in range(3): feat(emp, ep[n])
chk("empresa: 4.º destacado rechazado", feat(emp, ep[3]), True)

# ── Concurrencia: 8 publicaciones a la vez con 1 cupo libre → exactamente 1
su("delete from properties where id in (select id from properties where owner_id=%s limit 1)", (prop,))
free = 3 - sub(prop)['usage']['active_properties']
res = [None] * 8
def worker(k):
    cn = psycopg2.connect(uri); cn.autocommit = True; cu = cn.cursor()
    cu.execute("select set_config('request.jwt.claim.sub',%s,false)", (str(prop),)); cu.execute("set role authenticated")
    try: cu.execute(INS, ('C%d' % k, prop)); res[k] = 'ok'
    except Exception as e: res[k] = str(e).splitlines()[0]
    cn.close()
ts = [threading.Thread(target=worker, args=(k,)) for k in range(8)]
[t.start() for t in ts]; [t.join() for t in ts]
eq("concurrencia: entran exactamente los cupos libres (%d) y nunca más de 3" % free, (res.count('ok'), sub(prop)['usage']['active_properties']), (free, 3))

# ── Vencimiento: sin periodo vigente no se publica y las propiedades dejan de verse
su("update subscriptions set current_period_end = now() - interval '1 hour' where user_id=%s", (prop,))
eq("estado 'expired'", sub(prop)['status'], 'expired')
chk("plan vencido: no publica", as_(prop, INS, ('V', prop)), True)
chk("plan vencido: no destaca", feat(prop, act[1]), True)
chk("plan vencido: no renueva propiedades", as_(prop, "select renew_property(%s)", (act[1],)), True)
# renovar el plan: vuelve a publicar
rid3 = as_(prop, "select request_subscription('propietario','qr','X')")[1][0][0]; as_(adm, "select admin_resolve_subscription_request(%s,true,null)", (rid3,))
eq("pago confirmado tras vencer: vuelve a 'active'", sub(prop)['status'], 'active')
eq("nuevo periodo desde hoy (~30 días)", 28 < one("select extract(epoch from (current_period_end-now()))/86400 from subscriptions where user_id=%s", (prop,)) <= 30, True)
# renovación anticipada: se suma al periodo vigente
end0 = one("select current_period_end from subscriptions where user_id=%s", (prop,))
as_(adm, "select admin_grant_subscription(%s,'propietario',30)", (prop,))
eq("renovación anticipada suma 30 días al periodo vigente", round(one("select extract(epoch from (current_period_end - %s))/86400 from subscriptions where user_id=%s", (end0, prop))), 30)

# ── Cambio de plan: Agente (con 15) → Propietario (límite 3): solo las 3 más recientes se extienden
as_(adm, "select admin_grant_subscription(%s,'propietario',30)", (agt,))
eq("cambio de plan registrado", one("select count(*) from subscription_events where user_id=%s and kind='plan_change'", (agt,)), 1)
eq("plan nuevo: Propietario", sub(agt)['plan']['code'], 'propietario')
eq("solo 3 propiedades extendidas al nuevo periodo", one("select count(*) from properties p join subscriptions s on s.user_id=p.owner_id where p.owner_id=%s and abs(extract(epoch from (p.expires_at-s.current_period_end)))<0.001", (agt,)), 3)
chk("con 15 activas y plan de 3: no publica más", as_(agt, INS, ('Z', agt)), True)

# ── Cancelar y reanudar
chk("cancelar", as_(prop, "select cancel_subscription()"), False)
eq("cancelando conserva el plan hasta el fin del periodo", (sub(prop)['status'], sub(prop)['cancel_at_period_end']), ('canceling', True))
chk("sigue publicando mientras dura el periodo", as_(prop, "select 1"), False)
chk("reanudar", as_(prop, "select resume_subscription()"), False); eq("reanudada", sub(prop)['status'], 'active')
chk("sin suscripción no puede cancelar", as_(nosub, "select cancel_subscription()"), True)

# ── Aislamiento de datos
eq("cada persona ve solo su suscripción", set(r[0] for r in as_(prop, "select user_id from subscriptions")[1]), {prop})
eq("cada persona ve solo sus solicitudes", set(r[0] for r in as_(prop2, "select user_id from subscription_requests")[1]), {prop2})
eq("admin ve todas las suscripciones", len(as_(adm, "select * from subscriptions")[1]) >= 4, True)
chk("nadie escribe solicitudes directo", as_(prop, "insert into subscription_requests(user_id,plan_code,price_bs,method) values (%s,'empresa',1,'qr')", (prop,)), True)
chk("nadie edita el historial", as_(prop, "update subscription_events set kind='x'"), True)
chk("anon no llama a las funciones", as_(None, "select my_subscription()"), True)

# ── Contratos de exclusividad: los cubre el plan (Agente/Empresa), no créditos
DATA = json.dumps({"operacion": "venta", "moneda": "USD", "precio": 450000, "precio_minimo": 430000, "comision_porcentaje": 3, "impuestos_incluidos": True,
 "propietario_nombre": "Juan Pérez", "propietario_ci": "4567890 LP", "propietario_estado_civil": "casado", "propietario_domicilio": "Calle 1", "propietario_telefono": "7001", "propietario_email": "j@e.com",
 "tiene_copropietario": False, "tiene_apoderado": False, "inmueble_tipo": "Departamento", "inmueble_direccion": "Av. 1", "inmueble_zona": "Calacoto", "inmueble_ciudad": "La Paz",
 "inmueble_departamento": "La Paz", "inmueble_sup_terreno": 120.5, "inmueble_sup_construida": 98, "inmueble_matricula": "2.01.0.99.0012345", "con_gravamenes": False,
 "fecha_inicio": "2026-10-02", "plazo_dias": 90, "renovacion_automatica": False, "dias_preaviso": 15, "dias_proteccion": 90, "penalidad_porcentaje": 50, "frecuencia_informe": 15,
 "horas_aviso_visita": 24, "dias_subsanacion": 10, "forma_pago": "transferencia", "autoriza_letrero": True, "gastos_extra_detalle": "", "ejemplares": 2, "ciudad_firma": "La Paz",
 "ciudad_jurisdiccion": "La Paz", "agente_nombre": "Ana", "agente_ci": "7654321", "agente_registro": "", "agente_telefono": "7112", "agente_email": "a@b.uno", "agencia_nombre": "BASTET",
 "agencia_domicilio": "La Paz", "doc_testimonio": True, "doc_folio": True, "doc_impuestos": False, "doc_plano": False, "doc_ci": True, "doc_poder": False})
CC = "select create_exclusivity_contract(%s::jsonb, %s, 'exclusividad-v2')"
chk("sin suscripción: no genera contrato", as_(nosub, CC, (DATA, 'key-nosub-0001')), True)
r = as_(prop, CC, (DATA, 'key-prop-00001')); chk("plan Propietario: no incluye el contrato de exclusividad", r, True); eq("…mensaje del plan", 'no incluye' in r[1], True)
grant(prop2, 'agente')
r = as_(prop2, CC, (DATA, 'key-agent-0001')); chk("plan Agente: genera el contrato", r, False)
eq("…sin cobrar créditos", (r[1][0][0]['charged'], one("select credits_charged from exclusivity_contracts where agent_id=%s", (prop2,)), one("select count(*) from credit_ledger where user_id=%s", (prop2,))), (False, 0, 0))
chk("misma llave: devuelve el mismo contrato", as_(prop2, CC, (DATA, 'key-agent-0001')), False)
eq("…sin duplicar", one("select count(*) from exclusivity_contracts where agent_id=%s", (prop2,)), 1)
chk("admin genera contrato sin plan", as_(adm, CC, (DATA, 'key-admin-0001')), False)
su("update subscriptions set current_period_end = now() - interval '1 day' where user_id=%s", (prop2,))
chk("plan Agente vencido: no genera contrato", as_(prop2, CC, (DATA, 'key-agent-0002')), True)

# ── Créditos: ya no se compran; el historial queda
chk("comprar créditos: retirado", as_(nosub, "select request_credit_pack('esencial','qr')"), True)
su("insert into credit_wallets(user_id,balance) values (%s,40)", (nosub,))
eq("el saldo antiguo se conserva", as_(nosub, "select balance from credit_wallets where user_id=%s", (nosub,))[1][0][0], 40)

# ── Renovación automática antigua: ya no cobra nada
eq("process_auto_renewals no hace nada", as_(nosub, "select process_auto_renewals()")[1][0][0], 0)

print("\n%s: %d fallo(s)" % ("OK" if fails == 0 else "FALLAS", fails))
sys.exit(1 if fails else 0)
