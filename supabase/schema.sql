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
alter table public.properties add column if not exists operation text check (operation in ('venta', 'alquiler', 'anticretico', 'temporal'));
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
  -- Con Google nace habilitado (ver supabase/google-auto-activate.sql, versión vigente).
  insert into public.profiles (id, email, role, is_active, display_name)
  values (
    new.id, new.email, 'agent',
    new.invited_at is not null or coalesce(new.raw_app_meta_data->>'provider', '') = 'google',
    nullif(trim(coalesce(new.raw_user_meta_data->>'full_name', new.raw_user_meta_data->>'name', '')), '')
  )
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
  if auth.uid() is not null and not public.is_admin() then
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

-- (El flujo de invitación por correo y su trigger on_auth_user_invited se retiraron: ver supabase/drop-legacy.sql.)

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

-- =====================================================================
-- UNO · "Vender mi inmueble": solicitudes de propietarios desde el landing
-- (agregar al final de supabase/schema.sql). Idempotente: se puede correr completo más de una vez.
-- Un visitante (sin cuenta) llena el formulario del botón "Vender mi inmueble": sus datos, los del inmueble,
-- la ubicación en el mapa y, si los tiene, los documentos que respaldan la propiedad. Si no los tiene, marca que
-- necesita apoyo legal para sanear los papeles. Un administrador las ve en la pestaña "Propietarios".
-- Supone que existen: public.is_admin().
-- =====================================================================

create table if not exists public.sell_requests (
  id                  uuid primary key,                                   -- lo genera el navegador: sirve de carpeta de los documentos
  owner_name          text not null check (char_length(owner_name) between 3 and 120),
  owner_ci            text check (owner_ci is null or char_length(owner_ci) between 4 and 30),
  owner_phone         text not null check (owner_phone ~ '^\+?[0-9]{7,15}$'),
  owner_email         text check (owner_email is null or (char_length(owner_email) between 5 and 160 and owner_email like '%@%')),
  owner_role          text not null default 'propietario' check (owner_role in ('propietario','copropietario','apoderado','heredero')),
  property_type       text not null check (property_type in ('casa','departamento','terreno','otro')),
  operation           text not null default 'venta' check (operation in ('venta','anticretico','alquiler')),
  city                text not null check (char_length(city) between 2 and 60),
  zone                text check (zone is null or char_length(zone) <= 120),
  address             text not null check (char_length(address) between 5 and 250),
  latitude            double precision check (latitude between -90 and 90),
  longitude           double precision check (longitude between -180 and 180),
  price               numeric check (price is null or (price > 0 and price < 1000000000)),
  currency            text not null default 'USD' check (currency in ('USD','BOB')),
  land_area           numeric check (land_area is null or (land_area > 0 and land_area < 100000000)),
  built_area          numeric check (built_area is null or (built_area >= 0 and built_area < 100000000)),
  rooms               integer check (rooms is null or rooms between 0 and 99),
  baths               integer check (baths is null or baths between 0 and 99),
  description         text check (description is null or char_length(description) <= 1500),
  doc_status          text not null check (doc_status in ('en_regla','por_regularizar','sin_documentos')),
  needs_legal_support boolean not null default false,
  documents           jsonb not null default '[]'::jsonb,                 -- [{type,name,path,size}]
  consent             boolean not null check (consent),
  status              text not null default 'new' check (status in ('new','contacted','review','closed','discarded')),
  admin_notes         text check (admin_notes is null or char_length(admin_notes) <= 2000),
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  check ((latitude is null) = (longitude is null)),
  check (jsonb_typeof(documents) = 'array' and jsonb_array_length(documents) <= 12),
  check (doc_status <> 'sin_documentos' or needs_legal_support)           -- sin documentos => apoyo legal siempre
);
create index if not exists sell_requests_status_idx on public.sell_requests (status, created_at desc);

alter table public.sell_requests enable row level security;
-- Sin políticas para anon/agentes: la única puerta de entrada es submit_sell_request(). Los administradores leen y gestionan.
drop policy if exists "admin reads sell requests" on public.sell_requests;
create policy "admin reads sell requests" on public.sell_requests for select to authenticated using (public.is_admin());
drop policy if exists "admin updates sell requests" on public.sell_requests;
create policy "admin updates sell requests" on public.sell_requests for update to authenticated using (public.is_admin()) with check (public.is_admin());
drop policy if exists "admin deletes sell requests" on public.sell_requests;
create policy "admin deletes sell requests" on public.sell_requests for delete to authenticated using (public.is_admin());
revoke all on public.sell_requests from anon;
revoke insert on public.sell_requests from authenticated;

-- Un administrador solo cambia el seguimiento (estado y notas); los datos que dejó el propietario quedan congelados.
create or replace function public.protect_sell_request_columns()
returns trigger language plpgsql as $$
begin
  if auth.uid() is not null then
    new.id := old.id; new.owner_name := old.owner_name; new.owner_ci := old.owner_ci; new.owner_phone := old.owner_phone;
    new.owner_email := old.owner_email; new.owner_role := old.owner_role; new.property_type := old.property_type;
    new.operation := old.operation; new.city := old.city; new.zone := old.zone; new.address := old.address;
    new.latitude := old.latitude; new.longitude := old.longitude; new.price := old.price; new.currency := old.currency;
    new.land_area := old.land_area; new.built_area := old.built_area; new.rooms := old.rooms; new.baths := old.baths;
    new.description := old.description; new.doc_status := old.doc_status; new.needs_legal_support := old.needs_legal_support;
    new.documents := old.documents; new.consent := old.consent; new.created_at := old.created_at;
  end if;
  new.updated_at := now();
  return new;
end $$;
drop trigger if exists protect_sell_request_columns on public.sell_requests;
create trigger protect_sell_request_columns before update on public.sell_requests
  for each row execute function public.protect_sell_request_columns();

-- Alta desde el landing (anon y authenticated). Valida todo y limita el abuso.
create or replace function public.submit_sell_request(p jsonb)
returns boolean language plpgsql security definer set search_path = public as $$
declare
  rid   uuid;
  ph    text := regexp_replace(coalesce(p->>'owner_phone', ''), '[\s().-]', '', 'g');
  docs  jsonb := coalesce(p->'documents', '[]'::jsonb);
  d     jsonb;
  st    text := coalesce(p->>'doc_status', '');
  needs boolean := coalesce((p->>'needs_legal_support')::boolean, false);
begin
  begin rid := (p->>'id')::uuid; exception when others then raise exception 'Solicitud no válida.'; end;
  if rid is null then raise exception 'Solicitud no válida.'; end if;
  if coalesce((p->>'consent')::boolean, false) is not true then raise exception 'Debes aceptar que usemos tus datos para contactarte.'; end if;
  if ph !~ '^\+?[0-9]{7,15}$' then raise exception 'Escribe un número de WhatsApp válido (solo dígitos, con + si incluye código de país).'; end if;
  if jsonb_typeof(docs) <> 'array' or jsonb_array_length(docs) > 12 then raise exception 'Máximo 12 documentos.'; end if;
  for d in select * from jsonb_array_elements(docs) loop
    -- cada archivo debe estar dentro de la carpeta de ESTA solicitud
    if coalesce(d->>'path', '') !~ ('^' || rid::text || '/[A-Za-z0-9._-]{1,120}$') then raise exception 'Documento no válido.'; end if;
  end loop;
  if st = 'sin_documentos' then needs := true; docs := '[]'::jsonb; end if;

  -- Límites contra abuso: 3 por mismo teléfono en 24 h y 200 en total al día.
  if (select count(*) from public.sell_requests where owner_phone = ph and created_at > now() - interval '24 hours') >= 3 then
    raise exception 'Ya recibimos tus solicitudes. Un asesor te contactará pronto.';
  end if;
  if (select count(*) from public.sell_requests where created_at > now() - interval '24 hours') >= 200 then
    raise exception 'Hay muchas solicitudes en este momento. Inténtalo más tarde o escríbenos por WhatsApp.';
  end if;

  insert into public.sell_requests (
    id, owner_name, owner_ci, owner_phone, owner_email, owner_role, property_type, operation, city, zone, address,
    latitude, longitude, price, currency, land_area, built_area, rooms, baths, description,
    doc_status, needs_legal_support, documents, consent)
  values (
    rid, btrim(coalesce(p->>'owner_name', '')), nullif(btrim(coalesce(p->>'owner_ci', '')), ''), ph,
    nullif(btrim(coalesce(p->>'owner_email', '')), ''), coalesce(nullif(p->>'owner_role', ''), 'propietario'),
    p->>'property_type', coalesce(nullif(p->>'operation', ''), 'venta'), btrim(coalesce(p->>'city', '')),
    nullif(btrim(coalesce(p->>'zone', '')), ''), btrim(coalesce(p->>'address', '')),
    nullif(p->>'latitude', '')::double precision, nullif(p->>'longitude', '')::double precision,
    nullif(p->>'price', '')::numeric, coalesce(nullif(p->>'currency', ''), 'USD'),
    nullif(p->>'land_area', '')::numeric, nullif(p->>'built_area', '')::numeric,
    nullif(p->>'rooms', '')::integer, nullif(p->>'baths', '')::integer,
    nullif(btrim(coalesce(p->>'description', '')), ''), st, needs, docs, true);
  return true;
exception
  when unique_violation then raise exception 'Esta solicitud ya fue enviada.';
  when check_violation or invalid_text_representation or numeric_value_out_of_range then
    raise exception 'Revisa los datos del formulario: hay un campo incompleto o con un valor no válido.';
end $$;
revoke all on function public.submit_sell_request(jsonb) from public;
grant execute on function public.submit_sell_request(jsonb) to anon, authenticated;

-- ── Storage: carpeta privada de documentos. Cualquiera puede SUBIR (con tope de tamaño y tipo), solo un administrador puede VER.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('sell-documents', 'sell-documents', false, 10485760,
        array['application/pdf','image/jpeg','image/png','image/webp'])
on conflict (id) do update set public = false, file_size_limit = 10485760,
  allowed_mime_types = array['application/pdf','image/jpeg','image/png','image/webp'];

drop policy if exists "anyone can upload sell documents" on storage.objects;
create policy "anyone can upload sell documents" on storage.objects for insert to anon, authenticated
  with check (bucket_id = 'sell-documents' and name ~ '^[0-9a-f-]{36}/[A-Za-z0-9._-]{1,120}$');
drop policy if exists "admin reads sell documents" on storage.objects;
create policy "admin reads sell documents" on storage.objects for select to authenticated
  using (bucket_id = 'sell-documents' and public.is_admin());
drop policy if exists "admin deletes sell documents" on storage.objects;
create policy "admin deletes sell documents" on storage.objects for delete to authenticated
  using (bucket_id = 'sell-documents' and public.is_admin());

-- =====================================================================
-- UNO · Moneda del precio de la propiedad (dólares o bolivianos)
-- (agregar al final de supabase/schema.sql). Idempotente: se puede correr completo más de una vez.
-- Cada propiedad guarda en qué moneda está su precio: 'USD' (por defecto, como todas las que ya existen) o 'BOB' (Bs.-).
-- El "tipo de cambio aceptado" solo aplica a precios en dólares.
-- =====================================================================
alter table public.properties add column if not exists currency text not null default 'USD';

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'properties_currency_check' and conrelid = 'public.properties'::regclass) then
    alter table public.properties add constraint properties_currency_check check (currency in ('USD', 'BOB'));
  end if;
end $$;

-- =====================================================================
-- UNO · Historial de créditos: la compra de un pack desglosa el regalo
-- (agregar al final de supabase/schema.sql). Idempotente: se puede correr completo más de una vez.
-- Antes: "Pack Exclusivo · transferencia  +440".  Ahora: "Pack Exclusivo · 400 + 40 de regalo · transferencia  +440".
-- Solo cambia el texto del movimiento: el monto acreditado es el mismo (créditos + regalo, congelados al pedir).
-- =====================================================================
create or replace function public.admin_resolve_credit_request(p_id bigint, p_approve boolean)
returns void language plpgsql security definer set search_path = public as $$
declare rq public.credit_requests; gift integer; label text;
begin
  if not public.is_admin() then raise exception 'Solo administradores' using errcode = '42501'; end if;
  select * into rq from public.credit_requests where id = p_id and status = 'pending' for update;
  if not found then raise exception 'Solicitud no encontrada o ya resuelta'; end if;

  update public.credit_requests
     set status = case when p_approve then 'approved' else 'rejected' end,
         resolved_at = now(), resolved_by = auth.uid()
   where id = p_id;

  if p_approve then
    select least(coalesce(bonus, 0), rq.credits) into gift from public.credit_packs where code = rq.pack_code;
    gift := coalesce(gift, 0);
    label := 'Pack ' || rq.pack_name || ' · ' ||
             case when gift > 0 then (rq.credits - gift) || ' + ' || gift || ' de regalo' else rq.credits || ' créditos' end ||
             ' · ' || rq.method;
    insert into public.credit_wallets (user_id, balance) values (rq.user_id, rq.credits)
    on conflict (user_id) do update set balance = public.credit_wallets.balance + excluded.balance, updated_at = now();
    insert into public.credit_ledger (user_id, kind, amount, description)
    values (rq.user_id, 'purchase', rq.credits, label);
  end if;
end $$;

-- =====================================================================
-- UNO · Suscripciones mensuales (reemplazan los créditos)   — agregar al final de supabase/schema.sql
-- Idempotente: se puede correr completo más de una vez.
-- Supone: public.profiles, public.properties, public.is_admin(), public.is_active_user(), app_settings y los bloques
-- de créditos, publicaciones y contratos ya aplicados (esto los reemplaza en lo comercial; el historial se conserva).
--
-- Planes (precios en Bs, editables por un administrador en subscription_plans):
--   propietario  Bs 150/mes · 3 propiedades activas · 1 destacado por periodo  · sin herramientas de agente
--   agente       Bs 350/mes · 15 propiedades activas · 3 destacados por periodo · herramientas de agente
--   empresa      Bs 650/mes · 50 propiedades activas · 3 destacados por periodo · herramientas de agente
-- Reglas (las aplica la base de datos, nunca el navegador):
--  · Para publicar hace falta una suscripción vigente; "activa" = estado 'available' y no vencida. Una propiedad vendida
--    o vencida no ocupa cupo. Dos publicaciones simultáneas no pueden superar el cupo (bloqueo por persona).
--  · Toda propiedad vence cuando termina el periodo pagado (y se vuelve a extender al renovar: como máximo las N más
--    recientes, siendo N el límite del plan, así un plan menor no "revive" todo el inventario).
--  · Destacar: 1 plaza por propiedad a la vez (no se puede destacar de nuevo una propiedad ya destacada) y un tope de
--    destacados NUEVOS por ciclo de 30 días del periodo pagado. Duración de cada destacado: app_settings.featured_duration_days.
--  · Pago MANUAL: la persona solicita el plan, paga (transferencia / QR / efectivo) y un administrador confirma.
--    No hay cobro automático ni pasarela: el plan se activa solo al confirmar el pago.
--  · Los créditos dejan de venderse. Saldos e historial se conservan (sin conversión automática).
--  · Quien ya era agente activo recibe un periodo de cortesía del plan Agente (source = 'grace') para no cortar su servicio.
-- =====================================================================

-- 0) Valores de la regla en app_settings (duración del periodo y de un destacado)
create table if not exists public.app_settings (
  key   text primary key,
  value integer not null check (value >= 0)
);
insert into public.app_settings (key, value) values
  ('subscription_period_days', 30),
  ('featured_duration_days', 30)
on conflict (key) do nothing;

-- 1) Planes: configuración central de precios y límites
create table if not exists public.subscription_plans (
  code                    text primary key check (code in ('propietario', 'agente', 'empresa')),
  name                    text not null,
  price_bs                numeric(10,2) not null check (price_bs >= 0),
  max_active_properties   integer not null check (max_active_properties > 0),
  max_featured_per_period integer not null check (max_featured_per_period >= 0),
  agent_tools             boolean not null default false,   -- herramientas profesionales del agente (contrato de exclusividad, etc.)
  sort_order              integer not null default 0,
  active                  boolean not null default true
);
insert into public.subscription_plans (code, name, price_bs, max_active_properties, max_featured_per_period, agent_tools, sort_order) values
  ('propietario', 'Propietario', 150, 3, 1, false, 1),
  ('agente',      'Agente',      350, 15, 3, true,  2),
  ('empresa',     'Empresa',     650, 50, 3, true,  3)
on conflict (code) do nothing;

-- 2) Suscripción vigente de cada persona (una fila por persona) y su historial
create table if not exists public.subscriptions (
  user_id              uuid primary key references auth.users(id) on delete cascade,
  plan_code            text not null references public.subscription_plans(code),
  current_period_start timestamptz not null default now(),
  current_period_end   timestamptz not null,
  cancel_at_period_end boolean not null default false,
  canceled_at          timestamptz,
  source               text not null default 'payment' check (source in ('payment', 'grace', 'admin')),
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now()
);

create table if not exists public.subscription_requests (
  id          bigint generated always as identity primary key,
  user_id     uuid not null references auth.users(id) on delete cascade,
  plan_code   text not null references public.subscription_plans(code),
  price_bs    numeric(10,2) not null,                 -- precio congelado al pedir
  method      text not null check (method in ('transferencia', 'qr', 'efectivo')),
  reference   text check (reference is null or char_length(reference) <= 120),   -- nº de transferencia / comprobante, texto libre
  status      text not null default 'pending' check (status in ('pending', 'approved', 'rejected')),
  note        text,
  created_at  timestamptz not null default now(),
  resolved_at timestamptz,
  resolved_by uuid
);
create unique index if not exists subscription_requests_one_pending_idx on public.subscription_requests (user_id) where status = 'pending';
create index if not exists subscription_requests_status_idx on public.subscription_requests (status, created_at desc);

create table if not exists public.subscription_events (   -- historial auditable (altas, renovaciones, cambios de plan, cancelaciones)
  id         bigint generated always as identity primary key,
  user_id    uuid not null references auth.users(id) on delete cascade,
  kind       text not null,
  plan_from  text,
  plan_to    text,
  details    jsonb not null default '{}',
  created_by uuid,
  created_at timestamptz not null default now()
);
create index if not exists subscription_events_user_idx on public.subscription_events (user_id, created_at desc);

create table if not exists public.featured_activations (  -- un destacado nuevo = una fila (sin FK: sobrevive si se borra la propiedad)
  id             bigint generated always as identity primary key,
  user_id        uuid not null references auth.users(id) on delete cascade,
  property_id    uuid not null,
  featured_until timestamptz not null,
  created_at     timestamptz not null default now()
);
create index if not exists featured_activations_user_idx on public.featured_activations (user_id, created_at desc);

-- 3) RLS: lectura propia (o admin); los planes los puede ver cualquiera (precios públicos). Escritura solo por funciones.
alter table public.subscription_plans    enable row level security;
alter table public.subscriptions         enable row level security;
alter table public.subscription_requests enable row level security;
alter table public.subscription_events   enable row level security;
alter table public.featured_activations  enable row level security;

drop policy if exists subscription_plans_read  on public.subscription_plans;
drop policy if exists subscription_plans_admin on public.subscription_plans;
drop policy if exists subscriptions_read       on public.subscriptions;
drop policy if exists subscription_requests_read on public.subscription_requests;
drop policy if exists subscription_events_read on public.subscription_events;
drop policy if exists featured_activations_read on public.featured_activations;
create policy subscription_plans_read  on public.subscription_plans for select to anon, authenticated using (active or public.is_admin());
create policy subscription_plans_admin on public.subscription_plans for update to authenticated using (public.is_admin()) with check (public.is_admin());
create policy subscriptions_read          on public.subscriptions         for select to authenticated using (user_id = auth.uid() or public.is_admin());
create policy subscription_requests_read  on public.subscription_requests for select to authenticated using (user_id = auth.uid() or public.is_admin());
create policy subscription_events_read    on public.subscription_events   for select to authenticated using (user_id = auth.uid() or public.is_admin());
create policy featured_activations_read   on public.featured_activations  for select to authenticated using (user_id = auth.uid() or public.is_admin());

revoke all on public.subscriptions, public.subscription_requests, public.subscription_events, public.featured_activations from anon;
revoke insert, update, delete on public.subscriptions, public.subscription_requests, public.subscription_events, public.featured_activations from authenticated;
grant select on public.subscriptions, public.subscription_requests, public.subscription_events, public.featured_activations to authenticated;
revoke insert, delete on public.subscription_plans from anon, authenticated;
revoke update on public.subscription_plans from anon;
grant select on public.subscription_plans to anon, authenticated;
grant update on public.subscription_plans to authenticated;      -- la política limita la edición al admin

-- 4) Funciones internas
create or replace function public._setting(p_key text, p_default integer)
returns integer language sql stable security definer set search_path = public as $$
  select coalesce((select value from public.app_settings where key = p_key), p_default);
$$;

-- Propiedades que ocupan cupo: disponibles y no vencidas
create or replace function public._count_active_properties(p_uid uuid)
returns integer language sql stable security definer set search_path = public as $$
  select count(*)::integer from public.properties
   where owner_id = p_uid and status = 'available' and (expires_at is null or expires_at > now());
$$;

-- Inicio del ciclo de destacados en curso (ciclos de N días contados desde el inicio del periodo pagado)
create or replace function public._featured_cycle_start(p_period_start timestamptz)
returns timestamptz language sql stable security definer set search_path = public as $$
  select p_period_start + make_interval(days => (floor(extract(epoch from (now() - p_period_start)) / (public._setting('subscription_period_days', 30) * 86400.0)))::integer * public._setting('subscription_period_days', 30));
$$;

-- Extiende hasta p_end el vencimiento de las propiedades de la persona, con tope = límite del plan:
-- primero las que hoy están vigentes y luego las más recientes (las demás conservan su fecha y vencen solas).
create or replace function public._sync_property_expiry(p_uid uuid, p_end timestamptz, p_max integer)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform set_config('uno.renew_rpc', '1', true);
  with ranked as (
    select id, row_number() over (order by (expires_at is null or expires_at > now()) desc, created_at desc) rn
      from public.properties where owner_id = p_uid and status = 'available'
  )
  update public.properties p set expires_at = p_end
    from ranked r where p.id = r.id and r.rn <= p_max;
end $$;

-- Activa o renueva el plan de una persona (único camino: pago confirmado, cortesía o alta manual del admin)
create or replace function public._activate_subscription(p_user uuid, p_plan text, p_source text, p_days integer, p_by uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  cur       public.subscriptions;
  pl        public.subscription_plans;
  days      integer := coalesce(p_days, public._setting('subscription_period_days', 30));
  v_start   timestamptz;
  v_end     timestamptz;
  kind      text;
begin
  select * into pl from public.subscription_plans where code = p_plan;
  if not found then raise exception 'Plan no disponible' using errcode = '22023'; end if;
  perform pg_advisory_xact_lock(hashtext('plan:' || p_user::text));
  select * into cur from public.subscriptions where user_id = p_user for update;

  if found and cur.current_period_end > now() and cur.plan_code = p_plan then
    v_start := cur.current_period_start;                 -- renovación anticipada: se suma al periodo que ya tiene
    v_end   := cur.current_period_end + make_interval(days => days);
    kind    := 'renewal';
  else
    v_start := now();                                    -- alta nueva, plan vencido o cambio de plan: empieza hoy
    v_end   := now() + make_interval(days => days);
    kind    := case when found and cur.current_period_end > now() then 'plan_change' else 'activation' end;
  end if;

  insert into public.subscriptions (user_id, plan_code, current_period_start, current_period_end, cancel_at_period_end, canceled_at, source, updated_at)
  values (p_user, p_plan, v_start, v_end, false, null, p_source, now())
  on conflict (user_id) do update
    set plan_code = excluded.plan_code, current_period_start = excluded.current_period_start, current_period_end = excluded.current_period_end,
        cancel_at_period_end = false, canceled_at = null, source = excluded.source, updated_at = now();

  insert into public.subscription_events (user_id, kind, plan_from, plan_to, details, created_by)
  values (p_user, kind, cur.plan_code, p_plan, jsonb_build_object('source', p_source, 'days', days, 'period_end', v_end), p_by);

  perform public._sync_property_expiry(p_user, v_end, pl.max_active_properties);
  return jsonb_build_object('plan', p_plan, 'period_start', v_start, 'period_end', v_end, 'kind', kind);
end $$;

-- 5) Publicar: exige suscripción vigente y respeta el límite del plan (reemplaza el cobro en créditos)
create or replace function public.charge_property_publication()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  uid  uuid := auth.uid();
  sub  public.subscriptions;
  pl   public.subscription_plans;
begin
  -- Sin sesión (SQL Editor, importaciones) o administrador: sin plan ni límite (vigencia estándar de 30 días)
  if uid is null or public.is_admin() then
    new.expires_at := now() + make_interval(days => public._setting('publication_validity_days', 30));
    return new;
  end if;

  perform pg_advisory_xact_lock(hashtext('plan:' || uid::text));      -- dos publicaciones a la vez se procesan una detrás de otra
  select * into sub from public.subscriptions where user_id = uid and current_period_end > now();
  if not found then
    raise exception 'Necesitas una suscripción vigente para publicar propiedades' using errcode = 'P0403', hint = 'no_subscription';
  end if;
  select * into pl from public.subscription_plans where code = sub.plan_code;
  if public._count_active_properties(uid) >= pl.max_active_properties then
    raise exception 'Llegaste al límite de % propiedades activas del plan %', pl.max_active_properties, pl.name
      using errcode = 'P0403', hint = 'limit', detail = 'limit=' || pl.max_active_properties;
  end if;
  new.expires_at := sub.current_period_end;
  return new;
end $$;

-- Reactivar una propiedad vendida/oculta (vuelve a 'available') también ocupa un cupo
create or replace function public.enforce_plan_on_reactivate()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  uid uuid := auth.uid();
  sub public.subscriptions;
  pl  public.subscription_plans;
begin
  if new.status = 'available' and old.status is distinct from 'available' and uid is not null and not public.is_admin() then
    perform pg_advisory_xact_lock(hashtext('plan:' || uid::text));
    select * into sub from public.subscriptions where user_id = uid and current_period_end > now();
    if not found then
      raise exception 'Necesitas una suscripción vigente para publicar propiedades' using errcode = 'P0403', hint = 'no_subscription';
    end if;
    select * into pl from public.subscription_plans where code = sub.plan_code;
    if public._count_active_properties(uid) >= pl.max_active_properties then
      raise exception 'Llegaste al límite de % propiedades activas del plan %', pl.max_active_properties, pl.name
        using errcode = 'P0403', hint = 'limit', detail = 'limit=' || pl.max_active_properties;
    end if;
    perform set_config('uno.renew_rpc', '1', true);
    new.expires_at := sub.current_period_end;
  end if;
  return new;
end $$;
drop trigger if exists plan_limit_on_reactivate on public.properties;
create trigger plan_limit_on_reactivate
  before update of status on public.properties
  for each row execute function public.enforce_plan_on_reactivate();

-- Renovar una publicación vencida: dentro del periodo pagado y del límite del plan (sin costo en créditos)
drop function if exists public._do_renew(uuid, uuid, boolean, boolean);
create or replace function public.renew_property(p_property_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  uid uuid := auth.uid();
  p   record;
  sub public.subscriptions;
  pl  public.subscription_plans;
  new_exp timestamptz;
begin
  if uid is null or not public.is_active_user() then raise exception 'No autorizado' using errcode = '42501'; end if;
  select id, owner_id, status, expires_at into p from public.properties where id = p_property_id for update;
  if not found or (p.owner_id is distinct from uid and not public.is_admin()) then
    raise exception 'Propiedad no encontrada' using errcode = '22023';
  end if;
  perform set_config('uno.renew_rpc', '1', true);
  if public.is_admin() then
    new_exp := greatest(coalesce(p.expires_at, now()), now()) + make_interval(days => public._setting('publication_validity_days', 30));
  else
    perform pg_advisory_xact_lock(hashtext('plan:' || uid::text));
    select * into sub from public.subscriptions where user_id = uid and current_period_end > now();
    if not found then raise exception 'Necesitas una suscripción vigente para renovar' using errcode = 'P0403', hint = 'no_subscription'; end if;
    select * into pl from public.subscription_plans where code = sub.plan_code;
    -- una propiedad ya vigente no ocupa un cupo nuevo; una vencida sí
    if (p.expires_at is null or p.expires_at <= now()) and p.status = 'available'
       and public._count_active_properties(uid) >= pl.max_active_properties then
      raise exception 'Llegaste al límite de % propiedades activas del plan %', pl.max_active_properties, pl.name
        using errcode = 'P0403', hint = 'limit', detail = 'limit=' || pl.max_active_properties;
    end if;
    new_exp := sub.current_period_end;
  end if;
  update public.properties set expires_at = new_exp, last_renewed_at = now(), auto_renew_failed_at = null where id = p.id;
  return jsonb_build_object('expires_at', new_exp);
end $$;

-- La renovación automática en créditos ya no existe: el proceso queda como no-op (el sitio lo sigue llamando sin error)
create or replace function public._process_auto_renewals(p_force boolean)
returns integer language sql security definer set search_path = public as $$ select 0; $$;
do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule(jobid) from cron.job where jobname = 'uno-auto-renewals';
  end if;
exception when others then
  raise notice 'pg_cron no disponible: nada que desprogramar (%).', sqlerrm;
end $$;
update public.properties set auto_renew = false where auto_renew;

-- 6) Destacar: plan vigente, una sola plaza por propiedad y tope por ciclo (reemplaza el cobro en créditos)
create or replace function public.feature_property(p_property_id text, p_service text)   -- p_service ya no se usa (se conserva por compatibilidad con la firma anterior)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  uid  uuid := auth.uid();
  prop record;
  sub  public.subscriptions;
  pl   public.subscription_plans;
  used integer;
  cyc  timestamptz;
  new_until timestamptz;
  dur  integer := public._setting('featured_duration_days', 30);
begin
  if uid is null or not public.is_active_user() then raise exception 'No autorizado' using errcode = '42501'; end if;

  select p.id, p.owner_id, p.status, p.expires_at, p.featured_until into prop
    from public.properties p where p.id::text = p_property_id for update;
  if not found or (prop.owner_id is distinct from uid and not public.is_admin()) then raise exception 'Propiedad no encontrada'; end if;
  if prop.status <> 'available' then raise exception 'Solo se pueden destacar propiedades disponibles'; end if;
  if prop.featured_until is not null and prop.featured_until > now() then
    raise exception 'Esta propiedad ya está destacada hasta el %', to_char(prop.featured_until - interval '4 hours', 'DD/MM/YYYY')
      using errcode = 'P0409', hint = 'already_featured';
  end if;

  if not public.is_admin() then
    perform pg_advisory_xact_lock(hashtext('plan:' || uid::text));
    select * into sub from public.subscriptions where user_id = uid and current_period_end > now();
    if not found then raise exception 'Necesitas una suscripción vigente para destacar propiedades' using errcode = 'P0403', hint = 'no_subscription'; end if;
    select * into pl from public.subscription_plans where code = sub.plan_code;
    cyc := public._featured_cycle_start(sub.current_period_start);
    select count(*) into used from public.featured_activations where user_id = uid and created_at >= cyc;
    if used >= pl.max_featured_per_period then
      raise exception 'Ya usaste los % destacados de este periodo de tu plan %', pl.max_featured_per_period, pl.name
        using errcode = 'P0403', hint = 'featured_limit', detail = 'limit=' || pl.max_featured_per_period;
    end if;
  end if;

  new_until := now() + make_interval(days => dur);
  perform set_config('uno.credit_rpc', '1', true);
  update public.properties set featured_until = new_until where id = prop.id;
  if not public.is_admin() then
    insert into public.featured_activations (user_id, property_id, featured_until) values (uid, prop.id, new_until);
  end if;
  return jsonb_build_object('featured_until', new_until);
end $$;

-- 7) Solicitar un plan (pago manual): el precio sale de subscription_plans, nunca del navegador
create or replace function public.request_subscription(p_plan text, p_method text, p_reference text default null)
returns bigint language plpgsql security definer set search_path = public as $$
declare pl public.subscription_plans; rid bigint;
begin
  if auth.uid() is null or not public.is_active_user() then raise exception 'No autorizado' using errcode = '42501'; end if;
  if public.is_admin() then raise exception 'Los administradores no necesitan suscripción'; end if;
  select * into pl from public.subscription_plans where code = p_plan and active;
  if not found then raise exception 'Plan no disponible'; end if;
  if p_method not in ('transferencia', 'qr', 'efectivo') then raise exception 'Método de pago inválido'; end if;
  if exists (select 1 from public.subscription_requests where user_id = auth.uid() and status = 'pending') then
    raise exception 'Ya tienes una solicitud pendiente de confirmación';
  end if;
  insert into public.subscription_requests (user_id, plan_code, price_bs, method, reference)
  values (auth.uid(), pl.code, pl.price_bs, p_method, nullif(btrim(coalesce(p_reference, '')), ''))
  returning id into rid;
  insert into public.subscription_events (user_id, kind, plan_to, details, created_by)
  values (auth.uid(), 'request', pl.code, jsonb_build_object('request_id', rid, 'price_bs', pl.price_bs, 'method', p_method), auth.uid());
  return rid;
end $$;

-- El admin confirma el pago (activa el plan) o rechaza. Idempotente: una solicitud ya resuelta no se vuelve a procesar.
create or replace function public.admin_resolve_subscription_request(p_id bigint, p_approve boolean, p_note text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare rq public.subscription_requests; res jsonb;
begin
  if not public.is_admin() then raise exception 'Solo administradores' using errcode = '42501'; end if;
  select * into rq from public.subscription_requests where id = p_id and status = 'pending' for update;
  if not found then raise exception 'Solicitud no encontrada o ya resuelta'; end if;
  update public.subscription_requests
     set status = case when p_approve then 'approved' else 'rejected' end, resolved_at = now(), resolved_by = auth.uid(), note = nullif(btrim(coalesce(p_note, '')), '')
   where id = p_id;
  if p_approve then
    res := public._activate_subscription(rq.user_id, rq.plan_code, 'payment', null, auth.uid());
    insert into public.subscription_events (user_id, kind, plan_to, details, created_by)
    values (rq.user_id, 'payment_confirmed', rq.plan_code, jsonb_build_object('request_id', rq.id, 'price_bs', rq.price_bs, 'method', rq.method, 'reference', rq.reference), auth.uid());
  else
    insert into public.subscription_events (user_id, kind, plan_to, details, created_by)
    values (rq.user_id, 'payment_rejected', rq.plan_code, jsonb_build_object('request_id', rq.id, 'note', p_note), auth.uid());
  end if;
  return coalesce(res, '{}'::jsonb);
end $$;

-- El admin da de alta o corrige el plan de una persona a mano (cortesías, pagos en efectivo ya recibidos, etc.)
create or replace function public.admin_grant_subscription(p_user uuid, p_plan text, p_days integer default null)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Solo administradores' using errcode = '42501'; end if;
  if p_days is not null and (p_days < 1 or p_days > 400) then raise exception 'Los días deben estar entre 1 y 400'; end if;
  if not exists (select 1 from public.profiles where id = p_user and is_active) then raise exception 'Persona no encontrada o inactiva'; end if;
  return public._activate_subscription(p_user, p_plan, 'admin', p_days, auth.uid());
end $$;

-- Cancelar: la persona conserva el plan hasta el final del periodo pagado (no hay débito automático que detener)
create or replace function public.cancel_subscription()
returns void language plpgsql security definer set search_path = public as $$
declare cur public.subscriptions;
begin
  if auth.uid() is null or not public.is_active_user() then raise exception 'No autorizado' using errcode = '42501'; end if;
  select * into cur from public.subscriptions where user_id = auth.uid() and current_period_end > now() for update;
  if not found then raise exception 'No tienes una suscripción vigente'; end if;
  update public.subscriptions set cancel_at_period_end = true, canceled_at = now(), updated_at = now() where user_id = auth.uid();
  insert into public.subscription_events (user_id, kind, plan_from, details, created_by) values (auth.uid(), 'cancel', cur.plan_code, '{}', auth.uid());
end $$;

create or replace function public.resume_subscription()
returns void language plpgsql security definer set search_path = public as $$
declare cur public.subscriptions;
begin
  if auth.uid() is null or not public.is_active_user() then raise exception 'No autorizado' using errcode = '42501'; end if;
  select * into cur from public.subscriptions where user_id = auth.uid() and current_period_end > now() for update;
  if not found then raise exception 'No tienes una suscripción vigente'; end if;
  update public.subscriptions set cancel_at_period_end = false, canceled_at = null, updated_at = now() where user_id = auth.uid();
  insert into public.subscription_events (user_id, kind, plan_from, details, created_by) values (auth.uid(), 'resume', cur.plan_code, '{}', auth.uid());
end $$;

-- 8) Estado de la suscripción y uso, para el panel
create or replace function public.my_subscription()
returns jsonb language plpgsql security definer set search_path = public stable as $$
declare
  uid  uuid := auth.uid();
  sub  public.subscriptions;
  pl   public.subscription_plans;
  rq   public.subscription_requests;
  st   text;
  feat integer := 0;
begin
  if uid is null or not public.is_active_user() then raise exception 'No autorizado' using errcode = '42501'; end if;
  select * into rq from public.subscription_requests where user_id = uid and status = 'pending';
  if public.is_admin() then
    return jsonb_build_object('exempt', true, 'status', 'admin', 'plan', null,
      'usage', jsonb_build_object('active_properties', public._count_active_properties(uid), 'featured_used', 0),
      'pending_request', null);
  end if;
  select * into sub from public.subscriptions where user_id = uid;
  if not found then
    return jsonb_build_object('exempt', false, 'status', 'none', 'plan', null,
      'usage', jsonb_build_object('active_properties', public._count_active_properties(uid), 'featured_used', 0),
      'pending_request', case when rq.id is null then null else to_jsonb(rq) end);
  end if;
  select * into pl from public.subscription_plans where code = sub.plan_code;
  st := case when sub.current_period_end <= now() then 'expired' when sub.cancel_at_period_end then 'canceling' else 'active' end;
  if st <> 'expired' then
    select count(*) into feat from public.featured_activations where user_id = uid and created_at >= public._featured_cycle_start(sub.current_period_start);
  end if;
  return jsonb_build_object(
    'exempt', false, 'status', st, 'source', sub.source,
    'plan', jsonb_build_object('code', pl.code, 'name', pl.name, 'price_bs', pl.price_bs, 'max_active_properties', pl.max_active_properties,
                               'max_featured_per_period', pl.max_featured_per_period, 'agent_tools', pl.agent_tools),
    'period_start', sub.current_period_start, 'period_end', sub.current_period_end, 'cancel_at_period_end', sub.cancel_at_period_end,
    'usage', jsonb_build_object('active_properties', public._count_active_properties(uid), 'featured_used', feat,
                                'featured_cycle_start', case when st = 'expired' then null else public._featured_cycle_start(sub.current_period_start) end),
    'pending_request', case when rq.id is null then null else to_jsonb(rq) end);
end $$;

-- 9) Contrato de exclusividad: lo cubre el plan (Agente / Empresa); ya no cuesta créditos
create or replace function public.create_exclusivity_contract(p_data jsonb, p_idempotency_key text, p_template_version text default 'exclusividad-v1')
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  uid     uuid := auth.uid();
  key     text := btrim(coalesce(p_idempotency_key, ''));
  yr      integer;
  seq     integer;
  num     text;
  code    text;
  cid     uuid := gen_random_uuid();
  c       public.exclusivity_contracts;
  sub     public.subscriptions;
  pl      public.subscription_plans;
  alphabet constant text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
begin
  if uid is null or not public.is_active_user() then
    raise exception 'No autorizado' using errcode = '42501';
  end if;
  if char_length(key) < 8 or char_length(key) > 80 then raise exception 'Llave de idempotencia inválida' using errcode = '22023'; end if;
  if p_template_version is null or p_template_version not in ('exclusividad-v1', 'exclusividad-v2') then raise exception 'Plantilla no disponible' using errcode = '22023'; end if;

  -- Dos peticiones simultáneas con la misma llave se ejecutan una detrás de otra
  perform pg_advisory_xact_lock(hashtext(uid::text || ':' || key));

  select * into c from public.exclusivity_contracts where agent_id = uid and idempotency_key = key;
  if found then
    return jsonb_build_object('id', c.id, 'contract_number', c.contract_number, 'verification_code', c.verification_code,
                              'created_at', c.created_at, 'charged', false);
  end if;

  -- Las herramientas profesionales (contrato de exclusividad) requieren un plan que las incluya; el administrador está exento
  if not public.is_admin() then
    select * into sub from public.subscriptions where user_id = uid and current_period_end > now();
    if not found then raise exception 'Necesitas una suscripción vigente (plan Agente o Empresa)' using errcode = 'P0403', hint = 'no_subscription'; end if;
    select * into pl from public.subscription_plans sp where sp.code = sub.plan_code;   -- (alias: la variable local "code" chocaría con la columna)
    if not pl.agent_tools then raise exception 'Tu plan % no incluye el contrato de exclusividad (plan Agente o Empresa)', pl.name using errcode = 'P0403', hint = 'plan_tools'; end if;
  end if;

  perform public.validate_exclusivity_data(p_data);

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
  values (cid, uid, num, code, p_template_version, p_data, 0, key)
  returning * into c;

  return jsonb_build_object('id', c.id, 'contract_number', c.contract_number, 'verification_code', c.verification_code,
                            'created_at', c.created_at, 'charged', false);
end $$;

-- 10) La compra de créditos se retira (los saldos y el historial se conservan; las solicitudes viejas aún se pueden resolver)
create or replace function public.request_credit_pack(p_pack text, p_method text)
returns bigint language plpgsql security definer set search_path = public as $$
begin
  raise exception 'Los créditos ya no se venden. Elige un plan de suscripción.' using errcode = 'P0410';
end $$;

-- 11) Permisos de las funciones
revoke all on function public._setting(text, integer) from public, anon, authenticated;
revoke all on function public._count_active_properties(uuid) from public, anon, authenticated;
revoke all on function public._featured_cycle_start(timestamptz) from public, anon, authenticated;
revoke all on function public._sync_property_expiry(uuid, timestamptz, integer) from public, anon, authenticated;
revoke all on function public._activate_subscription(uuid, text, text, integer, uuid) from public, anon, authenticated;
revoke all on function public.charge_property_publication() from public, anon;
revoke all on function public.enforce_plan_on_reactivate() from public, anon;
revoke all on function public.renew_property(uuid) from public, anon;
revoke all on function public.feature_property(text, text) from public, anon;
revoke all on function public.request_subscription(text, text, text) from public, anon;
revoke all on function public.admin_resolve_subscription_request(bigint, boolean, text) from public, anon;
revoke all on function public.admin_grant_subscription(uuid, text, integer) from public, anon;
revoke all on function public.cancel_subscription() from public, anon;
revoke all on function public.resume_subscription() from public, anon;
revoke all on function public.my_subscription() from public, anon;
revoke all on function public.create_exclusivity_contract(jsonb, text, text) from public, anon;
revoke all on function public.request_credit_pack(text, text) from public, anon;
grant execute on function public.renew_property(uuid) to authenticated;
grant execute on function public.feature_property(text, text) to authenticated;
grant execute on function public.request_subscription(text, text, text) to authenticated;
grant execute on function public.admin_resolve_subscription_request(bigint, boolean, text) to authenticated;
grant execute on function public.admin_grant_subscription(uuid, text, integer) to authenticated;
grant execute on function public.cancel_subscription() to authenticated;
grant execute on function public.resume_subscription() to authenticated;
grant execute on function public.my_subscription() to authenticated;
grant execute on function public.create_exclusivity_contract(jsonb, text, text) to authenticated;
grant execute on function public.request_credit_pack(text, text) to authenticated;

-- 12) Transición: quien ya era agente activo y no tiene suscripción recibe 30 días de cortesía del plan Agente,
--     para no interrumpir su servicio. Sus propiedades siguen visibles; después debe elegir un plan.
do $$
declare r record; n integer := 0;
begin
  for r in
    select p.id from public.profiles p
     where p.is_active and p.role = 'agent' and not exists (select 1 from public.subscriptions s where s.user_id = p.id)
  loop
    perform public._activate_subscription(r.id, 'agente', 'grace', null, null);
    n := n + 1;
  end loop;
  if n > 0 then raise notice 'Cortesía de 30 días (plan Agente) para % agentes activos', n; end if;
end $$;

-- =====================================================================
-- UNO · Servicios del plan Propietario   — agregar al final de supabase/schema.sql (después de subscriptions.sql)
-- Idempotente: se puede correr completo más de una vez.
-- Supone: subscriptions.sql ya aplicado (planes, subscriptions, _count_active_properties).
--
-- 1) Directorio de agentes registrados (solo los que tienen un plan Agente/Empresa vigente) para que el propietario elija uno.
-- 2) Ofertas de colaboración: el propietario ofrece una de sus propiedades a un agente con condiciones (comisión, plazo,
--    exclusividad). El agente acepta o rechaza; se genera un documento (borrador sujeto a validación legal).
-- 3) Solicitudes a Maat Fima Legal: asesoramiento, trámites, saneamiento, impuestos, etc. Un administrador las gestiona.
-- Todo lo escribe la base de datos (funciones); el navegador no inserta ni cambia estados directamente.
-- Estas funciones son del plan Propietario: las demás cuentas (Agente/Empresa) no las usan.
-- =====================================================================

-- 1) Servicios legales configurables y solicitudes
create table if not exists public.legal_service_types (
  code       text primary key check (code ~ '^[a-z_]{3,30}$'),
  name       text not null,
  active     boolean not null default true,
  sort_order integer not null default 0
);
insert into public.legal_service_types (code, name, sort_order) values
  ('asesoramiento', 'Asesoramiento inmobiliario personalizado', 1),
  ('compra_venta',  'Apoyo en un proceso de compra y venta', 2),
  ('tramites',      'Trámites inmobiliarios', 3),
  ('saneamiento',   'Saneamiento de documentos', 4),
  ('impuestos',     'Apoyo con impuestos', 5),
  ('otro',          'Otro servicio', 6)
on conflict (code) do nothing;

create table if not exists public.legal_requests (
  id             bigint generated always as identity primary key,
  user_id        uuid not null references auth.users(id) on delete cascade,
  service_code   text not null references public.legal_service_types(code),
  property_id    uuid,                                 -- sin llave foránea: el pedido sobrevive si se borra la propiedad
  property_title text,
  description    text not null check (char_length(btrim(description)) between 10 and 2000),
  status         text not null default 'pending' check (status in ('pending', 'in_review', 'in_progress', 'completed', 'cancelled')),
  admin_note     text check (admin_note is null or char_length(admin_note) <= 1000),
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  resolved_by    uuid
);
create index if not exists legal_requests_user_idx on public.legal_requests (user_id, created_at desc);
create index if not exists legal_requests_status_idx on public.legal_requests (status, created_at desc);

-- 2) Ofertas de colaboración propietario → agente
create table if not exists public.owner_offer_counters (year integer primary key, last_number integer not null);
create table if not exists public.owner_offers (
  id            uuid primary key default gen_random_uuid(),
  doc_number    text not null unique,
  owner_id      uuid not null references auth.users(id) on delete cascade,
  agent_id      uuid not null references auth.users(id) on delete cascade,
  property_id   uuid not null,                         -- sin llave foránea: la oferta conserva su copia de los datos
  property_data jsonb not null,                        -- copia de la propiedad al ofrecerla (el documento sale siempre de aquí)
  owner_data    jsonb not null,
  agent_data    jsonb not null default '{}',                      -- nombre del agente al ofrecer; al aceptar se suman su C.I. y registro (si los tiene)
  terms         jsonb not null,
  status        text not null default 'pending' check (status in ('pending', 'accepted', 'rejected', 'canceled')),
  response_note text check (response_note is null or char_length(response_note) <= 500),
  responded_at  timestamptz,
  created_at    timestamptz not null default now(),
  check (owner_id <> agent_id)
);
create unique index if not exists owner_offers_one_pending_idx on public.owner_offers (property_id, agent_id) where status = 'pending';
alter table public.owner_offers add column if not exists agent_data jsonb not null default '{}';
create index if not exists owner_offers_owner_idx on public.owner_offers (owner_id, created_at desc);
create index if not exists owner_offers_agent_idx on public.owner_offers (agent_id, created_at desc);

create table if not exists public.owner_offer_events (
  id         bigint generated always as identity primary key,
  offer_id   uuid not null references public.owner_offers(id) on delete cascade,
  kind       text not null,
  actor      uuid,
  note       text,
  created_at timestamptz not null default now()
);
create index if not exists owner_offer_events_offer_idx on public.owner_offer_events (offer_id, created_at);

-- 3) RLS: cada parte ve lo suyo (el admin todo); sin escritura directa
alter table public.legal_service_types enable row level security;
alter table public.legal_requests      enable row level security;
alter table public.owner_offer_counters enable row level security;
alter table public.owner_offers        enable row level security;
alter table public.owner_offer_events  enable row level security;

drop policy if exists legal_service_types_read  on public.legal_service_types;
drop policy if exists legal_service_types_admin on public.legal_service_types;
drop policy if exists legal_requests_read       on public.legal_requests;
drop policy if exists owner_offers_read         on public.owner_offers;
drop policy if exists owner_offer_events_read   on public.owner_offer_events;
create policy legal_service_types_read  on public.legal_service_types for select to authenticated using (public.is_active_user());
create policy legal_service_types_admin on public.legal_service_types for all    to authenticated using (public.is_admin()) with check (public.is_admin());
create policy legal_requests_read on public.legal_requests for select to authenticated using (user_id = auth.uid() or public.is_admin());
create policy owner_offers_read   on public.owner_offers   for select to authenticated using (owner_id = auth.uid() or agent_id = auth.uid() or public.is_admin());
create policy owner_offer_events_read on public.owner_offer_events for select to authenticated
  using (exists (select 1 from public.owner_offers o where o.id = offer_id and (o.owner_id = auth.uid() or o.agent_id = auth.uid() or public.is_admin())));

revoke all on public.legal_service_types, public.legal_requests, public.owner_offer_counters, public.owner_offers, public.owner_offer_events from anon;
revoke insert, update, delete on public.legal_requests, public.owner_offer_counters, public.owner_offers, public.owner_offer_events from authenticated;
revoke all on public.owner_offer_counters from authenticated;
grant select on public.legal_requests, public.owner_offers, public.owner_offer_events to authenticated;
grant select, insert, update, delete on public.legal_service_types to authenticated;   -- las políticas limitan la edición al admin

-- 4) Directorio de agentes: solo con plan Agente/Empresa vigente y datos públicos (nunca correo, teléfono ni rol)
create or replace function public.list_agent_directory()
returns table (id uuid, display_name text, avatar_url text, facebook_url text, instagram_url text, tiktok_url text, plan_name text, active_properties integer)
language plpgsql security definer set search_path = public stable as $$
begin
  if auth.uid() is null or not public.is_active_user() then raise exception 'No autorizado' using errcode = '42501'; end if;
  return query
    select p.id, coalesce(nullif(btrim(p.display_name), ''), 'Agente de Bastet'), p.avatar_url, p.facebook_url, p.instagram_url, p.tiktok_url,
           pl.name, public._count_active_properties(p.id)
      from public.profiles p
      join public.subscriptions s on s.user_id = p.id and s.current_period_end > now()
      join public.subscription_plans pl on pl.code = s.plan_code and pl.agent_tools
     where p.is_active and p.role = 'agent' and p.id <> auth.uid()
     order by coalesce(nullif(btrim(p.display_name), ''), 'zzz'), p.id;
end $$;

-- 5) Solicitudes a Maat Fima Legal
create or replace function public.create_legal_request(p_service text, p_property uuid, p_description text)
returns bigint language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); sub public.subscriptions; svc public.legal_service_types; prop record; rid bigint; ptitle text;
begin
  if uid is null or not public.is_active_user() then raise exception 'No autorizado' using errcode = '42501'; end if;
  select * into sub from public.subscriptions where user_id = uid and current_period_end > now();
  if not found or sub.plan_code <> 'propietario' then
    raise exception 'Este servicio es del plan Propietario. Suscríbete para solicitarlo.' using errcode = 'P0403', hint = 'plan_owner';
  end if;
  select * into svc from public.legal_service_types where code = p_service and active;
  if not found then raise exception 'Servicio no disponible'; end if;
  if char_length(btrim(coalesce(p_description, ''))) < 10 or char_length(p_description) > 2000 then
    raise exception 'Describe lo que necesitas (entre 10 y 2000 caracteres)'; end if;
  if p_property is not null then
    select id, title into prop from public.properties where id = p_property and owner_id = uid;
    if not found then raise exception 'Propiedad no encontrada'; end if;
    ptitle := prop.title;
  end if;
  if (select count(*) from public.legal_requests where user_id = uid and status in ('pending', 'in_review', 'in_progress')) >= 10 then
    raise exception 'Tienes demasiadas solicitudes abiertas. Espera a que se atiendan algunas.'; end if;
  insert into public.legal_requests (user_id, service_code, property_id, property_title, description)
  values (uid, svc.code, p_property, ptitle, btrim(p_description)) returning id into rid;
  return rid;
end $$;

create or replace function public.cancel_legal_request(p_id bigint)
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null or not public.is_active_user() then raise exception 'No autorizado' using errcode = '42501'; end if;
  update public.legal_requests set status = 'cancelled', updated_at = now() where id = p_id and user_id = auth.uid() and status = 'pending';
  if not found then raise exception 'Solicitud no encontrada o ya en gestión'; end if;
end $$;

-- El admin gestiona el avance. Los estados finales (completada / cancelada) no se reabren.
create or replace function public.admin_update_legal_request(p_id bigint, p_status text, p_note text default null)
returns void language plpgsql security definer set search_path = public as $$
declare cur public.legal_requests;
begin
  if not public.is_admin() then raise exception 'Solo administradores' using errcode = '42501'; end if;
  if p_status not in ('pending', 'in_review', 'in_progress', 'completed', 'cancelled') then raise exception 'Estado inválido'; end if;
  select * into cur from public.legal_requests where id = p_id for update;
  if not found then raise exception 'Solicitud no encontrada'; end if;
  if cur.status in ('completed', 'cancelled') then raise exception 'La solicitud ya está cerrada'; end if;
  update public.legal_requests set status = p_status, admin_note = coalesce(nullif(btrim(coalesce(p_note, '')), ''), admin_note), updated_at = now(), resolved_by = auth.uid() where id = p_id;
end $$;

-- 6) Ofertas de colaboración
create or replace function public.create_owner_offer(p_property uuid, p_agent uuid, p_terms jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  uid uuid := auth.uid();
  sub public.subscriptions;
  prop record;
  ag record;
  asub public.subscriptions;
  apl public.subscription_plans;
  t jsonb := coalesce(p_terms, '{}'::jsonb);
  n numeric;
  yr integer; seq integer; num text; oid uuid := gen_random_uuid();
  me record;
begin
  if uid is null or not public.is_active_user() then raise exception 'No autorizado' using errcode = '42501'; end if;
  perform pg_advisory_xact_lock(hashtext('offer:' || uid::text));
  select * into sub from public.subscriptions where user_id = uid and current_period_end > now();
  if not found or sub.plan_code <> 'propietario' then
    raise exception 'Ofrecer tu propiedad a un agente es una función del plan Propietario' using errcode = 'P0403', hint = 'plan_owner';
  end if;

  select id, title, location, address, price, currency, area, rooms, baths, property_type, operation, code_number, description, status, expires_at, owner_whatsapp
    into prop from public.properties where id = p_property and owner_id = uid;
  if not found then raise exception 'Propiedad no encontrada'; end if;
  if prop.status <> 'available' or (prop.expires_at is not null and prop.expires_at <= now()) then raise exception 'Solo puedes ofrecer propiedades activas'; end if;

  select p.id, p.display_name into ag from public.profiles p where p.id = p_agent and p.is_active and p.role = 'agent';
  if not found or p_agent = uid then raise exception 'Agente no disponible'; end if;
  select * into asub from public.subscriptions where user_id = p_agent and current_period_end > now();
  if not found then raise exception 'Ese agente no tiene un plan vigente'; end if;
  select * into apl from public.subscription_plans where code = asub.plan_code;
  if not apl.agent_tools then raise exception 'Ese agente no tiene un plan con herramientas de agente'; end if;

  begin n := (t ->> 'comision_porcentaje')::numeric; exception when others then n := null; end;
  if n is null or n < 0.5 or n > 15 then raise exception 'La comisión debe estar entre 0,5 %% y 15 %%'; end if;
  begin n := (t ->> 'plazo_dias')::numeric; exception when others then n := null; end;
  if n is null or n <> trunc(n) or n < 15 or n > 365 then raise exception 'El plazo debe ser de 15 a 365 días'; end if;
  if jsonb_typeof(t -> 'exclusividad') is distinct from 'boolean' then raise exception 'Indica si la oferta es con exclusividad'; end if;
  if char_length(btrim(coalesce(t ->> 'owner_nombre', ''))) not between 3 and 120 then raise exception 'Escribe tu nombre completo'; end if;
  if coalesce(t ->> 'owner_ci', '') !~ '^[0-9]{4,10}([ -]?[0-9A-Za-z]{1,3})?$' then raise exception 'C.I. inválida'; end if;
  if char_length(btrim(coalesce(t ->> 'owner_telefono', ''))) not between 7 and 30 then raise exception 'Escribe un teléfono de contacto'; end if;
  if char_length(coalesce(t ->> 'mensaje', '')) > 500 then raise exception 'El mensaje es demasiado largo (máximo 500 caracteres)'; end if;
  if exists (select 1 from public.owner_offers where property_id = p_property and agent_id = p_agent and status = 'pending') then
    raise exception 'Ya tienes una oferta pendiente de esta propiedad para ese agente'; end if;
  if (select count(*) from public.owner_offers where owner_id = uid and status = 'pending') >= 10 then
    raise exception 'Tienes demasiadas ofertas pendientes. Espera respuestas o cancela alguna.'; end if;

  select email, display_name into me from public.profiles where id = uid;
  yr := extract(year from ((now() at time zone 'UTC') - interval '4 hours'))::integer;     -- año de Bolivia (UTC-4)
  insert into public.owner_offer_counters (year, last_number) values (yr, 1)
  on conflict (year) do update set last_number = public.owner_offer_counters.last_number + 1 returning last_number into seq;
  num := 'BST-CO-' || yr || '-' || lpad(seq::text, 4, '0');

  insert into public.owner_offers (id, doc_number, owner_id, agent_id, property_id, property_data, owner_data, agent_data, terms)
  values (oid, num, uid, p_agent, p_property,
    jsonb_build_object('title', prop.title, 'location', prop.location, 'address', prop.address, 'price', prop.price, 'currency', coalesce(prop.currency, 'USD'),
      'area', prop.area, 'rooms', prop.rooms, 'baths', prop.baths, 'property_type', prop.property_type, 'operation', prop.operation,
      'code_number', prop.code_number, 'description', left(coalesce(prop.description, ''), 1000)),
    jsonb_build_object('nombre', btrim(t ->> 'owner_nombre'), 'ci', btrim(t ->> 'owner_ci'), 'telefono', btrim(t ->> 'owner_telefono'), 'email', me.email),
    jsonb_build_object('nombre', coalesce(nullif(btrim(ag.display_name), ''), 'Agente de Bastet')),
    jsonb_build_object('comision_porcentaje', (t ->> 'comision_porcentaje')::numeric, 'plazo_dias', (t ->> 'plazo_dias')::integer,
      'exclusividad', (t -> 'exclusividad')::boolean, 'mensaje', nullif(btrim(coalesce(t ->> 'mensaje', '')), '')));
  insert into public.owner_offer_events (offer_id, kind, actor) values (oid, 'created', uid);
  return jsonb_build_object('id', oid, 'doc_number', num);
end $$;

create or replace function public.respond_owner_offer(p_id uuid, p_accept boolean, p_note text default null)
returns void language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); o public.owner_offers; sub public.subscriptions; pl public.subscription_plans;
begin
  if uid is null or not public.is_active_user() then raise exception 'No autorizado' using errcode = '42501'; end if;
  select * into o from public.owner_offers where id = p_id and agent_id = uid for update;
  if not found then raise exception 'Oferta no encontrada'; end if;
  if o.status <> 'pending' then raise exception 'La oferta ya fue respondida o cancelada'; end if;
  if p_accept then
    select * into sub from public.subscriptions where user_id = uid and current_period_end > now();
    if not found then raise exception 'Necesitas un plan vigente para aceptar ofertas' using errcode = 'P0403', hint = 'no_subscription'; end if;
    select * into pl from public.subscription_plans where code = sub.plan_code;
    if not pl.agent_tools then raise exception 'Tu plan no incluye herramientas de agente' using errcode = 'P0403', hint = 'plan_tools'; end if;
  end if;
  if char_length(coalesce(p_note, '')) > 500 then raise exception 'La nota es demasiado larga (máximo 500 caracteres)'; end if;
  update public.owner_offers set status = case when p_accept then 'accepted' else 'rejected' end, response_note = nullif(btrim(coalesce(p_note, '')), ''), responded_at = now(),
         agent_data = case when p_accept then agent_data || (select coalesce(jsonb_strip_nulls(jsonb_build_object('ci', nullif(btrim(l.ci), ''), 'registro', nullif(btrim(l.registration), ''), 'telefono', nullif(btrim(l.phone), ''))), '{}'::jsonb) from (select 1) x left join public.agent_legal_profiles l on l.user_id = uid) else agent_data end
   where id = p_id;
  insert into public.owner_offer_events (offer_id, kind, actor, note) values (p_id, case when p_accept then 'accepted' else 'rejected' end, uid, nullif(btrim(coalesce(p_note, '')), ''));
end $$;

create or replace function public.cancel_owner_offer(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid();
begin
  if uid is null or not public.is_active_user() then raise exception 'No autorizado' using errcode = '42501'; end if;
  update public.owner_offers set status = 'canceled', responded_at = now() where id = p_id and owner_id = uid and status = 'pending';
  if not found then raise exception 'Oferta no encontrada o ya respondida'; end if;
  insert into public.owner_offer_events (offer_id, kind, actor) values (p_id, 'canceled', uid);
end $$;

-- 7) Permisos de las funciones
revoke all on function public.list_agent_directory() from public, anon;
revoke all on function public.create_legal_request(text, uuid, text) from public, anon;
revoke all on function public.cancel_legal_request(bigint) from public, anon;
revoke all on function public.admin_update_legal_request(bigint, text, text) from public, anon;
revoke all on function public.create_owner_offer(uuid, uuid, jsonb) from public, anon;
revoke all on function public.respond_owner_offer(uuid, boolean, text) from public, anon;
revoke all on function public.cancel_owner_offer(uuid) from public, anon;
grant execute on function public.list_agent_directory() to authenticated;
grant execute on function public.create_legal_request(text, uuid, text) to authenticated;
grant execute on function public.cancel_legal_request(bigint) to authenticated;
grant execute on function public.admin_update_legal_request(bigint, text, text) to authenticated;
grant execute on function public.create_owner_offer(uuid, uuid, jsonb) to authenticated;
grant execute on function public.respond_owner_offer(uuid, boolean, text) to authenticated;
grant execute on function public.cancel_owner_offer(uuid) to authenticated;

-- =====================================================================
-- UNO · Registro de nuevos usuarios + prueba gratuita de 7 días   — agregar al final de supabase/schema.sql
-- (después de subscriptions.sql y owner-services.sql). Idempotente: se puede correr completo más de una vez.
--
-- Qué hace:
--  · Cada persona que entra por primera vez llena un formulario (nombre, WhatsApp, ciudad, empresa, interés). Los datos quedan en
--    su perfil y se ven en el panel, sección "Usuarios" (solo administradores).
--  · Puede empezar una PRUEBA GRATUITA de 7 días con el plan Propietario (solo para cuentas de propietario) o elegir un plan desde el inicio.
--    La prueba es solo una vez por persona y solo si todavía no pidió ni tiene un plan; al terminar debe elegir un plan.
--  · my_subscription() informa también si ya se registró y si puede usar la prueba.
-- =====================================================================

do $$
begin
  if to_regclass('public.subscriptions') is null then
    raise exception 'Primero corre supabase/subscriptions.sql (y luego owner-services.sql)';
  end if;
end $$;

-- 1) Datos de registro en el perfil (privados: el sitio público solo lee las columnas que ya tenían permiso)
alter table public.profiles add column if not exists full_name     text;
alter table public.profiles add column if not exists whatsapp      text;
alter table public.profiles add column if not exists city          text;
alter table public.profiles add column if not exists company       text;
alter table public.profiles add column if not exists interest      text;
alter table public.profiles add column if not exists registered_at timestamptz;
alter table public.profiles add column if not exists trial_used_at timestamptz;
alter table public.profiles add column if not exists age_confirmed_at timestamptz;   -- confirmó tener 18 años o más (verificación de edad)
alter table public.profiles drop constraint if exists profiles_interest_check;
alter table public.profiles add constraint profiles_interest_check check (interest is null or interest in ('propietario', 'agente', 'empresa'));

-- Las suscripciones de prueba llevan source = 'trial'
alter table public.subscriptions drop constraint if exists subscriptions_source_check;
alter table public.subscriptions add constraint subscriptions_source_check check (source in ('payment', 'grace', 'admin', 'trial'));

-- 2) Quien no es admin no puede editar a mano su rol, estado, correo, fecha de registro ni su prueba (solo las funciones de abajo)
create or replace function public.protect_profile_privileged_columns()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is not null and not public.is_admin() then
    new.role := old.role;
    new.is_active := old.is_active;
    new.email := old.email;
    if coalesce(current_setting('uno.reg_rpc', true), '') <> '1' then
      new.registered_at := old.registered_at;
      new.trial_used_at := old.trial_used_at;
      new.age_confirmed_at := old.age_confirmed_at;
    end if;
  end if;
  -- Desde 2026-09-29 no se crean administradores nuevos desde la app: el rol solo se cambia desde el SQL Editor
  if auth.uid() is not null then
    new.role := old.role;
  end if;
  return new;
end;
$$;

-- 3) Antiabuso: la prueba es UNA sola por cuenta de Google. Se registra en una lista aparte (trial_claims) que NO se borra si el
--    usuario o su perfil se eliminan, así que volver a crear la cuenta con el mismo correo no da otra prueba. El correo se normaliza
--    (minúsculas; en Gmail se ignoran los puntos y el "+alias") para que ana.perez@gmail.com y anaperez+2@gmail.com cuenten como uno.
create table if not exists public.trial_claims (
  email_key  text primary key,
  user_id    uuid,
  claimed_at timestamptz not null default now()
);
alter table public.trial_claims enable row level security;      -- sin políticas: solo las funciones de este archivo la leen y escriben
revoke all on public.trial_claims from public, anon, authenticated;

create or replace function public._email_key(p_email text)
returns text language sql immutable as $$
  select case
    when split_part(lower(btrim(coalesce(p_email, ''))), '@', 2) in ('gmail.com', 'googlemail.com')
      then replace(split_part(split_part(lower(btrim(p_email)), '@', 1), '+', 1), '.', '') || '@gmail.com'
    else lower(btrim(coalesce(p_email, '')))
  end;
$$;

-- Quien ya usó la prueba antes de esta lista queda anotado
insert into public.trial_claims (email_key, user_id, claimed_at)
select public._email_key(email), id, trial_used_at from public.profiles where trial_used_at is not null and coalesce(email, '') <> ''
on conflict (email_key) do nothing;

-- ¿Puede usar la prueba? Una vez por cuenta de Google, sin plan, sin solicitudes de plan y sin ser admin
create or replace function public._trial_eligible(p_uid uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select not exists (select 1 from public.profiles where id = p_uid and (trial_used_at is not null or role = 'admin'))
     and not exists (select 1 from public.trial_claims c join public.profiles p on public._email_key(p.email) = c.email_key where p.id = p_uid)
     and not exists (select 1 from public.subscriptions where user_id = p_uid)
     and not exists (select 1 from public.subscription_requests where user_id = p_uid);
$$;

create or replace function public._start_trial(p_uid uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare res jsonb; pl text;
begin
  select interest into pl from public.profiles where id = p_uid;
  if pl is distinct from 'propietario' then raise exception 'La prueba gratuita de 7 días es solo para cuentas de propietario. Para agente o empresa elige un plan de pago'; end if;
  if not public._trial_eligible(p_uid) then
    raise exception 'La prueba gratuita ya no está disponible para tu cuenta' using errcode = 'P0403', hint = 'trial_unavailable';
  end if;
  perform set_config('uno.reg_rpc', '1', true);
  update public.profiles set trial_used_at = now() where id = p_uid;
  insert into public.trial_claims (email_key, user_id) select public._email_key(email), p_uid from public.profiles where id = p_uid and coalesce(email, '') <> '' on conflict (email_key) do nothing;
  res := public._activate_subscription(p_uid, pl, 'trial', 7, p_uid);
  insert into public.subscription_events (user_id, kind, plan_to, details, created_by) values (p_uid, 'trial_started', pl, jsonb_build_object('days', 7), p_uid);
  return res;
end $$;

-- 4) Formulario de registro (y, si lo pide, empieza la prueba)
-- Se cambió la firma (nuevo parámetro p_adult): se elimina la anterior para que no queden dos versiones
drop function if exists public.complete_registration(text, text, text, text, text, boolean, boolean);
create or replace function public.complete_registration(p_full_name text, p_whatsapp text, p_city text, p_company text, p_interest text, p_consent boolean, p_start_trial boolean default false, p_adult boolean default false)
returns jsonb language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); nm text := btrim(coalesce(p_full_name, '')); wa text := btrim(coalesce(p_whatsapp, ''));
begin
  if uid is null or not public.is_active_user() then raise exception 'No autorizado' using errcode = '42501'; end if;
  if public.is_admin() then raise exception 'Los administradores no necesitan registro'; end if;
  if char_length(nm) not between 3 and 120 then raise exception 'Escribe tu nombre completo'; end if;
  if wa !~ '^\+?[0-9 ()-]{7,30}$' then raise exception 'Escribe un WhatsApp válido (solo números, con código de país si es de otro país)'; end if;
  if char_length(btrim(coalesce(p_city, ''))) > 80 or char_length(btrim(coalesce(p_company, ''))) > 120 then raise exception 'Ciudad o empresa demasiado largas'; end if;
  if p_interest is null or p_interest not in ('propietario', 'agente', 'empresa') then raise exception 'Elige cómo usarás Bastet: propietario, agente o empresa'; end if;
  if p_start_trial and p_interest is distinct from 'propietario' then raise exception 'La prueba gratuita de 7 días es solo para propietarios. Para agente o empresa elige un plan de pago'; end if;
  if p_adult is not true then raise exception 'Debes confirmar que tienes 18 años o más para crear una cuenta'; end if;
  if p_consent is not true then raise exception 'Debes aceptar el uso de tus datos para continuar'; end if;

  perform set_config('uno.reg_rpc', '1', true);
  update public.profiles
     set full_name = nm, whatsapp = wa, city = nullif(btrim(coalesce(p_city, '')), ''), company = nullif(btrim(coalesce(p_company, '')), ''),
         interest = p_interest, registered_at = coalesce(registered_at, now()), age_confirmed_at = coalesce(age_confirmed_at, now()),
         display_name = coalesce(nullif(btrim(coalesce(display_name, '')), ''), nm)
   where id = uid;
  if p_start_trial then perform public._start_trial(uid); end if;
  return public.my_subscription();
end $$;

-- Quien ya se registró pero todavía no pidió un plan puede empezar la prueba más tarde
create or replace function public.start_free_trial()
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null or not public.is_active_user() then raise exception 'No autorizado' using errcode = '42501'; end if;
  if not exists (select 1 from public.profiles where id = auth.uid() and registered_at is not null) then
    raise exception 'Primero completa tu registro'; end if;
  perform public._start_trial(auth.uid());
  return public.my_subscription();
end $$;

-- 5) my_subscription ahora informa del registro y de la prueba
create or replace function public.my_subscription()
returns jsonb language plpgsql security definer set search_path = public stable as $$
declare
  uid  uuid := auth.uid();
  sub  public.subscriptions;
  pl   public.subscription_plans;
  rq   public.subscription_requests;
  st   text;
  feat integer := 0;
  reg  boolean;
  extra jsonb;
begin
  if uid is null or not public.is_active_user() then raise exception 'No autorizado' using errcode = '42501'; end if;
  select registered_at is not null into reg from public.profiles where id = uid;
  select * into rq from public.subscription_requests where user_id = uid and status = 'pending';
  extra := jsonb_build_object('registered', coalesce(reg, false), 'trial_eligible', public._trial_eligible(uid),
                              'trial_used', exists (select 1 from public.profiles where id = uid and trial_used_at is not null),
                              'interest', (select interest from public.profiles where id = uid));
  if public.is_admin() then
    return extra || jsonb_build_object('exempt', true, 'registered', true, 'status', 'admin', 'plan', null,
      'usage', jsonb_build_object('active_properties', public._count_active_properties(uid), 'featured_used', 0),
      'pending_request', null);
  end if;
  select * into sub from public.subscriptions where user_id = uid;
  if not found then
    return extra || jsonb_build_object('exempt', false, 'status', 'none', 'plan', null,
      'usage', jsonb_build_object('active_properties', public._count_active_properties(uid), 'featured_used', 0),
      'pending_request', case when rq.id is null then null else to_jsonb(rq) end);
  end if;
  select * into pl from public.subscription_plans where code = sub.plan_code;
  st := case when sub.current_period_end <= now() then 'expired' when sub.cancel_at_period_end then 'canceling' else 'active' end;
  if st <> 'expired' then
    select count(*) into feat from public.featured_activations where user_id = uid and created_at >= public._featured_cycle_start(sub.current_period_start);
  end if;
  return extra || jsonb_build_object(
    'exempt', false, 'status', st, 'source', sub.source,
    'plan', jsonb_build_object('code', pl.code, 'name', pl.name, 'price_bs', pl.price_bs, 'max_active_properties', pl.max_active_properties,
                               'max_featured_per_period', pl.max_featured_per_period, 'agent_tools', pl.agent_tools),
    'period_start', sub.current_period_start, 'period_end', sub.current_period_end, 'cancel_at_period_end', sub.cancel_at_period_end,
    'usage', jsonb_build_object('active_properties', public._count_active_properties(uid), 'featured_used', feat,
                                'featured_cycle_start', case when st = 'expired' then null else public._featured_cycle_start(sub.current_period_start) end),
    'pending_request', case when rq.id is null then null else to_jsonb(rq) end);
end $$;

-- 6) Permisos
revoke all on function public._email_key(text) from public, anon, authenticated;
revoke all on function public._trial_eligible(uuid) from public, anon, authenticated;
revoke all on function public._start_trial(uuid) from public, anon, authenticated;
revoke all on function public.complete_registration(text, text, text, text, text, boolean, boolean, boolean) from public, anon;
revoke all on function public.start_free_trial() from public, anon;
revoke all on function public.my_subscription() from public, anon;
grant execute on function public.complete_registration(text, text, text, text, text, boolean, boolean, boolean) to authenticated;
grant execute on function public.start_free_trial() to authenticated;
grant execute on function public.my_subscription() to authenticated;

-- 7) Pide a la API de Supabase que recargue su caché de funciones (evita "Could not find the function … in the schema cache")
notify pgrst, 'reload schema';

-- =====================================================================
-- UNO · Comprobantes de pago de suscripción   — agregar al final de supabase/schema.sql
-- (después de subscriptions.sql y registration.sql). Idempotente: se puede correr completo más de una vez.
--
-- Qué hace: quien solicita un plan puede adjuntar la foto o PDF de su comprobante de pago (transferencia, QR). Se guarda en una
-- carpeta PRIVADA (payment-proofs/<id de usuario>/…): cada persona solo ve la suya y los administradores ven todas, mediante
-- enlaces firmados de corta duración, para verificar el pago antes de confirmarlo.
-- =====================================================================

do $$
begin
  if to_regclass('public.subscription_requests') is null then
    raise exception 'Primero corre supabase/subscriptions.sql';
  end if;
end $$;

alter table public.subscription_requests add column if not exists proof_path text;
alter table public.subscription_requests drop constraint if exists subscription_requests_proof_path_check;
alter table public.subscription_requests add constraint subscription_requests_proof_path_check check (proof_path is null or char_length(proof_path) <= 300);

-- Carpeta privada: imágenes y PDF de hasta 5 MB
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('payment-proofs', 'payment-proofs', false, 5242880, array['application/pdf', 'image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do update set public = false, file_size_limit = 5242880, allowed_mime_types = array['application/pdf', 'image/jpeg', 'image/png', 'image/webp'];

drop policy if exists "users upload own payment proof" on storage.objects;
create policy "users upload own payment proof" on storage.objects for insert to authenticated
  with check (bucket_id = 'payment-proofs' and (storage.foldername(name))[1] = auth.uid()::text);
drop policy if exists "users read own payment proof" on storage.objects;
create policy "users read own payment proof" on storage.objects for select to authenticated
  using (bucket_id = 'payment-proofs' and (storage.foldername(name))[1] = auth.uid()::text);
drop policy if exists "admin reads payment proofs" on storage.objects;
create policy "admin reads payment proofs" on storage.objects for select to authenticated
  using (bucket_id = 'payment-proofs' and public.is_admin());
drop policy if exists "admin deletes payment proofs" on storage.objects;
create policy "admin deletes payment proofs" on storage.objects for delete to authenticated
  using (bucket_id = 'payment-proofs' and public.is_admin());

-- Asocia el archivo subido con la solicitud pendiente de la persona (solo dentro de su propia carpeta)
create or replace function public.attach_payment_proof(p_request_id bigint, p_path text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null or not public.is_active_user() then raise exception 'No autorizado' using errcode = '42501'; end if;
  if p_path is null or char_length(p_path) > 300 or p_path not like auth.uid()::text || '/%' or p_path like '%..%' then
    raise exception 'Comprobante inválido'; end if;
  update public.subscription_requests set proof_path = p_path
   where id = p_request_id and user_id = auth.uid() and status = 'pending';
  if not found then raise exception 'No hay una solicitud pendiente para adjuntar el comprobante'; end if;
end $$;

revoke all on function public.attach_payment_proof(bigint, text) from public, anon;
grant execute on function public.attach_payment_proof(bigint, text) to authenticated;

notify pgrst, 'reload schema';

-- =====================================================================
-- UNO · WhatsApp de contacto del agente (público)   — agregar al final de supabase/schema.sql
-- Idempotente: se puede correr completo más de una vez.
--
-- Qué hace: cada agente puede poner su WhatsApp de contacto en «Mi cuenta». Se muestra como ícono de WhatsApp en sus propiedades
-- (junto a Facebook, Instagram y TikTok). Es una columna APARTE de profiles.whatsapp (el WhatsApp privado del registro), para no
-- publicar por error el número de quien solo se registró: solo contact_whatsapp es de lectura pública.
-- =====================================================================

alter table public.profiles add column if not exists contact_whatsapp text;
alter table public.profiles drop constraint if exists profiles_contact_whatsapp_check;
alter table public.profiles add constraint profiles_contact_whatsapp_check
  check (contact_whatsapp is null or contact_whatsapp ~ '^\+?[0-9 ()-]{7,30}$');

-- Lectura pública de esa única columna nueva (la política de filas «public can read active agent public info» sigue limitando a agentes activos)
grant select (contact_whatsapp) on public.profiles to anon;

-- Quien se registró como agente o empresa parte con su WhatsApp del registro (puede cambiarlo o borrarlo en Mi cuenta)
do $$
begin
  if exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'profiles' and column_name = 'interest') then
    update public.profiles
       set contact_whatsapp = btrim(whatsapp)
     where contact_whatsapp is null and interest in ('agente', 'empresa') and whatsapp ~ '^\+?[0-9 ()-]{7,30}$';
  end if;
end $$;

notify pgrst, 'reload schema';

-- =====================================================================
-- UNO · «Vender mi inmueble» acepta también la operación TEMPORAL   — agregar al final de supabase/schema.sql
-- Idempotente: se puede correr completo más de una vez.
--
-- Qué hace: el formulario público «Vender mi inmueble» ahora permite elegir «Temporal (por noche)» para quienes quieren ofrecer su
-- inmueble como alojamiento temporal. Solo amplía la lista de operaciones permitidas de sell_requests; nada más cambia.
-- =====================================================================

do $$
declare c record;
begin
  if to_regclass('public.sell_requests') is null then
    raise exception 'Primero corre supabase/sell-requests.sql';
  end if;
  -- se elimina la restricción actual de «operation» (su nombre automático) y se vuelve a crear con «temporal»
  for c in select conname from pg_constraint
            where conrelid = 'public.sell_requests'::regclass and contype = 'c' and pg_get_constraintdef(oid) ilike '%operation%' loop
    execute format('alter table public.sell_requests drop constraint %I', c.conname);
  end loop;
  alter table public.sell_requests add constraint sell_requests_operation_check
    check (operation in ('venta', 'anticretico', 'alquiler', 'temporal'));
end $$;

notify pgrst, 'reload schema';

-- =====================================================================
-- UNO · Estadías temporales: ubicación en el mapa, calificaciones y reseñas de huéspedes   — agregar al final de supabase/schema.sql
-- Idempotente: se puede correr completo más de una vez.
--
-- Qué hace:
--  1) properties.latitude / longitude: el punto exacto que el anfitrión marca en el mapa (para mostrar la ubicación en la ficha).
--  2) PRIVACIDAD: hasta ahora cualquier visitante podía leer TODAS las columnas de las propiedades disponibles con la clave pública de
--     la API, incluido owner_whatsapp (el teléfono privado del propietario). Desde aquí el visitante anónimo solo puede leer las columnas
--     públicas. Si agregas una columna pública nueva a properties, hay que darle permiso con «grant select (columna) on public.properties to anon».
--  3) Reseñas: el anfitrión (propietario, agente o empresa) genera un ENLACE DE RESEÑA de un solo uso para cada huésped que se alojó;
--     el huésped califica de 1 a 5 estrellas y escribe su reseña sin necesitar cuenta. Así solo reseñan quienes recibieron el enlace.
--     El anfitrión puede responder y un administrador puede ocultar reseñas inapropiadas.
-- =====================================================================

do $$
begin
  if to_regclass('public.properties') is null then raise exception 'Primero corre supabase/schema.sql'; end if;
end $$;

-- 1) Ubicación
alter table public.properties add column if not exists latitude  double precision;
alter table public.properties add column if not exists longitude double precision;
alter table public.properties drop constraint if exists properties_latlng_check;
alter table public.properties add constraint properties_latlng_check
  check ((latitude is null) = (longitude is null) and (latitude is null or (latitude between -90 and 90 and longitude between -180 and 180)));

-- 2) El visitante anónimo solo lee columnas públicas (nunca owner_whatsapp ni datos internos de renovación)
revoke select on public.properties from anon;
grant select (id, title, location, address, price, currency, exchange_rate, area, rooms, baths, description, photos, whatsapp, owner_id,
              featured, featured_until, sort_order, status, created_at, code_number, property_type, operation, floors, has_garage, garage_spots,
              has_storage, pets_allowed, kids_allowed, expires_at, latitude, longitude)
  on public.properties to anon;

-- 3) Reseñas de huéspedes
create table if not exists public.stay_review_invites (
  id          uuid primary key default gen_random_uuid(),
  property_id uuid not null references public.properties(id) on delete cascade,
  host_id     uuid not null references auth.users(id) on delete cascade,
  token       text not null unique,
  guest_name  text check (guest_name is null or char_length(guest_name) <= 80),
  created_at  timestamptz not null default now(),
  used_at     timestamptz
);
create index if not exists stay_review_invites_property_idx on public.stay_review_invites (property_id, used_at);

create table if not exists public.stay_reviews (
  id          uuid primary key default gen_random_uuid(),
  property_id uuid not null references public.properties(id) on delete cascade,
  invite_id   uuid unique references public.stay_review_invites(id) on delete set null,
  guest_name  text not null check (char_length(btrim(guest_name)) between 2 and 60),
  rating      smallint not null check (rating between 1 and 5),
  comment     text check (comment is null or char_length(comment) <= 1200),
  host_reply  text check (host_reply is null or char_length(host_reply) <= 800),
  replied_at  timestamptz,
  status      text not null default 'published' check (status in ('published', 'hidden')),
  created_at  timestamptz not null default now()
);
create index if not exists stay_reviews_property_idx on public.stay_reviews (property_id, status, created_at desc);

-- Nadie lee ni escribe estas tablas directamente: todo pasa por las funciones de abajo
alter table public.stay_review_invites enable row level security;
alter table public.stay_reviews enable row level security;
revoke all on public.stay_review_invites, public.stay_reviews from anon, authenticated;

-- El anfitrión crea un enlace de reseña (un solo uso) para un huésped
create or replace function public.create_review_invite(p_property uuid, p_guest text default null)
returns text language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); prop record; tok text; tries int := 0;
begin
  if uid is null or not public.is_active_user() then raise exception 'No autorizado' using errcode = '42501'; end if;
  select id, owner_id, operation, status into prop from public.properties where id = p_property;
  if not found or (prop.owner_id is distinct from uid and not public.is_admin()) then raise exception 'Propiedad no encontrada'; end if;
  if prop.operation is distinct from 'temporal' then raise exception 'Las reseñas son solo para alojamientos temporales'; end if;
  if (select count(*) from public.stay_review_invites where property_id = p_property and used_at is null) >= 20 then
    raise exception 'Ya tienes 20 enlaces de reseña sin usar en esta propiedad. Espera a que los huéspedes los usen o elimina alguno.';
  end if;
  if (select count(*) from public.stay_review_invites where property_id = p_property and created_at > now() - interval '30 days') >= 60 then
    raise exception 'Alcanzaste el máximo de enlaces de reseña de este mes para esta propiedad.';
  end if;
  loop
    tok := upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 12));
    begin
      insert into public.stay_review_invites (property_id, host_id, token, guest_name)
      values (p_property, uid, tok, nullif(btrim(coalesce(p_guest, '')), ''));
      return tok;
    exception when unique_violation then
      tries := tries + 1; if tries > 5 then raise; end if;
    end;
  end loop;
end $$;

-- El anfitrión elimina un enlace que aún no se usó
create or replace function public.revoke_review_invite(p_token text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null or not public.is_active_user() then raise exception 'No autorizado' using errcode = '42501'; end if;
  delete from public.stay_review_invites where token = upper(btrim(coalesce(p_token, ''))) and used_at is null and (host_id = auth.uid() or public.is_admin());
  if not found then raise exception 'Enlace no encontrado o ya usado'; end if;
end $$;

-- Datos mínimos del enlace para mostrar el formulario (no revela nada del anfitrión)
create or replace function public.get_review_invite(p_token text)
returns jsonb language plpgsql security definer set search_path = public stable as $$
declare i record;
begin
  select v.guest_name, v.used_at, p.title, p.location into i
    from public.stay_review_invites v join public.properties p on p.id = v.property_id
   where v.token = upper(btrim(coalesce(p_token, '')));
  if not found then return jsonb_build_object('valid', false); end if;
  return jsonb_build_object('valid', i.used_at is null, 'used', i.used_at is not null, 'guest_name', i.guest_name, 'title', i.title, 'location', i.location);
end $$;

-- El huésped envía su reseña con el enlace (sin cuenta). Un enlace sirve una sola vez.
create or replace function public.submit_stay_review(p_token text, p_name text, p_rating integer, p_comment text)
returns boolean language plpgsql security definer set search_path = public as $$
declare i public.stay_review_invites; nm text := btrim(coalesce(p_name, '')); cm text := nullif(btrim(coalesce(p_comment, '')), '');
begin
  select * into i from public.stay_review_invites where token = upper(btrim(coalesce(p_token, ''))) for update;
  if not found then raise exception 'Este enlace de reseña no es válido'; end if;
  if i.used_at is not null then raise exception 'Este enlace de reseña ya se usó. ¡Gracias por tu opinión!'; end if;
  if char_length(nm) not between 2 and 60 then raise exception 'Escribe tu nombre (entre 2 y 60 letras)'; end if;
  if p_rating is null or p_rating not between 1 and 5 then raise exception 'Elige de 1 a 5 estrellas'; end if;
  if cm is not null and char_length(cm) > 1200 then raise exception 'La reseña es demasiado larga (máximo 1200 caracteres)'; end if;
  insert into public.stay_reviews (property_id, invite_id, guest_name, rating, comment) values (i.property_id, i.id, nm, p_rating, cm);
  update public.stay_review_invites set used_at = now() where id = i.id;
  return true;
end $$;

-- Calificación promedio y cantidad de reseñas por propiedad (solo publicadas)
create or replace function public.list_stay_ratings(p_ids uuid[])
returns table (property_id uuid, avg_rating numeric, review_count integer)
language sql security definer set search_path = public stable as $$
  select r.property_id, round(avg(r.rating)::numeric, 2), count(*)::integer
    from public.stay_reviews r
   where r.status = 'published' and r.property_id = any (coalesce(p_ids, '{}'::uuid[])) and coalesce(array_length(p_ids, 1), 0) <= 300
   group by r.property_id;
$$;

-- Reseñas publicadas de una propiedad (el nombre se muestra como «Nombre A.»)
create or replace function public.list_stay_reviews(p_property uuid, p_limit integer default 30)
returns table (id uuid, guest_name text, rating smallint, comment text, host_reply text, created_at timestamptz)
language sql security definer set search_path = public stable as $$
  select r.id,
         split_part(btrim(r.guest_name), ' ', 1) || coalesce(' ' || upper(left(nullif(split_part(btrim(r.guest_name), ' ', 2), ''), 1)) || '.', ''),
         r.rating, r.comment, r.host_reply, r.created_at
    from public.stay_reviews r
   where r.property_id = p_property and r.status = 'published'
   order by r.created_at desc
   limit least(greatest(coalesce(p_limit, 30), 1), 100);
$$;

-- Panel del anfitrión: todas las reseñas (también las ocultas) y los enlaces pendientes
create or replace function public.host_stay_reviews(p_property uuid)
returns jsonb language plpgsql security definer set search_path = public stable as $$
declare uid uuid := auth.uid(); owner uuid;
begin
  if uid is null or not public.is_active_user() then raise exception 'No autorizado' using errcode = '42501'; end if;
  select owner_id into owner from public.properties where id = p_property;
  if not found or (owner is distinct from uid and not public.is_admin()) then raise exception 'Propiedad no encontrada'; end if;
  return jsonb_build_object(
    'reviews', coalesce((select jsonb_agg(jsonb_build_object('id', r.id, 'guest_name', r.guest_name, 'rating', r.rating, 'comment', r.comment,
                          'host_reply', r.host_reply, 'status', r.status, 'created_at', r.created_at) order by r.created_at desc)
                         from public.stay_reviews r where r.property_id = p_property), '[]'::jsonb),
    'invites', coalesce((select jsonb_agg(jsonb_build_object('token', v.token, 'guest_name', v.guest_name, 'created_at', v.created_at) order by v.created_at desc)
                         from public.stay_review_invites v where v.property_id = p_property and v.used_at is null), '[]'::jsonb));
end $$;

-- El anfitrión responde a una reseña de su propiedad
create or replace function public.reply_stay_review(p_review uuid, p_reply text)
returns void language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); rp text := nullif(btrim(coalesce(p_reply, '')), '');
begin
  if uid is null or not public.is_active_user() then raise exception 'No autorizado' using errcode = '42501'; end if;
  if rp is not null and char_length(rp) > 800 then raise exception 'La respuesta es demasiado larga (máximo 800 caracteres)'; end if;
  update public.stay_reviews r set host_reply = rp, replied_at = case when rp is null then null else now() end
   where r.id = p_review and exists (select 1 from public.properties p where p.id = r.property_id and (p.owner_id = uid or public.is_admin()));
  if not found then raise exception 'Reseña no encontrada'; end if;
end $$;

-- Un administrador oculta o vuelve a publicar una reseña
create or replace function public.admin_set_review_status(p_review uuid, p_status text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Solo administradores' using errcode = '42501'; end if;
  if p_status not in ('published', 'hidden') then raise exception 'Estado inválido'; end if;
  update public.stay_reviews set status = p_status where id = p_review;
  if not found then raise exception 'Reseña no encontrada'; end if;
end $$;

revoke all on function public.create_review_invite(uuid, text), public.revoke_review_invite(text), public.get_review_invite(text),
  public.submit_stay_review(text, text, integer, text), public.list_stay_ratings(uuid[]), public.list_stay_reviews(uuid, integer),
  public.host_stay_reviews(uuid), public.reply_stay_review(uuid, text), public.admin_set_review_status(uuid, text) from public, anon;
grant execute on function public.get_review_invite(text), public.submit_stay_review(text, text, integer, text),
  public.list_stay_ratings(uuid[]), public.list_stay_reviews(uuid, integer) to anon, authenticated;
grant execute on function public.create_review_invite(uuid, text), public.revoke_review_invite(text), public.host_stay_reviews(uuid),
  public.reply_stay_review(uuid, text), public.admin_set_review_status(uuid, text) to authenticated;

notify pgrst, 'reload schema';

-- =====================================================================
-- UNO · Estadías temporales: calendario de NO disponibilidad   — agregar al final de supabase/schema.sql
-- Idempotente: se puede correr completo más de una vez.
--
-- Qué hace: el anfitrión marca en un calendario entre qué fechas su alojamiento temporal NO estará disponible (o «desde hoy hasta que
-- yo lo reactive»). Mientras una propiedad está bloqueada no aparece en Estadías, y vuelve a aparecer sola cuando termina el periodo.
-- También se ocultan de la búsqueda cuando las fechas que elige el visitante chocan con un bloqueo. Las fechas se calculan con la hora
-- de Bolivia. El visitante solo ve las fechas bloqueadas (nunca la nota privada).
-- =====================================================================

create table if not exists public.stay_blocks (
  id          uuid primary key default gen_random_uuid(),
  property_id uuid not null references public.properties(id) on delete cascade,
  from_date   date not null,
  to_date     date,                                  -- null = sin fecha de regreso (hasta que el anfitrión lo reactive)
  note        text check (note is null or char_length(note) <= 120),
  created_by  uuid references auth.users(id) on delete set null,
  created_at  timestamptz not null default now(),
  constraint stay_blocks_range_check check (to_date is null or to_date >= from_date)
);
create index if not exists stay_blocks_property_idx on public.stay_blocks (property_id, to_date);

alter table public.stay_blocks enable row level security;
revoke all on public.stay_blocks from anon, authenticated;

-- Fecha de hoy en Bolivia (UTC-4, sin horario de verano)
create or replace function public.bo_today() returns date language sql stable as $$ select ((now() at time zone 'UTC') - interval '4 hours')::date $$;

-- El anfitrión (o un admin) bloquea fechas de su alojamiento temporal
create or replace function public.set_stay_block(p_property uuid, p_from date, p_to date default null, p_note text default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); prop record; new_id uuid;
begin
  if uid is null or not public.is_active_user() then raise exception 'No autorizado' using errcode = '42501'; end if;
  select id, owner_id, operation into prop from public.properties where id = p_property;
  if not found or (prop.owner_id is distinct from uid and not public.is_admin()) then raise exception 'Propiedad no encontrada'; end if;
  if prop.operation is distinct from 'temporal' then raise exception 'El calendario es solo para alojamientos temporales'; end if;
  if p_from is null then raise exception 'Indica desde qué fecha no estará disponible'; end if;
  if p_to is not null and p_to < p_from then raise exception 'La fecha de regreso no puede ser antes de la de inicio'; end if;
  if coalesce(p_to, p_from) < public.bo_today() then raise exception 'Las fechas ya pasaron'; end if;
  if (select count(*) from public.stay_blocks where property_id = p_property and (to_date is null or to_date >= public.bo_today())) >= 40 then
    raise exception 'Ya tienes 40 periodos bloqueados en esta propiedad. Elimina alguno.';
  end if;
  insert into public.stay_blocks (property_id, from_date, to_date, note, created_by)
  values (p_property, p_from, p_to, nullif(btrim(coalesce(p_note, '')), ''), uid) returning id into new_id;
  return new_id;
end $$;

-- El anfitrión quita un bloqueo (reactiva esas fechas)
create or replace function public.delete_stay_block(p_block uuid)
returns void language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid();
begin
  if uid is null or not public.is_active_user() then raise exception 'No autorizado' using errcode = '42501'; end if;
  delete from public.stay_blocks b where b.id = p_block
    and exists (select 1 from public.properties p where p.id = b.property_id and (p.owner_id = uid or public.is_admin()));
  if not found then raise exception 'Bloqueo no encontrado'; end if;
end $$;

-- Los bloqueos vigentes o futuros de mis propiedades (el panel los muestra en cada tarjeta; el admin ve los de todas)
create or replace function public.my_stay_blocks()
returns table (id uuid, property_id uuid, from_date date, to_date date, note text)
language plpgsql security definer set search_path = public stable as $$
declare uid uuid := auth.uid();
begin
  if uid is null or not public.is_active_user() then raise exception 'No autorizado' using errcode = '42501'; end if;
  return query select b.id, b.property_id, b.from_date, b.to_date, b.note
    from public.stay_blocks b join public.properties p on p.id = b.property_id
    where (p.owner_id = uid or public.is_admin()) and (b.to_date is null or b.to_date >= public.bo_today())
    order by b.from_date;
end $$;

-- Público: fechas bloqueadas vigentes o futuras de las propiedades pedidas (sin notas)
create or replace function public.stay_blocked_ranges(p_ids uuid[])
returns table (property_id uuid, from_date date, to_date date)
language sql security definer set search_path = public stable as $$
  select b.property_id, b.from_date, b.to_date from public.stay_blocks b
  where b.property_id = any(p_ids) and (b.to_date is null or b.to_date >= public.bo_today())
  order by b.from_date
$$;

revoke all on function public.set_stay_block(uuid, date, date, text), public.delete_stay_block(uuid), public.my_stay_blocks(),
  public.stay_blocked_ranges(uuid[]) from public, anon;
grant execute on function public.stay_blocked_ranges(uuid[]), public.bo_today() to anon, authenticated;
grant execute on function public.set_stay_block(uuid, date, date, text), public.delete_stay_block(uuid), public.my_stay_blocks() to authenticated;

notify pgrst, 'reload schema';

-- =====================================================================
-- UNO · «Solicitar una propiedad» (comprador / inquilino): solicitudes de búsqueda   — agregar al final de supabase/schema.sql
-- Idempotente: se puede correr completo más de una vez.
--
-- Un visitante (con o sin cuenta) describe qué propiedad busca (operación, tipo, ciudad, características, presupuesto y contacto).
-- La solicitud queda registrada para que un asesor de Bastet la atienda; el visitante puede ver el estado de sus solicitudes
-- («Activa», «En proceso», «Finalizada») y finalizar la suya. El administrador las ve y cambia su estado.
-- Nadie lee la tabla directamente: todo pasa por funciones. Supone que existen: public.is_admin().
-- =====================================================================

create table if not exists public.property_requests (
  id            uuid primary key,                                   -- lo genera el navegador: el visitante lo guarda para ver su estado
  user_id       uuid references auth.users(id) on delete set null,   -- si estaba con sesión
  operation     text not null check (operation in ('venta','alquiler','anticretico','temporal')),
  property_type text not null check (property_type in ('casa','departamento','terreno','oficina','local','otro')),
  city          text not null check (char_length(city) between 2 and 60),
  zone          text check (zone is null or char_length(zone) <= 120),
  rooms_min     integer check (rooms_min is null or rooms_min between 0 and 99),
  baths_min     integer check (baths_min is null or baths_min between 0 and 99),
  area_min      numeric check (area_min is null or (area_min >= 0 and area_min < 100000000)),
  area_max      numeric check (area_max is null or (area_max >= 0 and area_max < 100000000)),
  features      text[] not null default '{}',                        -- comodidades y servicios cercanos que le importan
  budget_min    numeric check (budget_min is null or (budget_min >= 0 and budget_min < 1000000000)),
  budget_max    numeric check (budget_max is null or (budget_max >= 0 and budget_max < 1000000000)),
  currency      text not null default 'USD' check (currency in ('USD','BOB')),
  description   text check (description is null or char_length(description) <= 1000),
  contact_name  text not null check (char_length(contact_name) between 3 and 120),
  contact_phone text not null check (contact_phone ~ '^\+?[0-9]{7,15}$'),
  contact_email text check (contact_email is null or (char_length(contact_email) between 5 and 160 and contact_email like '%@%')),
  consent       boolean not null check (consent),
  status        text not null default 'active' check (status in ('active','in_progress','finished')),
  admin_note    text check (admin_note is null or char_length(admin_note) <= 1000),
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  check (budget_min is null or budget_max is null or budget_max >= budget_min),
  check (area_min is null or area_max is null or area_max >= area_min),
  check (cardinality(features) <= 20)
);
create index if not exists property_requests_status_idx on public.property_requests (status, created_at desc);
create index if not exists property_requests_user_idx on public.property_requests (user_id);
create index if not exists property_requests_phone_idx on public.property_requests (contact_phone, created_at);

alter table public.property_requests enable row level security;
revoke all on public.property_requests from anon, authenticated;

-- Envío público (con o sin cuenta). Devuelve el id.
create or replace function public.submit_property_request(p jsonb)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  rid uuid;
  ph  text := regexp_replace(coalesce(p->>'contact_phone', ''), '[\s().-]', '', 'g');
  feats text[];
  num numeric;
begin
  begin rid := (p->>'id')::uuid; exception when others then raise exception 'Solicitud no válida.'; end;
  if rid is null then raise exception 'Solicitud no válida.'; end if;
  if coalesce((p->>'consent')::boolean, false) is not true then raise exception 'Debes aceptar que usemos tus datos para contactarte.'; end if;
  if ph !~ '^\+?[0-9]{7,15}$' then raise exception 'Escribe un número de WhatsApp válido (solo dígitos, con + si incluye código de país).'; end if;
  if exists (select 1 from public.property_requests where id = rid) then return rid; end if;     -- reintento del mismo envío

  if (select count(*) from public.property_requests where contact_phone = ph and created_at > now() - interval '24 hours') >= 3 then
    raise exception 'Ya recibimos tus solicitudes. Un asesor te contactará pronto.';
  end if;
  if (select count(*) from public.property_requests where created_at > now() - interval '24 hours') >= 200 then
    raise exception 'Hay muchas solicitudes en este momento. Inténtalo más tarde o escríbenos por WhatsApp.';
  end if;

  select coalesce(array_agg(left(btrim(x), 40)) filter (where btrim(x) <> ''), '{}') into feats
    from jsonb_array_elements_text(case when jsonb_typeof(p->'features') = 'array' then p->'features' else '[]'::jsonb end) x;

  insert into public.property_requests (id, user_id, operation, property_type, city, zone, rooms_min, baths_min, area_min, area_max, features,
    budget_min, budget_max, currency, description, contact_name, contact_phone, contact_email, consent)
  values (rid, auth.uid(), p->>'operation', p->>'property_type', btrim(coalesce(p->>'city', '')), nullif(btrim(coalesce(p->>'zone', '')), ''),
    nullif(p->>'rooms_min', '')::int, nullif(p->>'baths_min', '')::int, nullif(p->>'area_min', '')::numeric, nullif(p->>'area_max', '')::numeric, feats,
    nullif(p->>'budget_min', '')::numeric, nullif(p->>'budget_max', '')::numeric, coalesce(nullif(p->>'currency', ''), 'USD'),
    nullif(btrim(coalesce(p->>'description', '')), ''), btrim(coalesce(p->>'contact_name', '')), ph, nullif(btrim(coalesce(p->>'contact_email', '')), ''), true);
  return rid;
end $$;

-- Estado de mis solicitudes: las que pido por id (las guardó este navegador) y, si hay sesión, todas las de mi cuenta
create or replace function public.my_property_requests(p_ids uuid[] default '{}')
returns table (id uuid, operation text, property_type text, city text, zone text, budget_min numeric, budget_max numeric, currency text, status text, created_at timestamptz)
language sql security definer set search_path = public stable as $$
  select r.id, r.operation, r.property_type, r.city, r.zone, r.budget_min, r.budget_max, r.currency, r.status, r.created_at
  from public.property_requests r
  where r.id = any(coalesce(p_ids, '{}')) or (auth.uid() is not null and r.user_id = auth.uid())
  order by r.created_at desc limit 50
$$;

-- El solicitante finaliza la suya (ya encontró lo que buscaba)
create or replace function public.finish_property_request(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  update public.property_requests set status = 'finished', updated_at = now() where id = p_id;
  if not found then raise exception 'Solicitud no encontrada'; end if;
end $$;

-- Administración
create or replace function public.admin_property_requests()
returns setof public.property_requests language plpgsql security definer set search_path = public stable as $$
begin
  if not public.is_admin() then raise exception 'No autorizado' using errcode = '42501'; end if;
  return query select * from public.property_requests order by created_at desc limit 500;
end $$;

create or replace function public.admin_set_property_request_status(p_id uuid, p_status text, p_note text default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'No autorizado' using errcode = '42501'; end if;
  if p_status not in ('active','in_progress','finished') then raise exception 'Estado no válido'; end if;
  update public.property_requests set status = p_status, admin_note = coalesce(nullif(btrim(coalesce(p_note, '')), ''), admin_note), updated_at = now() where id = p_id;
  if not found then raise exception 'Solicitud no encontrada'; end if;
end $$;

revoke all on function public.submit_property_request(jsonb), public.my_property_requests(uuid[]), public.finish_property_request(uuid),
  public.admin_property_requests(), public.admin_set_property_request_status(uuid, text, text) from public, anon;
grant execute on function public.submit_property_request(jsonb), public.my_property_requests(uuid[]), public.finish_property_request(uuid) to anon, authenticated;
grant execute on function public.admin_property_requests(), public.admin_set_property_request_status(uuid, text, text) to authenticated;

notify pgrst, 'reload schema';

-- =====================================================================
-- Bastet · "Vender mi inmueble": paso «Fotos» (agregar al final de supabase/schema.sql, después de sell-requests.sql).
-- Idempotente. Las fotos viajan en la misma columna `documents` con type = 'foto' (misma carpeta privada `sell-documents`):
--   · hasta 8 fotos (solo imágenes) además de los 12 documentos de siempre → tope total 20 archivos;
--   · elegir «No tengo documentos» ya NO borra las fotos (solo los documentos).
-- Supone que existen: public.sell_requests y public.submit_sell_request() de supabase/sell-requests.sql.
-- =====================================================================

-- El tope de la tabla pasa de 12 a 20 archivos en total (12 documentos + 8 fotos)
do $$
declare c text;
begin
  for c in select conname from pg_constraint
           where conrelid = 'public.sell_requests'::regclass and contype = 'c'
             and pg_get_constraintdef(oid) like '%jsonb_array_length(documents)%' and conname <> 'sell_requests_documents_chk'
  loop
    execute format('alter table public.sell_requests drop constraint %I', c);
  end loop;
end $$;
alter table public.sell_requests drop constraint if exists sell_requests_documents_chk;
alter table public.sell_requests add constraint sell_requests_documents_chk
  check (jsonb_typeof(documents) = 'array' and jsonb_array_length(documents) <= 20);

create or replace function public.submit_sell_request(p jsonb)
returns boolean language plpgsql security definer set search_path = public as $$
declare
  rid   uuid;
  ph    text := regexp_replace(coalesce(p->>'owner_phone', ''), '[\s().-]', '', 'g');
  docs  jsonb := coalesce(p->'documents', '[]'::jsonb);
  d     jsonb;
  st    text := coalesce(p->>'doc_status', '');
  needs boolean := coalesce((p->>'needs_legal_support')::boolean, false);
  nfoto int := 0;
  ndoc  int := 0;
begin
  begin rid := (p->>'id')::uuid; exception when others then raise exception 'Solicitud no válida.'; end;
  if rid is null then raise exception 'Solicitud no válida.'; end if;
  if coalesce((p->>'consent')::boolean, false) is not true then raise exception 'Debes aceptar que usemos tus datos para contactarte.'; end if;
  if ph !~ '^\+?[0-9]{7,15}$' then raise exception 'Escribe un número de WhatsApp válido (solo dígitos, con + si incluye código de país).'; end if;
  if jsonb_typeof(docs) <> 'array' then raise exception 'Documento no válido.'; end if;
  for d in select * from jsonb_array_elements(docs) loop
    -- cada archivo debe estar dentro de la carpeta de ESTA solicitud
    if coalesce(d->>'path', '') !~ ('^' || rid::text || '/[A-Za-z0-9._-]{1,120}$') then raise exception 'Documento no válido.'; end if;
    if d->>'type' = 'foto' then
      if d->>'path' !~* '\.(jpe?g|png|webp)$' then raise exception 'Las fotos deben ser JPG, PNG o WEBP.'; end if;
      nfoto := nfoto + 1;
    else ndoc := ndoc + 1; end if;
  end loop;
  if nfoto > 8 then raise exception 'Máximo 8 fotos.'; end if;
  if ndoc > 12 then raise exception 'Máximo 12 documentos.'; end if;
  -- sin documentos: se descartan los documentos pero se conservan las fotos
  if st = 'sin_documentos' then
    needs := true;
    docs := coalesce((select jsonb_agg(x) from jsonb_array_elements(docs) x where x->>'type' = 'foto'), '[]'::jsonb);
  end if;

  -- Límites contra abuso: 3 por mismo teléfono en 24 h y 200 en total al día.
  if (select count(*) from public.sell_requests where owner_phone = ph and created_at > now() - interval '24 hours') >= 3 then
    raise exception 'Ya recibimos tus solicitudes. Un asesor te contactará pronto.';
  end if;
  if (select count(*) from public.sell_requests where created_at > now() - interval '24 hours') >= 200 then
    raise exception 'Hay muchas solicitudes en este momento. Inténtalo más tarde o escríbenos por WhatsApp.';
  end if;

  insert into public.sell_requests (
    id, owner_name, owner_ci, owner_phone, owner_email, owner_role, property_type, operation, city, zone, address,
    latitude, longitude, price, currency, land_area, built_area, rooms, baths, description,
    doc_status, needs_legal_support, documents, consent)
  values (
    rid, btrim(coalesce(p->>'owner_name', '')), nullif(btrim(coalesce(p->>'owner_ci', '')), ''), ph,
    nullif(btrim(coalesce(p->>'owner_email', '')), ''), coalesce(nullif(p->>'owner_role', ''), 'propietario'),
    p->>'property_type', coalesce(nullif(p->>'operation', ''), 'venta'), btrim(coalesce(p->>'city', '')),
    nullif(btrim(coalesce(p->>'zone', '')), ''), btrim(coalesce(p->>'address', '')),
    nullif(p->>'latitude', '')::double precision, nullif(p->>'longitude', '')::double precision,
    nullif(p->>'price', '')::numeric, coalesce(nullif(p->>'currency', ''), 'USD'),
    nullif(p->>'land_area', '')::numeric, nullif(p->>'built_area', '')::numeric,
    nullif(p->>'rooms', '')::integer, nullif(p->>'baths', '')::integer,
    nullif(btrim(coalesce(p->>'description', '')), ''), st, needs, docs, true);
  return true;
exception
  when unique_violation then raise exception 'Esta solicitud ya fue enviada.';
  when check_violation or invalid_text_representation or numeric_value_out_of_range then
    raise exception 'Revisa los datos del formulario: hay un campo incompleto o con un valor no válido.';
end $$;
revoke all on function public.submit_sell_request(jsonb) from public;
grant execute on function public.submit_sell_request(jsonb) to anon, authenticated;

notify pgrst, 'reload schema';

-- =====================================================================
-- Bastet · Favoritos guardados en la cuenta (agregar al final de supabase/schema.sql). Idempotente.
-- Quien inicia sesión conserva sus propiedades guardadas (corazón) en cualquier dispositivo. Cada persona solo ve y cambia las suyas.
-- Sin sesión los favoritos siguen en el navegador (localStorage); al iniciar sesión se unen con los de la cuenta.
-- Supone que existe: public.properties.
-- =====================================================================

create table if not exists public.property_favorites (
  user_id     uuid not null default auth.uid() references auth.users(id) on delete cascade,
  property_id uuid not null references public.properties(id) on delete cascade,
  created_at  timestamptz not null default now(),
  primary key (user_id, property_id)
);

alter table public.property_favorites enable row level security;
drop policy if exists "own favorites select" on public.property_favorites;
create policy "own favorites select" on public.property_favorites for select to authenticated using (user_id = auth.uid());
drop policy if exists "own favorites insert" on public.property_favorites;
create policy "own favorites insert" on public.property_favorites for insert to authenticated with check (user_id = auth.uid());
drop policy if exists "own favorites delete" on public.property_favorites;
create policy "own favorites delete" on public.property_favorites for delete to authenticated using (user_id = auth.uid());
revoke all on public.property_favorites from anon;
revoke update on public.property_favorites from authenticated;

-- Tope por persona (evita llenar la tabla)
create or replace function public.limit_property_favorites()
returns trigger language plpgsql as $$
begin
  if (select count(*) from public.property_favorites where user_id = new.user_id) >= 30 then
    raise exception 'Llegaste al máximo de 30 favoritos. Quita alguno para guardar otro.';
  end if;
  return new;
end $$;
drop trigger if exists limit_property_favorites on public.property_favorites;
create trigger limit_property_favorites before insert on public.property_favorites
  for each row execute function public.limit_property_favorites();

notify pgrst, 'reload schema';

-- =====================================================================
-- Bastet · Estadías temporales: reservas con aprobación del anfitrión y pago del 10 %   — correr DESPUÉS de stays.sql y stay-availability.sql
-- Idempotente: se puede correr completo más de una vez. Implementa docs/ESPECIFICACION_MAESTRA.md, secciones 3, 4 y 9.2.
--
-- Flujo: el huésped (sin cuenta) solicita fechas → el anfitrión tiene 2 horas para aceptar o rechazar → si acepta, el huésped paga a Bastet
-- el 10 % del total (QR/transferencia) y sube el comprobante → un administrador lo verifica → recién entonces se revela el contacto
-- (conexión). El 90 % restante se coordina directo entre huésped y anfitrión: Bastet NO lo cobra, retiene ni garantiza.
--
-- INTERRUPTOR: stay_settings.enabled (apagado por defecto). Mientras esté apagado, Estadías sigue consultando por WhatsApp.
--   Para encender:  update public.stay_settings set enabled = true where id = 1;
-- Tarifa y reglas son editables en stay_settings (o desde el panel, pestaña Reservas). El tipo de cambio es el INTERNO de Bastet.
-- NO DEFINIDO en la especificación (no se inventó): plazo para que el huésped pague tras la aceptación → pay_window_hours (null = sin plazo).
-- =====================================================================

do $$
begin
  if to_regclass('public.stay_blocks') is null then raise exception 'Primero corre supabase/stay-availability.sql'; end if;
end $$;

-- 1) Reglas editables (una sola fila)
create table if not exists public.stay_settings (
  id                  smallint primary key default 1 check (id = 1),
  enabled             boolean  not null default false,
  fee_percent         numeric(5,2) not null default 10 check (fee_percent between 0 and 50),   -- comisión de Bastet; en cancelación tardía el anfitrión retiene otro tanto
  response_hours      integer  not null default 2  check (response_hours between 1 and 72),
  free_cancel_hours   integer  not null default 72 check (free_cancel_hours between 0 and 720),
  pay_window_hours    integer  check (pay_window_hours is null or pay_window_hours between 1 and 720),   -- TODO(negocio): sin definir
  bob_per_usd         numeric(8,4) not null default 6.96 check (bob_per_usd > 0),               -- tipo de cambio INTERNO de Bastet
  pay_instructions    text not null default '' check (char_length(pay_instructions) <= 1500),
  pay_qr_url          text check (pay_qr_url is null or char_length(pay_qr_url) <= 400),
  updated_at          timestamptz not null default now()
);
insert into public.stay_settings (id) values (1) on conflict (id) do nothing;
alter table public.stay_settings enable row level security;
revoke all on public.stay_settings from anon, authenticated;

-- 2) Reservas
create table if not exists public.stay_bookings (
  id                 uuid primary key default gen_random_uuid(),
  code               text not null unique,
  property_id        uuid not null references public.properties(id) on delete cascade,
  host_id            uuid references auth.users(id) on delete set null,
  guest_name         text not null check (char_length(btrim(guest_name)) between 2 and 60),
  guest_phone        text not null check (char_length(guest_phone) between 7 and 20),
  guest_email        text check (guest_email is null or char_length(guest_email) <= 120),
  guests             smallint not null check (guests between 1 and 16),
  check_in           date not null,
  check_out          date not null,
  nights             integer not null check (nights between 1 and 90),
  currency           text not null check (currency in ('USD', 'BOB')),
  nightly_price      numeric(14,2) not null,
  total              numeric(14,2) not null,            -- valor total de la reserva, en la moneda de la propiedad
  fee_amount         numeric(14,2) not null,            -- 10 % del total, en la moneda de la propiedad
  bob_per_usd_used   numeric(8,4) not null,             -- tipo de cambio interno congelado al solicitar
  fee_bs             numeric(14,2) not null,            -- lo que se paga a Bastet, en bolivianos
  status             text not null default 'pendiente_respuesta_anfitrion' check (status in
                       ('pendiente_respuesta_anfitrion','rechazada','expirada','aceptada_pendiente_pago','comprobante_enviado',
                        'pago_en_revision','pago_verificado','conexion_generada','cancelada','en_disputa')),
  respond_by         timestamptz not null,
  accepted_at        timestamptz,
  proof_path         text check (proof_path is null or char_length(proof_path) <= 300),
  proof_at           timestamptz,
  verified_at        timestamptz,
  verified_by        uuid references auth.users(id) on delete set null,
  review_note        text check (review_note is null or char_length(review_note) <= 500),
  cancelled_by       text check (cancelled_by in ('guest', 'host', 'admin')),
  cancelled_at       timestamptz,
  cancel_reason      text check (cancel_reason is null or char_length(cancel_reason) <= 500),
  late_cancel        boolean,
  bastet_refund_bs   numeric(14,2),                     -- cuánto devuelve Bastet del pago que recibió
  host_retention     numeric(14,2),                     -- cancelación tardía del huésped: 10 % que conserva el anfitrión (moneda de la propiedad)
  host_refund_due    numeric(14,2),                     -- lo que el anfitrión debe devolver DIRECTO al huésped si recibió el 90 %
  direct_status      text check (direct_status in ('no_recibido', 'recibido_con_comprobante', 'declarado_sin_comprobante')),
  direct_amount      numeric(14,2),
  direct_date        date,
  direct_method      text check (direct_method is null or char_length(direct_method) <= 60),
  direct_proof_path  text check (direct_proof_path is null or char_length(direct_proof_path) <= 300),
  direct_declared_at timestamptz,
  direct_review      text check (direct_review in ('pendiente', 'revisado', 'controvertido')),
  direct_review_note text check (direct_review_note is null or char_length(direct_review_note) <= 500),
  created_at         timestamptz not null default now(),
  constraint stay_bookings_range_check check (check_out > check_in)
);
create index if not exists stay_bookings_property_idx on public.stay_bookings (property_id, status, check_in);
create index if not exists stay_bookings_host_idx on public.stay_bookings (host_id, created_at desc);
alter table public.stay_bookings enable row level security;
revoke all on public.stay_bookings from anon, authenticated;

-- 3) Auditoría: quién, cuándo, de qué estado a cuál y con qué datos (sección 9.6)
create table if not exists public.stay_booking_events (
  id          bigint generated always as identity primary key,
  booking_id  uuid not null references public.stay_bookings(id) on delete cascade,
  actor       text not null,                            -- guest | host | admin | system
  actor_id    uuid,
  event       text not null,
  from_status text,
  to_status   text,
  data        jsonb,
  created_at  timestamptz not null default now()
);
create index if not exists stay_booking_events_idx on public.stay_booking_events (booking_id, created_at);
alter table public.stay_booking_events enable row level security;
revoke all on public.stay_booking_events from anon, authenticated;

create or replace function public.stay_log(p_booking uuid, p_actor text, p_event text, p_from text, p_to text, p_data jsonb default null)
returns void language sql security definer set search_path = public as $$
  insert into public.stay_booking_events (booking_id, actor, actor_id, event, from_status, to_status, data)
  values (p_booking, p_actor, auth.uid(), p_event, p_from, p_to, p_data);
$$;
revoke all on function public.stay_log(uuid, text, text, text, text, jsonb) from public, anon, authenticated;

-- Solicitudes sin respuesta del anfitrión dentro del plazo → expiradas (se aplica al consultar, sin tareas programadas)
create or replace function public.stay_expire_pending()
returns void language plpgsql security definer set search_path = public as $$
declare r record;
begin
  for r in select id from public.stay_bookings where status = 'pendiente_respuesta_anfitrion' and respond_by < now() loop
    update public.stay_bookings set status = 'expirada' where id = r.id;
    perform public.stay_log(r.id, 'system', 'expirada_sin_respuesta', 'pendiente_respuesta_anfitrion', 'expirada');
  end loop;
  -- Plazo de pago (solo si el negocio lo define)
  for r in select b.id from public.stay_bookings b, public.stay_settings s
            where s.pay_window_hours is not null and b.status = 'aceptada_pendiente_pago' and b.accepted_at + make_interval(hours => s.pay_window_hours) < now() loop
    update public.stay_bookings set status = 'expirada' where id = r.id;
    perform public.stay_log(r.id, 'system', 'expirada_sin_pago', 'aceptada_pendiente_pago', 'expirada');
  end loop;
end $$;
revoke all on function public.stay_expire_pending() from public, anon, authenticated;

-- 4) Comprobantes: carpeta privada (huésped sube a <código>/…; anfitrión sube su constancia del 90 % a host/<id de reserva>/…)
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('stay-proofs', 'stay-proofs', false, 5242880, array['application/pdf', 'image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do update set public = false, file_size_limit = 5242880, allowed_mime_types = array['application/pdf', 'image/jpeg', 'image/png', 'image/webp'];

create or replace function public.stay_code_accepts_proof(p_code text)
returns boolean language sql security definer set search_path = public stable as $$
  select exists (select 1 from public.stay_bookings where code = p_code and status in ('aceptada_pendiente_pago', 'comprobante_enviado', 'pago_en_revision'));
$$;
create or replace function public.stay_host_owns_booking(p_id text)
returns boolean language sql security definer set search_path = public stable as $$
  select auth.uid() is not null and exists (select 1 from public.stay_bookings where id::text = p_id and host_id = auth.uid());
$$;
revoke all on function public.stay_code_accepts_proof(text), public.stay_host_owns_booking(text) from public;
grant execute on function public.stay_code_accepts_proof(text), public.stay_host_owns_booking(text) to anon, authenticated;

drop policy if exists "guest uploads stay proof" on storage.objects;
create policy "guest uploads stay proof" on storage.objects for insert to anon, authenticated
  with check (bucket_id = 'stay-proofs' and (storage.foldername(name))[1] <> 'host' and public.stay_code_accepts_proof((storage.foldername(name))[1]));
drop policy if exists "host uploads direct proof" on storage.objects;
create policy "host uploads direct proof" on storage.objects for insert to authenticated
  with check (bucket_id = 'stay-proofs' and (storage.foldername(name))[1] = 'host' and public.stay_host_owns_booking((storage.foldername(name))[2]));
drop policy if exists "admin reads stay proofs" on storage.objects;
create policy "admin reads stay proofs" on storage.objects for select to authenticated using (bucket_id = 'stay-proofs' and public.is_admin());
drop policy if exists "admin deletes stay proofs" on storage.objects;
create policy "admin deletes stay proofs" on storage.objects for delete to authenticated using (bucket_id = 'stay-proofs' and public.is_admin());

-- 5) Público: ¿están activas las reservas con pago?
create or replace function public.stay_booking_enabled()
returns boolean language sql security definer set search_path = public stable as $$ select coalesce((select enabled from public.stay_settings where id = 1), false) $$;
revoke all on function public.stay_booking_enabled() from public;
grant execute on function public.stay_booking_enabled() to anon, authenticated;

-- 6) El huésped solicita una reserva (sin cuenta). Devuelve su código de seguimiento.
create or replace function public.create_stay_booking(p_property uuid, p_from date, p_to date, p_guests integer, p_name text, p_phone text, p_email text default null)
returns text language plpgsql security definer set search_path = public as $$
declare s public.stay_settings; prop record; v_n integer; v_price numeric; v_total numeric; v_fee numeric; v_rate numeric; v_feebs numeric; tries int := 0; cd text;
        nm text := btrim(coalesce(p_name, '')); ph text := regexp_replace(coalesce(p_phone, ''), '[^0-9+]', '', 'g'); em text := nullif(btrim(coalesce(p_email, '')), '');
begin
  perform public.stay_expire_pending();
  select * into s from public.stay_settings where id = 1;
  if not found or not s.enabled then raise exception 'Las reservas en línea todavía no están activas'; end if;
  select id, owner_id, price, currency, operation, status, expires_at into prop from public.properties where id = p_property;
  if not found or prop.operation is distinct from 'temporal' or prop.status is distinct from 'available' or (prop.expires_at is not null and prop.expires_at < now()) then
    raise exception 'Este alojamiento no está disponible'; end if;
  if p_from is null or p_to is null or p_from < public.bo_today() then raise exception 'Elige una fecha de llegada que no haya pasado'; end if;
  v_n := p_to - p_from;
  if v_n < 1 or v_n > 90 then raise exception 'La estadía debe ser de 1 a 90 noches'; end if;
  if p_guests is null or p_guests not between 1 and 16 then raise exception 'Indica de 1 a 16 huéspedes'; end if;
  if char_length(nm) not between 2 and 60 then raise exception 'Escribe tu nombre (entre 2 y 60 letras)'; end if;
  if char_length(regexp_replace(ph, '[^0-9]', '', 'g')) not between 7 and 15 then raise exception 'Escribe un número de WhatsApp válido'; end if;
  if em is not null and em !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'El correo no es válido'; end if;
  if exists (select 1 from public.stay_blocks b where b.property_id = p_property and b.from_date < p_to and (b.to_date is null or b.to_date >= p_from)) then
    raise exception 'Esas fechas no están disponibles'; end if;
  if exists (select 1 from public.stay_bookings k where k.property_id = p_property and k.check_in < p_to and k.check_out > p_from
               and k.status in ('aceptada_pendiente_pago', 'comprobante_enviado', 'pago_en_revision', 'pago_verificado', 'conexion_generada', 'en_disputa')) then
    raise exception 'Esas fechas ya están reservadas'; end if;
  if (select count(*) from public.stay_bookings where guest_phone = ph and status = 'pendiente_respuesta_anfitrion') >= 3 then
    raise exception 'Ya tienes 3 solicitudes esperando respuesta. Espera a que respondan los anfitriones.'; end if;
  v_price := nullif(regexp_replace(prop.price::text, '[^0-9]', '', 'g'), '')::numeric;
  if v_price is null or v_price <= 0 then raise exception 'Este alojamiento no tiene precio por noche definido'; end if;
  v_total := v_price * v_n;
  v_fee := round(v_total * s.fee_percent / 100, 2);
  v_rate := s.bob_per_usd;
  v_feebs := round(case when prop.currency = 'BOB' then v_fee else v_fee * v_rate end, 2);
  loop
    cd := upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 10));
    begin
      insert into public.stay_bookings (code, property_id, host_id, guest_name, guest_phone, guest_email, guests, check_in, check_out, nights, currency, nightly_price, total,
                                        fee_amount, bob_per_usd_used, fee_bs, respond_by)
      values (cd, p_property, prop.owner_id, nm, ph, em, p_guests, p_from, p_to, v_n, prop.currency, v_price, v_total, v_fee, v_rate, v_feebs, now() + make_interval(hours => s.response_hours));
      exit;
    exception when unique_violation then
      tries := tries + 1; if tries > 5 then raise; end if;
    end;
  end loop;
  perform public.stay_log((select id from public.stay_bookings where code = cd), 'guest', 'solicitada', null, 'pendiente_respuesta_anfitrion',
                          jsonb_build_object('total', v_total, 'currency', prop.currency, 'fee_bs', v_feebs, 'bob_per_usd', v_rate));
  return cd;
end $$;

-- 7) El huésped consulta su reserva con el código. El contacto del anfitrión solo se entrega cuando el pago está verificado.
create or replace function public.get_stay_booking(p_code text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare b public.stay_bookings; s public.stay_settings; prop record; contact text; pay boolean; reveal boolean; arrival timestamp; host_name text;
begin
  perform public.stay_expire_pending();
  select * into b from public.stay_bookings where code = upper(btrim(coalesce(p_code, '')));
  if not found then return jsonb_build_object('found', false); end if;
  select * into s from public.stay_settings where id = 1;
  select title, location, photos[1] as photo, whatsapp into prop from public.properties where id = b.property_id;
  select display_name, contact_whatsapp into host_name, contact from public.profiles where id = b.host_id;
  reveal := b.status = 'conexion_generada';
  pay := b.status in ('aceptada_pendiente_pago', 'comprobante_enviado', 'pago_en_revision');
  arrival := b.check_in::timestamp;
  return jsonb_build_object('found', true, 'code', b.code, 'status', b.status, 'title', prop.title, 'location', prop.location, 'photo', prop.photo,
    'guest_name', b.guest_name, 'guests', b.guests, 'check_in', b.check_in, 'check_out', b.check_out, 'nights', b.nights, 'currency', b.currency,
    'total', b.total, 'fee_amount', b.fee_amount, 'fee_bs', b.fee_bs, 'balance', b.total - b.fee_amount, 'fee_percent', s.fee_percent,
    'respond_by', b.respond_by, 'proof_sent', b.proof_path is not null, 'review_note', b.review_note,
    'pay_instructions', case when pay then s.pay_instructions end, 'pay_qr_url', case when pay then s.pay_qr_url end,
    'host_name', case when reveal then host_name end, 'host_whatsapp', case when reveal then coalesce(contact, prop.whatsapp) end,
    'free_cancel_until', arrival - make_interval(hours => s.free_cancel_hours),
    'is_late_cancel', ((now() at time zone 'UTC') - interval '4 hours') > arrival - make_interval(hours => s.free_cancel_hours),
    'can_cancel', b.status in ('pendiente_respuesta_anfitrion', 'aceptada_pendiente_pago', 'comprobante_enviado', 'pago_en_revision', 'conexion_generada'),
    'cancelled_by', b.cancelled_by, 'late_cancel', b.late_cancel, 'bastet_refund_bs', b.bastet_refund_bs, 'host_retention', b.host_retention, 'host_refund_due', b.host_refund_due);
end $$;

-- 8) El huésped avisa que subió el comprobante (el archivo ya está en stay-proofs/<código>/…)
create or replace function public.attach_stay_proof(p_code text, p_path text)
returns void language plpgsql security definer set search_path = public as $$
declare b public.stay_bookings; cd text := upper(btrim(coalesce(p_code, '')));
begin
  if p_path is null or char_length(p_path) > 300 or p_path not like cd || '/%' or p_path like '%..%' then raise exception 'Comprobante inválido'; end if;
  select * into b from public.stay_bookings where code = cd for update;
  if not found or b.status not in ('aceptada_pendiente_pago', 'comprobante_enviado', 'pago_en_revision') then raise exception 'Esta reserva no espera un comprobante'; end if;
  update public.stay_bookings set proof_path = p_path, proof_at = now(), status = 'comprobante_enviado', review_note = null where id = b.id;
  perform public.stay_log(b.id, 'guest', 'comprobante_enviado', b.status, 'comprobante_enviado', jsonb_build_object('path', p_path));
end $$;

-- 9) El anfitrión (o un admin) acepta o rechaza dentro del plazo
create or replace function public.host_respond_stay_booking(p_booking uuid, p_accept boolean)
returns void language plpgsql security definer set search_path = public as $$
declare b public.stay_bookings; uid uuid := auth.uid();
begin
  if uid is null or not public.is_active_user() then raise exception 'No autorizado' using errcode = '42501'; end if;
  perform public.stay_expire_pending();
  select * into b from public.stay_bookings where id = p_booking for update;
  if not found or (b.host_id is distinct from uid and not public.is_admin()) then raise exception 'Reserva no encontrada'; end if;
  if b.status = 'expirada' then raise exception 'El plazo para responder terminó y la solicitud expiró'; end if;
  if b.status <> 'pendiente_respuesta_anfitrion' then raise exception 'Esta solicitud ya fue respondida'; end if;
  if p_accept then
    if exists (select 1 from public.stay_blocks x where x.property_id = b.property_id and x.from_date < b.check_out and (x.to_date is null or x.to_date >= b.check_in))
       or exists (select 1 from public.stay_bookings k where k.id <> b.id and k.property_id = b.property_id and k.check_in < b.check_out and k.check_out > b.check_in
                    and k.status in ('aceptada_pendiente_pago', 'comprobante_enviado', 'pago_en_revision', 'pago_verificado', 'conexion_generada', 'en_disputa')) then
      raise exception 'Esas fechas ya no están libres'; end if;
    update public.stay_bookings set status = 'aceptada_pendiente_pago', accepted_at = now() where id = b.id;
    perform public.stay_log(b.id, case when b.host_id = uid then 'host' else 'admin' end, 'aceptada', b.status, 'aceptada_pendiente_pago');
  else
    update public.stay_bookings set status = 'rechazada' where id = b.id;
    perform public.stay_log(b.id, case when b.host_id = uid then 'host' else 'admin' end, 'rechazada', b.status, 'rechazada');
  end if;
end $$;

-- 10) Un administrador verifica o rechaza el comprobante. Al verificar se genera la conexión y se revela el contacto.
create or replace function public.admin_review_stay_proof(p_booking uuid, p_approve boolean, p_note text default null)
returns void language plpgsql security definer set search_path = public as $$
declare b public.stay_bookings; nt text := nullif(btrim(coalesce(p_note, '')), '');
begin
  if not public.is_admin() then raise exception 'Solo administradores' using errcode = '42501'; end if;
  select * into b from public.stay_bookings where id = p_booking for update;
  if not found or b.status not in ('comprobante_enviado', 'pago_en_revision') then raise exception 'No hay un comprobante por revisar en esta reserva'; end if;
  if p_approve then
    update public.stay_bookings set status = 'conexion_generada', verified_at = now(), verified_by = auth.uid(), review_note = nt where id = b.id;
    perform public.stay_log(b.id, 'admin', 'pago_verificado_y_conexion', b.status, 'conexion_generada', jsonb_build_object('fee_bs', b.fee_bs, 'note', nt));
  else
    if nt is null then raise exception 'Escribe el motivo del rechazo para que el huésped pueda corregirlo'; end if;
    update public.stay_bookings set status = 'aceptada_pendiente_pago', proof_path = null, proof_at = null, review_note = nt where id = b.id;
    perform public.stay_log(b.id, 'admin', 'comprobante_rechazado', b.status, 'aceptada_pendiente_pago', jsonb_build_object('note', nt, 'path', b.proof_path));
  end if;
end $$;

-- 11) Cancelación por el huésped (con su código). Gratis hasta 72 h antes del día de llegada; después se retiene el 20 % (10 % Bastet + 10 % anfitrión).
create or replace function public.cancel_stay_booking(p_code text, p_reason text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare b public.stay_bookings; s public.stay_settings; arrival timestamp; late boolean := false; paid boolean; refund numeric := 0; hostret numeric := null; due numeric := null;
        rs text := nullif(btrim(coalesce(p_reason, '')), '');
begin
  perform public.stay_expire_pending();
  select * into b from public.stay_bookings where code = upper(btrim(coalesce(p_code, ''))) for update;
  if not found or b.status not in ('pendiente_respuesta_anfitrion', 'aceptada_pendiente_pago', 'comprobante_enviado', 'pago_en_revision', 'conexion_generada') then
    raise exception 'Esta reserva no se puede cancelar'; end if;
  select * into s from public.stay_settings where id = 1;
  paid := b.status = 'conexion_generada';
  if paid then
    arrival := b.check_in::timestamp;
    late := ((now() at time zone 'UTC') - interval '4 hours') > arrival - make_interval(hours => s.free_cancel_hours);
    if late then hostret := b.fee_amount; refund := 0; due := b.total - b.fee_amount - hostret;       -- se queda 10 % Bastet + 10 % anfitrión
    else refund := b.fee_bs; due := b.total - b.fee_amount; end if;                                       -- el anfitrión devuelve el 90 % si lo recibió
  elsif b.status in ('comprobante_enviado', 'pago_en_revision') then
    refund := b.fee_bs;                                                                                   -- el administrador confirma si hubo pago que devolver
  end if;
  update public.stay_bookings set status = 'cancelada', cancelled_by = 'guest', cancelled_at = now(), cancel_reason = rs, late_cancel = late,
         bastet_refund_bs = refund, host_retention = hostret, host_refund_due = due where id = b.id;
  perform public.stay_log(b.id, 'guest', 'cancelada_por_huesped', b.status, 'cancelada', jsonb_build_object('late', late, 'bastet_refund_bs', refund, 'host_retention', hostret, 'host_refund_due', due, 'reason', rs));
  return jsonb_build_object('late_cancel', late, 'bastet_refund_bs', refund, 'host_retention', hostret, 'host_refund_due', due, 'paid', paid);
end $$;

-- 12) Cancelación por el anfitrión: Bastet devuelve el 100 % de lo que recibió; el anfitrión devuelve DIRECTO el 90 % si lo recibió
create or replace function public.host_cancel_stay_booking(p_booking uuid, p_reason text)
returns void language plpgsql security definer set search_path = public as $$
declare b public.stay_bookings; uid uuid := auth.uid(); rs text := nullif(btrim(coalesce(p_reason, '')), '');
begin
  if uid is null or not public.is_active_user() then raise exception 'No autorizado' using errcode = '42501'; end if;
  if rs is null then raise exception 'Escribe el motivo de la cancelación'; end if;
  select * into b from public.stay_bookings where id = p_booking for update;
  if not found or (b.host_id is distinct from uid and not public.is_admin()) then raise exception 'Reserva no encontrada'; end if;
  if b.status not in ('aceptada_pendiente_pago', 'comprobante_enviado', 'pago_en_revision', 'conexion_generada') then raise exception 'Esta reserva no se puede cancelar'; end if;
  update public.stay_bookings set status = 'cancelada', cancelled_by = case when b.host_id = uid then 'host' else 'admin' end, cancelled_at = now(), cancel_reason = rs, late_cancel = false,
         bastet_refund_bs = case when b.status = 'aceptada_pendiente_pago' then 0 else b.fee_bs end, host_retention = null,
         host_refund_due = case when b.status = 'conexion_generada' then b.total - b.fee_amount else null end where id = b.id;
  perform public.stay_log(b.id, case when b.host_id = uid then 'host' else 'admin' end, 'cancelada_por_anfitrion', b.status, 'cancelada', jsonb_build_object('reason', rs));
end $$;

-- 13) El anfitrión declara si recibió el 90 % directo (obligatorio en cancelaciones tardías); adjunta comprobante cuando exista
create or replace function public.host_declare_direct_payment(p_booking uuid, p_status text, p_amount numeric default null, p_date date default null,
                                                              p_method text default null, p_proof_path text default null)
returns void language plpgsql security definer set search_path = public as $$
declare b public.stay_bookings; uid uuid := auth.uid(); pp text := nullif(btrim(coalesce(p_proof_path, '')), '');
begin
  if uid is null or not public.is_active_user() then raise exception 'No autorizado' using errcode = '42501'; end if;
  if p_status not in ('no_recibido', 'recibido_con_comprobante', 'declarado_sin_comprobante') then raise exception 'Estado inválido'; end if;
  select * into b from public.stay_bookings where id = p_booking for update;
  if not found or b.host_id is distinct from uid then raise exception 'Reserva no encontrada'; end if;
  if b.status not in ('conexion_generada', 'cancelada', 'en_disputa') or (b.status = 'cancelada' and b.verified_at is null) then
    raise exception 'Todavía no hay un pago directo que declarar en esta reserva'; end if;
  if p_status <> 'no_recibido' and (p_amount is null or p_amount <= 0 or p_date is null) then raise exception 'Indica el importe y la fecha en que lo recibiste'; end if;
  if p_status = 'recibido_con_comprobante' and pp is null then raise exception 'Adjunta el comprobante o elige «Lo recibí, sin comprobante»'; end if;
  if pp is not null and (char_length(pp) > 300 or pp not like 'host/' || b.id::text || '/%' or pp like '%..%') then raise exception 'Comprobante inválido'; end if;
  update public.stay_bookings set direct_status = p_status, direct_amount = case when p_status = 'no_recibido' then null else p_amount end,
         direct_date = case when p_status = 'no_recibido' then null else p_date end, direct_method = nullif(btrim(coalesce(p_method, '')), ''),
         direct_proof_path = pp, direct_declared_at = now(), direct_review = 'pendiente' where id = b.id;
  perform public.stay_log(b.id, 'host', 'declaro_pago_directo', b.status, b.status, jsonb_build_object('status', p_status, 'amount', p_amount, 'date', p_date, 'proof', pp));
end $$;

-- 14) Administración: revisar lo declarado del 90 % y abrir/cerrar disputas
create or replace function public.admin_review_direct_payment(p_booking uuid, p_review text, p_note text default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Solo administradores' using errcode = '42501'; end if;
  if p_review not in ('pendiente', 'revisado', 'controvertido') then raise exception 'Estado inválido'; end if;
  update public.stay_bookings set direct_review = p_review, direct_review_note = nullif(btrim(coalesce(p_note, '')), '') where id = p_booking;
  if not found then raise exception 'Reserva no encontrada'; end if;
  perform public.stay_log(p_booking, 'admin', 'revision_pago_directo', null, null, jsonb_build_object('review', p_review, 'note', p_note));
end $$;

create or replace function public.admin_set_stay_dispute(p_booking uuid, p_open boolean, p_note text default null)
returns void language plpgsql security definer set search_path = public as $$
declare b public.stay_bookings;
begin
  if not public.is_admin() then raise exception 'Solo administradores' using errcode = '42501'; end if;
  select * into b from public.stay_bookings where id = p_booking for update;
  if not found then raise exception 'Reserva no encontrada'; end if;
  if p_open then
    if b.status not in ('conexion_generada', 'cancelada') then raise exception 'Solo se abre una disputa en reservas con conexión o canceladas'; end if;
    update public.stay_bookings set status = 'en_disputa' where id = b.id;
    perform public.stay_log(b.id, 'admin', 'disputa_abierta', b.status, 'en_disputa', jsonb_build_object('note', p_note));
  else
    if b.status <> 'en_disputa' then raise exception 'La reserva no está en disputa'; end if;
    update public.stay_bookings set status = case when b.cancelled_at is not null then 'cancelada' else 'conexion_generada' end where id = b.id;
    perform public.stay_log(b.id, 'admin', 'disputa_cerrada', 'en_disputa', null, jsonb_build_object('note', p_note));
  end if;
end $$;

-- 15) Listas del panel. El anfitrión ve los datos de contacto del huésped solo cuando hay conexión; el administrador ve todo.
create or replace function public.my_stay_bookings()
returns jsonb language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); adm boolean;
begin
  if uid is null or not public.is_active_user() then raise exception 'No autorizado' using errcode = '42501'; end if;
  perform public.stay_expire_pending();
  adm := public.is_admin();
  return coalesce((select jsonb_agg(jsonb_build_object(
      'id', b.id, 'code', b.code, 'status', b.status, 'property_id', b.property_id, 'title', p.title, 'guest_name', b.guest_name, 'guests', b.guests,
      'check_in', b.check_in, 'check_out', b.check_out, 'nights', b.nights, 'currency', b.currency, 'total', b.total, 'fee_amount', b.fee_amount,
      'fee_bs', b.fee_bs, 'balance', b.total - b.fee_amount, 'respond_by', b.respond_by, 'created_at', b.created_at,
      'guest_phone', case when adm or b.status in ('conexion_generada', 'en_disputa') or b.verified_at is not null then b.guest_phone end,
      'guest_email', case when adm or b.status in ('conexion_generada', 'en_disputa') or b.verified_at is not null then b.guest_email end,
      'host_id', b.host_id, 'host_name', case when adm then (select display_name from public.profiles where id = b.host_id) end,
      'proof_path', case when adm then b.proof_path end, 'proof_at', b.proof_at, 'verified_at', b.verified_at, 'review_note', b.review_note,
      'cancelled_by', b.cancelled_by, 'cancel_reason', b.cancel_reason, 'late_cancel', b.late_cancel, 'bastet_refund_bs', b.bastet_refund_bs,
      'host_retention', b.host_retention, 'host_refund_due', b.host_refund_due, 'direct_status', b.direct_status, 'direct_amount', b.direct_amount,
      'direct_date', b.direct_date, 'direct_method', b.direct_method, 'direct_proof_path', b.direct_proof_path, 'direct_review', b.direct_review,
      'direct_review_note', b.direct_review_note, 'needs_direct_declaration', b.verified_at is not null and b.direct_status is null and b.status in ('cancelada', 'conexion_generada', 'en_disputa'))
      order by b.created_at desc)
    from public.stay_bookings b join public.properties p on p.id = b.property_id
    where (adm or b.host_id = uid) and b.created_at > now() - interval '18 months'), '[]'::jsonb);
end $$;

create or replace function public.stay_booking_events(p_booking uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Solo administradores' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('actor', e.actor, 'event', e.event, 'from', e.from_status, 'to', e.to_status, 'data', e.data, 'at', e.created_at) order by e.created_at, e.id)
                    from public.stay_booking_events e where e.booking_id = p_booking), '[]'::jsonb);
end $$;

-- 16) Reglas editables por administración
create or replace function public.get_stay_settings()
returns jsonb language plpgsql security definer set search_path = public stable as $$
begin
  if not public.is_admin() then raise exception 'Solo administradores' using errcode = '42501'; end if;
  return (select to_jsonb(s) from public.stay_settings s where id = 1);
end $$;

create or replace function public.admin_update_stay_settings(p_enabled boolean, p_bob_per_usd numeric, p_pay_instructions text, p_pay_qr_url text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Solo administradores' using errcode = '42501'; end if;
  if p_bob_per_usd is null or p_bob_per_usd <= 0 then raise exception 'El tipo de cambio debe ser mayor que cero'; end if;
  if p_enabled and char_length(btrim(coalesce(p_pay_instructions, ''))) < 10 then raise exception 'Antes de activar, escribe las instrucciones de pago (cuenta o QR)'; end if;
  update public.stay_settings set enabled = coalesce(p_enabled, false), bob_per_usd = p_bob_per_usd, pay_instructions = btrim(coalesce(p_pay_instructions, '')),
         pay_qr_url = nullif(btrim(coalesce(p_pay_qr_url, '')), ''), updated_at = now() where id = 1;
end $$;

revoke all on function public.create_stay_booking(uuid, date, date, integer, text, text, text), public.get_stay_booking(text), public.attach_stay_proof(text, text),
  public.cancel_stay_booking(text, text), public.host_respond_stay_booking(uuid, boolean), public.admin_review_stay_proof(uuid, boolean, text),
  public.host_cancel_stay_booking(uuid, text), public.host_declare_direct_payment(uuid, text, numeric, date, text, text), public.admin_review_direct_payment(uuid, text, text),
  public.admin_set_stay_dispute(uuid, boolean, text), public.my_stay_bookings(), public.stay_booking_events(uuid), public.get_stay_settings(),
  public.admin_update_stay_settings(boolean, numeric, text, text) from public, anon;
grant execute on function public.create_stay_booking(uuid, date, date, integer, text, text, text), public.get_stay_booking(text), public.attach_stay_proof(text, text),
  public.cancel_stay_booking(text, text) to anon, authenticated;
grant execute on function public.host_respond_stay_booking(uuid, boolean), public.admin_review_stay_proof(uuid, boolean, text), public.host_cancel_stay_booking(uuid, text),
  public.host_declare_direct_payment(uuid, text, numeric, date, text, text), public.admin_review_direct_payment(uuid, text, text), public.admin_set_stay_dispute(uuid, boolean, text),
  public.my_stay_bookings(), public.stay_booking_events(uuid), public.get_stay_settings(), public.admin_update_stay_settings(boolean, numeric, text, text) to authenticated;

notify pgrst, 'reload schema';
