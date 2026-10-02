"""Pruebas de la regla de publicaciones: 3 gratis al mes (se renuevan el día 1) y 8 créditos por cada propiedad extra.
Requiere: pip install pgserver psycopg2-binary  ->  python tests/publications_sql_test.py   (Postgres local desechable; no toca Supabase)."""
import pgserver, psycopg2, sys, threading, tempfile, pathlib, datetime
ROOT = pathlib.Path(__file__).resolve().parent.parent
srv = pgserver.get_server(tempfile.mkdtemp(prefix='uno-pg-'), cleanup_mode='delete')
uri = srv.get_uri()
R_ = str(ROOT / "supabase") + "/"
sch = open(R_ + "schema.sql", encoding='utf-8').read()
core = sch[:sch.index("-- ── Tabla property_events")]
i = sch.index("-- UNO · Créditos para agentes")
tail = sch[sch.rindex("\n", 0, i - 5) + 1:]
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
cur.execute(stub); cur.execute(core)
for _ in range(2): cur.execute(tail)          # el esquema completo (con el bloque de publicaciones) corre 2 veces
print("esquema completo corrido x2")
cur.execute("insert into auth.users(email,invited_at) values ('admin@x','2026-01-01'),('a1@x','2026-01-01'),('a2@x','2026-01-01'),('a3@x','2026-01-01'),('a4@x','2026-01-01') returning id")
adm, a1, a2, a3, a4 = [r[0] for r in cur.fetchall()]
cur.execute("alter table public.profiles disable trigger protect_profile_privileged"); cur.execute("update public.profiles set role='admin' where id=%s", (adm,))
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
    print(('PASS' if good else 'FAIL'), name, '->', str(res)[:120])
def eq(name, got, want):
    global fails
    good = got == want
    if not good: fails += 1
    print(('PASS' if good else 'FAIL'), name, '->', got)
def one(sql, a=None):
    cur.execute("reset role"); cur.execute(sql, a); return cur.fetchone()[0]
INS = "insert into properties(id,title,location,price,area,rooms,baths,owner_id) values (gen_random_uuid(),%s,'SC','1','1','1','1',%s)"
def quota(u): return as_(u, "select my_publication_quota()")[1][0][0]
def bal(u): return one("select coalesce((select balance from credit_wallets where user_id=%s),0)", (u,))

# ── regla vigente y contador inicial
q = quota(a1)
nxt = (datetime.date.today().replace(day=1) + datetime.timedelta(days=32)).replace(day=1)
eq("contador inicial: 3 de 3 gratis, costo 8", (q['free_total'], q['free_left'], q['cost'], q['exempt']), (3, 3, 8, False))
eq("se renueva el día 1 del mes siguiente", q['resets_on'], nxt.strftime('%Y-%m-01'))
eq("fecha de renovación es un día 1", q['resets_on'].endswith('-01'), True)
eq("mes de Bolivia: 31 oct 23:59 aún es octubre", one("select bolivia_month_start('2026-11-01 03:59:59+00')")  == datetime.date(2026, 10, 1), True)
eq("mes de Bolivia: 1 nov 00:00 ya es noviembre", one("select bolivia_month_start('2026-11-01 04:00:00+00')") == datetime.date(2026, 11, 1), True)
chk("anon no consulta el contador", as_(None, "select my_publication_quota()"), True)

# ── 3 gratis
for n in range(3): chk("publicación %d (gratis)" % (n + 1), as_(a1, INS, ('P%d' % n, a1)), False)
eq("no se cobró nada", (bal(a1), one("select count(*) from credit_ledger where user_id=%s", (a1,))), (0, 0))
eq("3 gratis registradas", one("select count(*) from property_publications where user_id=%s and kind='free'", (a1,)), 3)
q = quota(a1); eq("contador: 0 de 3 disponibles", (q['free_left'], q['free_used']), (0, 3))

# ── 4.ª sin saldo: rechazada y sin efectos
r = as_(a1, INS, ('P3', a1)); chk("4.ª sin saldo: rechazada", r, True); eq("mensaje 'Saldo insuficiente'", 'Saldo insuficiente' in r[1], True)
eq("no se creó la propiedad", one("select count(*) from properties where owner_id=%s", (a1,)), 3)
eq("no quedó registro de publicación extra", one("select count(*) from property_publications where user_id=%s", (a1,)), 3)

# ── con créditos: se cobran 8
cur.execute("insert into credit_wallets(user_id,balance) values (%s,20)", (a1,))
chk("4.ª con 20 créditos", as_(a1, INS, ('P3', a1)), False); eq("saldo 12 (cobró 8)", bal(a1), 12)
cur.execute("reset role"); cur.execute("select kind, amount, description, property_id is not null from credit_ledger where user_id=%s", (a1,)); row = cur.fetchone()
eq("movimiento de 8 créditos con la propiedad", (row[0], row[1], row[2].startswith('Publicación de propiedad: P3'), row[3]), ('spend', -8, True, True))
eq("registro 'paid' con 8 créditos", one("select credits_charged from property_publications where user_id=%s and kind='paid'", (a1,)), 8)
chk("5.ª con 12 créditos", as_(a1, INS, ('P4', a1)), False); eq("saldo 4", bal(a1), 4)
chk("6.ª con 4 créditos: rechazada", as_(a1, INS, ('P5', a1)), True); eq("saldo sigue 4", bal(a1), 4)

# ── borrar no devuelve cupo ni créditos
cur.execute("reset role"); cur.execute("delete from properties where owner_id=%s", (a1,))
eq("propiedades borradas", one("select count(*) from properties where owner_id=%s", (a1,)), 0)
q = quota(a1); eq("borrar no libera cupo gratis (sigue 0 de 3)", q['free_left'], 0)
eq("borrar no devuelve créditos", bal(a1), 4)
chk("publicar tras borrar sigue cobrando (4 < 8)", as_(a1, INS, ('P6', a1)), True)

# ── renovación mensual: se vuelve a 3
cur.execute("reset role"); cur.execute("update property_publications set month = (month - interval '1 month')::date where user_id=%s", (a1,))
q = quota(a1); eq("mes nuevo: de nuevo 3 de 3", (q['free_left'], q['free_used']), (3, 0))
chk("mes nuevo: otra gratis, sin cobro", as_(a1, INS, ('N1', a1)), False); eq("saldo intacto (4)", bal(a1), 4)
eq("mes nuevo: quedan 2", quota(a1)['free_left'], 2)
# sin uso, no se acumula: a2 nunca publicó en meses pasados
cur.execute("reset role"); cur.execute("insert into property_publications(user_id,month,kind) values (%s, '2026-01-01', 'free')", (a2,))
eq("lo no usado no se acumula (siempre máximo 3)", (quota(a2)['free_left'], quota(a2)['free_total']), (3, 3))

# ── administradores
for n in range(5): chk("admin publica %d sin límite" % (n + 1), as_(adm, INS, ('A%d' % n, adm)), False)
eq("admin: sin registros de cupo", one("select count(*) from property_publications where user_id=%s", (adm,)), 0)
eq("admin: exento en el contador", quota(adm)['exempt'], True)

# ── permisos
chk("agente no escribe publicaciones", as_(a1, "insert into property_publications(user_id,month,kind) values (%s,'2026-01-01','free')", (a1,)), True)
chk("agente no edita publicaciones", as_(a1, "update property_publications set kind='free'"), True)
chk("agente no borra publicaciones", as_(a1, "delete from property_publications"), True)
eq("agente ve solo las suyas", set(r[0] for r in as_(a1, "select user_id from property_publications")[1]), {a1})
eq("a2 no ve ninguna de a1", as_(a2, "select count(*) from property_publications where user_id=%s", (a1,))[1][0][0], 0)
eq("el agente lee la regla", as_(a1, "select value from app_settings where key='publication_cost_credits'")[1][0][0], 8)
as_(a1, "update app_settings set value=0"); eq("el agente no cambia la regla", one("select value from app_settings where key='publication_cost_credits'"), 8)
chk("anon no lee la regla", as_(None, "select * from app_settings"), True)
chk("no se publica a nombre de otro", as_(a1, INS, ('X', a2)), True)
# un admin puede cambiar la regla y el contador lo refleja
as_(adm, "update app_settings set value=5 where key='free_publications_per_month'"); eq("admin cambia el cupo a 5 → el contador lo refleja", quota(a2)['free_total'], 5)
as_(adm, "update app_settings set value=3 where key='free_publications_per_month'")

# ── reversión: si la inserción falla después del disparador, no queda cobro
cur.execute("reset role"); cur.execute("insert into credit_wallets(user_id,balance) values (%s,30)", (a3,))
for n in range(3): as_(a3, INS, ('F%d' % n, a3))
b0 = bal(a3); p0 = one("select count(*) from property_publications where user_id=%s", (a3,))
chk("falla tras el disparador (título nulo)", as_(a3, "insert into properties(id,title,location,price,area,rooms,baths,owner_id) values (gen_random_uuid(),null,'SC','1','1','1','1',%s)", (a3,)), True)
eq("falla: saldo intacto", bal(a3), b0); eq("falla: sin registro de publicación", one("select count(*) from property_publications where user_id=%s", (a3,)), p0)
pid = one("select id from properties where owner_id=%s limit 1", (a3,))
chk("id repetido: rechazado", as_(a3, "insert into properties(id,title,location,price,area,rooms,baths,owner_id) values (%s,'dup','SC','1','1','1','1',%s)", (pid, a3)), True)
eq("id repetido: saldo intacto", bal(a3), b0)

# ── concurrencia: 8 propiedades a la vez (3 gratis + créditos para 2 de pago) -> exactamente 3 gratis, 2 de pago, 3 rechazadas
cur.execute("insert into credit_wallets(user_id,balance) values (%s,20)", (a4,))
res = [None] * 8
def worker(k):
    cn = psycopg2.connect(uri); cn.autocommit = True; cu = cn.cursor()
    cu.execute("select set_config('request.jwt.claim.sub',%s,false)", (str(a4),)); cu.execute("set role authenticated")
    try: cu.execute(INS, ('C%d' % k, a4)); res[k] = 'ok'
    except Exception as e: res[k] = str(e).splitlines()[0]
    cn.close()
ts = [threading.Thread(target=worker, args=(k,)) for k in range(8)]
[t.start() for t in ts]; [t.join() for t in ts]
eq("concurrencia: 5 se publican y 3 se rechazan", (sum(1 for r in res if r == 'ok'), sum(1 for r in res if r != 'ok' and 'Saldo insuficiente' in r)), (5, 3))
eq("concurrencia: exactamente 3 gratis", one("select count(*) from property_publications where user_id=%s and kind='free'", (a4,)), 3)
eq("concurrencia: exactamente 2 de pago", one("select count(*) from property_publications where user_id=%s and kind='paid'", (a4,)), 2)
eq("concurrencia: saldo 4 (20 - 2×8)", bal(a4), 4)
eq("concurrencia: propiedades = publicaciones", one("select count(*) from properties where owner_id=%s", (a4,)), 5)
eq("concurrencia: el historial cuadra con lo cobrado", one("select coalesce(sum(-amount),0) from credit_ledger where user_id=%s and kind='spend'", (a4,)), one("select coalesce(sum(credits_charged),0) from property_publications where user_id=%s", (a4,)))

# ── agente desactivado
cur.execute("reset role"); cur.execute("update profiles set is_active=false where id=%s", (a2,))
chk("desactivado no publica", as_(a2, INS, ('Z', a2)), True); chk("desactivado no consulta el contador", as_(a2, "select my_publication_quota()"), True)
cur.execute("reset role"); cur.execute("update profiles set is_active=true where id=%s", (a2,))
# editar una propiedad no gasta cupo ni cobra
b0 = bal(a4); p0 = one("select count(*) from property_publications where user_id=%s", (a4,))
as_(a4, "update properties set title='cambio' where owner_id=%s", (a4,)); eq("editar no cobra ni gasta cupo", (bal(a4), one("select count(*) from property_publications where user_id=%s", (a4,))), (b0, p0))
print("\nFALLAS:", fails); sys.exit(1 if fails else 0)
