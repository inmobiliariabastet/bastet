# Pruebas

- `node --test tests/contracts-engine.test.js` — motor de contratos: números, montos y fechas en letras, formatos, plantilla (21 pruebas). No necesita instalar nada.
- `python tests/contracts_admin_sql_test.py` — anulación de contratos y verificación pública; corre el esquema completo dos veces.
- `python tests/owner_services_sql_test.py` — plan Propietario: directorio de agentes, ofertas de colaboración (validaciones, numeración BST-CO, respuesta del agente, cancelación, aislamiento) y solicitudes a Maat Fima Legal (estados, límites, solo admin avanza).
- `python tests/subscriptions_sql_test.py` — suscripciones: planes y precios (Bs 150/350/650), límites de propiedades activas (3/15/50) y de destacados (1/3/3) con concurrencia, pago manual confirmado por el admin (idempotente), vencimientos, cambio de plan, contratos cubiertos por el plan, aislamiento de datos y transición de agentes existentes. Reemplaza a la prueba antigua de publicaciones con créditos.
- `python tests/sell_requests_sql_test.py` — solicitudes "Vender mi inmueble": alta pública validada, límites por teléfono, apoyo legal obligatorio sin documentos, fotos (hasta 8, aparte de los 12 documentos; «sin documentos» las conserva), solo admin lee, documentos en carpeta privada.
- `python tests/property_currency_sql_test.py` — moneda del precio de las propiedades: USD por defecto, BOB opcional, rechaza otras monedas.
- `python tests/contracts_sql_test.py` — seguridad de la generación de contratos (cubiertos por el plan, idempotencia, concurrencia, reversión, aislamiento) en un Postgres local desechable (requiere `pip install pgserver psycopg2-binary`). No toca Supabase.

Estas carpetas se publican con el sitio (es un sitio estático) pero no son enlazadas ni usadas por las páginas.
- `credit_pack_ledger_sql_test.py` — el historial desglosa el regalo de cada pack (Esencial, Profesional, Exclusivo) y el saldo suma créditos + regalo.

## Pruebas agregadas el 2026-10-17
- `python tests/registration_sql_test.py` — registro con Google, prueba gratuita de 7 días y activación automática.
- `python tests/stays_sql_test.py` — estadías: ubicación (latitud/longitud), **privacidad de columnas para el visitante anónimo** (no puede leer `owner_whatsapp`), enlaces de reseña de un solo uso, calificaciones, respuestas del anfitrión y ocultar reseñas (41 comprobaciones).
- `python tests/stay_availability_sql_test.py` — calendario de no disponibilidad: bloqueos, permisos, periodos vencidos y lo que ve el público (sin notas).

**Resumen para correr todo** (requiere `pip install pgserver psycopg2-binary`; cada suite levanta un Postgres local desechable y no toca producción): `for t in tests/*_sql_test.py; do python $t; done` y `node tests/contracts-engine.test.js` (29 pruebas). Todas deben terminar con 0 fallas.
- `python tests/make_admin_stub.py admin|agent|owner|none` — genera `_stub_admin.html` + `_stub_supabase.js` (panel con Supabase simulado). **Borrarlos antes de commitear.** `tests/responsive-audit.js` — auditoría de desbordes a 320/390/768 px.
- `python tests/property_requests_sql_test.py` — solicitudes de propiedad (comprador/inquilino): envío público validado, límite por teléfono, estado de mis solicitudes (por id y por cuenta), finalizar y administración.
