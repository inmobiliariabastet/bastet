"""Pruebas de seguridad del SQL de contratos (cubiertos por el plan, idempotencia, concurrencia, reversión, aislamiento).
Requiere:  pip install pgserver psycopg2-binary   y se ejecuta con:  python tests/contracts_sql_test.py
Levanta un Postgres local desechable: NO toca Supabase ni producción."""
import pgserver, psycopg2, sys, threading, json, datetime, tempfile, pathlib
ROOT = pathlib.Path(__file__).resolve().parent.parent
srv = pgserver.get_server(tempfile.mkdtemp(prefix='uno-pg-'), cleanup_mode='delete')
uri = srv.get_uri()
R_ = str(ROOT / "supabase") + "/"
sch = open(R_ + "schema.sql", encoding='utf-8').read()
core = sch   # esquema COMPLETO (con políticas de seguridad y permisos), igual que la base real
i = sch.index("-- UNO · Créditos para agentes")
tail = sch[sch.rindex("\n", 0, i - 5) + 1:]
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
cur.execute(stub); cur.execute(core)
for _ in range(2): cur.execute(tail)
print("SQL ok x2")
cur.execute("insert into auth.users(email,invited_at) values ('admin@x','2026-01-01'),('a1@x','2026-01-01'),('a2@x','2026-01-01') returning id")
adm, a1, a2 = [r[0] for r in cur.fetchall()]
cur.execute("alter table public.profiles disable trigger protect_profile_privileged")
cur.execute("update public.profiles set role='admin' where id=%s", (adm,))
cur.execute("update public.profiles set display_name='Ana Agente' where id=%s", (a1,))
cur.execute("update public.profiles set interest='agente', registered_at=now() where id=%s", (a1,))
cur.execute("update public.profiles set interest='propietario', registered_at=now() where id=%s", (a2,))   # a2 es propietario: no genera contratos
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

def bal(u):
    cur.execute("reset role"); cur.execute("select coalesce((select balance from credit_wallets where user_id=%s),0)", (u,)); return cur.fetchone()[0]
def count(sql, a=None):
    cur.execute("reset role"); cur.execute(sql, a); return cur.fetchone()[0]

DATA = {
 "operacion": "venta", "moneda": "USD", "precio": 450000, "precio_minimo": 430000,
 "comision_porcentaje": 3, "impuestos_incluidos": True,
 "propietario_nombre": "Juan Pérez Mamani", "propietario_ci": "4567890 LP", "propietario_estado_civil": "casado",
 "propietario_domicilio": "Calle 21 de Calacoto Nº 100", "propietario_telefono": "70012345", "propietario_email": "juan@example.com",
 "tiene_copropietario": False, "tiene_apoderado": False,
 "inmueble_tipo": "Departamento", "inmueble_direccion": "Av. Ballivián Nº 1234", "inmueble_zona": "Calacoto", "inmueble_ciudad": "La Paz",
 "inmueble_departamento": "La Paz", "inmueble_sup_terreno": 120.5, "inmueble_sup_construida": 98, "inmueble_matricula": "2.01.0.99.0012345",
 "con_gravamenes": False,
 "fecha_inicio": "2026-10-02", "plazo_dias": 90, "renovacion_automatica": False, "dias_preaviso": 15,
 "dias_proteccion": 90, "penalidad_porcentaje": 50, "frecuencia_informe": 15, "horas_aviso_visita": 24, "dias_subsanacion": 10,
 "forma_pago": "transferencia bancaria o efectivo", "autoriza_letrero": True, "ejemplares": 2, "ciudad_firma": "La Paz", "ciudad_jurisdiccion": "La Paz",
 "agente_nombre": "Ana Agente", "agente_ci": "7654321", "agente_telefono": "71122334", "agente_email": "ana@bastet.uno",
 "agencia_nombre": "BASTET Propiedades Inmobiliarias", "agencia_domicilio": "Calle Yanacocha, Edif. Cristal Of. 706, La Paz"
}
D = lambda **kw: json.dumps({**DATA, **kw})
create = "select create_exclusivity_contract(%s::jsonb, %s)"

# ── cuenta de propietario (sin herramientas de agente)
r = as_(a2, create, (D(), 'key-0000-aaaa'))
chk("cuenta de propietario: error", r, True)
eq("cuenta de propietario: mensaje", 'agente o de empresa' in r[1], True)
eq("cuenta de propietario: no hay contrato", count("select count(*) from exclusivity_contracts"), 0)
eq("cuenta de propietario: contador sin usar", count("select count(*) from exclusivity_contract_counters"), 0)

# ── genera con el plan (sin cobrar créditos)
r = as_(a1, create, (D(), 'key-0001-aaaa')); chk("crea con el plan Agente", r, False)
res = r[1][0][0]
eq("no cobra: charged = false y sin movimientos", (res['charged'], count("select count(*) from credit_ledger")), (False, 0))
yr = datetime.datetime.now().year
eq("número correlativo", res['contract_number'], 'BST-CE-%d-0001' % yr)
eq("código de verificación 8 caracteres", len(res['verification_code']), 8)
eq("credits_charged = 0", count("select credits_charged from exclusivity_contracts where id=%s", (res['id'],)), 0)
r2 = as_(a1, create, (D(propietario_nombre='Otro Propietario'), 'key-0002-aaaa')); res2 = r2[1][0][0]
eq("segundo contrato correlativo 0002", res2['contract_number'], 'BST-CE-%d-0002' % yr)
cur.execute("reset role"); cur.execute("select set_config('request.jwt.claim.sub','',false)")
cur.execute("update public.profiles set interest='agente', registered_at=now() where id=%s", (a2,))

# ── idempotencia
r3 = as_(a1, create, (D(), 'key-0001-aaaa')); chk("misma llave: no falla", r3, False); res3 = r3[1][0][0]
eq("misma llave: mismo contrato", res3['id'], res['id']); eq("misma llave: charged=false", res3['charged'], False)
eq("misma llave: sin contrato duplicado", count("select count(*) from exclusivity_contracts where agent_id=%s", (a1,)), 2)
# llave de otro agente no choca
chk("otro agente con la misma llave crea el suyo", as_(a2, create, (D(), 'key-0001-aaaa')), False)

# ── concurrencia: 6 peticiones simultáneas con la misma llave -> 1 contrato, 1 cobro
def worker(out, idx):
    cn = psycopg2.connect(uri); cn.autocommit = True; cu = cn.cursor()
    cu.execute("select set_config('request.jwt.claim.sub',%s,false)", (str(a1),)); cu.execute("set role authenticated")
    try:
        cu.execute(create, (D(propietario_nombre='Concurrente'), 'key-conc-0001')); out[idx] = cu.fetchone()[0]
    except Exception as e: out[idx] = str(e).splitlines()[0]
    cn.close()
out = [None] * 6
ts = [threading.Thread(target=worker, args=(out, k)) for k in range(6)]
[t.start() for t in ts]; [t.join() for t in ts]
ok = [o for o in out if isinstance(o, dict)]
eq("concurrencia: todas devuelven el mismo contrato", len({o['id'] for o in ok}), 1)
eq("concurrencia: ninguna falló", len(ok), 6)
eq("concurrencia: se creó un solo contrato con esa llave", count("select count(*) from exclusivity_contracts where idempotency_key='key-conc-0001'"), 1)

# ── validación del servidor (no cobra)
n0 = count("select count(*) from exclusivity_contracts")
for name, kw in [("correo inválido", dict(propietario_email='sin-arroba')), ("C.I. inválida", dict(propietario_ci='abc')),
                 ("precio 0", dict(precio=0)), ("precio texto", dict(precio='mucho')), ("plazo 5", dict(plazo_dias=5)),
                 ("moneda rara", dict(moneda='EUR')), ("operación rara", dict(operacion='permuta')), ("fecha mala", dict(fecha_inicio='2026-13-45')),
                 ("% > 100", dict(comision_porcentaje=150)), ("falta nombre", dict(propietario_nombre='')),
                 ("copropietario sin datos", dict(tiene_copropietario=True)), ("apoderado sin datos", dict(tiene_apoderado=True)),
                 ("gravamen sin detalle", dict(con_gravamenes=True))]:
    chk("validación: " + name, as_(a1, create, (D(**kw), 'key-val-' + name[:6].replace(' ', '') + '0')), True)
chk("alquiler sin meses", as_(a1, create, (D(operacion='alquiler', comision_porcentaje=None), 'key-val-alq0')), True)
chk("alquiler con meses ok", as_(a1, create, (D(operacion='alquiler', comision_meses=1), 'key-val-alq1')), False)
eq("validación: solo el alquiler válido creó un contrato", count("select count(*) from exclusivity_contracts") - n0, 1)
chk("llave corta", as_(a1, create, (D(), 'abc')), True)
chk("plantilla inexistente", as_(a1, "select create_exclusivity_contract(%s::jsonb,'key-plantilla1','otra-v9')", (D(),)), True)
chk("datos no objeto", as_(a1, "select create_exclusivity_contract('[1,2]'::jsonb,'key-array-0001')"), True)
# el cliente no puede influir en el costo ni en el número
r = as_(a1, create, (D(costo=1, credits_charged=0, contract_number='BST-CE-1999-9999'), 'key-fraude-001')); res = r[1][0][0]
cur.execute("reset role"); cur.execute("select credits_charged, contract_number from exclusivity_contracts where id=%s", (res['id'],))
eq("cliente no fija costo ni número", cur.fetchone(), (0, res['contract_number']))

# ── rollback total si algo falla al guardar (el correlativo no se gasta)
cur.execute("reset role")
cur.execute("create or replace function public._boom() returns trigger language plpgsql as $$ begin raise exception 'fallo simulado'; end $$")
cur.execute("create trigger _boom before insert on exclusivity_contracts for each row execute function public._boom()")
n0 = count("select count(*) from exclusivity_contracts"); s0 = count("select coalesce(max(last_number),0) from exclusivity_contract_counters")
chk("fallo al guardar: error", as_(a1, create, (D(), 'key-boom-0001')), True)
eq("fallo: sin contrato nuevo", count("select count(*) from exclusivity_contracts"), n0)
eq("fallo: el correlativo no se gasta", count("select coalesce(max(last_number),0) from exclusivity_contract_counters"), s0)
cur.execute("reset role"); cur.execute("drop trigger _boom on exclusivity_contracts")
chk("tras corregir, la misma llave funciona", as_(a1, create, (D(), 'key-boom-0001')), False)

# ── aislamiento y permisos
cur.execute("reset role"); cur.execute("select id::text from exclusivity_contracts where agent_id=%s limit 1", (a1,)); cid1 = cur.fetchone()[0]
eq("a2 no ve contratos de a1", count("select 1"), 1)
eq("a2 ve solo los suyos", all(r[0] == str(a2) for r in as_(a2, "select agent_id from exclusivity_contracts")[1]), True)
eq("a2 no puede leer el de a1", as_(a2, "select count(*) from exclusivity_contracts where id=%s", (cid1,))[1][0][0], 0)
eq("a1 ve los suyos", as_(a1, "select count(*) from exclusivity_contracts")[1][0][0] > 0, True)
eq("admin ve todos", as_(adm, "select count(*) from exclusivity_contracts")[1][0][0], count("select count(*) from exclusivity_contracts"))
chk("anon no lee contratos", as_(None, "select * from exclusivity_contracts"), True)
chk("anon no crea", as_(None, create, (D(), 'key-anon-0001')), True)
chk("a1 no inserta directo", as_(a1, "insert into exclusivity_contracts(agent_id,contract_number,verification_code,template_version,data,credits_charged,idempotency_key) values (%s,'X','Y','v','{}',0,'k')", (a1,)), True)
chk("a1 no edita contrato", as_(a1, "update exclusivity_contracts set credits_charged=0"), True)
chk("a1 no borra contrato", as_(a1, "delete from exclusivity_contracts"), True)
chk("a1 no toca el contador", as_(a1, "update exclusivity_contract_counters set last_number=0"), True)
chk("a1 no lee el contador", as_(a1, "select * from exclusivity_contract_counters"), True)
# agente desactivado
cur.execute("reset role"); cur.execute("update profiles set is_active=false where id=%s", (a2,))
chk("agente desactivado no genera", as_(a2, create, (D(), 'key-inact-0001')), True)
eq("agente desactivado no ve contratos", as_(a2, "select count(*) from exclusivity_contracts")[1][0][0], 0)
cur.execute("reset role"); cur.execute("update profiles set is_active=true where id=%s", (a2,))

# ── verificación pública
vc = count("select verification_code from exclusivity_contracts where id=%s", (cid1,))
r = as_(None, "select * from verify_exclusivity_contract(%s)", (vc.lower(),)); chk("anon verifica (minúsculas ok)", r, False)
eq("verificación: número, fecha, agente, plantilla", (r[1][0][0].startswith('BST-CE-'), r[1][0][2], r[1][0][3]), (True, 'Ana Agente', 'exclusividad-v1'))
eq("verificación: no expone datos del propietario (solo 6 campos públicos)", len(r[1][0]), 6)
eq("código falso no devuelve nada", as_(None, "select count(*) from verify_exclusivity_contract('ZZZZZZZZ')")[1][0][0], 0)
eq("código vacío no devuelve nada", as_(None, "select count(*) from verify_exclusivity_contract('')")[1][0][0], 0)

# ── datos legales del agente: privados
chk("a1 guarda sus datos legales", as_(a1, "insert into agent_legal_profiles(user_id,ci,phone,registration) values (%s,'7654321','71122334','REG-1')", (a1,)), False)
chk("a1 no escribe datos de a2", as_(a1, "insert into agent_legal_profiles(user_id,ci) values (%s,'1')", (a2,)), True)
eq("a2 no ve datos legales de a1", as_(a2, "select count(*) from agent_legal_profiles")[1][0][0], 0)
chk("anon no ve datos legales", as_(None, "select * from agent_legal_profiles"), True)
chk("a1 actualiza sus datos", as_(a1, "update agent_legal_profiles set phone='71000000' where user_id=%s", (a1,)), False)

print("\nFALLAS:", fails); sys.exit(1 if fails else 0)
