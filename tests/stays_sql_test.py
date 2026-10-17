"""Pruebas de supabase/stays.sql: ubicación, privacidad de columnas para anónimos y reseñas de huéspedes.
Requiere:  pip install pgserver psycopg2-binary   y se ejecuta con:  python tests/registration_sql_test.py
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
mk = tail.index("-- =====================================================================" + chr(10) + "-- UNO · Registro de nuevos usuarios")
EQ2 = "-- =====================================================================" + chr(10) + "-- UNO · Comprobantes de pago"
end = tail.index(EQ2) if EQ2 in tail else len(tail)
assert tail[mk:end].strip() == open(R_ + "registration.sql", encoding="utf-8").read().strip(), "schema.sql no tiene el mismo bloque que registration.sql"
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
su("select 1")
for _ in range(2): cur.execute(tail)
print("esquema completo corrido x2")
import os
if os.environ.get("DROP_CREDITS"):
    su("select 1"); cur.execute(open(R_ + "drop-credits.sql", encoding="utf-8").read()); print("drop-credits.sql aplicado: las pruebas siguientes corren SIN el sistema de créditos")
cur.execute("insert into auth.users(email,invited_at) values ('admin@x','2026-01-01'),('own@x','2026-01-01'),('own2@x','2026-01-01'),('ag1@x','2026-01-01'),('ag2@x','2026-01-01'),('agx@x','2026-01-01'),('emp@x','2026-01-01'),('plain@x','2026-01-01') returning id")
adm, own, own2, ag1, ag2, agx, emp, plain = [r[0] for r in cur.fetchall()]
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


# --- el bloque de stays.sql está al final de schema.sql (y el esquema se aplicó 2 veces sin error)
sch_stays = open(R_ + "stays.sql", encoding="utf-8").read()
assert chr(10).join(sch_stays.split(chr(13))).strip() in chr(10).join(open(R_ + "schema.sql", encoding="utf-8").read().split(chr(13))), "stays.sql no está igual al final de schema.sql"

# --- propiedades de prueba (se insertan sin disparadores de plan)
su("set session_replication_role = replica")
def mkprop(owner, title, op='temporal', status='available', lat=None, lng=None):
    cur.execute("reset role; insert into properties (title, location, area, rooms, baths, description, price, owner_id, operation, status, property_type, latitude, longitude, owner_whatsapp) "
                "values (%s,'La Paz, Bolivia','80','2','1','x','60',%s,%s,%s,'casa',%s,%s,'70000000') returning id", (title, owner, op, status, lat, lng))
    return cur.fetchone()[0]
pT = mkprop(own, 'Casa temporal', lat=-16.5, lng=-68.13)
pV = mkprop(own, 'Casa en venta', op='venta')
pO = mkprop(own2, 'Otra temporal')
su("set session_replication_role = origin")

# --- ubicación
eq("la ubicación quedó guardada", row("select latitude, longitude from properties where id=%s", (pT,)), (-16.5, -68.13))
try:
    su("update properties set longitude = null where id=%s", (pT,)); fails += 1; print("FAIL latitud sin longitud aceptada")
except Exception:
    print("PASS latitud sin longitud rechazada")

# --- privacidad: el anónimo ya no puede leer owner_whatsapp ni columnas internas, pero sí las públicas
chk("anónimo lee columnas públicas", as_(None, "select id, title, price, photos, latitude, longitude, expires_at, status, operation from properties where status='available'"), False)
chk("anónimo NO lee owner_whatsapp", as_(None, "select owner_whatsapp from properties"), True)
chk("anónimo NO lee select *", as_(None, "select * from properties"), True)
chk("anónimo NO lee auto_renew", as_(None, "select auto_renew from properties"), True)
chk("el dueño autenticado sí lee owner_whatsapp", as_(own, "select owner_whatsapp from properties where id=%s", (pT,)), False)

# --- tablas de reseñas: nadie las toca directo
chk("anónimo no lee reseñas directo", as_(None, "select * from stay_reviews"), True)
chk("agente no lee invitaciones directo", as_(own, "select * from stay_review_invites"), True)

# --- enlaces de reseña
tok = as_(own, "select create_review_invite(%s, 'Carla Ríos')", (pT,)); chk("el anfitrión crea un enlace", tok, False); tok = tok[1][0][0]
eq("el enlace tiene 12 caracteres", len(tok), 12)
chk("no se crea en una propiedad que no es temporal", as_(own, "select create_review_invite(%s, null)", (pV,)), True)
chk("no se crea en la propiedad de otro", as_(own2, "select create_review_invite(%s, null)", (pT,)), True)
chk("anónimo no crea enlaces", as_(None, "select create_review_invite(%s, null)", (pT,)), True)
chk("el admin sí puede crear", as_(adm, "select create_review_invite(%s, 'Prueba')", (pT,)), False)
inv = as_(None, "select get_review_invite(%s)", (tok.lower(),))[1][0][0]
eq("el enlace es válido (acepta minúsculas)", (inv['valid'], inv['guest_name'], inv['title']), (True, 'Carla Ríos', 'Casa temporal'))
eq("enlace inexistente", as_(None, "select get_review_invite('XXXXXXXXXXXX')")[1][0][0]['valid'], False)

# --- reseña del huésped (sin cuenta)
chk("estrellas fuera de rango", as_(None, "select submit_stay_review(%s, 'Carla Ríos', 6, 'Muy bien')", (tok,)), True)
chk("estrellas 0", as_(None, "select submit_stay_review(%s, 'Carla Ríos', 0, 'x')", (tok,)), True)
chk("nombre muy corto", as_(None, "select submit_stay_review(%s, 'C', 5, 'x')", (tok,)), True)
chk("enlace inválido", as_(None, "select submit_stay_review('NOEXISTE0000', 'Carla Ríos', 5, 'x')"), True)
chk("reseña de 5 estrellas", as_(None, "select submit_stay_review(%s, 'Carla Ríos', 5, 'Todo impecable, volveremos')", (tok,)), False)
chk("el enlace no se reutiliza", as_(None, "select submit_stay_review(%s, 'Carla Ríos', 1, 'otra vez')", (tok,)), True)
eq("el enlace quedó usado", as_(None, "select get_review_invite(%s)", (tok,))[1][0][0]['used'], True)
# otras dos reseñas con enlaces nuevos
for nm, st, tx in (('Juan Pérez Gómez', 4, 'Buena ubicación'), ('Ana', 3, None)):
    tk = as_(own, "select create_review_invite(%s, null)", (pT,))[1][0][0]
    chk("reseña de " + nm, as_(None, "select submit_stay_review(%s, %s, %s, %s)", (tk, nm, st, tx)), False)

# --- calificaciones públicas
r = as_(None, "select property_id, avg_rating, review_count from list_stay_ratings(array[%s::uuid, %s::uuid])", (pT, pO))
eq("promedio y cantidad", [(str(a), float(b), c) for a, b, c in r[1]], [(str(pT), 4.0, 3)])
lst = as_(None, "select guest_name, rating, comment from list_stay_reviews(%s, 10)", (pT,))[1]
eq("se muestran como «Nombre A.»", sorted(x[0] for x in lst), ['Ana', 'Carla R.', 'Juan P.'])
eq("la más reciente primero", lst[0][0], 'Ana')

# --- panel del anfitrión
h = as_(own, "select host_stay_reviews(%s)", (pT,))[1][0][0]
eq("el anfitrión ve 3 reseñas y 1 enlace pendiente (el del admin)", (len(h['reviews']), len(h['invites'])), (3, 1))
chk("otro anfitrión no ve las reseñas ajenas", as_(own2, "select host_stay_reviews(%s)", (pT,)), True)
rid = h['reviews'][0]['id']
chk("el anfitrión responde", as_(own, "select reply_stay_review(%s, 'Gracias por alojarte con nosotros')", (rid,)), False)
chk("otro anfitrión no responde", as_(own2, "select reply_stay_review(%s, 'intruso')", (rid,)), True)
eq("la respuesta es pública", as_(None, "select host_reply from list_stay_reviews(%s, 1)", (pT,))[1][0][0], 'Gracias por alojarte con nosotros')
chk("el anfitrión no oculta reseñas", as_(own, "select admin_set_review_status(%s, 'hidden')", (rid,)), True)
chk("el admin oculta una reseña", as_(adm, "select admin_set_review_status(%s, 'hidden')", (rid,)), False)
r = as_(None, "select avg_rating, review_count from list_stay_ratings(array[%s::uuid])", (pT,))
eq("la reseña oculta no cuenta", [(float(a), b) for a, b in r[1]], [(4.5, 2)])
eq("el anfitrión sigue viéndola (oculta)", [x['status'] for x in as_(own, "select host_stay_reviews(%s)", (pT,))[1][0][0]['reviews']].count('hidden'), 1)
tk2 = as_(own, "select create_review_invite(%s, null)", (pT,))[1][0][0]
chk("el anfitrión elimina un enlace sin usar", as_(own, "select revoke_review_invite(%s)", (tk2,)), False)
chk("un anfitrión no elimina el enlace de otro", as_(own2, "select revoke_review_invite(%s)", (h['invites'][0]['token'],)), True)

# --- límite de enlaces sin usar (20)
for k in range(20): as_(own, "select create_review_invite(%s, null)", (pT,))
chk("no más de 20 enlaces sin usar", as_(own, "select create_review_invite(%s, null)", (pT,)), True)

# --- el SQL es idempotente
su("select 1")
for _ in range(2): cur.execute(sch_stays)
print("stays.sql re-corrido sin error")
print("FALLAS:", fails); sys.exit(1 if fails else 0)
