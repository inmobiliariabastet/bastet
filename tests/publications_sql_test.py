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

# ══════════ Vigencia de 30 días, renovación manual y renovación automática ══════════
def su():
    cur.execute('reset role'); cur.execute("select set_config('request.jwt.claim.sub','',false)")
su()
cur.execute("insert into auth.users(email,invited_at) values ('b1@x','2026-01-01'),('b2@x','2026-01-01'),('b3@x','2026-01-01') returning id")
b1, b2, b3 = [r[0] for r in cur.fetchall()]
cur.execute("insert into credit_wallets(user_id,balance) values (%s,40),(%s,0)", (b1, b2))
def su():
    cur.execute('reset role'); cur.execute("select set_config('request.jwt.claim.sub','',false)")
def exp(pid): return one("select expires_at from properties where id=%s", (pid,))
def days_from_now(ts): return round((ts - one("select now()")).total_seconds() / 86400, 1)
def newprop(u, title='V'):
    r = as_(u, "insert into properties(id,title,location,price,area,rooms,baths,owner_id) values (gen_random_uuid(),%s,'SC','1','1','1','1',%s) returning id", (title, u))
    return r[1][0][0] if r[0] == 'ok' else None

# ── vigencia fijada por el servidor
pid = newprop(b1, 'V1')
eq("al crear: vence a los 30 días", days_from_now(exp(pid)), 30.0)
r = as_(b1, "insert into properties(id,title,location,price,area,rooms,baths,owner_id,expires_at) values (gen_random_uuid(),'Tramposa','SC','1','1','1','1',%s,'2099-01-01') returning id", (b1,))
eq("el navegador no puede elegir la vigencia al crear", days_from_now(exp(r[1][0][0])), 30.0)
as_(b1, "update properties set expires_at='2099-01-01' where id=%s", (pid,)); eq("agente no puede alargar el vencimiento", days_from_now(exp(pid)), 30.0)
as_(adm, "update properties set expires_at = now() + interval '5 days' where id=%s", (pid,)); eq("admin sí puede cambiar el vencimiento", days_from_now(exp(pid)), 5.0)
su(); cur.execute("update properties set expires_at = now() + interval '30 days' where id=%s", (pid,))
cur.execute("update properties set expires_at = null where id=%s", (pid,)); cur.execute(open(R_ + "publications.sql", encoding='utf-8').read())
eq("las propiedades ya existentes reciben 30 días al activar", days_from_now(exp(pid)), 30.0)

# ── el público solo ve propiedades vigentes
su(); cur.execute("update properties set expires_at = now() - interval '1 day' where id=%s", (pid,))
eq("anon NO ve una propiedad vencida", as_(None, "select count(*) from properties where id=%s", (pid,))[1][0][0], 0)
eq("el dueño sí la ve en su panel", as_(b1, "select count(*) from properties where id=%s", (pid,))[1][0][0], 1)
eq("anon ve las vigentes", as_(None, "select count(*) from properties where owner_id=%s and title='V1'", (b1,))[1][0][0], 0)

# ── renovación manual: cupo gratis primero, luego créditos
su(); cur.execute("delete from property_publications where user_id=%s", (b1,))
bal0 = bal(b1)
r = as_(b1, "select renew_property(%s)", (pid,)); chk("renovar una vencida (con cupo gratis)", r, False); res = r[1][0][0]
eq("usó una gratis, sin cobro", (res['kind'], bal(b1)), ('free', bal0))
eq("30 días completos desde hoy (estaba vencida)", days_from_now(exp(pid)), 30.0)
eq("vuelve a verse para el público", as_(None, "select count(*) from properties where id=%s", (pid,))[1][0][0], 1)
eq("la renovación consumió un cupo del mes", quota(b1)['free_left'], 2)
su(); cur.execute("select is_renewal from property_publications where user_id=%s and kind='free'", (b1,)); eq("queda registrada como renovación", cur.fetchone()[0], True)
# sin cupo gratis: 8 créditos
su(); cur.execute("insert into property_publications(user_id,month,kind) select %s, bolivia_month_start(), 'free' from generate_series(1,2)", (b1,))
eq("sin cupo gratis", quota(b1)['free_left'], 0)
su(); cur.execute("update properties set expires_at = now() + interval '10 days' where id=%s", (pid,))
r = as_(b1, "select renew_property(%s)", (pid,)); chk("renovar con créditos", r, False)
eq("cobró 8 créditos", bal(b1), bal0 - 8)
eq("renovar antes de vencer suma 30 días al vencimiento (10 + 30)", days_from_now(exp(pid)), 40.0)
su(); cur.execute("select description from credit_ledger where user_id=%s order by id desc limit 1", (b1,)); eq("movimiento de renovación", cur.fetchone()[0].startswith('Renovación de propiedad: V1'), True)
# sin saldo: rechaza sin tocar nada
pid2 = newprop(b2, 'W1'); su(); cur.execute("insert into property_publications(user_id,month,kind) select %s, bolivia_month_start(), 'free' from generate_series(1,3)", (b2,))
cur.execute("update properties set expires_at = now() - interval '1 day' where id=%s", (pid2,)); e0 = exp(pid2)
chk("renovar sin saldo ni cupo: rechazada", as_(b2, "select renew_property(%s)", (pid2,)), True); eq("sin cambios en el vencimiento ni en el saldo", (exp(pid2), bal(b2)), (e0, 0))
# permisos
chk("otro agente no renueva lo ajeno", as_(b1, "select renew_property(%s)", (pid2,)), True)
chk("anon no renueva", as_(None, "select renew_property(%s)", (pid2,)), True)
r = as_(adm, "select renew_property(%s)", (pid2,)); chk("admin renueva cualquiera, gratis", r, False); eq("admin: sin cobro y sin cupo", (r[1][0][0]['kind'], bal(b2)), ('admin', 0))

# ── renovación automática
su(); cur.execute("delete from property_publications where user_id in (%s,%s)", (b1, b3))
cur.execute("insert into credit_wallets(user_id,balance) values (%s,16)", (b3,))
pa = newprop(b3, 'AUTO1'); pb = newprop(b3, 'AUTO2'); pc = newprop(b3, 'NOAUTO')
su(); cur.execute("update property_publications set kind='free' where user_id=%s", (b3,))
cur.execute("insert into property_publications(user_id,month,kind) select %s, bolivia_month_start(), 'free' from generate_series(1,3)", (b3,))   # cupo gratis agotado
eq("el agente activa la renovación automática de la suya", as_(b3, "update properties set auto_renew=true where id in (%s,%s) returning id", (pa, pb))[0], 'ok')
su(); eq("quedan activadas", one("select count(*) from properties where owner_id=%s and auto_renew", (b3,)), 2)
chk("no activa la de otro", as_(b1, "update properties set auto_renew=true where id=%s", (pa,)), False); eq("…y no cambió", one("select auto_renew from properties where id=%s", (pa,)), True)
su(); cur.execute("update properties set auto_renew=false where owner_id=%s and title='NOAUTO'", (b3,))
# vencen: AUTO1 en 30 minutos, AUTO2 dentro de 5 días, NOAUTO ayer
cur.execute("update properties set expires_at = now() + interval '30 minutes' where id=%s", (pa,))
cur.execute("update properties set expires_at = now() + interval '5 days' where id=%s", (pb,))
cur.execute("update properties set expires_at = now() - interval '1 day' where id=%s", (pc,))
eq("anon puede lanzar el proceso (sin parámetros)", as_(None, "select process_auto_renewals()")[0], 'ok')
su()
eq("renovó solo la que vencía en la próxima hora", (days_from_now(exp(pa)), days_from_now(exp(pb))), (30.0, 5.0))
eq("30 días completos desde su vencimiento (30 min + 30 días)", float(one("select extract(epoch from (expires_at - now()))/86400 from properties where id=%s", (pa,))) > 30.0, True)
eq("cobró 8 (sin cupo gratis)", bal(b3), 8)
eq("la que no tiene la opción NO se renueva", days_from_now(exp(pc)) < 0, True)
eq("sigue oculta para el público", as_(None, "select count(*) from properties where id=%s", (pc,))[1][0][0], 0)
su(); cur.execute("select description from credit_ledger where user_id=%s order by id desc limit 1", (b3,)); eq("movimiento 'Renovación automática'", cur.fetchone()[0].startswith('Renovación automática: AUTO1'), True)
eq("limitado: otra corrida inmediata no hace nada", as_(None, "select process_auto_renewals()")[1][0][0], 0)
# fuerza (como pg_cron) y saldo insuficiente: no cobra y marca el fallo
su(); cur.execute("update credit_wallets set balance=3 where user_id=%s", (b3,)); cur.execute("update properties set expires_at = now() - interval '2 days' where id=%s", (pb,))
cur.execute("select _process_auto_renewals(true)"); n = cur.fetchone()[0]
eq("sin saldo: no renueva", n, 0); eq("sin saldo: saldo intacto", bal(b3), 3)
eq("sin saldo: queda marcado el intento fallido", one("select auto_renew_failed_at is not null from properties where id=%s", (pb,)), True)
eq("sin saldo: sigue vencida y oculta", (days_from_now(exp(pb)) < 0, as_(None, "select count(*) from properties where id=%s", (pb,))[1][0][0]), (True, 0))
# el dueño compra créditos -> la siguiente corrida renueva desde HOY (30 días completos)
su(); cur.execute("update credit_wallets set balance=20 where user_id=%s", (b3,)); cur.execute("select _process_auto_renewals(true)")
eq("con saldo vuelve: renovada", cur.fetchone()[0], 1); eq("desde hoy, 30 días completos", days_from_now(exp(pb)), 30.0)
eq("se limpia la marca de fallo", one("select auto_renew_failed_at is null from properties where id=%s", (pb,)), True)
eq("vuelve a verse", as_(None, "select count(*) from properties where id=%s", (pb,))[1][0][0], 1)
# un administrador dueño con renovación automática: gratis
su(); padm = newprop(adm, 'ADMAUTO'); su(); cur.execute("update properties set auto_renew=true, expires_at = now() + interval '10 minutes' where id=%s", (padm,)); cur.execute("select _process_auto_renewals(true)")
eq("admin: renueva sin cobro ni cupo", (days_from_now(exp(padm)) > 29.9, one("select count(*) from property_publications where user_id=%s", (adm,))), (True, 0))
# propiedad vendida o dueño desactivado no se renuevan
su(); cur.execute("update properties set status='sold', expires_at = now() - interval '1 day' where id=%s", (pa,)); cur.execute("select _process_auto_renewals(true)")
eq("vendida: no se renueva", days_from_now(exp(pa)) < 0, True)
cur.execute("update properties set status='available', expires_at = now() - interval '1 day' where id=%s", (pa,)); cur.execute("update profiles set is_active=false where id=%s", (b3,)); cur.execute("select _process_auto_renewals(true)")
eq("dueño desactivado: no se renueva", days_from_now(exp(pa)) < 0, True)
cur.execute("update profiles set is_active=true where id=%s", (b3,))
chk("el navegador no puede forzar el proceso", as_(None, "select _process_auto_renewals(true)"), True)
chk("agente no llama al núcleo de renovación", as_(b3, "select _do_renew(%s, %s, true, true)", (pa, b3)), True)
eq("la cuenta del cupo ya no cambia al editar", quota(b3)['free_total'], 3)

print("\nFALLAS:", fails); sys.exit(1 if fails else 0)
