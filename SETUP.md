# Bastet Propiedades · Inmobiliarias — Guía de puesta en marcha

Sitio estático (HTML/CSS/JS puro, sin build) con Supabase como backend.

## 1. Crear el proyecto en Supabase

1. Ve a [supabase.com](https://supabase.com) y crea una cuenta / un proyecto nuevo (plan gratuito).
2. Espera a que termine de aprovisionarse (1-2 minutos).
3. En el menú lateral ve a **SQL Editor** → **New query**, pega el contenido completo de [`supabase/schema.sql`](supabase/schema.sql) y ejecútalo (▶ Run). Esto crea:
   - La tabla `properties` con sus políticas de seguridad (RLS), incluyendo `owner_id` (quién puede editarla) y `featured` (destacada en el carrusel).
   - La tabla `profiles` (rol `admin`/`agent` y estado activo/desactivado de cada usuario), con un trigger que crea automáticamente el perfil de cualquier usuario nuevo.
   - El bucket de Storage `property-photos` (público para lectura, autenticados activos pueden subir/borrar).
   - La tabla `partners` (logos de empresas aliadas, solo editable por administradores) y el bucket `partner-logos`.
   - Es seguro volver a correr este script completo si ya lo habías ejecutado antes (usa `if not exists` / `drop policy if exists`) — así obtienes las tablas/columnas nuevas sin duplicar nada.
   - Si el bucket `property-photos` o `partner-logos` no aparece después de correr el script (puede pasar por permisos del SQL Editor), créalo manualmente en **Storage → New bucket** con ese nombre exacto y marca "Public bucket".
   - **Importante:** cerca del final de la sección de `profiles`, el script tiene una línea `update public.profiles set role = 'admin' where email in (...)`. Edita esa lista con los correos que deben ser administradores (acceso total) antes de correrlo — cualquier otro usuario queda como `agent` (agente, solo ve/edita sus propias propiedades). Puedes volver a correr solo esa línea más adelante para promover a alguien más.
4. Ve a **Project Settings → API** y copia:
   - **Project URL**
   - **anon public** key

## 2. Conectar las credenciales

Abre [`assets/js/supabase-config.js`](assets/js/supabase-config.js) y reemplaza:

```js
const SUPABASE_URL = 'https://TU-PROYECTO.supabase.co';
const SUPABASE_ANON_KEY = 'TU-ANON-PUBLIC-KEY';
```

con tus valores reales. Este archivo lo usan tanto `index.html` (landing) como `admin/index.html` (panel).

## 3. Configurar Supabase Auth (seguridad y correos)

En el dashboard de Supabase:

1. **Authentication → Sign In / Providers:** desactiva **"Allow new users to sign up"**. Nadie puede crearse una cuenta solo; los usuarios entran únicamente por invitación.
2. **Authentication → URL Configuration:** *Site URL* = `https://bastet.uno/admin/` y *Redirect URLs* = `https://bastet.uno/**`.
3. **Authentication → Emails → SMTP Settings:** activa *Custom SMTP* con el buzón de Hostinger: host `smtp.hostinger.com`, puerto `465` (o `587`), usuario y remitente `inmobiliaria@bastet.uno`, nombre "Bastet Propiedades". Luego en **Rate Limits** sube el límite de correos (p. ej. 30/hora).
4. **Authentication → Emails → Templates:** pega las plantillas en español de [`supabase/email-templates/`](supabase/email-templates/) (Invite user y Reset password).

## 4. Crear el primer administrador

1. **Authentication → Users → Add user** con tu correo y contraseña (o invítate).
2. En `supabase/schema.sql`, la línea `update public.profiles set role = 'admin' where email in (...)` define quién es admin: agrega tu correo y corre esa línea en el SQL Editor. (También puedes cambiar `role` a `admin` en la tabla `profiles`.)
3. Si creaste el usuario a mano (no por invitación), su perfil nace **desactivado** por seguridad: actívalo con `update public.profiles set is_active = true where email = 'tu@correo.com';`.
4. Entra a `https://bastet.uno/admin/`. Desde ahí, los demás usuarios se invitan en la pestaña **Usuarios** (las personas que entran con Google se crean solas como agentes; ya no hay solicitudes ni invitaciones por correo).

## 5. Desplegar la función que invita usuarios

Crear cuentas requiere la clave `service_role`, que nunca debe estar en el navegador, así que esto corre en una Edge Function:

1. **Edge Functions → Deploy a new function**, nombre exacto `invite-admin`.
2. Pega el contenido completo de [`supabase/functions/invite-admin/index.ts`](supabase/functions/invite-admin/index.ts) y despliega. `SUPABASE_URL`, `SUPABASE_ANON_KEY` y `SUPABASE_SERVICE_ROLE_KEY` ya están disponibles automáticamente.
3. La función solo acepta invitaciones de un **administrador activo** (un agente recibe 403). Las personas invitadas entran como `agent` y reciben el correo de invitación para crear su contraseña.

## Panel /admin: estructura y fuentes

El panel usa un menú lateral (`<aside id="admin-side">` en `admin/index.html`): cada botón lleva `class="admin-tab"` y `data-tab="<nombre>"`, y `admin.js` muestra el panel `#tab-panel-<nombre>`. Para agregar una sección nueva: un botón en el menú, un `div#tab-panel-<nombre>` y, si es solo para administradores, la clase `admin-only-tab hidden`. Las fuentes del panel (Cormorant Garamond y Jost, libres) están en `assets/fonts/` y se declaran en `assets/css/admin-fonts.css`; el landing usa `fonts.css`. Si cambias un `.css`/`.js`/fuente, sube el `?v=` (ver abajo).

## Clientes interesados (leads)

El formulario "Quiero que me contacten" de la ficha de propiedad guarda contactos en `property_leads` mediante la función `submit_property_lead` (el visitante nunca escribe en la tabla). Para activarlo, corre [`supabase/leads.sql`](supabase/leads.sql) en Supabase → SQL Editor (es seguro volver a correrlo; también está al final de `schema.sql`). Cada agente ve solo los clientes de sus propiedades; los administradores ven todos, incluidos los de propiedades sin asignar. **Antes de publicar el formulario, valida con asesoría legal el texto de consentimiento y tu política de privacidad.**

## Comisiones (cobranzas)

La pestaña "Comisiones" lee la tabla `collections`. Para activarla, corre [`supabase/collections.sql`](supabase/collections.sql) en Supabase → SQL Editor (es seguro volver a correrlo; también está al final de `schema.sql`). Solo los administradores cargan, editan y eliminan cobranzas; cada agente ve únicamente las suyas. Los porcentajes y montos los define el administrador en cada cobranza: el sistema no aplica ninguna política de honorarios.

## Política de privacidad

La página pública es `privacidad.html` (estilos en `assets/css/legal.css`). Está enlazada desde el pie del landing, el formulario "Quiero que me contacten" y la solicitud de cuenta de agente. Si cambias qué datos recoge el sitio (formularios, analítica, proveedores), actualiza esa página y su fecha de última actualización, y valídala con asesoría legal.

## Páginas del sitio

`index.html` (inicio con vista previa de propiedades), `marketplace.html` (Marketplace Inmobiliario completo, con filtros), `privacidad.html` (política de privacidad) y `admin/` (panel). El inicio y el Marketplace comparten `assets/js/main.js` y `assets/css/style.css`. `marketplace.html` repite a mano el menú, el pie y las ventanas de `index.html`: si cambias uno, actualiza el otro.

## Contrato de Exclusividad (herramienta del panel)

Para activarla corre [`supabase/contracts.sql`](supabase/contracts.sql) en Supabase → SQL Editor (es seguro volver a correrlo; también está al final de `schema.sql`). Cada contrato generado descuenta los créditos que indique `credit_tool_prices` (`contrato_exclusividad`, hoy 5): para cambiar el precio, un administrador edita esa fila (`update credit_tool_prices set cost = 7 where code = 'contrato_exclusividad';`). El texto legal está en `assets/contracts/exclusividad-v1.md`: **cualquier cambio de redacción debe hacerlo y aprobarlo un abogado**; si cambias una cláusula de un contrato ya emitido, crea una versión nueva (`exclusividad-v2.md`) en lugar de editar la v1, para no alterar el texto de contratos ya generados. Los contratos se verifican en `verificar.html`. Pruebas: ver `tests/README.md`.

## Publicaciones gratis y costo por propiedad

Para activar la regla corre [`supabase/publications.sql`](supabase/publications.sql) en Supabase → SQL Editor (es seguro volver a correrlo; también está al final de `schema.sql`). Cada agente tiene 3 propiedades gratis por mes (se renuevan el día 1, hora de Bolivia, y no se acumulan); después cada propiedad nueva cuesta 8 créditos. Para cambiar los números: `update app_settings set value = 5 where key = 'free_publications_per_month';` y `update app_settings set value = 10 where key = 'publication_cost_credits';`. Los administradores no pagan. Borrar una propiedad no devuelve el cupo ni los créditos.

**Vigencia y renovación.** Toda publicación (gratis o de pago) dura **30 días** desde que se crea (`app_settings.publication_validity_days`). Al vencer **se oculta del sitio público**, pero el agente la sigue viendo en su panel como "Vencida" con el botón **Renovar**. Renovar cuesta igual que publicar: primero usa una gratis del mes y, si no quedan, 8 créditos; si aún no vencía, suma 30 días al vencimiento actual, y si ya venció cuenta 30 días desde hoy. Cada tarjeta del panel muestra la **cuenta regresiva** y un interruptor de **renovación automática** (también en el formulario): se renueva sola 1 hora antes de vencer con la misma regla; si no alcanza el saldo no cobra nada, la publicación vence y queda marcada con un aviso. Las propiedades que ya existían reciben 30 días desde que se corre el SQL. La renovación automática la dispara el sitio (landing y panel, `process_auto_renewals()`, máximo una corrida cada 5 minutos) y, si Supabase tiene la extensión `pg_cron`, también un programador cada 10 minutos (el SQL lo activa solo si está disponible).

## "Vender mi inmueble" (propietarios)

El botón **Vender mi inmueble** del landing abre un formulario con los datos del propietario, los del inmueble, la ubicación en el mapa y los documentos de respaldo (o la opción "no tengo documentos / necesito apoyo legal"). Para activarlo corre [`supabase/sell-requests.sql`](supabase/sell-requests.sql) en Supabase → SQL Editor (es seguro volver a correrlo; también está al final de `schema.sql`). Crea la tabla `sell_requests`, la función `submit_sell_request` (única puerta de entrada, con validaciones y límite de 3 envíos por teléfono cada 24 h) y la carpeta privada `sell-documents` de Storage (10 MB por archivo; PDF, JPG, PNG o WEBP). Los administradores ven las solicitudes en la pestaña **Propietarios** del panel (estado, notas, WhatsApp, ubicación y documentos con enlace temporal de 10 minutos). El mapa usa Leaflet con mosaicos de OpenStreetMap (oscurecidos por CSS, sin clave) y búsqueda de direcciones de OpenStreetMap (Nominatim); no requiere claves.

## Pantalla "Instalar app"

Los botones "Instalar app" del menú llevan a `app.html` (mockups de la versión móvil, ventajas para usuarios y agentes, y botones de descarga para Android y iPhone/iPad). No requiere SQL ni claves. La instalación es la de una app web (PWA): usa `manifest.json` y `sw.js` de la raíz del sitio; para cambiar el ícono o el nombre de la app edita `manifest.json` (íconos en `assets/img/uno-app-192.png` y `uno-app-512.png`). Para actualizar los textos o las maquetas edita `app.html` y `assets/css/app.css`.

## Precio en dólares o bolivianos

Cada propiedad puede tener su precio en **USD** (por defecto) o en **bolivianos (Bs.-)**: se elige en el formulario con "Moneda del precio". Para activarlo corre [`supabase/property-currency.sql`](supabase/property-currency.sql) en Supabase → SQL Editor (es seguro volver a correrlo; también está al final de `schema.sql`). Las propiedades que ya existían quedan en USD. En bolivianos no se pide tipo de cambio. El filtro de presupuesto del landing está en dólares; las propiedades en bolivianos se convierten con el tipo de cambio oficial de 6,96 (constante `BOB_PER_USD` al inicio de la sección de presupuesto en `assets/js/main.js`).

## 6. Publicar el sitio

El sitio se publica desde GitHub (`inmobiliariabastet/bastet`, rama `main`) con la integración de **Hostinger** → https://bastet.uno. No requiere build ni Node: son archivos HTML/CSS/JS servidos tal cual. `/admin` tiene `noindex, nofollow`.

**Importante:** Hostinger guarda en caché los `.js`/`.css` por 7 días. Cada vez que cambies uno, sube el número de versión `?v=` de sus `<link>`/`<script>` en `index.html` y `admin/index.html` (ver HANDOFF.md).

## Estructura del proyecto

```
index.html                          → landing pública
admin/index.html                    → panel de administración (admin y agentes)
assets/css/fonts.css + assets/fonts → tipografías del Brand Book (Conso, Cabinet Grotesk)
assets/css/style.css                → estilos del landing
assets/css/admin.css                → estilos del panel
assets/js/supabase-config.js        → credenciales de Supabase (editar aquí)
assets/js/bolivia-cities.js         → lista de ciudades de Bolivia (landing + panel)
assets/js/property-fields.js        → código BST-xxxx, tipos, operaciones y características (landing + panel)
assets/js/password-toggle.js        → botón para ver/ocultar contraseñas
assets/js/main.js                   → lógica del landing (carrusel 3D, filtros, ficha, WhatsApp, acceso agentes, efecto arena)
assets/js/admin.js                  → lógica del panel (auth, propiedades, analítica, marcas, testimonios, usuarios, solicitudes, mi cuenta)
supabase/schema.sql                 → esquema de base de datos + políticas + buckets (idempotente)
supabase/functions/invite-admin/    → Edge Function para invitar usuarios (paso 5)
supabase/email-templates/           → plantillas de correo en español (paso 3)
```

## Cómo funciona

- El landing solo muestra propiedades con `status = 'available'`, ordenadas por `sort_order`, y se pueden filtrar por operación, tipo, habitaciones, baños, presupuesto y ciudad.
- Cada propiedad tiene un código `BST-xxxx` asignado por la base de datos; el mensaje de WhatsApp (desde la ficha o desde la foto del agente en la tarjeta) empieza con ese código.
- La cinta de logos de auspiciadores va justo debajo del carrusel de propiedades y se alimenta de la tabla `partners` (pestaña **Marcas**).
- **Roles:** un **administrador** ve y gestiona todo (propiedades, marcas, testimonios, usuarios, solicitudes). Un **agente** solo ve/crea/edita sus propias propiedades, su analítica y "Mi cuenta"; no puede destacar propiedades ni reordenar (protegido también en la base de datos).
- Un administrador puede **desactivar** o **eliminar** usuarios desde **Usuarios**; al eliminar, sus propiedades quedan "Sin asignar" (no se borran).
- Cualquier persona puede entrar con **Acceder con cuenta** (solo Google): la cuenta se crea sola como agente activo con su prueba gratuita; no hay solicitudes ni aprobación. Los planes (Propietario, Agente, Empresa) se pagan con comprobante y un admin los confirma en **Pagos**.
- Al eliminar una propiedad, un logo o una foto, también se borra el archivo del bucket de Storage.

**Regalo de créditos en el historial.** Para que el historial de compras muestre "400 + 40 de regalo", corre [`supabase/credit-pack-ledger.sql`](supabase/credit-pack-ledger.sql) en Supabase → SQL Editor (es seguro volver a correrlo; también está al final de `schema.sql`). Solo cambia el texto de los movimientos nuevos.

## Estado vigente (2026-10-17): léelo antes de seguir esta guía

Esta guía se escribió al inicio del proyecto y describe la puesta en marcha desde cero; **algunas partes ya no aplican** (invitaciones por correo y Edge Function `invite-admin`, solicitudes de agentes, créditos). El estado real, los SQL que ya están corridos, las reglas de caché, los tests y las trampas conocidas están en **`HANDOFF.md` → «ESTADO ACTUAL Y GUÍA DE ARRANQUE»**.

**Para una instalación nueva, orden de SQL** (SQL Editor, cada archivo es idempotente): `schema.sql` (ya incluye todos los bloques acumulados hasta `stay-availability.sql`) y después, solo si hace falta correr uno suelto, el `.sql` correspondiente de `supabase/`. Los créditos fueron eliminados (`drop-credits.sql`): los archivos `credits-bs.sql` y `credit-pack-ledger.sql` son históricos.
