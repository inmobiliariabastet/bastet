-- Bastet Propiedades — esquema de base de datos
-- Ejecutar completo en Supabase: Dashboard > SQL Editor > New query > Run
-- Es seguro volver a ejecutar este archivo completo las veces que haga falta.

-- ── Tabla properties ─────────────────────────────────────────────
create table if not exists public.properties (
  id           uuid primary key default gen_random_uuid(),
  title        text not null,
  location     text not null,
  price        text not null, -- siempre expresado en USD
  exchange_rate text, -- tipo de cambio USD→Bs aceptado por el vendedor (opcional, texto libre)
  area         text not null,
  rooms        text not null,
  baths        text not null,
  description  text not null default '',
  photos       text[] not null default '{}',
  address      text, -- dirección exacta (calle/zona), sincronizada con el mapa del panel; location sigue siendo solo la ciudad
  whatsapp     text, -- WhatsApp del agente, público: si es NULL, el landing usa el número general de la firma
  owner_whatsapp text, -- WhatsApp del propietario del inmueble; privado, solo visible en el panel admin (nunca en el landing)
  owner_id     uuid references auth.users(id) on delete set null, -- quién creó/es dueño de la propiedad
  featured     boolean not null default false, -- solo un administrador puede marcarla (ver trigger más abajo); aparece más veces en el carrusel
  sort_order   integer not null default 0,
  status       text not null default 'available' check (status in ('available', 'sold')),
  created_at   timestamptz not null default now()
);

-- Si la tabla ya existía de una versión anterior del esquema, agrega las columnas nuevas.
alter table public.properties add column if not exists whatsapp text;
alter table public.properties add column if not exists owner_id uuid references auth.users(id) on delete set null;
alter table public.properties add column if not exists featured boolean not null default false;
alter table public.properties add column if not exists address text;
alter table public.properties add column if not exists exchange_rate text;
alter table public.properties add column if not exists owner_whatsapp text;

-- Código de referencia y características (2026-09-24).
-- code_number: número correlativo que asigna la base (se muestra como "BST-1001");
-- "generated always" impide que alguien lo cambie o lo repita a mano. Al agregarse,
-- las propiedades existentes también reciben su número.
alter table public.properties add column if not exists code_number integer generated always as identity (start with 1001);
create unique index if not exists properties_code_number_idx on public.properties (code_number);
alter table public.properties add column if not exists property_type text check (property_type in ('casa', 'departamento', 'terreno'));
alter table public.properties add column if not exists operation text check (operation in ('venta', 'alquiler', 'anticretico'));
alter table public.properties add column if not exists floors smallint check (floors between 1 and 50);
alter table public.properties add column if not exists has_garage boolean;
alter table public.properties add column if not exists garage_spots smallint check (garage_spots between 0 and 50);
alter table public.properties add column if not exists has_storage boolean; -- baulera
alter table public.properties add column if not exists pets_allowed boolean;
alter table public.properties add column if not exists kids_allowed boolean;

create index if not exists properties_sort_order_idx on public.properties (sort_order);
create index if not exists properties_status_idx on public.properties (status);
create index if not exists properties_owner_id_idx on public.properties (owner_id);

-- ── Tabla profiles (rol y estado de cada usuario) ────────────────
-- Todo usuario de Supabase Auth (admin creado a mano, o agente invitado)
-- obtiene automáticamente una fila aquí vía el trigger de abajo.
create table if not exists public.profiles (
  id          uuid primary key references auth.users(id) on delete cascade,
  email       text,
  role        text not null default 'agent' check (role in ('admin', 'agent')),
  is_active   boolean not null default true,
  display_name   text, -- nombre público del agente, se muestra en las tarjetas del carrusel
  avatar_url     text, -- foto de perfil / logo, público
  facebook_url   text,
  instagram_url  text,
  tiktok_url     text,
  created_at  timestamptz not null default now()
);

alter table public.profiles add column if not exists display_name text;
alter table public.profiles add column if not exists avatar_url text;
alter table public.profiles add column if not exists facebook_url text;
alter table public.profiles add column if not exists instagram_url text;
alter table public.profiles add column if not exists tiktok_url text;

-- Crea automáticamente el profile de cualquier usuario nuevo (admin o agente).
-- Seguridad: solo nace activo quien llegó por invitación (invited_at no nulo,
-- vía la Edge Function invite-admin). Cualquier cuenta creada por otra vía
-- (p. ej. alguien llamando directo a /auth/v1/signup con la anon key) nace
-- DESACTIVADA: el panel la desloguea y RLS no le deja tocar nada hasta que un
-- admin la reactive en "Usuarios".
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles (id, email, role, is_active)
  values (new.id, new.email, 'agent', new.invited_at is not null)
  on conflict (id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- Crea el profile de cualquier usuario que ya existiera antes de correr esto.
insert into public.profiles (id, email, role)
select id, email, 'agent' from auth.users
on conflict (id) do nothing;

-- ⚠️ IMPORTANTE: ajusta esta lista con los correos que deben ser administradores
-- (acceso total: todas las propiedades, Marcas, Administradores). Cualquier
-- otro usuario queda como 'agent' (solo ve/edita sus propias propiedades).
update public.profiles set role = 'admin'
where email in ('kunabox14@gmail.com', 'laboratoriovisnity@gmail.com');

-- ── Funciones helper de permisos (usadas en las políticas RLS) ───
create or replace function public.is_admin()
returns boolean
language sql
security definer
stable
set search_path = public
as $$
  select exists (
    select 1 from public.profiles
    where id = auth.uid() and role = 'admin' and is_active = true
  );
$$;

create or replace function public.is_active_user()
returns boolean
language sql
security definer
stable
set search_path = public
as $$
  select coalesce((select is_active from public.profiles where id = auth.uid()), false);
$$;

-- Evita que un agente marque sus propias propiedades como "destacadas".
create or replace function public.protect_featured_column()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_admin() and new.featured is distinct from old.featured then
    new.featured := old.featured;
  end if;
  return new;
end;
$$;

drop trigger if exists protect_featured on public.properties;
create trigger protect_featured
  before update on public.properties
  for each row execute function public.protect_featured_column();

-- Evita que un agente se autopromueva a admin o se reactive editando su propio
-- perfil (la pestaña "Mi cuenta" ahora permite auto-editar nombre/avatar/redes).
create or replace function public.protect_profile_privileged_columns()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_admin() then
    new.role := old.role;
    new.is_active := old.is_active;
    new.email := old.email;
  end if;
  -- Desde 2026-09-29 no se crean administradores nuevos desde la app: el rol
  -- solo se cambia desde el SQL Editor (auth.uid() es null ahí).
  if auth.uid() is not null then
    new.role := old.role;
  end if;
  return new;
end;
$$;

drop trigger if exists protect_profile_privileged on public.profiles;
create trigger protect_profile_privileged
  before update on public.profiles
  for each row execute function public.protect_profile_privileged_columns();

-- ── RLS: properties ───────────────────────────────────────────────
alter table public.properties enable row level security;

-- El landing público solo puede leer propiedades disponibles
drop policy if exists "public can read available properties" on public.properties;
create policy "public can read available properties"
  on public.properties for select
  to anon
  using (status = 'available');

-- Nota: owner_whatsapp (teléfono privado del propietario del inmueble, no del agente)
-- no se restringe a nivel de columna aquí a propósito: "select *" bajo RLS de fila
-- requiere permiso sobre todas las columnas, así que revocarlo rompería el landing
-- público entero. En su lugar, main.js pide explícitamente solo las columnas públicas
-- (sin owner_whatsapp) al consultar propiedades como "anon" — ver loadProperties().

-- Un usuario activo (admin o agente) puede leer todo (incluye owner_whatsapp,
-- el teléfono privado del propietario). Una sesión desactivada o no invitada
-- solo ve lo mismo que un visitante anónimo: propiedades disponibles.
drop policy if exists "authenticated can read all properties" on public.properties;
create policy "authenticated can read all properties"
  on public.properties for select
  to authenticated
  using (public.is_active_user() or status = 'available');

-- Un agente activo solo puede crear propiedades a su propio nombre; un admin también
drop policy if exists "authenticated can insert properties" on public.properties;
drop policy if exists "authenticated can insert own properties" on public.properties;
create policy "owner can insert own properties"
  on public.properties for insert
  to authenticated
  with check (owner_id = auth.uid() and public.is_active_user());

-- Solo el dueño (si está activo) o un admin pueden editar
drop policy if exists "authenticated can update properties" on public.properties;
drop policy if exists "owner or admin can update properties" on public.properties;
create policy "owner or admin can update properties"
  on public.properties for update
  to authenticated
  using ((owner_id = auth.uid() and public.is_active_user()) or public.is_admin())
  with check ((owner_id = auth.uid() and public.is_active_user()) or public.is_admin());

-- Solo el dueño (si está activo) o un admin pueden borrar
drop policy if exists "authenticated can delete properties" on public.properties;
drop policy if exists "owner or admin can delete properties" on public.properties;
create policy "owner or admin can delete properties"
  on public.properties for delete
  to authenticated
  using ((owner_id = auth.uid() and public.is_active_user()) or public.is_admin());

-- ── Tabla property_events (analítica: vistas y clics a WhatsApp) ──
-- Sin datos personales ni de sesión: solo cuenta eventos anónimos por propiedad.
create table if not exists public.property_events (
  id           uuid primary key default gen_random_uuid(),
  property_id  uuid not null references public.properties(id) on delete cascade,
  event_type   text not null check (event_type in ('view', 'whatsapp_click')),
  created_at   timestamptz not null default now()
);

create index if not exists property_events_property_id_idx on public.property_events (property_id);
create index if not exists property_events_created_at_idx on public.property_events (created_at);

alter table public.property_events enable row level security;

-- Cualquier visitante (incluso anónimo) puede registrar un evento; no puede leer ni modificar ninguno.
drop policy if exists "anyone can insert property events" on public.property_events;
create policy "anyone can insert property events"
  on public.property_events for insert
  to anon, authenticated
  with check (true);

-- Solo el dueño de la propiedad (o un admin) puede leer sus propias estadísticas.
drop policy if exists "owner or admin can read property events" on public.property_events;
create policy "owner or admin can read property events"
  on public.property_events for select
  to authenticated
  using (
    public.is_admin() or exists (
      select 1 from public.properties p
      where p.id = property_id and p.owner_id = auth.uid()
    )
  );

-- ── RLS: profiles ─────────────────────────────────────────────────
alter table public.profiles enable row level security;

drop policy if exists "users can read own profile" on public.profiles;
create policy "users can read own profile"
  on public.profiles for select
  to authenticated
  using (id = auth.uid());

drop policy if exists "admin can read all profiles" on public.profiles;
create policy "admin can read all profiles"
  on public.profiles for select
  to authenticated
  using (public.is_admin());

drop policy if exists "admin can update profiles" on public.profiles;
create policy "admin can update profiles"
  on public.profiles for update
  to authenticated
  using (public.is_admin())
  with check (public.is_admin());

-- Cualquier usuario activo puede editar su propio perfil (nombre, avatar, redes);
-- el trigger protect_profile_privileged de arriba bloquea que toque role/is_active/email.
drop policy if exists "users can update own profile" on public.profiles;
create policy "users can update own profile"
  on public.profiles for update
  to authenticated
  using (id = auth.uid())
  with check (id = auth.uid());

-- El landing público necesita el nombre/avatar/redes del agente para mostrarlos
-- en cada tarjeta del carrusel. Se restringe a esas columnas públicas nada más
-- (nunca email) mediante grants de columna, ya que RLS solo filtra filas.
drop policy if exists "public can read active agent public info" on public.profiles;
create policy "public can read active agent public info"
  on public.profiles for select
  to anon
  using (is_active = true);

revoke select on public.profiles from anon;
grant select (id, display_name, avatar_url, facebook_url, instagram_url, tiktok_url) on public.profiles to anon;

-- ── Storage: bucket de fotos de perfil / logo de agentes ─────────
insert into storage.buckets (id, name, public)
values ('agent-avatars', 'agent-avatars', true)
on conflict (id) do nothing;

drop policy if exists "public can view agent avatars" on storage.objects;
create policy "public can view agent avatars"
  on storage.objects for select
  to public
  using (bucket_id = 'agent-avatars');

drop policy if exists "users can upload own avatar" on storage.objects;
create policy "users can upload own avatar"
  on storage.objects for insert
  to authenticated
  with check (bucket_id = 'agent-avatars' and public.is_active_user());

drop policy if exists "users can update own avatar" on storage.objects;
create policy "users can update own avatar"
  on storage.objects for update
  to authenticated
  using (bucket_id = 'agent-avatars' and public.is_active_user());

drop policy if exists "users can delete own avatar" on storage.objects;
create policy "users can delete own avatar"
  on storage.objects for delete
  to authenticated
  using (bucket_id = 'agent-avatars' and public.is_active_user());

-- ── Storage: bucket de fotos de propiedades ─────────────────────
-- Cualquier autenticado activo puede subir/editar fotos (la propiedad a la que
-- se asocian ya está protegida por su propia política de owner_id arriba).
insert into storage.buckets (id, name, public)
values ('property-photos', 'property-photos', true)
on conflict (id) do nothing;

drop policy if exists "public can view property photos" on storage.objects;
create policy "public can view property photos"
  on storage.objects for select
  to public
  using (bucket_id = 'property-photos');

drop policy if exists "authenticated can upload property photos" on storage.objects;
create policy "authenticated can upload property photos"
  on storage.objects for insert
  to authenticated
  with check (bucket_id = 'property-photos' and public.is_active_user());

drop policy if exists "authenticated can update property photos" on storage.objects;
create policy "authenticated can update property photos"
  on storage.objects for update
  to authenticated
  using (bucket_id = 'property-photos' and public.is_active_user());

drop policy if exists "authenticated can delete property photos" on storage.objects;
create policy "authenticated can delete property photos"
  on storage.objects for delete
  to authenticated
  using (bucket_id = 'property-photos' and public.is_active_user());

-- ── Tabla partners (logos de empresas aliadas, franja del landing) ──
-- Solo administradores gestionan las marcas de la firma (los agentes no).
create table if not exists public.partners (
  id           uuid primary key default gen_random_uuid(),
  name         text not null default '',
  logo_url     text not null,
  url          text, -- sitio web de la marca; si está, el logo es clickeable en el landing
  sort_order   integer not null default 0,
  created_at   timestamptz not null default now()
);

alter table public.partners add column if not exists url text;

create index if not exists partners_sort_order_idx on public.partners (sort_order);

alter table public.partners enable row level security;

drop policy if exists "public can read partners" on public.partners;
create policy "public can read partners"
  on public.partners for select
  to anon
  using (true);

drop policy if exists "authenticated can read all partners" on public.partners;
create policy "authenticated can read all partners"
  on public.partners for select
  to authenticated
  using (true);

drop policy if exists "authenticated can insert partners" on public.partners;
drop policy if exists "admin can insert partners" on public.partners;
create policy "admin can insert partners"
  on public.partners for insert
  to authenticated
  with check (public.is_admin());

drop policy if exists "authenticated can update partners" on public.partners;
drop policy if exists "admin can update partners" on public.partners;
create policy "admin can update partners"
  on public.partners for update
  to authenticated
  using (public.is_admin())
  with check (public.is_admin());

drop policy if exists "authenticated can delete partners" on public.partners;
drop policy if exists "admin can delete partners" on public.partners;
create policy "admin can delete partners"
  on public.partners for delete
  to authenticated
  using (public.is_admin());

-- ── Storage: bucket de logos de empresas aliadas ─────────────────
insert into storage.buckets (id, name, public)
values ('partner-logos', 'partner-logos', true)
on conflict (id) do nothing;

drop policy if exists "public can view partner logos" on storage.objects;
create policy "public can view partner logos"
  on storage.objects for select
  to public
  using (bucket_id = 'partner-logos');

drop policy if exists "authenticated can upload partner logos" on storage.objects;
drop policy if exists "admin can upload partner logos" on storage.objects;
create policy "admin can upload partner logos"
  on storage.objects for insert
  to authenticated
  with check (bucket_id = 'partner-logos' and public.is_admin());

drop policy if exists "authenticated can update partner logos" on storage.objects;
drop policy if exists "admin can update partner logos" on storage.objects;
create policy "admin can update partner logos"
  on storage.objects for update
  to authenticated
  using (bucket_id = 'partner-logos' and public.is_admin());

drop policy if exists "authenticated can delete partner logos" on storage.objects;
drop policy if exists "admin can delete partner logos" on storage.objects;
create policy "admin can delete partner logos"
  on storage.objects for delete
  to authenticated
  using (bucket_id = 'partner-logos' and public.is_admin());

-- ── Tabla testimonials (testimonios de clientes, franja del landing) ──
-- Solo administradores gestionan los testimonios (los agentes no).
create table if not exists public.testimonials (
  id           uuid primary key default gen_random_uuid(),
  name         text not null,
  role_label   text not null default '', -- ej: "Vendió su departamento en La Paz con Bastet"
  quote        text not null,
  photo_url    text,
  sort_order   integer not null default 0,
  is_active    boolean not null default true,
  created_at   timestamptz not null default now()
);

create index if not exists testimonials_sort_order_idx on public.testimonials (sort_order);

alter table public.testimonials enable row level security;

drop policy if exists "public can read active testimonials" on public.testimonials;
create policy "public can read active testimonials"
  on public.testimonials for select
  to anon
  using (is_active = true);

drop policy if exists "authenticated can read all testimonials" on public.testimonials;
create policy "authenticated can read all testimonials"
  on public.testimonials for select
  to authenticated
  using (true);

drop policy if exists "admin can insert testimonials" on public.testimonials;
create policy "admin can insert testimonials"
  on public.testimonials for insert
  to authenticated
  with check (public.is_admin());

drop policy if exists "admin can update testimonials" on public.testimonials;
create policy "admin can update testimonials"
  on public.testimonials for update
  to authenticated
  using (public.is_admin())
  with check (public.is_admin());

drop policy if exists "admin can delete testimonials" on public.testimonials;
create policy "admin can delete testimonials"
  on public.testimonials for delete
  to authenticated
  using (public.is_admin());

-- ── Storage: bucket de fotos de testimonios ──────────────────────
insert into storage.buckets (id, name, public)
values ('testimonial-photos', 'testimonial-photos', true)
on conflict (id) do nothing;

drop policy if exists "public can view testimonial photos" on storage.objects;
create policy "public can view testimonial photos"
  on storage.objects for select
  to public
  using (bucket_id = 'testimonial-photos');

drop policy if exists "admin can upload testimonial photos" on storage.objects;
create policy "admin can upload testimonial photos"
  on storage.objects for insert
  to authenticated
  with check (bucket_id = 'testimonial-photos' and public.is_admin());

drop policy if exists "admin can update testimonial photos" on storage.objects;
create policy "admin can update testimonial photos"
  on storage.objects for update
  to authenticated
  using (bucket_id = 'testimonial-photos' and public.is_admin());

drop policy if exists "admin can delete testimonial photos" on storage.objects;
create policy "admin can delete testimonial photos"
  on storage.objects for delete
  to authenticated
  using (bucket_id = 'testimonial-photos' and public.is_admin());

-- Testimonios iniciales. Los uuid son fijos para que sea seguro volver a
-- correr este script sin duplicar filas. photo_url apunta a las imágenes
-- estáticas en assets/img/testimonials/ (no requieren Supabase Storage).
insert into public.testimonials (id, name, role_label, quote, photo_url, sort_order) values
  ('a1b2c3d4-0001-4000-8000-000000000001', 'María Elena Rojas', 'Vendió su departamento en La Paz con Bastet', 'Todo el proceso se sintió acompañado de principio a fin. Nunca tuve que preocuparme por los trámites, siempre supe en qué paso estábamos.', 'assets/img/testimonials/testi-05.jpg', 0),
  ('a1b2c3d4-0001-4000-8000-000000000002', 'Carlos Fernández', 'Compró su primera casa en Santa Cruz de la Sierra', 'Buscaba certeza más que rapidez, y eso fue exactamente lo que encontré. Cada documento fue revisado con una seriedad que me dio mucha tranquilidad.', 'assets/img/testimonials/testi-09.jpg', 1),
  ('a1b2c3d4-0001-4000-8000-000000000003', 'Familia Quispe Mamani', 'Vendieron su terreno en Cochabamba', 'Confiamos nuestro patrimonio familiar a Bastet y sentimos en cada momento que lo cuidaban como si fuera propio.', 'assets/img/testimonials/testi-06.jpg', 2),
  ('a1b2c3d4-0001-4000-8000-000000000004', 'Andrés Villarroel', 'Compró su departamento en El Alto', 'La claridad con la que me explicaron cada cláusula del contrato hizo toda la diferencia. Firmé sabiendo exactamente qué estaba adquiriendo.', 'assets/img/testimonials/testi-02.jpg', 3),
  ('a1b2c3d4-0001-4000-8000-000000000005', 'Familia Torrez Salazar', 'Vendieron su casa en Sucre', 'Un acompañamiento sereno y profesional. Los plazos que nos dieron al inicio se cumplieron tal cual se acordó.', 'assets/img/testimonials/testi-08.jpg', 4),
  ('a1b2c3d4-0001-4000-8000-000000000006', 'Daniela Ríos', 'Compró su oficina en Santa Cruz de la Sierra', 'Se nota la experiencia en cada detalle. Resolvieron dudas que ni yo sabía que tenía que hacerme antes de firmar.', 'assets/img/testimonials/testi-04.jpg', 5),
  ('a1b2c3d4-0001-4000-8000-000000000007', 'Familia Gutiérrez Paz', 'Vendieron su propiedad en Tarija', 'Nos sentimos protegidos durante toda la negociación, nunca presionados. Así es como debería sentirse vender algo tan importante.', 'assets/img/testimonials/testi-10.jpg', 6),
  ('a1b2c3d4-0001-4000-8000-000000000008', 'Jorge Luis Medina', 'Compró su casa en Oruro', 'La verificación registral que hicieron descubrió un detalle que yo jamás habría notado. Eso solo ya justificó la decisión de trabajar con ellos.', 'assets/img/testimonials/testi-01.jpg', 7),
  ('a1b2c3d4-0001-4000-8000-000000000009', 'Familia Choque Ibáñez', 'Vendieron su departamento en Potosí', 'Un equipo que realmente escucha. Adaptaron el proceso a nuestro ritmo sin nunca perder seriedad ni orden.', 'assets/img/testimonials/testi-03.jpg', 8),
  ('a1b2c3d4-0001-4000-8000-000000000010', 'Valeria Ontiveros', 'Compró su primer departamento en La Paz', 'Era mi primera compra y tenía muchas dudas. Me guiaron con una paciencia y una claridad que no esperaba encontrar.', 'assets/img/testimonials/testi-07.jpg', 9)
on conflict (id) do nothing;

-- ── Tabla agent_requests (solicitudes de cuenta de agentes desde el landing) ──
-- Un visitante anónimo llena el formulario "Solicitar cuenta" del botón
-- "Acceso agentes"; la solicitud llega aquí como 'pending' y un admin la
-- revisa en la pestaña "Solicitudes" del panel. El acceso se da manualmente
-- (invitando el correo desde "Usuarios"), no automáticamente.
create table if not exists public.agent_requests (
  id           uuid primary key default gen_random_uuid(),
  full_name    text not null check (char_length(full_name) between 3 and 120),
  email        text not null check (char_length(email) between 5 and 160 and email like '%@%'),
  whatsapp     text not null check (char_length(whatsapp) between 7 and 30),
  city         text check (char_length(city) <= 60),
  company      text check (char_length(company) <= 120),
  experience   text check (char_length(experience) <= 40),
  message      text check (char_length(message) <= 1000),
  status       text not null default 'pending' check (status in ('pending', 'approved', 'rejected')),
  created_at   timestamptz not null default now()
);

create index if not exists agent_requests_created_at_idx on public.agent_requests (created_at);

alter table public.agent_requests enable row level security;

-- Cualquiera puede enviar una solicitud, pero solo como 'pending'; no puede leer ninguna.
drop policy if exists "anyone can submit agent request" on public.agent_requests;
create policy "anyone can submit agent request"
  on public.agent_requests for insert
  to anon, authenticated
  with check (status = 'pending');

drop policy if exists "admin can read agent requests" on public.agent_requests;
create policy "admin can read agent requests"
  on public.agent_requests for select
  to authenticated
  using (public.is_admin());

drop policy if exists "admin can update agent requests" on public.agent_requests;
create policy "admin can update agent requests"
  on public.agent_requests for update
  to authenticated
  using (public.is_admin())
  with check (public.is_admin());

drop policy if exists "admin can delete agent requests" on public.agent_requests;
create policy "admin can delete agent requests"
  on public.agent_requests for delete
  to authenticated
  using (public.is_admin());

-- ── Eliminar usuarios desde el panel (pestaña Usuarios, ícono de basurero) ──
-- Borra la cuenta de Supabase Auth; su profile se borra en cascada y sus
-- propiedades quedan "Sin asignar" (owner_id -> null, no se pierden).
-- Security definer para poder tocar auth.users, pero solo lo ejecuta un admin
-- activo y nunca sobre su propia cuenta.
create or replace function public.admin_delete_user(target uuid)
returns void
language plpgsql
security definer
set search_path = public, auth
as $$
begin
  if not public.is_admin() then
    raise exception 'Solo un administrador puede eliminar usuarios.';
  end if;
  if target = auth.uid() then
    raise exception 'No puedes eliminar tu propia cuenta.';
  end if;
  delete from auth.users where id = target;
end;
$$;

revoke all on function public.admin_delete_user(uuid) from public, anon;
grant execute on function public.admin_delete_user(uuid) to authenticated;

-- =====================================================================
-- UNO · Créditos para agentes  (agregar al final de supabase/schema.sql)
-- Idempotente: se puede correr completo más de una vez.
-- Supone que existen: public.profiles(id = auth.users.id), public.properties,
-- public.is_admin() y public.is_active_user() (según HANDOFF.md).
-- =====================================================================

-- 1) Catálogo (precios editables por el admin, nunca se confían al navegador)
create table if not exists public.credit_packs (
  code        text primary key,
  name        text not null,
  credits     integer not null check (credits > 0),
  bonus       integer not null default 0 check (bonus >= 0),
  price_usd   numeric(10,2) not null check (price_usd >= 0),
  perks       text[] not null default '{}',
  highlighted boolean not null default false,
  active      boolean not null default true
);

create table if not exists public.credit_services (
  code   text primary key,
  name   text not null,
  cost   integer not null check (cost > 0),
  days   integer not null check (days > 0),
  active boolean not null default true
);

-- Valores de partida: AJUSTAR a los precios reales.
insert into public.credit_packs (code, name, credits, bonus, price_usd, perks, highlighted) values
  ('esencial',    'Esencial',    50,  0,  45,  array['Soporte por correo'], false),
  ('profesional', 'Profesional', 150, 10, 120, array['+10 créditos de regalo','Soporte prioritario'], true),
  ('exclusivo',   'Exclusivo',   400, 40, 290, array['+40 créditos de regalo','Gestor de cuenta dedicado'], false)
on conflict (code) do nothing;

insert into public.credit_services (code, name, cost, days) values
  ('destacar_7',  'Destacar propiedad · 7 días',  10, 7),
  ('destacar_30', 'Destacar propiedad · 30 días', 25, 30)
on conflict (code) do nothing;

-- 2) Saldo, historial y solicitudes de compra
create table if not exists public.credit_wallets (
  user_id    uuid primary key references public.profiles(id) on delete cascade,
  balance    integer not null default 0 check (balance >= 0),
  updated_at timestamptz not null default now()
);

create table if not exists public.credit_ledger (
  id          bigint generated always as identity primary key,
  user_id     uuid not null references public.profiles(id) on delete cascade,
  kind        text not null check (kind in ('purchase','spend','bonus','adjustment')),
  amount      integer not null check (amount <> 0),
  description text not null,
  created_by  uuid default auth.uid(),
  created_at  timestamptz not null default now()
);
create index if not exists credit_ledger_user_idx on public.credit_ledger (user_id, created_at desc);

-- property_id con el mismo tipo que properties.id (uuid o bigint), sin asumirlo.
do $$
declare t text;
begin
  select format_type(atttypid, atttypmod) into t
  from pg_attribute where attrelid = 'public.properties'::regclass and attname = 'id';
  execute format('alter table public.credit_ledger add column if not exists property_id %s', t);
end $$;

create table if not exists public.credit_requests (
  id          bigint generated always as identity primary key,
  user_id     uuid not null references public.profiles(id) on delete cascade,
  pack_code   text not null,
  pack_name   text not null,
  credits     integer not null,      -- créditos + bonificación, congelados al pedir
  price_usd   numeric(10,2) not null,
  method      text not null check (method in ('transferencia','qr','efectivo')),
  status      text not null default 'pending' check (status in ('pending','approved','rejected')),
  created_at  timestamptz not null default now(),
  resolved_at timestamptz,
  resolved_by uuid
);
create index if not exists credit_requests_status_idx on public.credit_requests (status, created_at desc);

-- 3) Destacado con vencimiento (no se toca la columna "featured" del admin)
alter table public.properties add column if not exists featured_until timestamptz;

-- Solo la función feature_property (o un admin) puede cambiar featured_until.
create or replace function public.protect_featured_until()
returns trigger language plpgsql as $$
begin
  if coalesce(current_setting('uno.credit_rpc', true), '') = '1' or public.is_admin() then
    return new;
  end if;
  if tg_op = 'INSERT' then
    new.featured_until := null;              -- un agente no puede crear una propiedad ya "destacada"
  elsif new.featured_until is distinct from old.featured_until then
    new.featured_until := old.featured_until;
  end if;
  return new;
end $$;

drop trigger if exists protect_featured_until on public.properties;
create trigger protect_featured_until
  before insert or update on public.properties
  for each row execute function public.protect_featured_until();

-- 4) RLS: lectura propia (o admin). Ninguna escritura directa desde el navegador.
alter table public.credit_packs    enable row level security;
alter table public.credit_services enable row level security;
alter table public.credit_wallets  enable row level security;
alter table public.credit_ledger   enable row level security;
alter table public.credit_requests enable row level security;

drop policy if exists credit_packs_read    on public.credit_packs;
drop policy if exists credit_packs_admin   on public.credit_packs;
drop policy if exists credit_services_read  on public.credit_services;
drop policy if exists credit_services_admin on public.credit_services;
drop policy if exists credit_wallets_read  on public.credit_wallets;
drop policy if exists credit_ledger_read   on public.credit_ledger;
drop policy if exists credit_requests_read on public.credit_requests;

create policy credit_packs_read     on public.credit_packs    for select to authenticated using (public.is_active_user());
create policy credit_packs_admin    on public.credit_packs    for all    to authenticated using (public.is_admin()) with check (public.is_admin());
create policy credit_services_read  on public.credit_services for select to authenticated using (public.is_active_user());
create policy credit_services_admin on public.credit_services for all    to authenticated using (public.is_admin()) with check (public.is_admin());
create policy credit_wallets_read   on public.credit_wallets  for select to authenticated using (user_id = auth.uid() or public.is_admin());
create policy credit_ledger_read    on public.credit_ledger   for select to authenticated using (user_id = auth.uid() or public.is_admin());
create policy credit_requests_read  on public.credit_requests for select to authenticated using (user_id = auth.uid() or public.is_admin());

revoke insert, update, delete on public.credit_wallets, public.credit_ledger, public.credit_requests from anon, authenticated;
revoke all on public.credit_packs, public.credit_services, public.credit_wallets, public.credit_ledger, public.credit_requests from anon;
grant select on public.credit_wallets, public.credit_ledger, public.credit_requests to authenticated;
grant select, insert, update, delete on public.credit_packs, public.credit_services to authenticated; -- las políticas limitan la escritura al admin

-- 5) Funciones (security definer): único camino para mover créditos.

-- 5a) El agente pide un pack. El precio y los créditos salen de credit_packs.
create or replace function public.request_credit_pack(p_pack text, p_method text)
returns bigint language plpgsql security definer set search_path = public as $$
declare pk public.credit_packs; rid bigint;
begin
  if auth.uid() is null or not public.is_active_user() then
    raise exception 'No autorizado' using errcode = '42501';
  end if;
  select * into pk from public.credit_packs where code = p_pack and active;
  if not found then raise exception 'Pack no disponible'; end if;
  if exists (select 1 from public.credit_requests where user_id = auth.uid() and status = 'pending') then
    raise exception 'Ya tienes una solicitud pendiente de confirmación';
  end if;
  insert into public.credit_requests (user_id, pack_code, pack_name, credits, price_usd, method)
  values (auth.uid(), pk.code, pk.name, pk.credits + pk.bonus, pk.price_usd, p_method)
  returning id into rid;
  return rid;
end $$;

-- 5b) El admin confirma el pago (acredita) o rechaza.
create or replace function public.admin_resolve_credit_request(p_id bigint, p_approve boolean)
returns void language plpgsql security definer set search_path = public as $$
declare rq public.credit_requests;
begin
  if not public.is_admin() then raise exception 'Solo administradores' using errcode = '42501'; end if;
  select * into rq from public.credit_requests where id = p_id and status = 'pending' for update;
  if not found then raise exception 'Solicitud no encontrada o ya resuelta'; end if;

  update public.credit_requests
     set status = case when p_approve then 'approved' else 'rejected' end,
         resolved_at = now(), resolved_by = auth.uid()
   where id = p_id;

  if p_approve then
    insert into public.credit_wallets (user_id, balance) values (rq.user_id, rq.credits)
    on conflict (user_id) do update set balance = public.credit_wallets.balance + excluded.balance, updated_at = now();
    insert into public.credit_ledger (user_id, kind, amount, description)
    values (rq.user_id, 'purchase', rq.credits, 'Pack ' || rq.pack_name || ' · ' || rq.method);
  end if;
end $$;

-- 5c) Bonos o ajustes manuales del admin (monto negativo = descuento).
create or replace function public.admin_grant_credits(p_user uuid, p_amount integer, p_description text)
returns integer language plpgsql security definer set search_path = public as $$
declare bal integer;
begin
  if not public.is_admin() then raise exception 'Solo administradores' using errcode = '42501'; end if;
  if p_amount = 0 then raise exception 'El monto no puede ser 0'; end if;
  insert into public.credit_wallets (user_id, balance) values (p_user, greatest(p_amount, 0))
  on conflict (user_id) do update set balance = public.credit_wallets.balance + p_amount, updated_at = now()
  returning balance into bal;   -- si queda negativo, el CHECK de la tabla aborta
  insert into public.credit_ledger (user_id, kind, amount, description)
  values (p_user, case when p_amount > 0 then 'bonus' else 'adjustment' end, p_amount,
          coalesce(nullif(trim(p_description), ''), 'Ajuste del administrador'));
  return bal;
end $$;

-- 5d) El agente gasta créditos en destacar SU propiedad.
create or replace function public.feature_property(p_property_id text, p_service text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  uid uuid := auth.uid();
  svc public.credit_services;
  prop record;
  bal integer;
  new_until timestamptz;
begin
  if uid is null or not public.is_active_user() then
    raise exception 'No autorizado' using errcode = '42501';
  end if;
  select * into svc from public.credit_services where code = p_service and active;
  if not found then raise exception 'Servicio no disponible'; end if;

  select p.id, p.owner_id, p.featured_until into prop
    from public.properties p where p.id::text = p_property_id for update;
  if not found or prop.owner_id is distinct from uid then
    raise exception 'Propiedad no encontrada';
  end if;

  update public.credit_wallets w set balance = w.balance - svc.cost, updated_at = now()
   where w.user_id = uid and w.balance >= svc.cost
   returning w.balance into bal;
  if not found then raise exception 'Saldo insuficiente'; end if;

  new_until := greatest(now(), coalesce(prop.featured_until, now())) + make_interval(days => svc.days);
  perform set_config('uno.credit_rpc', '1', true);
  update public.properties set featured_until = new_until where id = prop.id;
  insert into public.credit_ledger (user_id, kind, amount, description, property_id)
  values (uid, 'spend', -svc.cost, svc.name, prop.id);

  return jsonb_build_object('balance', bal, 'featured_until', new_until);
end $$;

revoke all on function public.request_credit_pack(text, text)            from public, anon;
revoke all on function public.admin_resolve_credit_request(bigint, boolean) from public, anon;
revoke all on function public.admin_grant_credits(uuid, integer, text)   from public, anon;
revoke all on function public.feature_property(text, text)               from public, anon;
grant execute on function public.request_credit_pack(text, text)            to authenticated;
grant execute on function public.admin_resolve_credit_request(bigint, boolean) to authenticated;
grant execute on function public.admin_grant_credits(uuid, integer, text)   to authenticated;
grant execute on function public.feature_property(text, text)               to authenticated;

-- =====================================================================
-- UNO · Clientes interesados (leads)   — agregar al final de supabase/schema.sql
-- Idempotente: se puede correr completo más de una vez.
-- Supone: public.properties (id uuid, owner_id, status), public.is_admin(), public.is_active_user().
-- El visitante NO escribe en la tabla: solo llama a submit_property_lead().
-- =====================================================================

create table if not exists public.property_leads (
  id          bigint generated always as identity primary key,
  property_id uuid not null references public.properties(id) on delete cascade,
  agent_id    uuid references auth.users(id) on delete set null, -- copia de properties.owner_id al crear; null = propiedad sin asignar (solo la ve un admin)
  full_name   text not null check (char_length(full_name) between 3 and 120),
  whatsapp    text not null check (whatsapp ~ '^\+?[0-9]{7,15}$'),
  message     text check (message is null or char_length(message) <= 500),
  consent     boolean not null check (consent),
  status      text not null default 'new' check (status in ('new','contacted','visit','closed','lost')),
  agent_notes text check (agent_notes is null or char_length(agent_notes) <= 2000),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create index if not exists property_leads_agent_idx    on public.property_leads (agent_id, status, created_at desc);
create index if not exists property_leads_property_idx on public.property_leads (property_id, whatsapp, created_at desc);
create index if not exists property_leads_created_idx  on public.property_leads (created_at desc);

-- 1) Alta desde el landing (anon y authenticated). Único camino de escritura para visitantes.
create or replace function public.submit_property_lead(
  p_property_id uuid, p_name text, p_whatsapp text, p_message text, p_consent boolean
) returns boolean
language plpgsql security definer set search_path = public as $$
declare
  prop   record;
  nm     text := btrim(coalesce(p_name, ''));
  ph     text := regexp_replace(coalesce(p_whatsapp, ''), '[\s().-]', '', 'g');
  msg    text := nullif(btrim(coalesce(p_message, '')), '');
begin
  if p_consent is not true then raise exception 'Debes aceptar que compartamos tus datos con el agente.'; end if;
  if char_length(nm) < 3 or char_length(nm) > 120 then raise exception 'Escribe tu nombre (entre 3 y 120 caracteres).'; end if;
  if ph !~ '^\+?[0-9]{7,15}$' then raise exception 'Escribe un número de WhatsApp válido (solo dígitos, con + si incluye código de país).'; end if;
  if msg is not null and char_length(msg) > 500 then raise exception 'El mensaje no puede pasar de 500 caracteres.'; end if;

  select id, owner_id into prop from public.properties where id = p_property_id and status = 'available';
  if not found then raise exception 'Esta propiedad ya no está disponible.'; end if;

  -- Límites contra abuso: 3 por mismo teléfono y propiedad en 24 h, 30 por propiedad al día y 500 en total al día.
  if (select count(*) from public.property_leads
       where property_id = prop.id and whatsapp = ph and created_at > now() - interval '24 hours') >= 3 then
    raise exception 'Ya recibimos tus solicitudes para esta propiedad. El agente te contactará pronto.';
  end if;
  if (select count(*) from public.property_leads
       where property_id = prop.id and created_at > now() - interval '24 hours') >= 30
     or (select count(*) from public.property_leads where created_at > now() - interval '24 hours') >= 500 then
    raise exception 'Hay muchas solicitudes en este momento. Inténtalo más tarde o escríbenos por WhatsApp.';
  end if;

  insert into public.property_leads (property_id, agent_id, full_name, whatsapp, message, consent)
  values (prop.id, prop.owner_id, nm, ph, msg, true);
  return true;
end $$;

revoke all on function public.submit_property_lead(uuid, text, text, text, boolean) from public;
grant execute on function public.submit_property_lead(uuid, text, text, text, boolean) to anon, authenticated;

-- 2) Solo cambian status y agent_notes; el resto queda congelado (la app nunca los edita).
create or replace function public.protect_property_lead_columns()
returns trigger language plpgsql as $$
begin
  if auth.uid() is not null then  -- desde el SQL Editor (auth.uid() nulo) se puede corregir cualquier dato
    new.property_id := old.property_id;
    new.agent_id    := old.agent_id;
    new.full_name   := old.full_name;
    new.whatsapp    := old.whatsapp;
    new.message     := old.message;
    new.consent     := old.consent;
    new.created_at  := old.created_at;
  end if;
  new.updated_at := now();
  return new;
end $$;

drop trigger if exists protect_property_lead_columns on public.property_leads;
create trigger protect_property_lead_columns
  before update on public.property_leads
  for each row execute function public.protect_property_lead_columns();

-- 3) RLS: cada agente ve y trabaja solo sus leads; el admin ve todos (incluidos los sin asignar).
alter table public.property_leads enable row level security;
drop policy if exists property_leads_read   on public.property_leads;
drop policy if exists property_leads_update on public.property_leads;
create policy property_leads_read on public.property_leads for select to authenticated
  using ((agent_id = auth.uid() and public.is_active_user()) or public.is_admin());
create policy property_leads_update on public.property_leads for update to authenticated
  using ((agent_id = auth.uid() and public.is_active_user()) or public.is_admin())
  with check ((agent_id = auth.uid() and public.is_active_user()) or public.is_admin());

-- Privilegios: anon no toca la tabla; authenticated solo lee y edita status / agent_notes. Nadie borra ni inserta directo.
revoke all on public.property_leads from anon, authenticated;
grant select on public.property_leads to authenticated;
grant update (status, agent_notes) on public.property_leads to authenticated;

-- =====================================================================
-- UNO · Cobranzas / comisiones   — agregar al final de supabase/schema.sql
-- Idempotente: se puede correr completo más de una vez.
-- Supone: public.properties (id uuid), public.is_admin(), public.is_active_user().
-- El sistema NO calcula honorarios por política: el admin carga cada cobranza (el % y el monto son suyos).
-- Escritura solo admin. Lectura: el agente solo las suyas; el admin todas.
-- =====================================================================

create table if not exists public.collections (
  id             bigint generated always as identity primary key,
  property_id    uuid references public.properties(id) on delete set null,   -- si se borra la propiedad, la cobranza se conserva
  agent_id       uuid references auth.users(id) on delete set null,          -- null = sin agente (solo la ve un admin)
  client_name    text not null check (char_length(client_name) between 1 and 160),
  operation      text not null check (operation in ('venta','alquiler','anticretico')),
  sale_price_usd numeric(14,2) not null check (sale_price_usd >= 0),
  commission_pct numeric(5,2) check (commission_pct is null or (commission_pct >= 0 and commission_pct <= 100)),
  commission_usd numeric(14,2) not null check (commission_usd >= 0),         -- se puede ingresar o calcular (venta × %), y el admin lo corrige
  status         text not null default 'pending' check (status in ('pending','in_process','paid')),
  due_date       date,
  paid_at        timestamptz,
  notes          text check (notes is null or char_length(notes) <= 2000),
  created_by     uuid default auth.uid(),
  created_at     timestamptz not null default now()
);
create index if not exists collections_agent_idx    on public.collections (agent_id, status, created_at desc);
create index if not exists collections_property_idx on public.collections (property_id);

-- paid_at sigue al estado (pagada = tiene fecha; cualquier otro estado la borra); created_by / created_at no se editan.
create or replace function public.collections_before_write()
returns trigger language plpgsql as $$
begin
  if tg_op = 'UPDATE' then
    new.created_by := old.created_by;
    new.created_at := old.created_at;
  end if;
  if new.status = 'paid' then
    new.paid_at := coalesce(new.paid_at, now());
  else
    new.paid_at := null;
  end if;
  return new;
end $$;

drop trigger if exists collections_before_write on public.collections;
create trigger collections_before_write
  before insert or update on public.collections
  for each row execute function public.collections_before_write();

alter table public.collections enable row level security;
drop policy if exists collections_read         on public.collections;
drop policy if exists collections_admin_insert on public.collections;
drop policy if exists collections_admin_update on public.collections;
drop policy if exists collections_admin_delete on public.collections;
create policy collections_read on public.collections for select to authenticated
  using ((agent_id = auth.uid() and public.is_active_user()) or public.is_admin());
create policy collections_admin_insert on public.collections for insert to authenticated with check (public.is_admin());
create policy collections_admin_update on public.collections for update to authenticated using (public.is_admin()) with check (public.is_admin());
create policy collections_admin_delete on public.collections for delete to authenticated using (public.is_admin());

revoke all on public.collections from anon;
grant select, insert, update, delete on public.collections to authenticated; -- las políticas limitan la escritura al admin

-- =====================================================================
-- UNO · Generador de contratos de exclusividad   — agregar al final de supabase/schema.sql
-- Idempotente: se puede correr completo más de una vez.
-- Supone: public.profiles, public.is_admin(), public.is_active_user() y el bloque de créditos
-- (credit_wallets / credit_ledger) ya aplicados. Cada contrato generado cuesta créditos (hoy 5).
-- El cobro es 100% del servidor: el navegador nunca envía el costo.
-- =====================================================================

-- 1) Precio de las herramientas (editable por un admin; el cliente solo lo lee para mostrarlo)
create table if not exists public.credit_tool_prices (
  code   text primary key,
  name   text not null,
  cost   integer not null check (cost > 0),
  active boolean not null default true
);
insert into public.credit_tool_prices (code, name, cost) values
  ('contrato_exclusividad', 'Contrato de exclusividad', 5)
on conflict (code) do nothing;

-- Los movimientos de créditos pueden referenciar el contrato que los originó
alter table public.credit_ledger add column if not exists contract_id uuid;

-- 2) Datos legales del agente (C.I., teléfono, registro): privados, solo del propio agente
create table if not exists public.agent_legal_profiles (
  user_id      uuid primary key references public.profiles(id) on delete cascade,
  ci           text check (ci is null or char_length(ci) <= 30),
  phone        text check (phone is null or char_length(phone) <= 30),
  registration text check (registration is null or char_length(registration) <= 60),
  updated_at   timestamptz not null default now()
);

-- 3) Contratos generados y numeración correlativa por año
create table if not exists public.exclusivity_contract_counters (
  year        integer primary key,
  last_number integer not null default 0
);

create table if not exists public.exclusivity_contracts (
  id               uuid primary key default gen_random_uuid(),
  agent_id         uuid references auth.users(id) on delete set null,
  contract_number  text not null unique,
  verification_code text not null unique,
  template_version text not null,
  data             jsonb not null,           -- copia fiel de los campos del formulario: el PDF se vuelve a generar desde aquí (gratis)
  credits_charged  integer not null,
  idempotency_key  text not null,
  created_at       timestamptz not null default now(),
  unique (agent_id, idempotency_key)
);
create index if not exists exclusivity_contracts_agent_idx on public.exclusivity_contracts (agent_id, created_at desc);

-- 4) RLS: cada agente ve solo sus contratos (el admin todos); nadie escribe directo desde el navegador
alter table public.credit_tool_prices          enable row level security;
alter table public.agent_legal_profiles        enable row level security;
alter table public.exclusivity_contract_counters enable row level security;
alter table public.exclusivity_contracts       enable row level security;

drop policy if exists credit_tool_prices_read   on public.credit_tool_prices;
drop policy if exists credit_tool_prices_admin  on public.credit_tool_prices;
drop policy if exists agent_legal_own_select    on public.agent_legal_profiles;
drop policy if exists agent_legal_own_insert    on public.agent_legal_profiles;
drop policy if exists agent_legal_own_update    on public.agent_legal_profiles;
drop policy if exists exclusivity_contracts_read on public.exclusivity_contracts;

create policy credit_tool_prices_read  on public.credit_tool_prices for select to authenticated using (public.is_active_user());
create policy credit_tool_prices_admin on public.credit_tool_prices for all    to authenticated using (public.is_admin()) with check (public.is_admin());
create policy agent_legal_own_select on public.agent_legal_profiles for select to authenticated using (user_id = auth.uid() and public.is_active_user());
create policy agent_legal_own_insert on public.agent_legal_profiles for insert to authenticated with check (user_id = auth.uid() and public.is_active_user());
create policy agent_legal_own_update on public.agent_legal_profiles for update to authenticated using (user_id = auth.uid() and public.is_active_user()) with check (user_id = auth.uid() and public.is_active_user());
create policy exclusivity_contracts_read on public.exclusivity_contracts for select to authenticated
  using ((agent_id = auth.uid() and public.is_active_user()) or public.is_admin());
-- (el contador no tiene políticas: solo lo toca la función security definer)

revoke all on public.credit_tool_prices, public.agent_legal_profiles, public.exclusivity_contract_counters, public.exclusivity_contracts from anon;
revoke insert, update, delete on public.exclusivity_contracts, public.exclusivity_contract_counters from authenticated;
revoke all on public.exclusivity_contract_counters from authenticated;
grant select on public.exclusivity_contracts to authenticated;
grant select on public.credit_tool_prices to authenticated;
grant insert, update on public.credit_tool_prices to authenticated;          -- las políticas limitan la escritura al admin
grant select, insert, update on public.agent_legal_profiles to authenticated;

-- 5) Validación del lado servidor (mismas reglas que el formulario; el costo y los números nunca vienen del cliente)
create or replace function public.validate_exclusivity_data(d jsonb)
returns void language plpgsql immutable as $$
declare
  k text;
  n numeric;
  txt text;
begin
  if d is null or jsonb_typeof(d) <> 'object' then raise exception 'Datos del contrato inválidos' using errcode = '22023'; end if;
  if pg_column_size(d) > 20000 then raise exception 'Los datos del contrato son demasiado extensos' using errcode = '22023'; end if;

  foreach k in array array[
    'propietario_nombre','propietario_ci','propietario_estado_civil','propietario_domicilio','propietario_telefono','propietario_email',
    'inmueble_tipo','inmueble_direccion','inmueble_zona','inmueble_ciudad','inmueble_departamento','inmueble_matricula',
    'agente_nombre','agente_ci','agente_telefono','agente_email','agencia_nombre','agencia_domicilio',
    'forma_pago','ciudad_firma','ciudad_jurisdiccion','fecha_inicio'
  ] loop
    txt := btrim(coalesce(d ->> k, ''));
    if txt = '' then raise exception 'Falta el dato obligatorio: %', k using errcode = '22023'; end if;
    if char_length(txt) > 300 then raise exception 'El dato % es demasiado largo', k using errcode = '22023'; end if;
  end loop;

  if (d ->> 'operacion') not in ('venta','alquiler','anticretico') then raise exception 'Operación inválida' using errcode = '22023'; end if;
  if (d ->> 'moneda') not in ('Bs','USD') then raise exception 'Moneda inválida' using errcode = '22023'; end if;
  if (d ->> 'propietario_email') !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'Correo del propietario inválido' using errcode = '22023'; end if;
  if (d ->> 'agente_email') !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'Correo del agente inválido' using errcode = '22023'; end if;
  if (d ->> 'propietario_ci') !~ '^[0-9]{4,10}([ -]?[0-9A-Za-z]{1,3})?$' then raise exception 'C.I. del propietario inválida' using errcode = '22023'; end if;
  if (d ->> 'agente_ci') !~ '^[0-9]{4,10}([ -]?[0-9A-Za-z]{1,3})?$' then raise exception 'C.I. del agente inválida' using errcode = '22023'; end if;
  if (d ->> 'fecha_inicio') !~ '^\d{4}-\d{2}-\d{2}$' then raise exception 'Fecha de inicio inválida' using errcode = '22023'; end if;
  perform (d ->> 'fecha_inicio')::date;

  foreach k in array array['precio','inmueble_sup_terreno'] loop
    begin n := (d ->> k)::numeric; exception when others then n := null; end;
    if n is null or n <= 0 or n > 100000000000 then raise exception 'El campo % debe ser un número mayor que 0', k using errcode = '22023'; end if;
  end loop;
  if nullif(d ->> 'precio_minimo', '') is not null then
    begin n := (d ->> 'precio_minimo')::numeric; exception when others then n := null; end;
    if n is null or n <= 0 then raise exception 'El precio mínimo debe ser mayor que 0' using errcode = '22023'; end if;
  end if;

  begin n := (d ->> 'plazo_dias')::numeric; exception when others then n := null; end;
  if n is null or n <> trunc(n) or n < 15 or n > 730 then raise exception 'El plazo debe ser de 15 a 730 días' using errcode = '22023'; end if;

  if (d ->> 'operacion') = 'alquiler' then
    begin n := (d ->> 'comision_meses')::numeric; exception when others then n := null; end;
    if n is null or n <= 0 or n > 24 then raise exception 'Los meses de honorarios deben ser mayores que 0' using errcode = '22023'; end if;
  else
    begin n := (d ->> 'comision_porcentaje')::numeric; exception when others then n := null; end;
    if n is null or n <= 0 or n > 100 then raise exception 'El porcentaje de honorarios debe estar entre 0 y 100' using errcode = '22023'; end if;
  end if;

  if coalesce((d ->> 'tiene_copropietario')::boolean, false) and (btrim(coalesce(d ->> 'copropietario_nombre','')) = '' or btrim(coalesce(d ->> 'copropietario_ci','')) = '') then
    raise exception 'Faltan los datos del copropietario' using errcode = '22023';
  end if;
  if coalesce((d ->> 'tiene_apoderado')::boolean, false) and (btrim(coalesce(d ->> 'apoderado_nombre','')) = '' or btrim(coalesce(d ->> 'apoderado_ci','')) = ''
      or btrim(coalesce(d ->> 'poder_numero','')) = '' or btrim(coalesce(d ->> 'poder_fecha','')) = '' or btrim(coalesce(d ->> 'poder_notaria','')) = '') then
    raise exception 'Faltan los datos del apoderado' using errcode = '22023';
  end if;
  if coalesce((d ->> 'con_gravamenes')::boolean, false) and btrim(coalesce(d ->> 'gravamenes_detalle','')) = '' then
    raise exception 'Describe el gravamen del inmueble' using errcode = '22023';
  end if;
end $$;

-- 6) Generar el contrato: cobra, numera y guarda en UNA transacción. Si algo falla, no se cobra nada.
create or replace function public.create_exclusivity_contract(p_data jsonb, p_idempotency_key text, p_template_version text default 'exclusividad-v1')
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  uid     uuid := auth.uid();
  key     text := btrim(coalesce(p_idempotency_key, ''));
  cost    integer;
  bal     integer;
  yr      integer;
  seq     integer;
  num     text;
  code    text;
  cid     uuid := gen_random_uuid();
  c       public.exclusivity_contracts;
  alphabet constant text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
begin
  if uid is null or not public.is_active_user() then
    raise exception 'No autorizado' using errcode = '42501';
  end if;
  if char_length(key) < 8 or char_length(key) > 80 then raise exception 'Llave de idempotencia inválida' using errcode = '22023'; end if;
  if p_template_version is distinct from 'exclusividad-v1' then raise exception 'Plantilla no disponible' using errcode = '22023'; end if;

  -- Dos peticiones simultáneas con la misma llave se ejecutan una detrás de otra
  perform pg_advisory_xact_lock(hashtext(uid::text || ':' || key));

  select * into c from public.exclusivity_contracts where agent_id = uid and idempotency_key = key;
  if found then
    select balance into bal from public.credit_wallets where user_id = uid;
    return jsonb_build_object('id', c.id, 'contract_number', c.contract_number, 'verification_code', c.verification_code,
                              'created_at', c.created_at, 'balance', coalesce(bal, 0), 'charged', false);
  end if;

  perform public.validate_exclusivity_data(p_data);

  select t.cost into cost from public.credit_tool_prices t where t.code = 'contrato_exclusividad' and t.active;
  if cost is null then raise exception 'Herramienta no disponible' using errcode = '22023'; end if;

  -- Descuento atómico: solo si alcanza el saldo (la fila queda bloqueada hasta el final de la transacción)
  update public.credit_wallets w set balance = w.balance - cost, updated_at = now()
   where w.user_id = uid and w.balance >= cost
   returning w.balance into bal;
  if not found then
    select balance into bal from public.credit_wallets where user_id = uid;
    raise exception 'Saldo insuficiente' using errcode = 'P0402', detail = 'balance=' || coalesce(bal, 0), hint = 'cost=' || cost;
  end if;

  yr := extract(year from ((now() at time zone 'UTC') - interval '4 hours'))::integer; -- hora de Bolivia (UTC-4, sin horario de verano)
  insert into public.exclusivity_contract_counters (year, last_number) values (yr, 1)
  on conflict (year) do update set last_number = public.exclusivity_contract_counters.last_number + 1
  returning last_number into seq;
  num := 'BST-CE-' || yr || '-' || lpad(seq::text, 4, '0');

  loop
    select string_agg(substr(alphabet, 1 + floor(random() * 32)::integer, 1), '') into code from generate_series(1, 8);
    exit when not exists (select 1 from public.exclusivity_contracts where verification_code = code);
  end loop;

  insert into public.exclusivity_contracts (id, agent_id, contract_number, verification_code, template_version, data, credits_charged, idempotency_key)
  values (cid, uid, num, code, p_template_version, p_data, cost, key)
  returning * into c;

  insert into public.credit_ledger (user_id, kind, amount, description, contract_id)
  values (uid, 'spend', -cost, 'Contrato de exclusividad ' || num, cid);

  return jsonb_build_object('id', c.id, 'contract_number', c.contract_number, 'verification_code', c.verification_code,
                            'created_at', c.created_at, 'balance', bal, 'charged', true);
end $$;

-- 7) Verificación pública: confirma que el contrato existe SIN mostrar datos del propietario
drop function if exists public.verify_exclusivity_contract(text);
create function public.verify_exclusivity_contract(p_code text)
returns table (contract_number text, created_at timestamptz, agent_name text, template_version text)
language sql security definer set search_path = public stable as $$
  select c.contract_number, c.created_at, coalesce(nullif(btrim(p.display_name), ''), 'Agente de Bastet'), c.template_version
    from public.exclusivity_contracts c
    left join public.profiles p on p.id = c.agent_id
   where c.verification_code = upper(btrim(coalesce(p_code, '')))
   limit 1;
$$;

revoke all on function public.validate_exclusivity_data(jsonb) from public, anon;
revoke all on function public.create_exclusivity_contract(jsonb, text, text) from public, anon;
revoke all on function public.verify_exclusivity_contract(text) from public;
grant execute on function public.create_exclusivity_contract(jsonb, text, text) to authenticated;
grant execute on function public.verify_exclusivity_contract(text) to anon, authenticated;

-- =====================================================================
-- UNO · Precios de los packs de créditos en BOLIVIANOS   — agregar al final de supabase/schema.sql
-- Idempotente: se puede correr completo más de una vez.
-- Regla: cada crédito comprado cuesta 4 Bs (50 créditos = 200 Bs). Los créditos de regalo (bonus) no se cobran.
-- Supone el bloque de créditos ya aplicado (credit_packs / credit_requests / request_credit_pack).
-- =====================================================================

-- Nueva columna de precio en bolivianos (la de dólares queda como histórico y ya no es obligatoria)
alter table public.credit_packs    add column if not exists price_bs numeric(10,2) check (price_bs is null or price_bs >= 0);
alter table public.credit_requests add column if not exists price_bs numeric(10,2) check (price_bs is null or price_bs >= 0);
alter table public.credit_packs    alter column price_usd drop not null;
alter table public.credit_requests alter column price_usd drop not null;

-- Precio de los packs actuales: 4 Bs por crédito comprado (solo donde todavía no tienen precio en Bs;
-- si después editas un precio a mano, volver a correr este archivo no lo pisa).
update public.credit_packs set price_bs = credits * 4 where price_bs is null;

-- La solicitud de compra congela el precio en Bs del pack (el navegador nunca envía el precio)
create or replace function public.request_credit_pack(p_pack text, p_method text)
returns bigint language plpgsql security definer set search_path = public as $$
declare pk public.credit_packs; rid bigint;
begin
  if auth.uid() is null or not public.is_active_user() then
    raise exception 'No autorizado' using errcode = '42501';
  end if;
  select * into pk from public.credit_packs where code = p_pack and active;
  if not found then raise exception 'Pack no disponible'; end if;
  if pk.price_bs is null then raise exception 'Pack sin precio'; end if;
  if exists (select 1 from public.credit_requests where user_id = auth.uid() and status = 'pending') then
    raise exception 'Ya tienes una solicitud pendiente de confirmación';
  end if;
  insert into public.credit_requests (user_id, pack_code, pack_name, credits, price_bs, method)
  values (auth.uid(), pk.code, pk.name, pk.credits + pk.bonus, pk.price_bs, p_method)
  returning id into rid;
  return rid;
end $$;

revoke all on function public.request_credit_pack(text, text) from public, anon;
grant execute on function public.request_credit_pack(text, text) to authenticated;

-- =====================================================================
-- UNO · Administración de contratos: anular un contrato   — agregar al final de supabase/schema.sql
-- Idempotente: se puede correr completo más de una vez.
-- Supone el bloque de contratos (contracts.sql) ya aplicado.
-- Anular NO borra nada ni devuelve créditos: el contrato queda marcado, la página pública de verificación
-- muestra "Anulado" y los PDF que se vuelvan a descargar llevan la marca de agua ANULADO.
-- =====================================================================

alter table public.exclusivity_contracts add column if not exists voided_at   timestamptz;
alter table public.exclusivity_contracts add column if not exists voided_by   uuid references auth.users(id) on delete set null;
alter table public.exclusivity_contracts add column if not exists void_reason text check (void_reason is null or char_length(void_reason) <= 300);

-- Solo un administrador activo puede anular. Es irreversible desde la app (deja quién y cuándo).
create or replace function public.admin_void_exclusivity_contract(p_id uuid, p_reason text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  reason text := btrim(coalesce(p_reason, ''));
  c public.exclusivity_contracts;
begin
  if not public.is_admin() then raise exception 'Solo administradores' using errcode = '42501'; end if;
  if char_length(reason) < 5 then raise exception 'Escribe el motivo de la anulación (mínimo 5 caracteres)' using errcode = '22023'; end if;
  if char_length(reason) > 300 then raise exception 'El motivo es demasiado largo (máximo 300 caracteres)' using errcode = '22023'; end if;

  select * into c from public.exclusivity_contracts where id = p_id for update;
  if not found then raise exception 'Contrato no encontrado' using errcode = '22023'; end if;
  if c.voided_at is not null then raise exception 'Este contrato ya está anulado' using errcode = '22023'; end if;

  update public.exclusivity_contracts
     set voided_at = now(), voided_by = auth.uid(), void_reason = reason
   where id = p_id
   returning * into c;

  return jsonb_build_object('id', c.id, 'contract_number', c.contract_number, 'voided_at', c.voided_at);
end $$;

revoke all on function public.admin_void_exclusivity_contract(uuid, text) from public, anon;
grant execute on function public.admin_void_exclusivity_contract(uuid, text) to authenticated;

-- La verificación pública ahora también informa si el contrato fue anulado (sin el motivo ni quién lo anuló)
drop function if exists public.verify_exclusivity_contract(text);
create function public.verify_exclusivity_contract(p_code text)
returns table (contract_number text, created_at timestamptz, agent_name text, template_version text, voided boolean, voided_at timestamptz)
language sql security definer set search_path = public stable as $$
  select c.contract_number, c.created_at, coalesce(nullif(btrim(p.display_name), ''), 'Agente de Bastet'), c.template_version,
         (c.voided_at is not null), c.voided_at
    from public.exclusivity_contracts c
    left join public.profiles p on p.id = c.agent_id
   where c.verification_code = upper(btrim(coalesce(p_code, '')))
   limit 1;
$$;
revoke all on function public.verify_exclusivity_contract(text) from public;
grant execute on function public.verify_exclusivity_contract(text) to anon, authenticated;

-- =====================================================================
-- UNO · Publicaciones: cupo gratis, costo por propiedad extra y vigencia de 30 días   — agregar al final de supabase/schema.sql
-- Idempotente: se puede correr completo más de una vez.
-- Reglas:
--  · Cada agente tiene 3 publicaciones (crear propiedades) gratis por mes. El contador se renueva el día 1 de cada mes (hora de
--    Bolivia, UTC-4) y vuelve a 3, se hayan usado o no (no se acumulan). Después de las 3, cada propiedad nueva cuesta 8 créditos.
--  · Cada publicación dura 30 días desde que se crea. Al vencer deja de verse en el sitio y debe RENOVARSE (otros 30 días).
--    Renovar usa la misma regla que publicar: primero las gratis del mes y, si ya no hay, 8 créditos.
--  · Todo lo cobra la base de datos (disparador y función), no el navegador. Los administradores no pagan ni consumen cupo.
--    Borrar una propiedad NO devuelve la publicación gratis ni los créditos.
-- Supone el bloque de créditos (credit_wallets / credit_ledger) y public.is_admin()/is_active_user() ya aplicados.
-- =====================================================================

-- 1) Valores de la regla (editables por un admin; el navegador solo los lee)
create table if not exists public.app_settings (
  key   text primary key,
  value integer not null check (value >= 0)
);
insert into public.app_settings (key, value) values
  ('free_publications_per_month', 3),
  ('publication_cost_credits', 8),
  ('publication_validity_days', 30)
on conflict (key) do nothing;

-- 2) Registro de publicaciones y renovaciones (la cuenta de gratis usadas sale de aquí, no de contar propiedades:
--    así borrar una propiedad no libera un cupo gratis)
create table if not exists public.property_publications (
  id              bigint generated always as identity primary key,
  user_id         uuid not null references auth.users(id) on delete cascade,
  property_id     uuid,                                   -- sin llave foránea a propósito: el registro sobrevive si se borra la propiedad
  month           date not null,                          -- primer día del mes (hora de Bolivia)
  kind            text not null check (kind in ('free', 'paid')),
  credits_charged integer not null default 0 check (credits_charged >= 0),
  created_at      timestamptz not null default now()
);
alter table public.property_publications add column if not exists is_renewal boolean not null default false;
create index if not exists property_publications_user_month_idx on public.property_publications (user_id, month, kind);

alter table public.app_settings          enable row level security;
alter table public.property_publications enable row level security;
drop policy if exists app_settings_read   on public.app_settings;
drop policy if exists app_settings_admin  on public.app_settings;
drop policy if exists property_publications_read on public.property_publications;
create policy app_settings_read  on public.app_settings for select to authenticated using (public.is_active_user());
create policy app_settings_admin on public.app_settings for all    to authenticated using (public.is_admin()) with check (public.is_admin());
create policy property_publications_read on public.property_publications for select to authenticated
  using ((user_id = auth.uid() and public.is_active_user()) or public.is_admin());
revoke all on public.app_settings, public.property_publications from anon;
revoke insert, update, delete on public.property_publications from authenticated;
grant select on public.app_settings, public.property_publications to authenticated;
grant insert, update on public.app_settings to authenticated;     -- las políticas limitan la escritura al admin

-- 3) Vigencia: cada propiedad vence a los 30 días. Las que ya existían reciben 30 días a partir de hoy (no se vencen de golpe).
alter table public.properties add column if not exists expires_at timestamptz;
alter table public.properties add column if not exists auto_renew boolean not null default false;       -- el agente elige renovar sola cada publicación
alter table public.properties add column if not exists auto_renew_failed_at timestamptz;                  -- última vez que la renovación automática no pudo cobrar
alter table public.properties add column if not exists last_renewed_at timestamptz;                       -- última renovación (manual o automática)
update public.properties set expires_at = now() + interval '30 days' where expires_at is null;
create index if not exists properties_expires_at_idx on public.properties (expires_at);

-- El público (visitantes sin sesión) solo ve propiedades disponibles Y vigentes
drop policy if exists "public can read available properties" on public.properties;
create policy "public can read available properties"
  on public.properties for select
  to anon
  using (status = 'available' and (expires_at is null or expires_at > now()));

-- Mes de Bolivia (UTC-4, sin horario de verano)
create or replace function public.bolivia_month_start(ts timestamptz default now())
returns date language sql immutable as $$
  select date_trunc('month', (ts at time zone 'UTC') - interval '4 hours')::date;
$$;

-- 4) Consumir una publicación: una gratis del mes o, si ya no hay, el costo en créditos (nunca queda cobro sin publicación)
create or replace function public._consume_publication(p_uid uuid, p_property uuid, p_title text, p_label text, p_renewal boolean)
returns text language plpgsql security definer set search_path = public as $$
declare
  m          date := public.bolivia_month_start();
  free_total integer;
  cost       integer;
  used       integer;
  bal        integer;
begin
  -- Dos operaciones a la vez de la misma persona se procesan una detrás de otra
  perform pg_advisory_xact_lock(hashtext('publication:' || p_uid::text));

  select value into free_total from public.app_settings where key = 'free_publications_per_month';
  select value into cost       from public.app_settings where key = 'publication_cost_credits';
  free_total := coalesce(free_total, 3);
  cost       := coalesce(cost, 8);

  select count(*) into used from public.property_publications where user_id = p_uid and month = m and kind = 'free';

  if used < free_total then
    insert into public.property_publications (user_id, property_id, month, kind, is_renewal) values (p_uid, p_property, m, 'free', p_renewal);
    return 'free';
  end if;

  update public.credit_wallets w set balance = w.balance - cost, updated_at = now()
   where w.user_id = p_uid and w.balance >= cost
   returning w.balance into bal;
  if not found then
    select balance into bal from public.credit_wallets where user_id = p_uid;
    raise exception 'Saldo insuficiente' using errcode = 'P0402', detail = 'balance=' || coalesce(bal, 0), hint = 'cost=' || cost;
  end if;

  insert into public.property_publications (user_id, property_id, month, kind, credits_charged, is_renewal) values (p_uid, p_property, m, 'paid', cost, p_renewal);
  insert into public.credit_ledger (user_id, kind, amount, description, property_id)
  values (p_uid, 'spend', -cost, p_label || ': ' || left(coalesce(p_title, ''), 80), p_property);
  return 'paid';
end $$;

-- 5) Disparador al crear la propiedad: fija la vigencia (el navegador no la puede elegir) y consume la publicación
create or replace function public.charge_property_publication()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  uid  uuid := auth.uid();
  days integer;
begin
  select value into days from public.app_settings where key = 'publication_validity_days';
  new.expires_at := now() + make_interval(days => coalesce(days, 30));

  -- Sin sesión (SQL Editor, importaciones) o administrador: sin cobro ni cupo
  if uid is null or public.is_admin() then return new; end if;

  perform public._consume_publication(uid, new.id, new.title, 'Publicación de propiedad', false);
  return new;
end $$;

drop trigger if exists charge_property_publication on public.properties;
create trigger charge_property_publication
  before insert on public.properties
  for each row execute function public.charge_property_publication();

-- La fecha de vencimiento solo cambia con renew_property (o por un administrador)
create or replace function public.protect_expires_at()
returns trigger language plpgsql as $$
begin
  -- Sin sesión (SQL Editor) o administrador: se puede corregir a mano; los agentes no
  if new.expires_at is distinct from old.expires_at
     and auth.uid() is not null
     and coalesce(current_setting('uno.renew_rpc', true), '') <> '1'
     and not public.is_admin() then
    new.expires_at := old.expires_at;
  end if;
  return new;
end $$;
drop trigger if exists protect_expires_at on public.properties;
create trigger protect_expires_at
  before update on public.properties
  for each row execute function public.protect_expires_at();

-- 6) Renovar. Núcleo común: cobra con la misma regla que publicar (gratis del mes o créditos) y extiende 30 días.
--    Los 30 días cuentan desde el vencimiento actual si todavía no venció (no se pierde ningún día) o desde hoy si ya venció.
create or replace function public._do_renew(p_property uuid, p_payer uuid, p_free_pass boolean, p_auto boolean)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  p       record;
  days    integer;
  v_kind  text;
  base    timestamptz;
  new_exp timestamptz;
  bal     integer;
  left_free integer;
begin
  select id, title, expires_at into p from public.properties where id = p_property for update;
  select value into days from public.app_settings where key = 'publication_validity_days';
  days := coalesce(days, 30);

  if p_free_pass then v_kind := 'admin';
  else v_kind := public._consume_publication(p_payer, p.id, p.title, case when p_auto then 'Renovación automática' else 'Renovación de propiedad' end, true);
  end if;

  -- Siempre 30 días completos: desde el vencimiento actual si todavía no venció (no se pierde ningún día), o desde hoy si ya venció
  base := case when p.expires_at is null or p.expires_at <= now() then now() else p.expires_at end;
  new_exp := base + make_interval(days => days);

  perform set_config('uno.renew_rpc', '1', true);
  update public.properties set expires_at = new_exp, last_renewed_at = now(), auto_renew_failed_at = null where id = p.id;

  select balance into bal from public.credit_wallets where user_id = p_payer;
  select greatest(coalesce((select value from public.app_settings where key = 'free_publications_per_month'), 3)
                  - (select count(*) from public.property_publications where user_id = p_payer and month = public.bolivia_month_start() and kind = 'free'), 0)
    into left_free;
  return jsonb_build_object('expires_at', new_exp, 'kind', v_kind, 'balance', coalesce(bal, 0), 'free_left', left_free);
end $$;

-- Renovar a mano: la persona dueña (o un administrador) renueva una publicación
create or replace function public.renew_property(p_property_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  uid uuid := auth.uid();
  p   record;
begin
  if uid is null or not public.is_active_user() then raise exception 'No autorizado' using errcode = '42501'; end if;
  select id, owner_id into p from public.properties where id = p_property_id;
  if not found or (p.owner_id is distinct from uid and not public.is_admin()) then
    raise exception 'Propiedad no encontrada' using errcode = '22023';
  end if;
  -- Administradores: sin cobro. Agentes: una gratis del mes o los créditos (los paga quien renueva, que es el dueño).
  return public._do_renew(p.id, uid, public.is_admin(), false);
end $$;

-- Registro de la última corrida del proceso (para no repetirlo más de una vez cada pocos minutos)
create table if not exists public.job_runs (
  job      text primary key,
  last_run timestamptz not null default now()
);
alter table public.job_runs enable row level security;
revoke all on public.job_runs from anon, authenticated;

-- Renovación automática: renueva las publicaciones con la opción activada que vencen en la próxima hora (o ya vencieron).
-- Si el saldo no alcanza, NO se cobra nada, la publicación sigue su curso (vence y se oculta) y queda marcado el intento fallido.
-- Se llama con process_auto_renewals() (sin datos, una corrida cada 5 minutos como máximo): lo ejecutan el inicio del sitio y el panel
-- y, si la base de datos tiene pg_cron, también un programador cada 10 minutos (ver más abajo).
create or replace function public._process_auto_renewals(p_force boolean)
returns integer language plpgsql security definer set search_path = public as $$
declare
  claimed int;
  r       record;
  renewed integer := 0;
begin
  perform pg_advisory_xact_lock(hashtext('process_auto_renewals'));
  if p_force then
    insert into public.job_runs (job, last_run) values ('auto_renewals', now())
    on conflict (job) do update set last_run = now();
  else
    insert into public.job_runs (job, last_run) values ('auto_renewals', now())
    on conflict (job) do update set last_run = now() where public.job_runs.last_run < now() - interval '5 minutes';
    get diagnostics claimed = row_count;
    if claimed = 0 then return 0; end if;
  end if;

  for r in
    select pr.id, pr.owner_id, (o.role = 'admin') as owner_is_admin
      from public.properties pr
      join public.profiles o on o.id = pr.owner_id and o.is_active
     where pr.auto_renew and pr.status = 'available' and pr.expires_at <= now() + interval '1 hour'
     order by pr.expires_at
     limit 200
  loop
    begin   -- cada renovación en su propia subtransacción: si una falla, no afecta a las demás ni deja cobros a medias
      perform public._do_renew(r.id, r.owner_id, r.owner_is_admin, true);
      renewed := renewed + 1;
    exception when others then
      update public.properties set auto_renew_failed_at = now() where id = r.id;
    end;
  end loop;
  return renewed;
end $$;

-- Versión pública: sin parámetros (no se puede forzar desde el navegador) y limitada a una corrida cada 5 minutos
create or replace function public.process_auto_renewals()
returns integer language sql security definer set search_path = public as $$
  select public._process_auto_renewals(false);
$$;

-- Si la base de datos tiene pg_cron (Supabase: Database → Extensions), el proceso también corre solo cada 10 minutos.
-- Si no está disponible no pasa nada: el inicio del sitio y el panel lo ejecutan igualmente.
do $$
begin
  if exists (select 1 from pg_available_extensions where name = 'pg_cron') then
    create extension if not exists pg_cron;
    perform cron.unschedule(jobid) from cron.job where jobname = 'uno-auto-renewals';
    perform cron.schedule('uno-auto-renewals', '*/10 * * * *', 'select public._process_auto_renewals(true)');
  end if;
exception when others then
  raise notice 'pg_cron no disponible (%): la renovación automática se ejecuta desde el sitio y el panel.', sqlerrm;
end $$;

-- 7) Contador para el panel: cuántas gratis quedan, cuándo se renuevan, cuánto cuesta la siguiente y el saldo
create or replace function public.my_publication_quota()
returns jsonb language plpgsql security definer set search_path = public stable as $$
declare
  uid        uuid := auth.uid();
  m          date := public.bolivia_month_start();
  free_total integer;
  cost       integer;
  validity   integer;
  used       integer;
  bal        integer;
begin
  if uid is null or not public.is_active_user() then raise exception 'No autorizado' using errcode = '42501'; end if;
  select value into free_total from public.app_settings where key = 'free_publications_per_month';
  select value into cost       from public.app_settings where key = 'publication_cost_credits';
  select value into validity   from public.app_settings where key = 'publication_validity_days';
  free_total := coalesce(free_total, 3);
  cost       := coalesce(cost, 8);
  validity   := coalesce(validity, 30);
  select count(*) into used from public.property_publications where user_id = uid and month = m and kind = 'free';
  select balance into bal from public.credit_wallets where user_id = uid;
  return jsonb_build_object(
    'exempt', public.is_admin(),
    'free_total', free_total,
    'free_used', least(used, free_total),
    'free_left', greatest(free_total - used, 0),
    'cost', cost,
    'validity_days', validity,
    'balance', coalesce(bal, 0),
    'resets_on', (m + interval '1 month')::date
  );
end $$;

revoke all on function public._consume_publication(uuid, uuid, text, text, boolean) from public, anon, authenticated;
revoke all on function public.charge_property_publication() from public, anon;
revoke all on function public._do_renew(uuid, uuid, boolean, boolean) from public, anon, authenticated;
revoke all on function public._process_auto_renewals(boolean) from public, anon, authenticated;
revoke all on function public.process_auto_renewals() from public;
grant execute on function public.process_auto_renewals() to anon, authenticated;
revoke all on function public.renew_property(uuid) from public, anon;
revoke all on function public.my_publication_quota() from public, anon;
grant execute on function public.renew_property(uuid) to authenticated;
grant execute on function public.my_publication_quota() to authenticated;
