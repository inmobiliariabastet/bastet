"""Pruebas de seguridad de la anulación de contratos (solo admin, motivo obligatorio, irreversible, verificación pública).
Corre el esquema completo dos veces y requiere:  pip install pgserver psycopg2-binary  ->  python tests/contracts_admin_sql_test.py
Levanta un Postgres local desechable: NO toca Supabase ni producción."""
import pgserver, psycopg2, sys, json, tempfile, pathlib
ROOT = pathlib.Path(__file__).resolve().parent.parent
srv = pgserver.get_server(tempfile.mkdtemp(prefix='uno-pg-'), cleanup_mode='delete')
uri = srv.get_uri()
R_ = str(ROOT / "supabase") + "/"
sch = open(R_ + "schema.sql", encoding='utf-8').read()
core = sch[:sch.index("-- ── Tabla property_events")]
i = sch.index("-- UNO · Créditos para agentes")
tail = sch[sch.rindex("\n", 0, i - 5) + 1:]       # TODO lo que va después del núcleo: créditos, leads, cobranzas, contratos, Bs, anulación
stub = """
create role anon nologin; create role authenticated nologin;
create schema auth;
create schema storage; create table storage.buckets(id text primary key, name text, public boolean, file_size_limit bigint, allowed_mime_types text[]); create table storage.objects(id uuid default gen_random_uuid() primary key, bucket_id text, name text); alter table storage.objects enable row level security; grant usage on schema storage to anon, authenticated; grant all on storage.objects to anon, authenticated;
create table auth.users(id uuid primary key default gen_random_uuid(), email text, invited_at timestamptz);
create function auth.uid() returns uuid language sql stable as $$ select nullif(current_setting('request.jwt.claim.sub', true),'')::uuid $$;
grant usage on schema auth to anon, authenticated; grant usage on schema public to anon, authenticated;
alter default privileges in schema public grant all on tables to anon, authenticated;
alter default privileges in schema public grant execute on functions to anon, authenticated, public;
"""
c = psycopg2.connect(uri); c.autocommit = True; cur = c.cursor()
cur.execute(stub); cur.execute(core)
for n in range(2): cur.execute(tail)        # el esquema completo corre dos veces sin error (incluye drop/create de la función de verificación)
print("esquema completo corrido x2")
cur.execute("insert into auth.users(email,invited_at) values ('admin@x','2026-01-01'),('a1@x','2026-01-01'),('a2@x','2026-01-01'),('admin2@x','2026-01-01') returning id")
adm, a1, a2, adm2 = [r[0] for r in cur.fetchall()]
cur.execute("alter table public.profiles disable trigger protect_profile_privileged")
cur.execute("update public.profiles set role='admin' where id in (%s,%s)", (adm, adm2)); cur.execute("update public.profiles set display_name='Ana Agente' where id=%s", (a1,))
cur.execute("insert into credit_wallets(user_id,balance) values (%s,50),(%s,50)", (a1, a2))
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
    cur.execute("reset role"); cur.execute(sql, a); return cur.fetchone()[0]

D = {"operacion": "venta", "moneda": "USD", "precio": 450000, "comision_porcentaje": 3,
 "propietario_nombre": "Juan Pérez", "propietario_ci": "4567890", "propietario_estado_civil": "casado(a)", "propietario_domicilio": "Calle 1", "propietario_telefono": "70012345", "propietario_email": "j@x.com",
 "inmueble_tipo": "Casa", "inmueble_direccion": "Av. X 1", "inmueble_zona": "Z", "inmueble_ciudad": "La Paz", "inmueble_departamento": "La Paz", "inmueble_sup_terreno": 100, "inmueble_matricula": "2.01",
 "fecha_inicio": "2026-10-02", "plazo_dias": 90, "forma_pago": "transferencia", "ciudad_firma": "La Paz", "ciudad_jurisdiccion": "La Paz",
 "agente_nombre": "Ana", "agente_ci": "7654321", "agente_telefono": "7112", "agente_email": "a@b.co", "agencia_nombre": "BASTET", "agencia_domicilio": "Calle"}
r1 = as_(a1, "select create_exclusivity_contract(%s::jsonb,'key-admin-0001')", (json.dumps(D),))[1][0][0]
r2 = as_(a2, "select create_exclusivity_contract(%s::jsonb,'key-admin-0002')", (json.dumps({**D, "propietario_nombre": "Otro"}),))[1][0][0]
cid1, cid2 = r1['id'], r2['id']; code1 = r1['verification_code']
bal_before = one("select balance from credit_wallets where user_id=%s", (a1,))

# ── verificación pública antes de anular
r = as_(None, "select * from verify_exclusivity_contract(%s)", (code1,)); chk("anon verifica", r, False)
eq("vigente: voided = false", (r[1][0][4], r[1][0][5]), (False, None))

# ── quién puede anular
chk("agente no puede anular (ni el suyo)", as_(a1, "select admin_void_exclusivity_contract(%s,'quiero anularlo ya')", (cid1,)), True)
chk("anon no puede anular", as_(None, "select admin_void_exclusivity_contract(%s,'motivo valido')", (cid1,)), True)
eq("el contrato sigue vigente tras intentos", one("select voided_at is null from exclusivity_contracts where id=%s", (cid1,)), True)
chk("agente no escribe voided_at directo", as_(a1, "update exclusivity_contracts set voided_at=now() where id=%s", (cid1,)), True)
chk("agente no escribe void_reason directo", as_(a1, "update exclusivity_contracts set void_reason='x' where id=%s", (cid1,)), True)
chk("motivo vacío", as_(adm, "select admin_void_exclusivity_contract(%s,'')", (cid1,)), True)
chk("motivo muy corto", as_(adm, "select admin_void_exclusivity_contract(%s,'no')", (cid1,)), True)
chk("motivo muy largo", as_(adm, "select admin_void_exclusivity_contract(%s,%s)", (cid1, 'x' * 301)), True)
chk("contrato inexistente", as_(adm, "select admin_void_exclusivity_contract('00000000-0000-0000-0000-000000000000','motivo valido')"), True)
eq("nada se anuló por errores", one("select count(*) from exclusivity_contracts where voided_at is not null"), 0)

# ── anular
r = as_(adm, "select admin_void_exclusivity_contract(%s,'  Datos del propietario incorrectos  ')", (cid1,)); chk("admin anula", r, False)
cur.execute("reset role"); cur.execute("select voided_at is not null, voided_by=%s, void_reason from exclusivity_contracts where id=%s", (adm, cid1)); eq("queda registrado: cuándo, quién y por qué", cur.fetchone(), (True, True, 'Datos del propietario incorrectos'))
chk("no se puede anular dos veces", as_(adm2, "select admin_void_exclusivity_contract(%s,'otro motivo')", (cid1,)), True)
eq("el segundo intento no cambia al responsable", one("select voided_by=%s from exclusivity_contracts where id=%s", (adm, cid1)), True)
eq("anular no devuelve créditos", one("select balance from credit_wallets where user_id=%s", (a1,)), bal_before)
eq("anular no borra el movimiento", one("select count(*) from credit_ledger where contract_id=%s", (cid1,)), 1)
eq("el otro contrato sigue vigente", one("select voided_at is null from exclusivity_contracts where id=%s", (cid2,)), True)

# ── verificación pública después de anular
r = as_(None, "select * from verify_exclusivity_contract(%s)", (code1,))
eq("anon ve: anulado = true con fecha", (r[1][0][4], r[1][0][5] is not None), (True, True))
eq("anon no ve motivo ni responsable", len(r[1][0]), 6)
r = as_(None, "select * from verify_exclusivity_contract(%s)", (r2['verification_code'],)); eq("el otro sigue verificándose vigente", r[1][0][4], False)
eq("código falso sigue sin devolver nada", as_(None, "select count(*) from verify_exclusivity_contract('ZZZZZZZZ')")[1][0][0], 0)

# ── lectura
eq("el agente sigue viendo su contrato anulado", as_(a1, "select voided_at is not null from exclusivity_contracts where id=%s", (cid1,))[1][0][0], True)
eq("el agente ve el motivo de su contrato", as_(a1, "select void_reason from exclusivity_contracts where id=%s", (cid1,))[1][0][0], 'Datos del propietario incorrectos')
eq("a2 no ve el contrato de a1", as_(a2, "select count(*) from exclusivity_contracts where id=%s", (cid1,))[1][0][0], 0)
eq("el admin ve todos", as_(adm, "select count(*) from exclusivity_contracts")[1][0][0], 2)
eq("un admin desactivado no puede anular", (cur.execute("reset role"), cur.execute("update profiles set is_active=false where id=%s", (adm2,)), as_(adm2, "select admin_void_exclusivity_contract(%s,'motivo valido')", (cid2,))[0])[2], 'ERR')
cur.execute("reset role"); cur.execute("update profiles set is_active=true where id=%s", (adm2,))
# la idempotencia de la generación no se ve afectada por anular
r = as_(a1, "select create_exclusivity_contract(%s::jsonb,'key-admin-0001')", (json.dumps(D),)); eq("misma llave devuelve el mismo contrato, sin cobrar", (r[1][0][0]['id'], r[1][0][0]['charged']), (cid1, False))
print("\nFALLAS:", fails); sys.exit(1 if fails else 0)
