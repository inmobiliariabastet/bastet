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
4. Entra a `https://bastet.uno/admin/`. Desde ahí, los demás usuarios se invitan en la pestaña **Usuarios** o se aprueban en **Solicitudes**.

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
- Los visitantes pueden pedir una cuenta de agente desde **Acceso agentes → Quiero una cuenta**; la solicitud llega a la pestaña **Solicitudes**, donde el admin la aprueba (envía la invitación) o la rechaza.
- Al eliminar una propiedad, un logo o una foto, también se borra el archivo del bucket de Storage.
