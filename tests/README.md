# Pruebas

- `node --test tests/contracts-engine.test.js` — motor de contratos: números, montos y fechas en letras, formatos, plantilla (21 pruebas). No necesita instalar nada.
- `python tests/contracts_admin_sql_test.py` — anulación de contratos y verificación pública; corre el esquema completo dos veces.
- `python tests/subscriptions_sql_test.py` — suscripciones: planes y precios (Bs 150/350/650), límites de propiedades activas (3/15/50) y de destacados (1/3/3) con concurrencia, pago manual confirmado por el admin (idempotente), vencimientos, cambio de plan, contratos cubiertos por el plan, aislamiento de datos y transición de agentes existentes. Reemplaza a la prueba antigua de publicaciones con créditos.
- `python tests/sell_requests_sql_test.py` — solicitudes "Vender mi inmueble": alta pública validada, límites por teléfono, apoyo legal obligatorio sin documentos, solo admin lee, documentos en carpeta privada.
- `python tests/property_currency_sql_test.py` — moneda del precio de las propiedades: USD por defecto, BOB opcional, rechaza otras monedas.
- `python tests/contracts_sql_test.py` — seguridad de la generación de contratos (cubiertos por el plan, idempotencia, concurrencia, reversión, aislamiento) en un Postgres local desechable (requiere `pip install pgserver psycopg2-binary`). No toca Supabase.

Estas carpetas se publican con el sitio (es un sitio estático) pero no son enlazadas ni usadas por las páginas.
- `credit_pack_ledger_sql_test.py` — el historial desglosa el regalo de cada pack (Esencial, Profesional, Exclusivo) y el saldo suma créditos + regalo.
