# Pruebas

- `node --test tests/contracts-engine.test.js` — motor de contratos: números, montos y fechas en letras, formatos, plantilla (21 pruebas). No necesita instalar nada.
- `python tests/contracts_admin_sql_test.py` — anulación de contratos y verificación pública; corre el esquema completo dos veces.
- `python tests/contracts_sql_test.py` — seguridad del cobro de contratos en un Postgres local desechable (requiere `pip install pgserver psycopg2-binary`). No toca Supabase.

Estas carpetas se publican con el sitio (es un sitio estático) pero no son enlazadas ni usadas por las páginas.
