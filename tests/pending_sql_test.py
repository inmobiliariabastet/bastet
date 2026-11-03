"""Prueba de supabase/run-pending.sql: simula el estado REAL de producción (esquema hasta retire-subscriptions, sin los módulos nuevos) y corre el archivo
único de pendientes dos veces. También verifica que run-pending.sql esté al día con los 5 archivos que lo componen.
Se ejecuta con:  python tests/pending_sql_test.py   (requiere pip install pgserver psycopg2-binary; no toca Supabase)."""
import pgserver, psycopg2, tempfile
srv = pgserver.get_server(tempfile.mkdtemp(prefix='uno-prod-'), cleanup_mode='delete')
c = psycopg2.connect(srv.get_uri()); c.autocommit = True; cur = c.cursor()
sch = open('supabase/schema.sql', encoding='utf-8').read()
cut = sch.index('-- =====================================================================\n-- Bastet · Conexiones y tarifas')
prod = sch[:cut]
stub = open('tests/stay_bookings_sql_test.py', encoding='utf-8').read(); stub = stub[stub.index('stub = """') + 10:]; stub = stub[:stub.index('"""')]
cur.execute(stub); cur.execute(prod)
print('estado actual de producción aplicado (', len(prod), 'caracteres )')
FILES = ['connections.sql', 'security-hardening.sql', 'operations.sql', 'verification.sql', 'investigations.sql']
pend = open('supabase/run-pending.sql', encoding='utf-8').read()
for f in FILES:
    assert open('supabase/' + f, encoding='utf-8').read().strip() in pend, 'run-pending.sql está desactualizado: falta ' + f + ' (regenerarlo con la concatenación de los 5 archivos)'
print('run-pending.sql al día con sus 5 archivos')
for n in (1, 2):
    try:
        cur.execute(pend); print('run-pending.sql corrida', n, 'OK')
    except Exception as e:
        print('ERROR en la corrida', n, ':', str(e)[:500]); raise SystemExit(1)
cur.execute("select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname in ('request_connection','start_property_closure','request_verification','admin_open_investigation','public_property_contact','my_account')")
print('funciones clave presentes:', cur.fetchone()[0], 'de 6')
cur.execute("select to_regclass('public.connections') is not null, to_regclass('public.operations') is not null, to_regclass('public.verification_requests') is not null, to_regclass('public.investigations') is not null")
print('tablas nuevas:', cur.fetchone())

print('FALLAS: 0')
