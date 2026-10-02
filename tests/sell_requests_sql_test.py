"""Pruebas de las solicitudes "Vender mi inmueble" (alta pública validada, límites, privacidad, solo admin lee, documentos privados).
Requiere:  pip install pgserver psycopg2-binary  ->  python tests/sell_requests_sql_test.py
Levanta un Postgres local desechable: NO toca Supabase ni producción."""
import pgserver, psycopg2, sys, json, uuid, tempfile, pathlib
ROOT = pathlib.Path(__file__).resolve().parent.parent
srv = pgserver.get_server(tempfile.mkdtemp(prefix='uno-pg-'), cleanup_mode='delete')
uri = srv.get_uri()
R_ = str(ROOT / "supabase") + "/"
sch = open(R_ + "schema.sql", encoding='utf-8').read()
core = sch[:sch.index("-- ── Tabla property_events")]
stub = """
create role anon nologin; create role authenticated nologin;
create schema auth; create schema storage;
create table auth.users(id uuid primary key default gen_random_uuid(), email text, invited_at timestamptz);
create function auth.uid() returns uuid language sql stable as $$ select nullif(current_setting('request.jwt.claim.sub', true),'')::uuid $$;
create table storage.buckets(id text primary key, name text, public boolean, file_size_limit bigint, allowed_mime_types text[]);
create table storage.objects(id uuid default gen_random_uuid() primary key, bucket_id text, name text);
alter table storage.objects enable row level security;
grant usage on schema auth, storage to anon, authenticated; grant usage on schema public to anon, authenticated;
grant all on storage.objects to anon, authenticated;
alter default privileges in schema public grant all on tables to anon, authenticated;
alter default privileges in schema public grant execute on functions to anon, authenticated, public;
"""
c = psycopg2.connect(uri); c.autocommit = True; cur = c.cursor()
cur.execute(stub); cur.execute(core)
sql = open(R_ + "sell-requests.sql", encoding='utf-8').read()
for n in range(2): cur.execute(sql)
print("sell-requests.sql corrido x2")
assert sql.replace('\r\n', '\n').strip() in sch.replace('\r\n', '\n'), "el bloque de sell-requests.sql no está igual al final de schema.sql"
cur.execute("insert into auth.users(email,invited_at) values ('admin@x','2026-01-01'),('a1@x','2026-01-01') returning id")
adm, a1 = [r[0] for r in cur.fetchall()]
cur.execute("alter table public.profiles disable trigger protect_profile_privileged")
cur.execute("update public.profiles set role='admin' where id=%s", (adm,))
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
    cur.execute("reset role; select set_config('request.jwt.claim.sub','',false)"); cur.execute(sql, a); return cur.fetchone()[0]
def sub(p): return as_(None, "select submit_sell_request(%s::jsonb)", (json.dumps(p),))
def base(**kw):
    d = {"id": str(uuid.uuid4()), "owner_name": "María López", "owner_ci": "4567890", "owner_phone": "+591 70012345", "owner_email": "m@x.com",
         "owner_role": "propietario", "property_type": "casa", "operation": "venta", "city": "La Paz", "zone": "Sopocachi",
         "address": "Av. 6 de Agosto 1234", "latitude": -16.5, "longitude": -68.13, "price": 120000, "currency": "USD",
         "land_area": 200, "built_area": 150, "rooms": 3, "baths": 2, "description": "Linda casa",
         "doc_status": "en_regla", "needs_legal_support": False, "documents": [], "consent": True}
    d.update(kw); return d

# ── alta pública
p = base(); p["documents"] = [{"type": "folio", "name": "folio.pdf", "path": p["id"] + "/folio-1.pdf", "size": 1000}]
chk("anon envía una solicitud completa", sub(p), False)
eq("teléfono guardado sin espacios", one("select owner_phone from sell_requests where id=%s", (p["id"],)), "+59170012345")
eq("estado inicial 'new'", one("select status from sell_requests where id=%s", (p["id"],)), 'new')
eq("el documento quedó registrado", one("select jsonb_array_length(documents) from sell_requests where id=%s", (p["id"],)), 1)

# ── validaciones
chk("sin aceptar el consentimiento", sub(base(consent=False, owner_phone="70011111")), True)
chk("teléfono inválido", sub(base(owner_phone="abc")), True)
chk("nombre muy corto", sub(base(owner_name="Al", owner_phone="70022222")), True)
chk("tipo de inmueble inválido", sub(base(property_type="castillo", owner_phone="70033333")), True)
chk("latitud sin longitud", sub(base(longitude=None, owner_phone="70044444")), True)
chk("coordenadas fuera de rango", sub(base(latitude=200, owner_phone="70055555")), True)
chk("precio negativo", sub(base(price=-5, owner_phone="70066666")), True)
chk("id repetido", sub({**p, "owner_phone": "70012399"}), True)
chk("id no válido", sub(base(id="no-es-uuid", owner_phone="70077777")), True)
q = base(owner_phone="70088888")
chk("documento fuera de la carpeta de la solicitud", sub({**q, "documents": [{"type": "folio", "name": "x", "path": str(uuid.uuid4()) + "/x.pdf"}]}), True)
chk("documento con ruta tramposa", sub({**q, "documents": [{"type": "folio", "name": "x", "path": q["id"] + "/../x.pdf"}]}), True)
chk("más de 12 documentos", sub({**q, "documents": [{"type": "otro", "name": "x", "path": q["id"] + "/f%d.pdf" % i} for i in range(13)]}), True)

# ── sin documentos => apoyo legal obligatorio
s = base(owner_phone="70099991", doc_status="sin_documentos", needs_legal_support=False)
chk("sin documentos", sub(s), False)
eq("sin documentos marca apoyo legal solo", one("select needs_legal_support from sell_requests where id=%s", (s["id"],)), True)
s2 = base(owner_phone="70099992", doc_status="por_regularizar", needs_legal_support=True)
chk("por regularizar con apoyo legal", sub(s2), False)
eq("apoyo legal guardado", one("select doc_status || needs_legal_support::text from sell_requests where id=%s", (s2["id"],)), "por_regularizartrue")
cur.execute("reset role")
try:
    cur.execute("insert into sell_requests(id,owner_name,owner_phone,property_type,city,address,doc_status,needs_legal_support,consent) values (gen_random_uuid(),'Pedro P','70011122','casa','LP','Calle 12345','sin_documentos',false,true)")
    fails += 1; print("FAIL la tabla debe exigir apoyo legal sin documentos")
except Exception:
    print("PASS la tabla exige apoyo legal sin documentos")

# ── límites
t = "70012121"
for i in range(3): chk("mismo teléfono, envío %d" % (i + 1), sub(base(owner_phone=t)), False)
chk("4.º envío del mismo teléfono en 24 h rechazado", sub(base(owner_phone=t)), True)

# ── privacidad y permisos
chk("anon no lee solicitudes", as_(None, "select * from sell_requests"), True)
eq("agente no ve ninguna", as_(a1, "select count(*) from sell_requests")[1][0][0], 0)
chk("agente no inserta directo", as_(a1, "insert into sell_requests(id,owner_name,owner_phone,property_type,city,address,doc_status,consent) values (gen_random_uuid(),'Pedro P','70011122','casa','LP','Calle 12345','en_regla',true)"), True)
eq("agente no cambia nada (RLS)", as_(a1, "update sell_requests set status='closed' returning id")[1] in ([], 0), True)
eq("admin ve todas", as_(adm, "select count(*) from sell_requests")[1][0][0], 6)
r = as_(adm, "update sell_requests set status='contacted', admin_notes='Llamé', owner_name='HACK', price=1, documents='[]' where id=%s returning status, owner_name, price, jsonb_array_length(documents)", (p["id"],))
eq("admin cambia estado y notas; datos del propietario congelados", r[1][0], ('contacted', 'María López', 120000, 1))
chk("admin puede borrar", as_(adm, "delete from sell_requests where id=%s", (s2["id"],)), False)

# ── storage
O = "insert into storage.objects(bucket_id,name) values (%s,%s)"
good = str(uuid.uuid4()) + "/folio-1.pdf"
chk("anon sube un documento al bucket privado", as_(None, O, ("sell-documents", good)), False)
chk("anon no sube fuera de carpeta/uuid", as_(None, O, ("sell-documents", "x/../y.pdf")), True)
chk("anon no sube a otro bucket", as_(None, O, ("property-photos", good)), True)
eq("anon no puede listar documentos", as_(None, "select count(*) from storage.objects")[1][0][0], 0)
eq("agente no ve documentos", as_(a1, "select count(*) from storage.objects")[1][0][0], 0)
eq("admin ve los documentos", as_(adm, "select count(*) from storage.objects")[1][0][0], 1)
eq("bucket privado, tope 10 MB, 4 tipos", one("select (not public)::text || file_size_limit::text || array_length(allowed_mime_types,1)::text from storage.buckets where id='sell-documents'"), "true104857604")
print("\nFALLAS:", fails); sys.exit(1 if fails else 0)
