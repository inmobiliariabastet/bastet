"""Pruebas de seguridad del SQL de contratos (cobro atómico, idempotencia, concurrencia, reversión, aislamiento).
Requiere:  pip install pgserver psycopg2-binary   y se ejecuta con:  python tests/contracts_sql_test.py
Levanta un Postgres local desechable: NO toca Supabase ni producción."""
import pgserver, psycopg2, sys, threading, json, datetime, tempfile, pathlib
ROOT = pathlib.Path(__file__).resolve().parent.parent
srv = pgserver.get_server(tempfile.mkdtemp(prefix='uno-pg-'), cleanup_mode='delete')
uri = srv.get_uri()
R_ = str(ROOT / "supabase") + "/"
sch = open(R_ + "schema.sql", encoding='utf-8').read()
core = sch[:sch.index("-- ── Tabla property_events")]
i = sch.index("-- UNO · Créditos para agentes")
tail = sch[sch.rindex("\n", 0, i - 5) + 1:]
contracts = open(R_ + "contracts.sql", encoding='utf-8').read()
stub = """
create role anon nologin; create role authenticated nologin;
create schema auth;
create table auth.users(id uuid primary key default gen_random_uuid(), email text, invited_at timestamptz);
create function auth.uid() returns uuid language sql stable as $$ select nullif(current_setting('request.jwt.claim.sub', true),'')::uuid $$;
grant usage on schema auth to anon, authenticated; grant usage on schema public to anon, authenticated;
alter default privileges in schema public grant all on tables to anon, authenticated;
alter default privileges in schema public grant execute on functions to anon, authenticated, public;
"""
c = psycopg2.connect(uri); c.autocommit = True; cur = c.cursor()
cur.execute(stub); cur.execute(core); cur.execute(tail)
for _ in range(2): cur.execute(contracts)
print("SQL ok x2")
cur.execute("insert into auth.users(email,invited_at) values ('admin@x','2026-01-01'),('a1@x','2026-01-01'),('a2@x','2026-01-01') returning id")
adm, a1, a2 = [r[0] for r in cur.fetchall()]
cur.execute("alter table public.profiles disable trigger protect_profile_privileged")
cur.execute("update public.profiles set role='admin' where id=%s", (adm,))
cur.execute("update public.profiles set display_name='Ana Agente' where id=%s", (a1,))
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

# ── saldo insuficiente
r = as_(a1, create, (D(), 'key-0000-aaaa'))
chk("sin saldo: error", r, True)
eq("sin saldo: mensaje", 'Saldo insuficiente' in r[1], True)
eq("sin saldo: no hay contrato", count("select count(*) from exclusivity_contracts"), 0)
eq("sin saldo: no hay movimiento", count("select count(*) from credit_ledger"), 0)
eq("sin saldo: contador sin usar", count("select count(*) from exclusivity_contract_counters"), 0)
cur.execute("reset role"); cur.execute("insert into credit_wallets(user_id,balance) values (%s,12),(%s,3)", (a1, a2))
chk("saldo 3 (<5): rechaza", as_(a2, create, (D(), 'key-0000-bbbb')), True)
eq("saldo 3 intacto", bal(a2), 3)

# ── cobro correcto
r = as_(a1, create, (D(), 'key-0001-aaaa')); chk("cobra y crea", r, False)
res = r[1][0][0]
eq("cobró exactamente 5", bal(a1), 7)
eq("charged = true y balance devuelto", (res['charged'], res['balance']), (True, 7))
yr = datetime.datetime.now().year
eq("número correlativo", res['contract_number'], 'BST-CE-%d-0001' % yr)
eq("código de verificación 8 caracteres", len(res['verification_code']), 8)
cur.execute("reset role"); cur.execute("select kind, amount, description, contract_id::text from credit_ledger where user_id=%s", (a1,)); row = cur.fetchone()
eq("movimiento en el historial", (row[0], row[1], row[2].startswith('Contrato de exclusividad BST-CE-')), ('spend', -5, True))
eq("movimiento referencia el contrato", row[3], res['id'])
r2 = as_(a1, create, (D(propietario_nombre='Otro Propietario'), 'key-0002-aaaa')); res2 = r2[1][0][0]
eq("segundo contrato correlativo 0002", res2['contract_number'], 'BST-CE-%d-0002' % yr); eq("saldo 2", bal(a1), 2)

# ── idempotencia
chk("saldo insuficiente ahora (2<5)", as_(a1, create, (D(), 'key-0003-aaaa')), True)
cur.execute("reset role"); cur.execute("update credit_wallets set balance = 20 where user_id=%s", (a1,))
r3 = as_(a1, create, (D(), 'key-0001-aaaa')); chk("misma llave: no falla", r3, False); res3 = r3[1][0][0]
eq("misma llave: mismo contrato", res3['id'], res['id']); eq("misma llave: charged=false", res3['charged'], False)
eq("misma llave: sin cobro extra", bal(a1), 20)
eq("misma llave: un solo movimiento por contrato", count("select count(*) from credit_ledger where contract_id=%s", (res['id'],)), 1)
# llave de otro agente no choca
cur.execute("reset role"); cur.execute("update credit_wallets set balance = 20 where user_id=%s", (a2,))
chk("otro agente con la misma llave crea el suyo", as_(a2, create, (D(), 'key-0001-aaaa')), False)

# ── concurrencia: 6 peticiones simultáneas con la misma llave -> 1 contrato, 1 cobro
def worker(out, idx):
    cn = psycopg2.connect(uri); cn.autocommit = True; cu = cn.cursor()
    cu.execute("select set_config('request.jwt.claim.sub',%s,false)", (str(a1),)); cu.execute("set role authenticated")
    try:
        cu.execute(create, (D(propietario_nombre='Concurrente'), 'key-conc-0001')); out[idx] = cu.fetchone()[0]
    except Exception as e: out[idx] = str(e).splitlines()[0]
    cn.close()
before = bal(a1); out = [None] * 6
ts = [threading.Thread(target=worker, args=(out, k)) for k in range(6)]
[t.start() for t in ts]; [t.join() for t in ts]
ok = [o for o in out if isinstance(o, dict)]
eq("concurrencia: todas devuelven el mismo contrato", len({o['id'] for o in ok}), 1)
eq("concurrencia: ninguna falló", len(ok), 6)
eq("concurrencia: se cobró una sola vez", before - bal(a1), 5)
eq("concurrencia: solo una marcada charged", sum(1 for o in ok if o['charged']), 1)

# ── validación del servidor (no cobra)
b0 = bal(a1); n0 = count("select count(*) from exclusivity_contracts")
for name, kw in [("correo inválido", dict(propietario_email='sin-arroba')), ("C.I. inválida", dict(propietario_ci='abc')),
                 ("precio 0", dict(precio=0)), ("precio texto", dict(precio='mucho')), ("plazo 5", dict(plazo_dias=5)),
                 ("moneda rara", dict(moneda='EUR')), ("operación rara", dict(operacion='permuta')), ("fecha mala", dict(fecha_inicio='2026-13-45')),
                 ("% > 100", dict(comision_porcentaje=150)), ("falta nombre", dict(propietario_nombre='')),
                 ("copropietario sin datos", dict(tiene_copropietario=True)), ("apoderado sin datos", dict(tiene_apoderado=True)),
                 ("gravamen sin detalle", dict(con_gravamenes=True))]:
    chk("validación: " + name, as_(a1, create, (D(**kw), 'key-val-' + name[:6].replace(' ', '') + '0')), True)
chk("alquiler sin meses", as_(a1, create, (D(operacion='alquiler', comision_porcentaje=None), 'key-val-alq0')), True)
chk("alquiler con meses ok", as_(a1, create, (D(operacion='alquiler', comision_meses=1), 'key-val-alq1')), False)
eq("validación: el único cobro fue el del alquiler", b0 - bal(a1), 5)
chk("llave corta", as_(a1, create, (D(), 'abc')), True)
chk("plantilla inexistente", as_(a1, "select create_exclusivity_contract(%s::jsonb,'key-plantilla1','otra-v9')", (D(),)), True)
chk("datos no objeto", as_(a1, "select create_exclusivity_contract('[1,2]'::jsonb,'key-array-0001')"), True)
# el cliente no puede influir en el costo ni en el número
r = as_(a1, create, (D(costo=1, credits_charged=0, contract_number='BST-CE-1999-9999'), 'key-fraude-001')); res = r[1][0][0]
cur.execute("reset role"); cur.execute("select credits_charged, contract_number from exclusivity_contracts where id=%s", (res['id'],))
eq("cliente no fija costo ni número", cur.fetchone(), (5, res['contract_number']))

# ── rollback total si algo falla DESPUÉS del descuento (p. ej. al registrar el movimiento)
cur.execute("reset role")
cur.execute("create or replace function public._boom() returns trigger language plpgsql as $$ begin raise exception 'fallo simulado'; end $$")
cur.execute("create trigger _boom before insert on credit_ledger for each row execute function public._boom()")
b0 = bal(a1); n0 = count("select count(*) from exclusivity_contracts"); s0 = count("select coalesce(max(last_number),0) from exclusivity_contract_counters")
chk("fallo tras descontar: error", as_(a1, create, (D(), 'key-boom-0001')), True)
eq("fallo: saldo intacto", bal(a1), b0)
eq("fallo: sin contrato nuevo", count("select count(*) from exclusivity_contracts"), n0)
eq("fallo: el correlativo no se gasta", count("select coalesce(max(last_number),0) from exclusivity_contract_counters"), s0)
cur.execute("reset role"); cur.execute("drop trigger _boom on credit_ledger")
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
chk("a1 no cambia el precio", as_(a1, "update credit_tool_prices set cost=1"), False)
eq("…y el precio sigue en 5", count("select cost from credit_tool_prices where code='contrato_exclusividad'"), 5)
chk("a1 lee el precio", as_(a1, "select cost from credit_tool_prices where code='contrato_exclusividad'"), False)
chk("anon no lee precios", as_(None, "select * from credit_tool_prices"), True)
chk("admin cambia el precio", as_(adm, "update credit_tool_prices set cost=7 where code='contrato_exclusividad'"), False)
cur.execute('reset role'); cur.execute('update credit_wallets set balance = 20 where user_id=%s', (a1,))
b0 = bal(a1); as_(a1, create, (D(), 'key-precio-007'))
eq("el cobro sigue al precio del servidor (7)", b0 - bal(a1), 7)
as_(adm, "update credit_tool_prices set cost=5 where code='contrato_exclusividad'")
# agente desactivado
cur.execute("reset role"); cur.execute("update profiles set is_active=false where id=%s", (a2,))
chk("agente desactivado no genera", as_(a2, create, (D(), 'key-inact-0001')), True)
eq("agente desactivado no ve contratos", as_(a2, "select count(*) from exclusivity_contracts")[1][0][0], 0)
cur.execute("reset role"); cur.execute("update profiles set is_active=true where id=%s", (a2,))

# ── verificación pública
vc = count("select verification_code from exclusivity_contracts where id=%s", (cid1,))
r = as_(None, "select * from verify_exclusivity_contract(%s)", (vc.lower(),)); chk("anon verifica (minúsculas ok)", r, False)
eq("verificación: número, fecha, agente, plantilla", (r[1][0][0].startswith('BST-CE-'), r[1][0][2], r[1][0][3]), (True, 'Ana Agente', 'exclusividad-v1'))
eq("verificación: no expone datos del propietario", len(r[1][0]), 4)
eq("código falso no devuelve nada", as_(None, "select count(*) from verify_exclusivity_contract('ZZZZZZZZ')")[1][0][0], 0)
eq("código vacío no devuelve nada", as_(None, "select count(*) from verify_exclusivity_contract('')")[1][0][0], 0)

# ── datos legales del agente: privados
chk("a1 guarda sus datos legales", as_(a1, "insert into agent_legal_profiles(user_id,ci,phone,registration) values (%s,'7654321','71122334','REG-1')", (a1,)), False)
chk("a1 no escribe datos de a2", as_(a1, "insert into agent_legal_profiles(user_id,ci) values (%s,'1')", (a2,)), True)
eq("a2 no ve datos legales de a1", as_(a2, "select count(*) from agent_legal_profiles")[1][0][0], 0)
chk("anon no ve datos legales", as_(None, "select * from agent_legal_profiles"), True)
chk("a1 actualiza sus datos", as_(a1, "update agent_legal_profiles set phone='71000000' where user_id=%s", (a1,)), False)

# el saldo nunca queda negativo y el ledger cuadra
eq("ledger de a1: suma de gastos = créditos cobrados", count("select coalesce(sum(-amount),0) from credit_ledger where user_id=%s and kind='spend' and contract_id is not null", (a1,)), count("select coalesce(sum(credits_charged),0) from exclusivity_contracts where agent_id=%s", (a1,)))
print("\nFALLAS:", fails); sys.exit(1 if fails else 0)
