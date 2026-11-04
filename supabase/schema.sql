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
-- Plazo del huésped para pagar tras la aceptación: 12 horas (decisión de la dueña, 2026-11-03), editable en pay_window_hours.
-- Aviso al anfitrión: contador y actualización automática en su panel + botón «Avisar por WhatsApp» para administración (my_stay_bookings devuelve host_whatsapp solo al admin).
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
  free_cancel_hours   integer  not null default 4  check (free_cancel_hours between 0 and 720),   -- horas de cancelación gratuita CONTADAS DESDE que se verifica el pago (2026-11-03)
  pay_window_hours    integer  default 12 check (pay_window_hours is null or pay_window_hours between 1 and 720),   -- horas que tiene el huésped para pagar tras la aceptación (null = sin plazo)
  bob_per_usd         numeric(8,4) not null default 6.96 check (bob_per_usd > 0),               -- tipo de cambio INTERNO de Bastet
  pay_instructions    text not null default '' check (char_length(pay_instructions) <= 1500),
  pay_qr_url          text check (pay_qr_url is null or char_length(pay_qr_url) <= 400),
  updated_at          timestamptz not null default now()
);
alter table public.stay_settings alter column pay_window_hours set default 12;
alter table public.stay_settings alter column free_cancel_hours set default 4;
update public.stay_settings set free_cancel_hours = 4 where id = 1 and free_cancel_hours = 72;   -- la regla anterior (72 h antes de la llegada) se retiró
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
declare b public.stay_bookings; s public.stay_settings; prop record; contact text; pay boolean; reveal boolean; free_until timestamptz; host_name text;
begin
  perform public.stay_expire_pending();
  select * into b from public.stay_bookings where code = upper(btrim(coalesce(p_code, '')));
  if not found then return jsonb_build_object('found', false); end if;
  select * into s from public.stay_settings where id = 1;
  select title, location, photos[1] as photo, whatsapp into prop from public.properties where id = b.property_id;
  select display_name, contact_whatsapp into host_name, contact from public.profiles where id = b.host_id;
  reveal := b.status = 'conexion_generada';
  pay := b.status in ('aceptada_pendiente_pago', 'comprobante_enviado', 'pago_en_revision');
  free_until := b.verified_at + make_interval(hours => s.free_cancel_hours);
  return jsonb_build_object('found', true, 'code', b.code, 'status', b.status, 'title', prop.title, 'location', prop.location, 'photo', prop.photo,
    'guest_name', b.guest_name, 'guests', b.guests, 'check_in', b.check_in, 'check_out', b.check_out, 'nights', b.nights, 'currency', b.currency,
    'total', b.total, 'fee_amount', b.fee_amount, 'fee_bs', b.fee_bs, 'balance', b.total - b.fee_amount, 'fee_percent', s.fee_percent,
    'respond_by', b.respond_by, 'pay_by', case when b.status = 'aceptada_pendiente_pago' and s.pay_window_hours is not null then b.accepted_at + make_interval(hours => s.pay_window_hours) end, 'proof_sent', b.proof_path is not null, 'review_note', b.review_note,
    'pay_instructions', case when pay then s.pay_instructions end, 'pay_qr_url', case when pay then s.pay_qr_url end,
    'host_name', case when reveal then host_name end, 'host_whatsapp', case when reveal then coalesce(contact, prop.whatsapp) end,
    'free_cancel_until', case when reveal then free_until end, 'free_cancel_hours', s.free_cancel_hours,
    'is_late_cancel', reveal and now() > free_until,
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

-- 11) Cancelación por el huésped (con su código). Gratis durante las primeras 4 h desde que se verifica el pago (sirve también para reservas del día siguiente); después se retiene el 20 % (10 % Bastet + 10 % anfitrión).
create or replace function public.cancel_stay_booking(p_code text, p_reason text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare b public.stay_bookings; s public.stay_settings; late boolean := false; paid boolean; refund numeric := 0; hostret numeric := null; due numeric := null;
        rs text := nullif(btrim(coalesce(p_reason, '')), '');
begin
  perform public.stay_expire_pending();
  select * into b from public.stay_bookings where code = upper(btrim(coalesce(p_code, ''))) for update;
  if not found or b.status not in ('pendiente_respuesta_anfitrion', 'aceptada_pendiente_pago', 'comprobante_enviado', 'pago_en_revision', 'conexion_generada') then
    raise exception 'Esta reserva no se puede cancelar'; end if;
  select * into s from public.stay_settings where id = 1;
  paid := b.status = 'conexion_generada';
  if paid then
    late := now() > coalesce(b.verified_at, now()) + make_interval(hours => s.free_cancel_hours);
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
      'host_whatsapp', case when adm then coalesce((select contact_whatsapp from public.profiles where id = b.host_id), p.whatsapp) end,
      'accepted_at', b.accepted_at, 'pay_by', case when b.status = 'aceptada_pendiente_pago' and s.pay_window_hours is not null then b.accepted_at + make_interval(hours => s.pay_window_hours) end,
      'proof_path', case when adm then b.proof_path end, 'proof_at', b.proof_at, 'verified_at', b.verified_at, 'review_note', b.review_note,
      'cancelled_by', b.cancelled_by, 'cancel_reason', b.cancel_reason, 'late_cancel', b.late_cancel, 'bastet_refund_bs', b.bastet_refund_bs,
      'host_retention', b.host_retention, 'host_refund_due', b.host_refund_due, 'direct_status', b.direct_status, 'direct_amount', b.direct_amount,
      'direct_date', b.direct_date, 'direct_method', b.direct_method, 'direct_proof_path', b.direct_proof_path, 'direct_review', b.direct_review,
      'direct_review_note', b.direct_review_note, 'needs_direct_declaration', b.verified_at is not null and b.direct_status is null and b.status in ('cancelada', 'conexion_generada', 'en_disputa'))
      order by b.created_at desc)
    from public.stay_bookings b join public.properties p on p.id = b.property_id cross join public.stay_settings s
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

drop function if exists public.admin_update_stay_settings(boolean, numeric, text, text, integer);
create or replace function public.admin_update_stay_settings(p_enabled boolean, p_bob_per_usd numeric, p_pay_instructions text, p_pay_qr_url text, p_pay_window_hours integer default 12)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Solo administradores' using errcode = '42501'; end if;
  if p_bob_per_usd is null or p_bob_per_usd <= 0 then raise exception 'El tipo de cambio debe ser mayor que cero'; end if;
  if p_pay_window_hours is not null and p_pay_window_hours not between 1 and 720 then raise exception 'El plazo de pago debe ser de 1 a 720 horas (déjalo vacío para no poner plazo)'; end if;
  if p_enabled and char_length(btrim(coalesce(p_pay_instructions, ''))) < 10 then raise exception 'Antes de activar, escribe las instrucciones de pago (cuenta o QR)'; end if;
  update public.stay_settings set enabled = coalesce(p_enabled, false), bob_per_usd = p_bob_per_usd, pay_instructions = btrim(coalesce(p_pay_instructions, '')),
         pay_qr_url = nullif(btrim(coalesce(p_pay_qr_url, '')), ''), pay_window_hours = p_pay_window_hours, updated_at = now() where id = 1;
end $$;

revoke all on function public.create_stay_booking(uuid, date, date, integer, text, text, text), public.get_stay_booking(text), public.attach_stay_proof(text, text),
  public.cancel_stay_booking(text, text), public.host_respond_stay_booking(uuid, boolean), public.admin_review_stay_proof(uuid, boolean, text),
  public.host_cancel_stay_booking(uuid, text), public.host_declare_direct_payment(uuid, text, numeric, date, text, text), public.admin_review_direct_payment(uuid, text, text),
  public.admin_set_stay_dispute(uuid, boolean, text), public.my_stay_bookings(), public.stay_booking_events(uuid), public.get_stay_settings(),
  public.admin_update_stay_settings(boolean, numeric, text, text, integer) from public, anon;
grant execute on function public.create_stay_booking(uuid, date, date, integer, text, text, text), public.get_stay_booking(text), public.attach_stay_proof(text, text),
  public.cancel_stay_booking(text, text) to anon, authenticated;
grant execute on function public.host_respond_stay_booking(uuid, boolean), public.admin_review_stay_proof(uuid, boolean, text), public.host_cancel_stay_booking(uuid, text),
  public.host_declare_direct_payment(uuid, text, numeric, date, text, text), public.admin_review_direct_payment(uuid, text, text), public.admin_set_stay_dispute(uuid, boolean, text),
  public.my_stay_bookings(), public.stay_booking_events(uuid), public.get_stay_settings(), public.admin_update_stay_settings(boolean, numeric, text, text, integer) to authenticated;

notify pgrst, 'reload schema';

-- 17) Fechas ocupadas por reservas (público, sin datos personales): alimenta el calendario y la etiqueta «EN USO».
--     to_date es la ÚLTIMA noche ocupada (el día de salida queda libre). confirmed = pago verificado.
create or replace function public.stay_booked_ranges(p_ids uuid[])
returns table (property_id uuid, from_date date, to_date date, confirmed boolean)
language plpgsql security definer set search_path = public as $$
begin
  if coalesce(array_length(p_ids, 1), 0) > 300 then raise exception 'Demasiadas propiedades'; end if;
  perform public.stay_expire_pending();
  return query
    select b.property_id, b.check_in, b.check_out - 1, b.status in ('pago_verificado', 'conexion_generada', 'en_disputa')
      from public.stay_bookings b
     where b.property_id = any (coalesce(p_ids, '{}'::uuid[]))
       and b.status in ('aceptada_pendiente_pago', 'comprobante_enviado', 'pago_en_revision', 'pago_verificado', 'conexion_generada', 'en_disputa')
       and b.check_out - 1 >= public.bo_today()
     order by b.check_in;
end $$;

-- 18) Verificación pública de una reserva con su código (pestaña «Verificar»). Es el código que tiene el huésped: quien lo tenga ve el
--     detalle de la reserva. El WhatsApp del anfitrión solo se entrega si el pago del 10 % está verificado y la reserva no se canceló.
--     Nunca devuelve teléfono ni correo del huésped, comprobantes, ni lo declarado del 90 % directo.
create or replace function public.verify_stay_booking(p_code text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare b public.stay_bookings; prop record; host_name text; contact text; ok boolean;
begin
  perform public.stay_expire_pending();
  select * into b from public.stay_bookings where code = upper(btrim(coalesce(p_code, '')));
  if not found then return jsonb_build_object('found', false); end if;
  select title, location, address, photos, latitude, longitude, whatsapp into prop from public.properties where id = b.property_id;
  select display_name, contact_whatsapp into host_name, contact from public.profiles where id = b.host_id;
  ok := b.verified_at is not null and b.status in ('conexion_generada', 'en_disputa');
  return jsonb_build_object('found', true, 'code', b.code, 'status', b.status, 'verified', ok, 'verified_at', b.verified_at,
    'title', prop.title, 'location', prop.location, 'address', prop.address, 'latitude', prop.latitude, 'longitude', prop.longitude,
    'photos', to_jsonb(coalesce(prop.photos, '{}'::text[])),
    'check_in', b.check_in, 'check_out', b.check_out, 'nights', b.nights, 'guests', b.guests,
    'guest_name', split_part(btrim(b.guest_name), ' ', 1) || coalesce(' ' || upper(left(nullif(split_part(btrim(b.guest_name), ' ', 2), ''), 1)) || '.', ''),
    'currency', b.currency, 'total', b.total, 'fee_bs', b.fee_bs, 'balance', b.total - b.fee_amount,
    'host_name', case when ok then host_name end, 'host_whatsapp', case when ok then coalesce(contact, prop.whatsapp) end,
    'cancelled_by', b.cancelled_by, 'created_at', b.created_at,
    'events', coalesce((select jsonb_agg(jsonb_build_object('event', e.event, 'at', e.created_at) order by e.created_at, e.id)
                          from public.stay_booking_events e
                         where e.booking_id = b.id and e.event in ('solicitada', 'aceptada', 'rechazada', 'expirada_sin_respuesta', 'expirada_sin_pago', 'comprobante_enviado',
                               'comprobante_rechazado', 'pago_verificado_y_conexion', 'cancelada_por_huesped', 'cancelada_por_anfitrion', 'disputa_abierta', 'disputa_cerrada')), '[]'::jsonb),
    'busy', coalesce((select jsonb_agg(jsonb_build_object('from', k.check_in, 'to', k.check_out - 1))
                        from public.stay_bookings k
                       where k.property_id = b.property_id and k.id <> b.id and k.check_out - 1 >= public.bo_today()
                         and k.status in ('aceptada_pendiente_pago', 'comprobante_enviado', 'pago_en_revision', 'pago_verificado', 'conexion_generada', 'en_disputa')), '[]'::jsonb));
end $$;

revoke all on function public.stay_booked_ranges(uuid[]), public.verify_stay_booking(text) from public;
grant execute on function public.stay_booked_ranges(uuid[]), public.verify_stay_booking(text) to anon, authenticated;

notify pgrst, 'reload schema';

-- =====================================================================
-- Bastet · Retiro del modelo de suscripción (planes Propietario/Agente/Empresa, prueba gratuita, límites y vencimientos)   — fase 2, paso A
-- Idempotente: se puede correr completo más de una vez. Correr DESPUÉS de todo lo demás (subscriptions, registration, owner-services, stay-bookings).
--
-- Decisiones de la dueña (2026-11-03): publicar es libre y sin tope ni vencimiento; solo administración destaca propiedades; el contrato de
-- exclusividad lo genera cualquier cuenta de agente o empresa; los servicios de propietario se mantienen por tipo de cuenta (profiles.interest).
-- El ingreso pasa a ser por conexiones y comisiones (docs/ESPECIFICACION_MAESTRA.md, sección 1).
--
-- NO borra datos: las tablas subscriptions, subscription_plans, subscription_requests, subscription_events, featured_activations y trial_claims
-- se conservan como historial (se pueden eliminar más adelante). Sí borra las funciones de planes y deja las propiedades sin vencimiento.
-- =====================================================================

do $$
begin
  if to_regclass('public.subscriptions') is null or to_regprocedure('public.create_owner_offer(uuid, uuid, jsonb)') is null then
    raise exception 'Primero corre schema.sql completo (subscriptions, registration y owner-services)';
  end if;
end $$;

-- 1) Publicar: libre, sin tope y sin vencimiento
create or replace function public.charge_property_publication()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  new.expires_at := null;
  return new;
end $$;

drop trigger if exists plan_limit_on_reactivate on public.properties;
drop function if exists public.enforce_plan_on_reactivate();
drop function if exists public.renew_property(uuid);

do $$
begin
  perform set_config('uno.renew_rpc', '1', true);
  update public.properties set expires_at = null where expires_at is not null;
end $$;

-- 2) Destacar: solo administración (sin cupos ni ciclos)
create or replace function public.feature_property(p_property_id text, p_service text)   -- p_service ya no se usa (firma conservada)
returns jsonb language plpgsql security definer set search_path = public as $$
declare prop record; new_until timestamptz; dur integer := public._setting('featured_duration_days', 30);
begin
  if auth.uid() is null or not public.is_admin() then raise exception 'Solo administración puede destacar propiedades' using errcode = '42501'; end if;
  select p.id, p.status, p.featured_until into prop from public.properties p where p.id::text = p_property_id for update;
  if not found then raise exception 'Propiedad no encontrada'; end if;
  if prop.status <> 'available' then raise exception 'Solo se pueden destacar propiedades disponibles'; end if;
  if prop.featured_until is not null and prop.featured_until > now() then
    raise exception 'Esta propiedad ya está destacada hasta el %', to_char(prop.featured_until - interval '4 hours', 'DD/MM/YYYY') using errcode = 'P0409', hint = 'already_featured';
  end if;
  new_until := now() + make_interval(days => dur);
  perform set_config('uno.credit_rpc', '1', true);
  update public.properties set featured_until = new_until where id = prop.id;
  return jsonb_build_object('featured_until', new_until);
end $$;

-- 3) Estado de la cuenta para el panel (reemplaza a my_subscription): tipo de cuenta, registro y propiedades activas
create or replace function public.my_account()
returns jsonb language plpgsql security definer set search_path = public stable as $$
declare uid uuid := auth.uid(); p record; adm boolean; it text;
begin
  if uid is null or not public.is_active_user() then raise exception 'No autorizado' using errcode = '42501'; end if;
  adm := public.is_admin();
  select registered_at, interest into p from public.profiles where id = uid;
  it := case when adm then 'admin' else coalesce(p.interest, 'agente') end;
  return jsonb_build_object('exempt', adm, 'registered', adm or p.registered_at is not null, 'interest', p.interest,
    'account', jsonb_build_object('type', it, 'agent_tools', adm or it <> 'propietario',
      'name', case it when 'propietario' then 'Propietario' when 'empresa' then 'Empresa' when 'admin' then 'Administrador' else 'Agente' end),
    'active_properties', public._count_active_properties(uid));
end $$;

-- 4) Registro sin prueba gratuita (misma firma; p_start_trial se ignora)
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
  if p_adult is not true then raise exception 'Debes confirmar que tienes 18 años o más para crear una cuenta'; end if;
  if p_consent is not true then raise exception 'Debes aceptar el uso de tus datos para continuar'; end if;

  perform set_config('uno.reg_rpc', '1', true);
  update public.profiles
     set full_name = nm, whatsapp = wa, city = nullif(btrim(coalesce(p_city, '')), ''), company = nullif(btrim(coalesce(p_company, '')), ''),
         interest = p_interest, registered_at = coalesce(registered_at, now()), age_confirmed_at = coalesce(age_confirmed_at, now()),
         display_name = coalesce(nullif(btrim(coalesce(display_name, '')), ''), nm)
   where id = uid;
  return public.my_account();
end $$;

-- 5) Contrato de exclusividad por tipo de cuenta
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

  -- El contrato de exclusividad es una herramienta de cuentas de agente o de empresa; el administrador está exento
  if not public.is_admin() and coalesce((select interest from public.profiles where id = uid), 'agente') = 'propietario' then
    raise exception 'El contrato de exclusividad es para cuentas de agente o de empresa' using errcode = 'P0403', hint = 'account_tools';
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

-- 6) Servicios del propietario y ofertas, por tipo de cuenta
create or replace function public.list_agent_directory()
returns table (id uuid, display_name text, avatar_url text, facebook_url text, instagram_url text, tiktok_url text, plan_name text, active_properties integer)
language plpgsql security definer set search_path = public stable as $$
begin
  if auth.uid() is null or not public.is_active_user() then raise exception 'No autorizado' using errcode = '42501'; end if;
  return query
    select p.id, coalesce(nullif(btrim(p.display_name), ''), 'Agente de Bastet'), p.avatar_url, p.facebook_url, p.instagram_url, p.tiktok_url,
           case p.interest when 'empresa' then 'Empresa' else 'Agente' end, public._count_active_properties(p.id)
      from public.profiles p
     where p.is_active and p.role = 'agent' and p.registered_at is not null and coalesce(p.interest, 'agente') in ('agente', 'empresa') and p.id <> auth.uid()
     order by coalesce(nullif(btrim(p.display_name), ''), 'zzz'), p.id;
end $$;

create or replace function public.create_legal_request(p_service text, p_property uuid, p_description text)
returns bigint language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); svc public.legal_service_types; prop record; rid bigint; ptitle text;
begin
  if uid is null or not public.is_active_user() then raise exception 'No autorizado' using errcode = '42501'; end if;
  if coalesce((select interest from public.profiles where id = uid), 'agente') <> 'propietario' then
    raise exception 'Este servicio es para cuentas de propietario.' using errcode = 'P0403', hint = 'plan_owner';
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

create or replace function public.create_owner_offer(p_property uuid, p_agent uuid, p_terms jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  uid uuid := auth.uid();
  prop record;
  ag record;
  t jsonb := coalesce(p_terms, '{}'::jsonb);
  n numeric;
  yr integer; seq integer; num text; oid uuid := gen_random_uuid();
  me record;
begin
  if uid is null or not public.is_active_user() then raise exception 'No autorizado' using errcode = '42501'; end if;
  perform pg_advisory_xact_lock(hashtext('offer:' || uid::text));
  if coalesce((select interest from public.profiles where id = uid), 'agente') <> 'propietario' then
    raise exception 'Ofrecer tu propiedad a un agente es una función de las cuentas de propietario' using errcode = 'P0403', hint = 'plan_owner';
  end if;

  select id, title, location, address, price, currency, area, rooms, baths, property_type, operation, code_number, description, status, expires_at, owner_whatsapp
    into prop from public.properties where id = p_property and owner_id = uid;
  if not found then raise exception 'Propiedad no encontrada'; end if;
  if prop.status <> 'available' or (prop.expires_at is not null and prop.expires_at <= now()) then raise exception 'Solo puedes ofrecer propiedades activas'; end if;

  select p.id, p.display_name into ag from public.profiles p where p.id = p_agent and p.is_active and p.role = 'agent';
  if not found or p_agent = uid then raise exception 'Agente no disponible'; end if;
  if coalesce((select interest from public.profiles where id = p_agent), 'agente') = 'propietario' then raise exception 'Agente no disponible'; end if;

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
declare uid uuid := auth.uid(); o public.owner_offers;
begin
  if uid is null or not public.is_active_user() then raise exception 'No autorizado' using errcode = '42501'; end if;
  select * into o from public.owner_offers where id = p_id and agent_id = uid for update;
  if not found then raise exception 'Oferta no encontrada'; end if;
  if o.status <> 'pending' then raise exception 'La oferta ya fue respondida o cancelada'; end if;
  if p_accept and not public.is_admin() and coalesce((select interest from public.profiles where id = uid), 'agente') = 'propietario' then
    raise exception 'Solo las cuentas de agente o de empresa aceptan ofertas' using errcode = 'P0403', hint = 'plan_tools';
  end if;
  if char_length(coalesce(p_note, '')) > 500 then raise exception 'La nota es demasiado larga (máximo 500 caracteres)'; end if;
  update public.owner_offers set status = case when p_accept then 'accepted' else 'rejected' end, response_note = nullif(btrim(coalesce(p_note, '')), ''), responded_at = now(),
         agent_data = case when p_accept then agent_data || (select coalesce(jsonb_strip_nulls(jsonb_build_object('ci', nullif(btrim(l.ci), ''), 'registro', nullif(btrim(l.registration), ''), 'telefono', nullif(btrim(l.phone), ''))), '{}'::jsonb) from (select 1) x left join public.agent_legal_profiles l on l.user_id = uid) else agent_data end
   where id = p_id;
  insert into public.owner_offer_events (offer_id, kind, actor, note) values (p_id, case when p_accept then 'accepted' else 'rejected' end, uid, nullif(btrim(coalesce(p_note, '')), ''));
end $$;

-- 7) Se retiran las funciones del modelo de planes y de la prueba gratuita (las tablas quedan como historial)
drop function if exists public.start_free_trial();
drop function if exists public.my_subscription();
drop function if exists public.request_subscription(text, text, text);
drop function if exists public.admin_resolve_subscription_request(bigint, boolean, text);
drop function if exists public.admin_grant_subscription(uuid, text, integer);
drop function if exists public.cancel_subscription();
drop function if exists public.resume_subscription();
drop function if exists public.attach_payment_proof(bigint, text);
drop function if exists public._start_trial(uuid);
drop function if exists public._trial_eligible(uuid);
drop function if exists public._activate_subscription(uuid, text, text, integer, uuid);
drop function if exists public._sync_property_expiry(uuid, timestamptz, integer);
drop function if exists public._featured_cycle_start(timestamptz);

-- 8) Permisos
revoke all on function public.my_account() from public, anon;
grant execute on function public.my_account() to authenticated;
revoke all on function public.feature_property(text, text) from public, anon;
grant execute on function public.feature_property(text, text) to authenticated;
revoke all on function public.complete_registration(text, text, text, text, text, boolean, boolean, boolean) from public, anon;
grant execute on function public.complete_registration(text, text, text, text, text, boolean, boolean, boolean) to authenticated;
revoke all on function public.create_exclusivity_contract(jsonb, text, text) from public, anon;
grant execute on function public.create_exclusivity_contract(jsonb, text, text) to authenticated;
revoke all on function public.list_agent_directory() from public, anon;
grant execute on function public.list_agent_directory() to authenticated;
revoke all on function public.create_legal_request(text, uuid, text), public.create_owner_offer(uuid, uuid, jsonb), public.respond_owner_offer(uuid, boolean, text) from public, anon;
grant execute on function public.create_legal_request(text, uuid, text), public.create_owner_offer(uuid, uuid, jsonb), public.respond_owner_offer(uuid, boolean, text) to authenticated;

notify pgrst, 'reload schema';

-- =====================================================================
-- Bastet · Conexiones y tarifas (fase 2, paso B)   — correr DESPUÉS de stay-bookings.sql y retire-subscriptions.sql
-- Idempotente: se puede correr completo más de una vez. Implementa docs/ESPECIFICACION_MAESTRA.md, secciones 1 y 9.1–9.3.
--
-- Flujo (venta, alquiler y anticrético): la persona interesada (sin cuenta) solicita contacto → el titular de la cuenta que publicó (agente,
-- empresa o propietario) acepta o rechaza → si acepta, nace la obligación económica: la tarifa de conexión, calculada con la matriz editable y
-- CONGELADA en esa conexión → el titular paga a Bastet (QR/transferencia) y sube su comprobante → un administrador lo verifica → recién entonces
-- el titular ve los datos del interesado (conexión). Cada conexión genera una constancia numerada BST-CX-AAAA-NNNN con la versión del contrato marco.
-- Antes de publicar su primera propiedad el titular acepta un contrato marco (una vez por versión).
--
-- INTERRUPTOR: connection_settings.enabled (apagado por defecto). Apagado, el sitio sigue como antes (WhatsApp directo y formulario de clientes).
--   Para encenderlo hacen falta las instrucciones de pago y el TEXTO del contrato marco (que debe revisar un abogado en Bolivia).
-- Tarifas en Bs. Rangos fijos por la especificación: alquiler 10–50, venta 51–200; anticrético se calcula por matriz (10–200, sin rango aprobado).
-- Los valores iniciales de la matriz son PROVISIONALES (punto medio de cada rango) y están marcados así: la dueña los ajusta en el panel.
-- NO incluido todavía: ocultar de verdad el teléfono público de la propiedad en la API (hoy solo se oculta en la pantalla) — paso B2.
-- =====================================================================

do $$
begin
  if to_regclass('public.stay_settings') is null then raise exception 'Primero corre supabase/stay-bookings.sql'; end if;
  if to_regprocedure('public.my_account()') is null then raise exception 'Primero corre supabase/retire-subscriptions.sql'; end if;
end $$;

-- 1) Ajustes (una sola fila)
create table if not exists public.connection_settings (
  id                smallint primary key default 1 check (id = 1),
  enabled           boolean not null default false,
  pay_instructions  text not null default '' check (char_length(pay_instructions) <= 1500),
  pay_qr_url        text check (pay_qr_url is null or char_length(pay_qr_url) <= 400),
  framework_version integer not null default 1,
  framework_text    text not null default '' check (char_length(framework_text) <= 60000),
  updated_at        timestamptz not null default now()
);
insert into public.connection_settings (id) values (1) on conflict (id) do nothing;
alter table public.connection_settings enable row level security;
revoke all on public.connection_settings from anon, authenticated;

-- 2) Matriz de tarifas: límites por operación (especificación) y reglas editables
create table if not exists public.fee_bounds (
  operation text primary key check (operation in ('venta', 'alquiler', 'anticretico')),
  min_bs    numeric(10,2) not null,
  max_bs    numeric(10,2) not null,
  check (min_bs <= max_bs)
);
insert into public.fee_bounds (operation, min_bs, max_bs) values ('alquiler', 10, 50), ('venta', 51, 200), ('anticretico', 10, 200) on conflict (operation) do nothing;

create table if not exists public.fee_rules (
  id           bigint generated always as identity primary key,
  operation    text not null check (operation in ('venta', 'alquiler', 'anticretico')),
  property_type text,                                   -- null = cualquier tipo de inmueble
  value_min_bs numeric(14,2),                           -- valor del inmueble en Bs (null = sin mínimo)
  value_max_bs numeric(14,2),
  fee_bs       numeric(10,2) not null check (fee_bs >= 0),
  priority     integer not null default 0,
  label        text check (label is null or char_length(label) <= 100),
  provisional  boolean not null default false,
  active       boolean not null default true,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  check (value_min_bs is null or value_max_bs is null or value_min_bs <= value_max_bs)
);
insert into public.fee_rules (operation, fee_bs, label, provisional)
select v.operation, v.fee_bs, v.label, true
  from (values ('alquiler', 30, 'Alquiler · valor inicial provisional'), ('venta', 125, 'Venta · valor inicial provisional'),
               ('anticretico', 100, 'Anticrético · valor inicial provisional')) as v(operation, fee_bs, label)
 where not exists (select 1 from public.fee_rules);
alter table public.fee_rules enable row level security;
alter table public.fee_bounds enable row level security;
revoke all on public.fee_rules, public.fee_bounds from anon, authenticated;

create table if not exists public.fee_rule_events (        -- historial de cambios de la matriz (sección 1.2)
  id         bigint generated always as identity primary key,
  rule_id    bigint,
  actor      uuid,
  action     text not null,
  old_data   jsonb,
  new_data   jsonb,
  created_at timestamptz not null default now()
);
alter table public.fee_rule_events enable row level security;
revoke all on public.fee_rule_events from anon, authenticated;

-- 3) Contrato marco: quién aceptó qué versión
create table if not exists public.framework_acceptances (
  user_id     uuid not null references auth.users(id) on delete cascade,
  version     integer not null,
  accepted_at timestamptz not null default now(),
  primary key (user_id, version)
);
alter table public.framework_acceptances enable row level security;
revoke all on public.framework_acceptances from anon, authenticated;

-- 4) Conexiones
create table if not exists public.connection_counters (year integer primary key, last_number integer not null);
alter table public.connection_counters enable row level security;
revoke all on public.connection_counters from anon, authenticated;

create table if not exists public.connections (
  id                uuid primary key default gen_random_uuid(),
  code              text not null unique,
  number            text unique,                         -- constancia BST-CX-AAAA-NNNN (se asigna al aceptar)
  property_id       uuid not null references public.properties(id) on delete cascade,
  titular_id        uuid references auth.users(id) on delete set null,
  operation         text not null check (operation in ('venta', 'alquiler', 'anticretico')),
  interested_type   text not null check (interested_type in ('comprador', 'arrendatario', 'anticresista')),
  interested_name   text not null check (char_length(btrim(interested_name)) between 2 and 120),
  interested_phone  text not null check (char_length(interested_phone) between 7 and 20),
  interested_email  text check (interested_email is null or char_length(interested_email) <= 120),
  message           text check (message is null or char_length(message) <= 500),
  status            text not null default 'solicitada' check (status in
                      ('solicitada', 'rechazada', 'aceptada_pendiente_pago', 'comprobante_enviado', 'conexion_generada', 'cancelada')),
  fee_bs            numeric(10,2),                       -- tarifa CONGELADA al aceptar
  fee_calc          jsonb,                               -- regla, valor del inmueble en Bs y tipo de cambio usados
  property_snapshot jsonb,                               -- datos del inmueble al aceptar (constancia)
  framework_version integer,
  accepted_at       timestamptz,
  proof_path        text check (proof_path is null or char_length(proof_path) <= 300),
  proof_at          timestamptz,
  verified_at       timestamptz,
  verified_by       uuid references auth.users(id) on delete set null,
  review_note       text check (review_note is null or char_length(review_note) <= 500),
  cancelled_note    text check (cancelled_note is null or char_length(cancelled_note) <= 500),
  created_at        timestamptz not null default now()
);
create index if not exists connections_titular_idx on public.connections (titular_id, status, created_at desc);
create index if not exists connections_property_idx on public.connections (property_id, status);
alter table public.connections enable row level security;
revoke all on public.connections from anon, authenticated;

create table if not exists public.connection_events (
  id          bigint generated always as identity primary key,
  connection_id uuid not null references public.connections(id) on delete cascade,
  actor       text not null,
  actor_id    uuid,
  event       text not null,
  from_status text,
  to_status   text,
  data        jsonb,
  created_at  timestamptz not null default now()
);
create index if not exists connection_events_idx on public.connection_events (connection_id, created_at);
alter table public.connection_events enable row level security;
revoke all on public.connection_events from anon, authenticated;

create or replace function public._conn_log(p_conn uuid, p_actor text, p_event text, p_from text, p_to text, p_data jsonb default null)
returns void language sql security definer set search_path = public as $$
  insert into public.connection_events (connection_id, actor, actor_id, event, from_status, to_status, data) values (p_conn, p_actor, auth.uid(), p_event, p_from, p_to, p_data);
$$;
revoke all on function public._conn_log(uuid, text, text, text, text, jsonb) from public, anon, authenticated;

-- 5) Comprobantes de pago de la tarifa: carpeta privada, cada titular sube a la suya; el administrador lee todas
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('connection-proofs', 'connection-proofs', false, 5242880, array['application/pdf', 'image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do update set public = false, file_size_limit = 5242880, allowed_mime_types = array['application/pdf', 'image/jpeg', 'image/png', 'image/webp'];
drop policy if exists "titular uploads connection proof" on storage.objects;
create policy "titular uploads connection proof" on storage.objects for insert to authenticated
  with check (bucket_id = 'connection-proofs' and (storage.foldername(name))[1] = auth.uid()::text);
drop policy if exists "titular reads own connection proof" on storage.objects;
create policy "titular reads own connection proof" on storage.objects for select to authenticated
  using (bucket_id = 'connection-proofs' and (storage.foldername(name))[1] = auth.uid()::text);
drop policy if exists "admin reads connection proofs" on storage.objects;
create policy "admin reads connection proofs" on storage.objects for select to authenticated using (bucket_id = 'connection-proofs' and public.is_admin());
drop policy if exists "admin deletes connection proofs" on storage.objects;
create policy "admin deletes connection proofs" on storage.objects for delete to authenticated using (bucket_id = 'connection-proofs' and public.is_admin());

-- 6) Cálculo de la tarifa con la matriz (siempre en Bs; el valor en USD se convierte con el tipo de cambio INTERNO de Bastet)
create or replace function public._connection_fee(p_property uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare prop record; v numeric; rate numeric; vbs numeric; r record; b record; fee numeric; clamped boolean := false;
begin
  select id, coalesce(operation, 'venta') as operation, property_type, price, currency into prop from public.properties where id = p_property;   -- sin operación = venta (listados antiguos)
  if not found or prop.operation not in ('venta', 'alquiler', 'anticretico') then raise exception 'Esta propiedad no genera conexiones'; end if;
  v := nullif(regexp_replace(prop.price::text, '[^0-9]', '', 'g'), '')::numeric;
  select bob_per_usd into rate from public.stay_settings where id = 1;
  rate := coalesce(rate, 6.96);
  vbs := case when v is null then null when prop.currency = 'BOB' then v else v * rate end;
  select * into r from public.fee_rules f
   where f.active and f.operation = prop.operation and (f.property_type is null or f.property_type = prop.property_type)
     and (f.value_min_bs is null or (vbs is not null and vbs >= f.value_min_bs)) and (f.value_max_bs is null or (vbs is not null and vbs <= f.value_max_bs))
   order by ((f.property_type is not null)::int + (f.value_min_bs is not null)::int + (f.value_max_bs is not null)::int) desc, f.priority desc, f.id
   limit 1;
  if not found then raise exception 'No hay una regla de tarifa activa para esta propiedad. Avisa a administración.'; end if;
  select * into b from public.fee_bounds where operation = prop.operation;
  fee := r.fee_bs;
  if fee < b.min_bs then fee := b.min_bs; clamped := true; elsif fee > b.max_bs then fee := b.max_bs; clamped := true; end if;
  return jsonb_build_object('fee_bs', fee, 'rule_id', r.id, 'rule_label', r.label, 'provisional', r.provisional, 'clamped', clamped, 'operation', prop.operation,
    'property_type', prop.property_type, 'value_bs', vbs, 'bob_per_usd', rate, 'min_bs', b.min_bs, 'max_bs', b.max_bs);
end $$;
revoke all on function public._connection_fee(uuid) from public, anon, authenticated;

-- 7) Público: ¿están activas las conexiones?
create or replace function public.connections_enabled()
returns boolean language sql security definer set search_path = public stable as $$ select coalesce((select enabled from public.connection_settings where id = 1), false) $$;
revoke all on function public.connections_enabled() from public;
grant execute on function public.connections_enabled() to anon, authenticated;

-- 8) La persona interesada solicita contacto (sin cuenta)
create or replace function public.request_connection(p_property uuid, p_name text, p_phone text, p_email text default null, p_message text default null, p_consent boolean default false)
returns text language plpgsql security definer set search_path = public as $$
declare prop record; nm text := btrim(coalesce(p_name, '')); ph text := regexp_replace(coalesce(p_phone, ''), '[^0-9+]', '', 'g'); em text := nullif(btrim(coalesce(p_email, '')), '');
        msg text := nullif(btrim(coalesce(p_message, '')), ''); it text; cd text; tries int := 0;
begin
  if not public.connections_enabled() then raise exception 'Las solicitudes de contacto todavía no están activas'; end if;
  if p_consent is not true then raise exception 'Debes aceptar que se compartan tus datos con el agente'; end if;
  select id, owner_id, coalesce(operation, 'venta') as operation, status, expires_at into prop from public.properties where id = p_property;   -- sin operación = venta (listados antiguos)
  if not found or prop.status is distinct from 'available' or prop.operation not in ('venta', 'alquiler', 'anticretico')
     or (prop.expires_at is not null and prop.expires_at < now()) then raise exception 'Esta propiedad no está disponible'; end if;
  if char_length(nm) not between 2 and 120 then raise exception 'Escribe tu nombre'; end if;
  if char_length(regexp_replace(ph, '[^0-9]', '', 'g')) not between 7 and 15 then raise exception 'Escribe un número de WhatsApp válido'; end if;
  if em is not null and em !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'El correo no es válido'; end if;
  if msg is not null and char_length(msg) > 500 then raise exception 'El mensaje es demasiado largo (máximo 500 caracteres)'; end if;
  if exists (select 1 from public.connections c where c.property_id = p_property and c.interested_phone = ph and c.status in ('solicitada', 'aceptada_pendiente_pago', 'comprobante_enviado', 'conexion_generada')) then
    raise exception 'Ya enviaste una solicitud para esta propiedad'; end if;
  if (select count(*) from public.connections where interested_phone = ph and status = 'solicitada') >= 5 then
    raise exception 'Ya tienes 5 solicitudes esperando respuesta. Espera a que los agentes respondan.'; end if;
  it := case prop.operation when 'venta' then 'comprador' when 'alquiler' then 'arrendatario' else 'anticresista' end;
  loop
    cd := upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 10));
    begin
      insert into public.connections (code, property_id, titular_id, operation, interested_type, interested_name, interested_phone, interested_email, message)
      values (cd, p_property, prop.owner_id, prop.operation, it, nm, ph, em, msg);
      exit;
    exception when unique_violation then tries := tries + 1; if tries > 5 then raise; end if;
    end;
  end loop;
  perform public._conn_log((select id from public.connections where code = cd), 'interested', 'solicitada', null, 'solicitada', jsonb_build_object('type', it));
  return cd;
end $$;

-- 9) Contrato marco: estado y aceptación
create or replace function public.my_framework()
returns jsonb language plpgsql security definer set search_path = public stable as $$
declare s public.connection_settings; uid uuid := auth.uid(); req boolean;
begin
  if uid is null or not public.is_active_user() then raise exception 'No autorizado' using errcode = '42501'; end if;
  select * into s from public.connection_settings where id = 1;
  req := s.enabled and char_length(btrim(s.framework_text)) > 0 and not public.is_admin();
  return jsonb_build_object('required', req, 'version', s.framework_version, 'text', case when req then s.framework_text end,
    'accepted', not req or exists (select 1 from public.framework_acceptances a where a.user_id = uid and a.version = s.framework_version));
end $$;

create or replace function public.accept_framework_contract(p_version integer)
returns void language plpgsql security definer set search_path = public as $$
declare s public.connection_settings;
begin
  if auth.uid() is null or not public.is_active_user() then raise exception 'No autorizado' using errcode = '42501'; end if;
  select * into s from public.connection_settings where id = 1;
  if p_version is distinct from s.framework_version then raise exception 'El contrato marco cambió. Vuelve a leerlo y acéptalo.'; end if;
  insert into public.framework_acceptances (user_id, version) values (auth.uid(), s.framework_version) on conflict do nothing;
end $$;

-- Antes de la primera publicación (y tras cada nueva versión) hay que aceptar el contrato marco
create or replace function public.require_framework_on_publish()
returns trigger language plpgsql security definer set search_path = public as $$
declare s public.connection_settings; uid uuid := auth.uid();
begin
  if uid is null or public.is_admin() then return new; end if;
  select * into s from public.connection_settings where id = 1;
  if s.enabled and char_length(btrim(s.framework_text)) > 0
     and not exists (select 1 from public.framework_acceptances a where a.user_id = uid and a.version = s.framework_version) then
    raise exception 'Antes de publicar debes aceptar el contrato marco de Bastet' using errcode = 'P0403', hint = 'framework';
  end if;
  return new;
end $$;
drop trigger if exists require_framework_on_publish on public.properties;
create trigger require_framework_on_publish before insert on public.properties for each row execute function public.require_framework_on_publish();

-- 10) Titular (y administración): lista de conexiones. Los datos del interesado solo se ven con la conexión verificada (el admin ve todo).
create or replace function public.my_connections()
returns jsonb language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); adm boolean; s public.connection_settings;
begin
  if uid is null or not public.is_active_user() then raise exception 'No autorizado' using errcode = '42501'; end if;
  adm := public.is_admin();
  select * into s from public.connection_settings where id = 1;
  return jsonb_build_object('enabled', s.enabled, 'pay_instructions', s.pay_instructions, 'pay_qr_url', s.pay_qr_url,
    'items', coalesce((select jsonb_agg(jsonb_build_object(
        'id', c.id, 'code', c.code, 'number', c.number, 'status', c.status, 'property_id', c.property_id, 'title', p.title, 'property_code', p.code_number,
        'operation', c.operation, 'interested_type', c.interested_type, 'message', c.message, 'created_at', c.created_at,
        'interested_name', case when adm or c.status = 'conexion_generada' then c.interested_name
                                else split_part(btrim(c.interested_name), ' ', 1) || coalesce(' ' || upper(left(nullif(split_part(btrim(c.interested_name), ' ', 2), ''), 1)) || '.', '') end,
        'interested_phone', case when adm or c.status = 'conexion_generada' then c.interested_phone end,
        'interested_email', case when adm or c.status = 'conexion_generada' then c.interested_email end,
        'fee_bs', c.fee_bs, 'fee_calc', case when adm then c.fee_calc end, 'accepted_at', c.accepted_at, 'proof_at', c.proof_at, 'verified_at', c.verified_at,
        'review_note', c.review_note, 'proof_path', case when adm then c.proof_path end, 'framework_version', c.framework_version,
        'titular_name', case when adm then (select display_name from public.profiles where id = c.titular_id) end) order by c.created_at desc)
      from public.connections c join public.properties p on p.id = c.property_id
      where (adm or c.titular_id = uid) and c.created_at > now() - interval '24 months'), '[]'::jsonb));
end $$;

-- 11) El titular acepta o rechaza. Al aceptar nace la obligación: se congela la tarifa, se numera la constancia y se guarda la versión del contrato marco.
create or replace function public.respond_connection(p_id uuid, p_accept boolean)
returns jsonb language plpgsql security definer set search_path = public as $$
declare c public.connections; uid uuid := auth.uid(); s public.connection_settings; fee jsonb; yr integer; seq integer; num text; snap jsonb; who text;
begin
  if uid is null or not public.is_active_user() then raise exception 'No autorizado' using errcode = '42501'; end if;
  select * into c from public.connections where id = p_id for update;
  if not found or (c.titular_id is distinct from uid and not public.is_admin()) then raise exception 'Solicitud no encontrada'; end if;
  if c.status <> 'solicitada' then raise exception 'Esta solicitud ya fue respondida'; end if;
  who := case when c.titular_id = uid then 'titular' else 'admin' end;
  if not p_accept then
    update public.connections set status = 'rechazada' where id = c.id;
    perform public._conn_log(c.id, who, 'rechazada', c.status, 'rechazada');
    return jsonb_build_object('status', 'rechazada');
  end if;
  select * into s from public.connection_settings where id = 1;
  if s.enabled and char_length(btrim(s.framework_text)) > 0 and c.titular_id is not null
     and not exists (select 1 from public.framework_acceptances a where a.user_id = c.titular_id and a.version = s.framework_version) then
    raise exception 'Antes de aceptar debes aceptar el contrato marco de Bastet' using errcode = 'P0403', hint = 'framework';
  end if;
  fee := public._connection_fee(c.property_id);
  yr := extract(year from ((now() at time zone 'UTC') - interval '4 hours'))::integer;
  insert into public.connection_counters (year, last_number) values (yr, 1)
  on conflict (year) do update set last_number = public.connection_counters.last_number + 1 returning last_number into seq;
  num := 'BST-CX-' || yr || '-' || lpad(seq::text, 4, '0');
  select jsonb_build_object('title', p.title, 'code_number', p.code_number, 'location', p.location, 'address', p.address, 'price', p.price, 'currency', p.currency,
                            'operation', p.operation, 'property_type', p.property_type) into snap from public.properties p where p.id = c.property_id;
  update public.connections set status = 'aceptada_pendiente_pago', accepted_at = now(), number = num, fee_bs = (fee ->> 'fee_bs')::numeric, fee_calc = fee,
         property_snapshot = snap, framework_version = case when s.enabled and char_length(btrim(s.framework_text)) > 0 then s.framework_version end where id = c.id;
  perform public._conn_log(c.id, who, 'aceptada', c.status, 'aceptada_pendiente_pago', jsonb_build_object('number', num, 'fee', fee));
  return jsonb_build_object('status', 'aceptada_pendiente_pago', 'number', num, 'fee_bs', (fee ->> 'fee_bs')::numeric);
end $$;

-- 12) El titular avisa que subió el comprobante de la tarifa (el archivo ya está en connection-proofs/<id del titular>/…)
create or replace function public.attach_connection_proof(p_id uuid, p_path text)
returns void language plpgsql security definer set search_path = public as $$
declare c public.connections; uid uuid := auth.uid();
begin
  if uid is null or not public.is_active_user() then raise exception 'No autorizado' using errcode = '42501'; end if;
  if p_path is null or char_length(p_path) > 300 or p_path not like uid::text || '/%' or p_path like '%..%' then raise exception 'Comprobante inválido'; end if;
  select * into c from public.connections where id = p_id for update;
  if not found or c.titular_id is distinct from uid then raise exception 'Conexión no encontrada'; end if;
  if c.status not in ('aceptada_pendiente_pago', 'comprobante_enviado') then raise exception 'Esta conexión no espera un comprobante'; end if;
  update public.connections set proof_path = p_path, proof_at = now(), status = 'comprobante_enviado', review_note = null where id = c.id;
  perform public._conn_log(c.id, 'titular', 'comprobante_enviado', c.status, 'comprobante_enviado', jsonb_build_object('path', p_path));
end $$;

-- 13) Administración verifica o rechaza el comprobante; al verificar se genera la conexión y se revelan los datos del interesado
create or replace function public.admin_review_connection_proof(p_id uuid, p_approve boolean, p_note text default null)
returns void language plpgsql security definer set search_path = public as $$
declare c public.connections; nt text := nullif(btrim(coalesce(p_note, '')), '');
begin
  if not public.is_admin() then raise exception 'Solo administradores' using errcode = '42501'; end if;
  select * into c from public.connections where id = p_id for update;
  if not found or c.status <> 'comprobante_enviado' then raise exception 'No hay un comprobante por revisar en esta conexión'; end if;
  if p_approve then
    update public.connections set status = 'conexion_generada', verified_at = now(), verified_by = auth.uid(), review_note = nt where id = c.id;
    perform public._conn_log(c.id, 'admin', 'pago_verificado_y_conexion', c.status, 'conexion_generada', jsonb_build_object('fee_bs', c.fee_bs, 'note', nt));
  else
    if nt is null then raise exception 'Escribe el motivo del rechazo para que el titular pueda corregirlo'; end if;
    update public.connections set status = 'aceptada_pendiente_pago', proof_path = null, proof_at = null, review_note = nt where id = c.id;
    perform public._conn_log(c.id, 'admin', 'comprobante_rechazado', c.status, 'aceptada_pendiente_pago', jsonb_build_object('note', nt, 'path', c.proof_path));
  end if;
end $$;

create or replace function public.admin_cancel_connection(p_id uuid, p_note text)
returns void language plpgsql security definer set search_path = public as $$
declare c public.connections; nt text := nullif(btrim(coalesce(p_note, '')), '');
begin
  if not public.is_admin() then raise exception 'Solo administradores' using errcode = '42501'; end if;
  if nt is null then raise exception 'Escribe el motivo de la cancelación'; end if;
  select * into c from public.connections where id = p_id for update;
  if not found or c.status in ('cancelada', 'rechazada') then raise exception 'Conexión no encontrada o ya cerrada'; end if;
  update public.connections set status = 'cancelada', cancelled_note = nt where id = c.id;
  perform public._conn_log(c.id, 'admin', 'cancelada', c.status, 'cancelada', jsonb_build_object('note', nt));
end $$;

create or replace function public.connection_events(p_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Solo administradores' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('actor', e.actor, 'event', e.event, 'from', e.from_status, 'to', e.to_status, 'data', e.data, 'at', e.created_at) order by e.created_at, e.id)
                     from public.connection_events e where e.connection_id = p_id), '[]'::jsonb);
end $$;

-- 14) Vista previa de la tarifa de una propiedad (titular o administración)
create or replace function public.preview_connection_fee(p_property uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare owner uuid;
begin
  if auth.uid() is null or not public.is_active_user() then raise exception 'No autorizado' using errcode = '42501'; end if;
  select owner_id into owner from public.properties where id = p_property;
  if not found or (owner is distinct from auth.uid() and not public.is_admin()) then raise exception 'Propiedad no encontrada'; end if;
  return public._connection_fee(p_property);
end $$;

-- 15) Administración: ajustes, matriz, historial
create or replace function public.get_connection_settings()
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Solo administradores' using errcode = '42501'; end if;
  return jsonb_build_object('settings', (select to_jsonb(s) from public.connection_settings s where id = 1),
    'bounds', coalesce((select jsonb_agg(to_jsonb(b) order by b.operation) from public.fee_bounds b), '[]'::jsonb),
    'rules', coalesce((select jsonb_agg(to_jsonb(r) order by r.operation, r.priority desc, r.id) from public.fee_rules r), '[]'::jsonb),
    'history', coalesce((select jsonb_agg(jsonb_build_object('rule_id', h.rule_id, 'action', h.action, 'before', h.old_data, 'after', h.new_data, 'at', h.created_at) order by h.created_at desc)
                           from (select * from public.fee_rule_events order by created_at desc limit 50) h), '[]'::jsonb));
end $$;

create or replace function public.admin_update_connection_settings(p_enabled boolean, p_pay_instructions text, p_pay_qr_url text, p_framework_text text)
returns void language plpgsql security definer set search_path = public as $$
declare cur public.connection_settings; ft text := btrim(coalesce(p_framework_text, ''));
begin
  if not public.is_admin() then raise exception 'Solo administradores' using errcode = '42501'; end if;
  select * into cur from public.connection_settings where id = 1;
  if p_enabled and char_length(btrim(coalesce(p_pay_instructions, ''))) < 10 then raise exception 'Antes de activar, escribe las instrucciones de pago (cuenta o QR)'; end if;
  if p_enabled and char_length(ft) < 100 then raise exception 'Antes de activar, pega el texto del contrato marco (revisado por un abogado)'; end if;
  update public.connection_settings set enabled = coalesce(p_enabled, false), pay_instructions = btrim(coalesce(p_pay_instructions, '')),
         pay_qr_url = nullif(btrim(coalesce(p_pay_qr_url, '')), ''), framework_text = ft,
         framework_version = case when ft is distinct from cur.framework_text then cur.framework_version + 1 else cur.framework_version end, updated_at = now() where id = 1;
end $$;

create or replace function public.admin_save_fee_rule(p_id bigint, p_operation text, p_property_type text, p_min_bs numeric, p_max_bs numeric, p_fee_bs numeric,
                                                      p_priority integer, p_label text, p_active boolean)
returns bigint language plpgsql security definer set search_path = public as $$
declare b public.fee_bounds; old_row jsonb; rid bigint := p_id; pt text := nullif(btrim(coalesce(p_property_type, '')), '');
begin
  if not public.is_admin() then raise exception 'Solo administradores' using errcode = '42501'; end if;
  select * into b from public.fee_bounds where operation = p_operation;
  if not found then raise exception 'Operación inválida'; end if;
  if p_fee_bs is null or p_fee_bs < b.min_bs or p_fee_bs > b.max_bs then
    raise exception 'La tarifa de % debe estar entre Bs % y Bs %', p_operation, b.min_bs, b.max_bs; end if;
  if p_min_bs is not null and p_max_bs is not null and p_min_bs > p_max_bs then raise exception 'El valor mínimo no puede superar al máximo'; end if;
  if p_id is null then
    insert into public.fee_rules (operation, property_type, value_min_bs, value_max_bs, fee_bs, priority, label, active)
    values (p_operation, pt, p_min_bs, p_max_bs, p_fee_bs, coalesce(p_priority, 0), nullif(btrim(coalesce(p_label, '')), ''), coalesce(p_active, true)) returning id into rid;
    insert into public.fee_rule_events (rule_id, actor, action, new_data) select rid, auth.uid(), 'creada', to_jsonb(r) from public.fee_rules r where r.id = rid;
  else
    select to_jsonb(r) into old_row from public.fee_rules r where r.id = p_id;
    if old_row is null then raise exception 'Regla no encontrada'; end if;
    update public.fee_rules set operation = p_operation, property_type = pt, value_min_bs = p_min_bs, value_max_bs = p_max_bs, fee_bs = p_fee_bs,
           priority = coalesce(p_priority, 0), label = nullif(btrim(coalesce(p_label, '')), ''), active = coalesce(p_active, true), provisional = false, updated_at = now() where id = p_id;
    insert into public.fee_rule_events (rule_id, actor, action, old_data, new_data) select p_id, auth.uid(), 'editada', old_row, to_jsonb(r) from public.fee_rules r where r.id = p_id;
  end if;
  return rid;
end $$;

create or replace function public.admin_delete_fee_rule(p_id bigint)
returns void language plpgsql security definer set search_path = public as $$
declare old_row jsonb;
begin
  if not public.is_admin() then raise exception 'Solo administradores' using errcode = '42501'; end if;
  select to_jsonb(r) into old_row from public.fee_rules r where r.id = p_id;
  if old_row is null then raise exception 'Regla no encontrada'; end if;
  delete from public.fee_rules where id = p_id;
  insert into public.fee_rule_events (rule_id, actor, action, old_data) values (p_id, auth.uid(), 'eliminada', old_row);
end $$;

-- 16) Permisos
revoke all on function public.request_connection(uuid, text, text, text, text, boolean), public.my_framework(), public.accept_framework_contract(integer),
  public.require_framework_on_publish(), public.my_connections(), public.respond_connection(uuid, boolean), public.attach_connection_proof(uuid, text),
  public.admin_review_connection_proof(uuid, boolean, text), public.admin_cancel_connection(uuid, text), public.connection_events(uuid),
  public.preview_connection_fee(uuid), public.get_connection_settings(), public.admin_update_connection_settings(boolean, text, text, text),
  public.admin_save_fee_rule(bigint, text, text, numeric, numeric, numeric, integer, text, boolean), public.admin_delete_fee_rule(bigint) from public, anon;
grant execute on function public.request_connection(uuid, text, text, text, text, boolean) to anon, authenticated;
grant execute on function public.my_framework(), public.accept_framework_contract(integer), public.my_connections(), public.respond_connection(uuid, boolean),
  public.attach_connection_proof(uuid, text), public.admin_review_connection_proof(uuid, boolean, text), public.admin_cancel_connection(uuid, text),
  public.connection_events(uuid), public.preview_connection_fee(uuid), public.get_connection_settings(), public.admin_update_connection_settings(boolean, text, text, text),
  public.admin_save_fee_rule(bigint, text, text, numeric, numeric, numeric, integer, text, boolean), public.admin_delete_fee_rule(bigint) to authenticated;

notify pgrst, 'reload schema';

-- =====================================================================
-- Bastet · Blindaje de datos y antiabuso (fase 2, paso B2)
-- Idempotente: se puede correr completo más de una vez. Correr DESPUÉS de todo lo demás (connections.sql incluida).
--
-- Qué cierra (hallazgos de la auditoría del 2026-11-03):
--  1) CONTACTO: el visitante podía leer properties.whatsapp y profiles.contact_whatsapp con la clave pública de la API (y así saltarse la tarifa
--     de conexión). Ahora esas columnas no se leen; el contacto solo sale por public_property_contact / public_agent_contact, que respetan el
--     modelo vigente (con conexiones activas no entregan el teléfono).
--  2) CUENTAS: cualquier persona con sesión (basta una cuenta de Google) podía leer TODAS las columnas de TODAS las propiedades, incluido el
--     teléfono privado del propietario (owner_whatsapp), y las no disponibles. Ahora ve solo columnas públicas de propiedades disponibles (y las
--     suyas); sus propios teléfonos los obtiene con my_property_contacts().
--  3) FOTOS Y AVATARES: cualquier usuario activo podía borrar o reemplazar las fotos de propiedades y los avatares de otras personas. Ahora solo
--     el dueño de la propiedad (carpeta = id de la propiedad) o de la cuenta (carpeta = su id), o un administrador.
--  4) ANTIABUSO: límite de intentos por IP en los formularios públicos y en las consultas por código (spam y fuerza bruta).
--  5) PERMISOS MÍNIMOS: el visitante ya no tiene permisos de escritura sobre las tablas (antes solo los frenaba la seguridad por filas).
--  6) Perfiles públicos solo de agentes con propiedades disponibles (no se puede listar a todos los usuarios); sin planes públicos.
-- =====================================================================

do $$
begin
  if to_regprocedure('public.request_connection(uuid, text, text, text, text, boolean)') is null then raise exception 'Primero corre schema.sql completo (incluye connections.sql)'; end if;
end $$;

-- 1) Límite de intentos por IP (la IP la entrega el gateway en request.headers; sin cabeceras —SQL Editor, pruebas internas— no se limita)
create table if not exists public.rate_limits (
  key          text not null,
  action       text not null,
  window_start timestamptz not null,
  n            integer not null default 0,
  primary key (key, action, window_start)
);
alter table public.rate_limits enable row level security;
revoke all on public.rate_limits from anon, authenticated;

create or replace function public._throttle(p_action text, p_max integer, p_window_seconds integer)
returns void language plpgsql security definer set search_path = public as $$
declare hdr text; h json; ip text; ws timestamptz; cur integer;
begin
  hdr := current_setting('request.headers', true);
  if hdr is null or hdr = '' then return; end if;
  begin h := hdr::json; exception when others then return; end;
  -- La IP del cliente: cf-connecting-ip si existe; si no, el ÚLTIMO elemento de x-forwarded-for (el que añade el gateway, no el que escribe el cliente)
  ip := nullif(btrim(coalesce(h ->> 'cf-connecting-ip', (string_to_array(coalesce(h ->> 'x-forwarded-for', ''), ','))[array_length(string_to_array(coalesce(h ->> 'x-forwarded-for', ''), ','), 1)], h ->> 'x-real-ip', '')), '');
  if ip is null then return; end if;
  ws := to_timestamp(floor(extract(epoch from now()) / p_window_seconds) * p_window_seconds);
  select n into cur from public.rate_limits where key = ip and action = p_action and window_start = ws;
  if coalesce(cur, 0) >= p_max then   -- se verifica ANTES de sumar: si se lanzara el error después, la transacción desharía el conteo
    raise exception 'Demasiados intentos. Espera unos minutos e inténtalo de nuevo.' using errcode = 'P0429';
  end if;
  insert into public.rate_limits (key, action, window_start, n) values (ip, p_action, ws, 1)
  on conflict (key, action, window_start) do update set n = public.rate_limits.n + 1;
  if random() < 0.01 then delete from public.rate_limits where window_start < now() - interval '2 days'; end if;
end $$;
revoke all on function public._throttle(text, integer, integer) from public, anon, authenticated;

-- 2) Funciones públicas existentes, con límite por IP (copias de su última definición + una línea)
create or replace function public.request_connection(p_property uuid, p_name text, p_phone text, p_email text default null, p_message text default null, p_consent boolean default false)
returns text language plpgsql security definer set search_path = public as $$
declare prop record; nm text := btrim(coalesce(p_name, '')); ph text := regexp_replace(coalesce(p_phone, ''), '[^0-9+]', '', 'g'); em text := nullif(btrim(coalesce(p_email, '')), '');
        msg text := nullif(btrim(coalesce(p_message, '')), ''); it text; cd text; tries int := 0;
begin
  perform public._throttle('request_connection', 8, 600);
  if not public.connections_enabled() then raise exception 'Las solicitudes de contacto todavía no están activas'; end if;
  if p_consent is not true then raise exception 'Debes aceptar que se compartan tus datos con el agente'; end if;
  select id, owner_id, coalesce(operation, 'venta') as operation, status, expires_at into prop from public.properties where id = p_property;   -- sin operación = venta (listados antiguos)
  if not found or prop.status is distinct from 'available' or prop.operation not in ('venta', 'alquiler', 'anticretico')
     or (prop.expires_at is not null and prop.expires_at < now()) then raise exception 'Esta propiedad no está disponible'; end if;
  if char_length(nm) not between 2 and 120 then raise exception 'Escribe tu nombre'; end if;
  if char_length(regexp_replace(ph, '[^0-9]', '', 'g')) not between 7 and 15 then raise exception 'Escribe un número de WhatsApp válido'; end if;
  if em is not null and em !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'El correo no es válido'; end if;
  if msg is not null and char_length(msg) > 500 then raise exception 'El mensaje es demasiado largo (máximo 500 caracteres)'; end if;
  if exists (select 1 from public.connections c where c.property_id = p_property and c.interested_phone = ph and c.status in ('solicitada', 'aceptada_pendiente_pago', 'comprobante_enviado', 'conexion_generada')) then
    raise exception 'Ya enviaste una solicitud para esta propiedad'; end if;
  if (select count(*) from public.connections where interested_phone = ph and status = 'solicitada') >= 5 then
    raise exception 'Ya tienes 5 solicitudes esperando respuesta. Espera a que los agentes respondan.'; end if;
  it := case prop.operation when 'venta' then 'comprador' when 'alquiler' then 'arrendatario' else 'anticresista' end;
  loop
    cd := upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 10));
    begin
      insert into public.connections (code, property_id, titular_id, operation, interested_type, interested_name, interested_phone, interested_email, message)
      values (cd, p_property, prop.owner_id, prop.operation, it, nm, ph, em, msg);
      exit;
    exception when unique_violation then tries := tries + 1; if tries > 5 then raise; end if;
    end;
  end loop;
  perform public._conn_log((select id from public.connections where code = cd), 'interested', 'solicitada', null, 'solicitada', jsonb_build_object('type', it));
  return cd;
end $$;

create or replace function public.create_stay_booking(p_property uuid, p_from date, p_to date, p_guests integer, p_name text, p_phone text, p_email text default null)
returns text language plpgsql security definer set search_path = public as $$
declare s public.stay_settings; prop record; v_n integer; v_price numeric; v_total numeric; v_fee numeric; v_rate numeric; v_feebs numeric; tries int := 0; cd text;
        nm text := btrim(coalesce(p_name, '')); ph text := regexp_replace(coalesce(p_phone, ''), '[^0-9+]', '', 'g'); em text := nullif(btrim(coalesce(p_email, '')), '');
begin
  perform public._throttle('create_stay_booking', 8, 600);
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

create or replace function public.cancel_stay_booking(p_code text, p_reason text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare b public.stay_bookings; s public.stay_settings; late boolean := false; paid boolean; refund numeric := 0; hostret numeric := null; due numeric := null;
        rs text := nullif(btrim(coalesce(p_reason, '')), '');
begin
  perform public._throttle('cancel_stay_booking', 20, 600);
  perform public.stay_expire_pending();
  select * into b from public.stay_bookings where code = upper(btrim(coalesce(p_code, ''))) for update;
  if not found or b.status not in ('pendiente_respuesta_anfitrion', 'aceptada_pendiente_pago', 'comprobante_enviado', 'pago_en_revision', 'conexion_generada') then
    raise exception 'Esta reserva no se puede cancelar'; end if;
  select * into s from public.stay_settings where id = 1;
  paid := b.status = 'conexion_generada';
  if paid then
    late := now() > coalesce(b.verified_at, now()) + make_interval(hours => s.free_cancel_hours);
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

create or replace function public.attach_stay_proof(p_code text, p_path text)
returns void language plpgsql security definer set search_path = public as $$
declare b public.stay_bookings; cd text := upper(btrim(coalesce(p_code, '')));
begin
  perform public._throttle('attach_stay_proof', 20, 600);
  if p_path is null or char_length(p_path) > 300 or p_path not like cd || '/%' or p_path like '%..%' then raise exception 'Comprobante inválido'; end if;
  select * into b from public.stay_bookings where code = cd for update;
  if not found or b.status not in ('aceptada_pendiente_pago', 'comprobante_enviado', 'pago_en_revision') then raise exception 'Esta reserva no espera un comprobante'; end if;
  update public.stay_bookings set proof_path = p_path, proof_at = now(), status = 'comprobante_enviado', review_note = null where id = b.id;
  perform public.stay_log(b.id, 'guest', 'comprobante_enviado', b.status, 'comprobante_enviado', jsonb_build_object('path', p_path));
end $$;

create or replace function public.get_stay_booking(p_code text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare b public.stay_bookings; s public.stay_settings; prop record; contact text; pay boolean; reveal boolean; free_until timestamptz; host_name text;
begin
  perform public._throttle('get_stay_booking', 90, 60);
  perform public.stay_expire_pending();
  select * into b from public.stay_bookings where code = upper(btrim(coalesce(p_code, '')));
  if not found then return jsonb_build_object('found', false); end if;
  select * into s from public.stay_settings where id = 1;
  select title, location, photos[1] as photo, whatsapp into prop from public.properties where id = b.property_id;
  select display_name, contact_whatsapp into host_name, contact from public.profiles where id = b.host_id;
  reveal := b.status = 'conexion_generada';
  pay := b.status in ('aceptada_pendiente_pago', 'comprobante_enviado', 'pago_en_revision');
  free_until := b.verified_at + make_interval(hours => s.free_cancel_hours);
  return jsonb_build_object('found', true, 'code', b.code, 'status', b.status, 'title', prop.title, 'location', prop.location, 'photo', prop.photo,
    'guest_name', b.guest_name, 'guests', b.guests, 'check_in', b.check_in, 'check_out', b.check_out, 'nights', b.nights, 'currency', b.currency,
    'total', b.total, 'fee_amount', b.fee_amount, 'fee_bs', b.fee_bs, 'balance', b.total - b.fee_amount, 'fee_percent', s.fee_percent,
    'respond_by', b.respond_by, 'pay_by', case when b.status = 'aceptada_pendiente_pago' and s.pay_window_hours is not null then b.accepted_at + make_interval(hours => s.pay_window_hours) end, 'proof_sent', b.proof_path is not null, 'review_note', b.review_note,
    'pay_instructions', case when pay then s.pay_instructions end, 'pay_qr_url', case when pay then s.pay_qr_url end,
    'host_name', case when reveal then host_name end, 'host_whatsapp', case when reveal then coalesce(contact, prop.whatsapp) end,
    'free_cancel_until', case when reveal then free_until end, 'free_cancel_hours', s.free_cancel_hours,
    'is_late_cancel', reveal and now() > free_until,
    'can_cancel', b.status in ('pendiente_respuesta_anfitrion', 'aceptada_pendiente_pago', 'comprobante_enviado', 'pago_en_revision', 'conexion_generada'),
    'cancelled_by', b.cancelled_by, 'late_cancel', b.late_cancel, 'bastet_refund_bs', b.bastet_refund_bs, 'host_retention', b.host_retention, 'host_refund_due', b.host_refund_due);
end $$;

create or replace function public.verify_stay_booking(p_code text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare b public.stay_bookings; prop record; host_name text; contact text; ok boolean;
begin
  perform public._throttle('verify_stay_booking', 30, 60);
  perform public.stay_expire_pending();
  select * into b from public.stay_bookings where code = upper(btrim(coalesce(p_code, '')));
  if not found then return jsonb_build_object('found', false); end if;
  select title, location, address, photos, latitude, longitude, whatsapp into prop from public.properties where id = b.property_id;
  select display_name, contact_whatsapp into host_name, contact from public.profiles where id = b.host_id;
  ok := b.verified_at is not null and b.status in ('conexion_generada', 'en_disputa');
  return jsonb_build_object('found', true, 'code', b.code, 'status', b.status, 'verified', ok, 'verified_at', b.verified_at,
    'title', prop.title, 'location', prop.location, 'address', prop.address, 'latitude', prop.latitude, 'longitude', prop.longitude,
    'photos', to_jsonb(coalesce(prop.photos, '{}'::text[])),
    'check_in', b.check_in, 'check_out', b.check_out, 'nights', b.nights, 'guests', b.guests,
    'guest_name', split_part(btrim(b.guest_name), ' ', 1) || coalesce(' ' || upper(left(nullif(split_part(btrim(b.guest_name), ' ', 2), ''), 1)) || '.', ''),
    'currency', b.currency, 'total', b.total, 'fee_bs', b.fee_bs, 'balance', b.total - b.fee_amount,
    'host_name', case when ok then host_name end, 'host_whatsapp', case when ok then coalesce(contact, prop.whatsapp) end,
    'cancelled_by', b.cancelled_by, 'created_at', b.created_at,
    'events', coalesce((select jsonb_agg(jsonb_build_object('event', e.event, 'at', e.created_at) order by e.created_at, e.id)
                          from public.stay_booking_events e
                         where e.booking_id = b.id and e.event in ('solicitada', 'aceptada', 'rechazada', 'expirada_sin_respuesta', 'expirada_sin_pago', 'comprobante_enviado',
                               'comprobante_rechazado', 'pago_verificado_y_conexion', 'cancelada_por_huesped', 'cancelada_por_anfitrion', 'disputa_abierta', 'disputa_cerrada')), '[]'::jsonb),
    'busy', coalesce((select jsonb_agg(jsonb_build_object('from', k.check_in, 'to', k.check_out - 1))
                        from public.stay_bookings k
                       where k.property_id = b.property_id and k.id <> b.id and k.check_out - 1 >= public.bo_today()
                         and k.status in ('aceptada_pendiente_pago', 'comprobante_enviado', 'pago_en_revision', 'pago_verificado', 'conexion_generada', 'en_disputa')), '[]'::jsonb));
end $$;

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
  perform public._throttle('submit_property_lead', 8, 600);
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
  perform public._throttle('submit_sell_request', 5, 600);
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

create or replace function public.submit_property_request(p jsonb)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  rid uuid;
  ph  text := regexp_replace(coalesce(p->>'contact_phone', ''), '[\s().-]', '', 'g');
  feats text[];
  num numeric;
begin
  perform public._throttle('submit_property_request', 8, 600);
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

create or replace function public.submit_stay_review(p_token text, p_name text, p_rating integer, p_comment text)
returns boolean language plpgsql security definer set search_path = public as $$
declare i public.stay_review_invites; nm text := btrim(coalesce(p_name, '')); cm text := nullif(btrim(coalesce(p_comment, '')), '');
begin
  perform public._throttle('submit_stay_review', 8, 600);
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

create or replace function public.get_review_invite(p_token text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare i record;
begin
  perform public._throttle('get_review_invite', 30, 60);
  select v.guest_name, v.used_at, p.title, p.location into i
    from public.stay_review_invites v join public.properties p on p.id = v.property_id
   where v.token = upper(btrim(coalesce(p_token, '')));
  if not found then return jsonb_build_object('valid', false); end if;
  return jsonb_build_object('valid', i.used_at is null, 'used', i.used_at is not null, 'guest_name', i.guest_name, 'title', i.title, 'location', i.location);
end $$;

create or replace function public.finish_property_request(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform public._throttle('finish_property_request', 20, 600);
  update public.property_requests set status = 'finished', updated_at = now() where id = p_id;
  if not found then raise exception 'Solicitud no encontrada'; end if;
end $$;

create or replace function public.stay_booked_ranges(p_ids uuid[])
returns table (property_id uuid, from_date date, to_date date, confirmed boolean)
language plpgsql security definer set search_path = public as $$
begin
  perform public._throttle('stay_booked_ranges', 120, 60);
  if coalesce(array_length(p_ids, 1), 0) > 300 then raise exception 'Demasiadas propiedades'; end if;
  perform public.stay_expire_pending();
  return query
    select b.property_id, b.check_in, b.check_out - 1, b.status in ('pago_verificado', 'conexion_generada', 'en_disputa')
      from public.stay_bookings b
     where b.property_id = any (coalesce(p_ids, '{}'::uuid[]))
       and b.status in ('aceptada_pendiente_pago', 'comprobante_enviado', 'pago_en_revision', 'pago_verificado', 'conexion_generada', 'en_disputa')
       and b.check_out - 1 >= public.bo_today()
     order by b.check_in;
end $$;

-- La verificación de contratos pasa a plpgsql para poder limitarla (misma firma y mismo resultado)
create or replace function public.verify_exclusivity_contract(p_code text)
returns table (contract_number text, created_at timestamptz, agent_name text, template_version text, voided boolean, voided_at timestamptz)
language plpgsql security definer set search_path = public as $$
begin
  perform public._throttle('verify_contract', 30, 60);
  return query
  select c.contract_number, c.created_at, coalesce(nullif(btrim(p.display_name), ''), 'Agente de Bastet'), c.template_version, (c.voided_at is not null), c.voided_at
    from public.exclusivity_contracts c left join public.profiles p on p.id = c.agent_id
   where c.verification_code = upper(btrim(coalesce(p_code, ''))) limit 1;
end $$;

-- 3) Contacto: el teléfono ya no se lee de las tablas
revoke select (whatsapp) on public.properties from anon;
revoke select on public.properties from authenticated;
grant select (id, title, location, address, price, currency, exchange_rate, area, rooms, baths, description, photos, owner_id, featured, featured_until, sort_order, status, created_at, code_number, property_type, operation, floors, has_garage, garage_spots, has_storage, pets_allowed, kids_allowed, expires_at, latitude, longitude) on public.properties to authenticated;
revoke select (contact_whatsapp) on public.profiles from anon;

drop policy if exists "authenticated can read all properties" on public.properties;
create policy "authenticated can read all properties" on public.properties for select to authenticated
  using (status = 'available' or owner_id = auth.uid() or public.is_admin());

drop policy if exists "public can read active agent public info" on public.profiles;
create policy "public can read active agent public info" on public.profiles for select to anon
  using (is_active = true and exists (select 1 from public.properties p where p.owner_id = profiles.id and p.status = 'available'));

-- Teléfonos de las propiedades de quien consulta (o de todas, si es administrador)
create or replace function public.my_property_contacts()
returns table (property_id uuid, whatsapp text, owner_whatsapp text)
language plpgsql security definer set search_path = public stable as $$
begin
  if auth.uid() is null or not public.is_active_user() then raise exception 'No autorizado' using errcode = '42501'; end if;
  return query select p.id, p.whatsapp, p.owner_whatsapp from public.properties p where p.owner_id = auth.uid() or public.is_admin();
end $$;

-- Contacto público: solo cuando el modelo vigente permite el contacto directo (con conexiones activas o reservas activas, el contacto va por la
-- solicitud o la reserva). Devuelve el teléfono del agente que publicó o, si no tiene, el de la propiedad.
create or replace function public.public_property_contact(p_property uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare prop record; op text; allowed boolean; ph text;
begin
  perform public._throttle('public_contact', 40, 60);
  select owner_id, whatsapp, status, expires_at, coalesce(operation, 'venta') as operation into prop from public.properties where id = p_property;
  if not found or prop.status is distinct from 'available' or (prop.expires_at is not null and prop.expires_at < now()) then return jsonb_build_object('allowed', false); end if;
  allowed := case when prop.operation = 'temporal' then not public.stay_booking_enabled() else not public.connections_enabled() end;
  if not allowed then return jsonb_build_object('allowed', false, 'via', case when prop.operation = 'temporal' then 'reserva' else 'solicitud' end); end if;
  select nullif(btrim(contact_whatsapp), '') into ph from public.profiles where id = prop.owner_id and is_active;
  return jsonb_build_object('allowed', true, 'phone', coalesce(ph, nullif(btrim(prop.whatsapp), '')));
end $$;

create or replace function public.public_agent_contact(p_agent uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare ph text;
begin
  perform public._throttle('public_contact', 40, 60);
  if public.connections_enabled() then return jsonb_build_object('allowed', false, 'via', 'solicitud'); end if;
  select nullif(btrim(contact_whatsapp), '') into ph from public.profiles p
   where p.id = p_agent and p.is_active and exists (select 1 from public.properties x where x.owner_id = p.id and x.status = 'available');
  return jsonb_build_object('allowed', ph is not null, 'phone', ph);
end $$;

revoke all on function public.my_property_contacts(), public.public_property_contact(uuid), public.public_agent_contact(uuid) from public, anon;
grant execute on function public.my_property_contacts() to authenticated;
grant execute on function public.public_property_contact(uuid), public.public_agent_contact(uuid) to anon, authenticated;

-- 4) Fotos de propiedades y avatares: solo su dueño (o un administrador)
create or replace function public.storage_property_folder_ok(p_folder text)
returns boolean language sql security definer set search_path = public stable as $$
  -- carpeta = id de la propiedad. Si la propiedad aún no existe (las fotos se suben antes de guardarla), se permite; si existe, solo su dueño o un admin
  select auth.uid() is not null and public.is_active_user() and (
    public.is_admin()
    or not exists (select 1 from public.properties where id::text = p_folder)
    or exists (select 1 from public.properties where id::text = p_folder and owner_id = auth.uid()));
$$;
revoke all on function public.storage_property_folder_ok(text) from public, anon;
grant execute on function public.storage_property_folder_ok(text) to authenticated;

drop policy if exists "authenticated can upload property photos" on storage.objects;
create policy "authenticated can upload property photos" on storage.objects for insert to authenticated
  with check (bucket_id = 'property-photos' and public.storage_property_folder_ok((storage.foldername(name))[1]));
drop policy if exists "authenticated can update property photos" on storage.objects;
create policy "authenticated can update property photos" on storage.objects for update to authenticated
  using (bucket_id = 'property-photos' and public.storage_property_folder_ok((storage.foldername(name))[1]));
drop policy if exists "authenticated can delete property photos" on storage.objects;
create policy "authenticated can delete property photos" on storage.objects for delete to authenticated
  using (bucket_id = 'property-photos' and public.storage_property_folder_ok((storage.foldername(name))[1]));

drop policy if exists "users can upload own avatar" on storage.objects;
create policy "users can upload own avatar" on storage.objects for insert to authenticated
  with check (bucket_id = 'agent-avatars' and public.is_active_user() and ((storage.foldername(name))[1] = auth.uid()::text or public.is_admin()));
drop policy if exists "users can update own avatar" on storage.objects;
create policy "users can update own avatar" on storage.objects for update to authenticated
  using (bucket_id = 'agent-avatars' and public.is_active_user() and ((storage.foldername(name))[1] = auth.uid()::text or public.is_admin()));
drop policy if exists "users can delete own avatar" on storage.objects;
create policy "users can delete own avatar" on storage.objects for delete to authenticated
  using (bucket_id = 'agent-avatars' and public.is_active_user() and ((storage.foldername(name))[1] = auth.uid()::text or public.is_admin()));

-- 5) Permisos mínimos
revoke insert, update, delete, truncate, references, trigger on all tables in schema public from anon;
grant insert on public.property_events to anon;                         -- analítica de vistas y clics
revoke truncate, references, trigger on all tables in schema public from authenticated;
alter default privileges in schema public revoke insert, update, delete, truncate, references, trigger on tables from anon;
revoke select on public.subscription_plans from anon;                    -- el modelo de planes está retirado
do $$
begin
  begin execute 'revoke execute on function public.handle_new_user() from public, anon, authenticated'; exception when undefined_function then null; end;
  begin execute 'revoke execute on function public.process_auto_renewals() from public, anon, authenticated'; exception when undefined_function then null; end;
end $$;

notify pgrst, 'reload schema';

-- =====================================================================
-- Bastet · Comisiones y cierre de operaciones (fase 3)   — correr DESPUÉS de connections.sql (y security-hardening.sql)
-- Idempotente: se puede correr completo más de una vez. Implementa docs/ESPECIFICACION_MAESTRA.md, secciones 1.3, 1.5 y 9.3.
--
-- Qué hace: cuando el titular quiere marcar como vendida, alquilada o anticretada (o retirar) una propiedad CON conexiones de Bastet
-- (aceptadas, en pago o verificadas), ya no puede hacerlo a mano: pasa por «Cerrar operación».
--   · Si lo vendió/alquiló a la persona de una conexión verificada, esa persona confirma por un enlace → se registra la operación, se calcula la
--     comisión (venta 0,75 % del precio; alquiler un mes de canon; anticrético 2 % del monto entregado), en Bs con el tipo de cambio INTERNO
--     de Bastet, congelada; la propiedad se cierra y el titular paga la comisión con comprobante (verifica un admin).
--   · Si lo vendió a otra persona (o el interesado no confirma), NO hay atribución automática: la operación queda «en revisión», la propiedad
--     sigue activa y administración analiza el caso y decide.
--   · Si desiste y quiere retirarla, acepta una declaración jurada digital de desistimiento (el TEXTO lo define la dueña con su abogado; sin texto no
--     se puede retirar una propiedad con conexiones).
-- Solo rige con connection_settings.enabled = true. Sin conexiones el titular marca vendida/retira como siempre.
-- =====================================================================

do $$
begin
  if to_regclass('public.connections') is null then raise exception 'Primero corre supabase/connections.sql'; end if;
  if to_regprocedure('public._throttle(text, integer, integer)') is null then raise exception 'Primero corre supabase/security-hardening.sql'; end if;
end $$;

-- 1) Ajustes (los porcentajes son los de la especificación; se editan solo por SQL)
alter table public.connection_settings add column if not exists sale_percent        numeric(6,3) not null default 0.75 check (sale_percent between 0 and 20);
alter table public.connection_settings add column if not exists anticretico_percent numeric(6,3) not null default 2    check (anticretico_percent between 0 and 20);
alter table public.connection_settings add column if not exists rent_months         numeric(4,2) not null default 1    check (rent_months between 0 and 12);
alter table public.connection_settings add column if not exists desist_version      integer not null default 1;
alter table public.connection_settings add column if not exists desist_text         text not null default '' check (char_length(desist_text) <= 20000);

-- Nuevo estado de propiedad: retirada (desistimiento)
alter table public.properties drop constraint if exists properties_status_check;
alter table public.properties add constraint properties_status_check check (status in ('available', 'sold', 'withdrawn'));

-- 2) Operaciones
create table if not exists public.operation_counters (year integer primary key, last_number integer not null);
alter table public.operation_counters enable row level security;
revoke all on public.operation_counters from anon, authenticated;

create table if not exists public.operations (
  id                    uuid primary key default gen_random_uuid(),
  code                  text not null unique,
  number                text unique,                       -- BST-OP-AAAA-NNNN (al confirmarse)
  cert_code             text unique,                       -- código del certificado público (OP-XXXXXXXX), se consulta en «Verificar»
  property_id           uuid references public.properties(id) on delete set null,
  titular_id            uuid references auth.users(id) on delete set null,
  connection_id         uuid references public.connections(id) on delete set null,
  kind                  text not null check (kind in ('venta', 'alquiler', 'anticretico', 'desistimiento')),
  status                text not null check (status in ('pendiente_interesado', 'en_revision', 'confirmada', 'rechazada', 'desistida', 'cancelada')),
  counterparty_name     text check (counterparty_name is null or char_length(counterparty_name) <= 120),
  to_interested         boolean,                           -- el titular dice que fue a la persona de la conexión
  amount                numeric(16,2),                     -- precio total / canon mensual / monto entregado
  currency              text check (currency in ('USD', 'BOB')),
  signed_date           date,
  interested_token      text unique,
  interested_confirmed  boolean,
  interested_at         timestamptz,
  commission_percent    numeric(6,3),
  commission_amount     numeric(16,2),                     -- en la moneda de la operación
  bob_per_usd_used      numeric(8,4),
  commission_bs         numeric(16,2),                     -- congelada, en bolivianos
  commission_status     text not null default 'no_aplica' check (commission_status in ('no_aplica', 'exigible', 'comprobante_enviado', 'pagada')),
  proof_path            text check (proof_path is null or char_length(proof_path) <= 300),
  proof_at              timestamptz,
  paid_at               timestamptz,
  review_note           text check (review_note is null or char_length(review_note) <= 500),
  declaration_version   integer,                           -- desistimiento
  declaration_text      text,
  declaration_at        timestamptz,
  reason                text check (reason is null or char_length(reason) <= 500),
  admin_note            text check (admin_note is null or char_length(admin_note) <= 800),
  resolved_by           uuid references auth.users(id) on delete set null,
  resolved_at           timestamptz,
  property_snapshot     jsonb,
  created_at            timestamptz not null default now()
);
alter table public.operations add column if not exists cert_code text unique;
create index if not exists operations_titular_idx on public.operations (titular_id, created_at desc);
create index if not exists operations_property_idx on public.operations (property_id, status);
alter table public.operations enable row level security;
revoke all on public.operations from anon, authenticated;

create table if not exists public.operation_events (
  id           bigint generated always as identity primary key,
  operation_id uuid not null references public.operations(id) on delete cascade,
  actor        text not null,
  actor_id     uuid,
  event        text not null,
  from_status  text,
  to_status    text,
  data         jsonb,
  created_at   timestamptz not null default now()
);
create index if not exists operation_events_idx on public.operation_events (operation_id, created_at);
alter table public.operation_events enable row level security;
revoke all on public.operation_events from anon, authenticated;

create or replace function public._op_log(p_op uuid, p_actor text, p_event text, p_from text, p_to text, p_data jsonb default null)
returns void language sql security definer set search_path = public as $$
  insert into public.operation_events (operation_id, actor, actor_id, event, from_status, to_status, data) values (p_op, p_actor, auth.uid(), p_event, p_from, p_to, p_data);
$$;
revoke all on function public._op_log(uuid, text, text, text, text, jsonb) from public, anon, authenticated;

-- 3) Una propiedad con conexiones de Bastet no se marca vendida ni se retira ni se borra a mano (solo por «Cerrar operación»)
create or replace function public.protect_closed_properties()
returns trigger language plpgsql security definer set search_path = public as $$
declare pid uuid; bad boolean := false;
begin
  if auth.uid() is null or public.is_admin() or coalesce(current_setting('uno.closure_rpc', true), '') = '1' or not public.connections_enabled() then
    if TG_OP = 'DELETE' then return old; else return new; end if;
  end if;
  if TG_OP = 'UPDATE' then
    bad := old.status = 'available' and new.status is distinct from 'available';
    pid := old.id;
  else
    bad := true; pid := old.id;
  end if;
  if bad and exists (select 1 from public.connections c where c.property_id = pid and c.status in ('aceptada_pendiente_pago', 'comprobante_enviado', 'conexion_generada')) then
    raise exception 'Esta propiedad tiene conexiones de Bastet. Para marcarla como vendida o alquilada, o para retirarla, usa «Cerrar operación».' using errcode = 'P0403', hint = 'closure';
  end if;
  if TG_OP = 'DELETE' then return old; else return new; end if;
end $$;
drop trigger if exists protect_closed_status on public.properties;
create trigger protect_closed_status before update of status on public.properties for each row execute function public.protect_closed_properties();
drop trigger if exists protect_closed_delete on public.properties;
create trigger protect_closed_delete before delete on public.properties for each row execute function public.protect_closed_properties();

-- 4) Comisión de una operación (siempre en Bs, con el tipo de cambio INTERNO)
create or replace function public._op_commission(p_kind text, p_amount numeric, p_currency text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare s public.connection_settings; rate numeric; pct numeric; cur numeric;
begin
  select * into s from public.connection_settings where id = 1;
  select bob_per_usd into rate from public.stay_settings where id = 1; rate := coalesce(rate, 6.96);
  if p_kind = 'venta' then pct := s.sale_percent; cur := round(p_amount * pct / 100, 2);
  elsif p_kind = 'anticretico' then pct := s.anticretico_percent; cur := round(p_amount * pct / 100, 2);
  elsif p_kind = 'alquiler' then pct := null; cur := round(p_amount * s.rent_months, 2);
  else raise exception 'Operación inválida'; end if;
  return jsonb_build_object('percent', pct, 'amount', cur, 'rate', rate, 'bs', round(case when p_currency = 'BOB' then cur else cur * rate end, 2));
end $$;
revoke all on function public._op_commission(text, numeric, text) from public, anon, authenticated;

-- Confirma una operación: comisión congelada, constancia numerada, propiedad cerrada
create or replace function public._confirm_operation(p_id uuid, p_with_commission boolean default true)
returns void language plpgsql security definer set search_path = public as $$
declare o public.operations; cm jsonb; yr integer; seq integer; snap jsonb; cert text; alpha constant text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
begin
  select * into o from public.operations where id = p_id for update;
  loop
    select 'OP-' || string_agg(substr(alpha, 1 + floor(random() * 32)::integer, 1), '') into cert from generate_series(1, 8);
    exit when not exists (select 1 from public.operations where cert_code = cert);
  end loop;
  yr := extract(year from ((now() at time zone 'UTC') - interval '4 hours'))::integer;
  insert into public.operation_counters (year, last_number) values (yr, 1)
  on conflict (year) do update set last_number = public.operation_counters.last_number + 1 returning last_number into seq;
  select jsonb_build_object('title', p.title, 'code_number', p.code_number, 'location', p.location, 'address', p.address, 'price', p.price, 'currency', p.currency, 'operation', p.operation)
    into snap from public.properties p where p.id = o.property_id;
  if p_with_commission then
    cm := public._op_commission(o.kind, o.amount, o.currency);
    update public.operations set commission_percent = (cm ->> 'percent')::numeric, commission_amount = (cm ->> 'amount')::numeric, bob_per_usd_used = (cm ->> 'rate')::numeric,
           commission_bs = (cm ->> 'bs')::numeric, commission_status = 'exigible' where id = o.id;
  end if;
  update public.operations set status = 'confirmada', number = 'BST-OP-' || yr || '-' || lpad(seq::text, 4, '0'), cert_code = cert, property_snapshot = snap, resolved_at = coalesce(resolved_at, now()) where id = o.id;
  perform set_config('uno.closure_rpc', '1', true);
  update public.properties set status = 'sold' where id = o.property_id;
  perform public._op_log(o.id, 'system', 'confirmada', o.status, 'confirmada', jsonb_build_object('commission', cm, 'with_commission', p_with_commission));
end $$;
revoke all on function public._confirm_operation(uuid, boolean) from public, anon, authenticated;

-- 5) Estado del cierre para el panel
create or replace function public.closure_state(p_property uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); prop record; s public.connection_settings;
begin
  if uid is null or not public.is_active_user() then raise exception 'No autorizado' using errcode = '42501'; end if;
  select id, owner_id, status, coalesce(operation, 'venta') as operation, title into prop from public.properties where id = p_property;
  if not found or (prop.owner_id is distinct from uid and not public.is_admin()) then raise exception 'Propiedad no encontrada'; end if;
  select * into s from public.connection_settings where id = 1;
  return jsonb_build_object('enabled', s.enabled, 'operation', prop.operation, 'status', prop.status, 'title', prop.title,
    'protected', s.enabled and exists (select 1 from public.connections c where c.property_id = p_property and c.status in ('aceptada_pendiente_pago', 'comprobante_enviado', 'conexion_generada')),
    'desist_ready', char_length(btrim(s.desist_text)) > 0, 'desist_version', s.desist_version, 'desist_text', case when char_length(btrim(s.desist_text)) > 0 then s.desist_text end,
    'connections', coalesce((select jsonb_agg(jsonb_build_object('id', c.id, 'code', c.code, 'number', c.number, 'status', c.status,
        'name', split_part(btrim(c.interested_name), ' ', 1) || coalesce(' ' || upper(left(nullif(split_part(btrim(c.interested_name), ' ', 2), ''), 1)) || '.', '')) order by c.created_at)
        from public.connections c where c.property_id = p_property and c.status = 'conexion_generada'), '[]'::jsonb),
    'open_operation', (select to_jsonb(x) from (select id, code, kind, status, created_at from public.operations where property_id = p_property and status in ('pendiente_interesado', 'en_revision') order by created_at desc limit 1) x));
end $$;

-- 6) El titular inicia el cierre (venta, alquiler o anticrético)
create or replace function public.start_property_closure(p_property uuid, p_kind text, p_connection uuid, p_buyer text, p_amount numeric, p_currency text, p_signed date)
returns jsonb language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); prop record; conn public.connections; st text; tok text; cd text; oid uuid; tries int := 0; bn text := btrim(coalesce(p_buyer, ''));
begin
  if uid is null or not public.is_active_user() then raise exception 'No autorizado' using errcode = '42501'; end if;
  if not public.connections_enabled() then raise exception 'El cierre de operaciones todavía no está activo'; end if;
  select id, owner_id, status, coalesce(operation, 'venta') as operation into prop from public.properties where id = p_property for update;
  if not found or prop.owner_id is distinct from uid then raise exception 'Propiedad no encontrada'; end if;
  if prop.status <> 'available' then raise exception 'La propiedad ya no está disponible'; end if;
  if p_kind not in ('venta', 'alquiler', 'anticretico') or p_kind <> prop.operation then raise exception 'El tipo de operación no coincide con la propiedad (%)', prop.operation; end if;
  if p_amount is null or p_amount <= 0 or p_amount > 100000000 then raise exception 'Indica el monto de la operación'; end if;
  if p_currency not in ('USD', 'BOB') then raise exception 'Elige la moneda'; end if;
  if p_signed is null or p_signed > public.bo_today() or p_signed < public.bo_today() - 90 then raise exception 'La fecha de firma debe ser de los últimos 90 días'; end if;
  if char_length(bn) not between 2 and 120 then raise exception 'Escribe el nombre de la persona a quien se vendió o alquiló'; end if;
  if exists (select 1 from public.operations where property_id = p_property and status in ('pendiente_interesado', 'en_revision')) then raise exception 'Ya hay una confirmación en curso para esta propiedad'; end if;
  if p_connection is not null then
    select * into conn from public.connections where id = p_connection and property_id = p_property and titular_id = uid and status = 'conexion_generada';
    if not found then raise exception 'La conexión elegida no corresponde a esta propiedad o aún no está verificada'; end if;
  end if;
  st := case when p_connection is not null then 'pendiente_interesado' else 'en_revision' end;
  tok := case when p_connection is not null then lower(replace(gen_random_uuid()::text, '-', '')) end;
  loop
    cd := upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 10));
    begin
      insert into public.operations (code, property_id, titular_id, connection_id, kind, status, counterparty_name, to_interested, amount, currency, signed_date, interested_token)
      values (cd, p_property, uid, p_connection, p_kind, st, bn, p_connection is not null, p_amount, p_currency, p_signed, tok) returning id into oid;
      exit;
    exception when unique_violation then tries := tries + 1; if tries > 5 then raise; end if;
    end;
  end loop;
  perform public._op_log(oid, 'titular', 'cierre_iniciado', null, st, jsonb_build_object('kind', p_kind, 'amount', p_amount, 'currency', p_currency, 'to_interested', p_connection is not null));
  return jsonb_build_object('id', oid, 'code', cd, 'status', st, 'token', tok);
end $$;

create or replace function public.cancel_property_closure(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare o public.operations;
begin
  if auth.uid() is null or not public.is_active_user() then raise exception 'No autorizado' using errcode = '42501'; end if;
  select * into o from public.operations where id = p_id and titular_id = auth.uid() and status in ('pendiente_interesado', 'en_revision') for update;
  if not found then raise exception 'Confirmación no encontrada o ya resuelta'; end if;
  update public.operations set status = 'cancelada' where id = o.id;
  perform public._op_log(o.id, 'titular', 'cierre_cancelado', o.status, 'cancelada');
end $$;

-- 7) La persona de la conexión confirma (o niega) por su enlace, sin cuenta
create or replace function public.get_operation_confirmation(p_token text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare o public.operations; p record;
begin
  perform public._throttle('operation_confirm', 30, 60);
  select * into o from public.operations where interested_token = lower(btrim(coalesce(p_token, '')));
  if not found then return jsonb_build_object('valid', false); end if;
  select title, location into p from public.properties where id = o.property_id;
  return jsonb_build_object('valid', o.status = 'pendiente_interesado', 'answered', o.status <> 'pendiente_interesado', 'kind', o.kind, 'title', coalesce(p.title, (o.property_snapshot ->> 'title')),
    'location', p.location, 'amount', o.amount, 'currency', o.currency, 'signed_date', o.signed_date);
end $$;

create or replace function public.respond_operation_confirmation(p_token text, p_confirm boolean)
returns jsonb language plpgsql security definer set search_path = public as $$
declare o public.operations;
begin
  perform public._throttle('operation_confirm', 30, 60);
  select * into o from public.operations where interested_token = lower(btrim(coalesce(p_token, ''))) for update;
  if not found then raise exception 'Este enlace no es válido'; end if;
  if o.status <> 'pendiente_interesado' then raise exception 'Esta operación ya fue respondida'; end if;
  update public.operations set interested_confirmed = coalesce(p_confirm, false), interested_at = now() where id = o.id;
  if p_confirm is true then
    perform public._confirm_operation(o.id);
    perform public._op_log(o.id, 'interested', 'interesado_confirma', o.status, 'confirmada');
    return jsonb_build_object('status', 'confirmada');
  end if;
  update public.operations set status = 'en_revision' where id = o.id;
  perform public._op_log(o.id, 'interested', 'interesado_niega', o.status, 'en_revision');
  return jsonb_build_object('status', 'en_revision');
end $$;

-- 8) Administración resuelve los casos en revisión (sin atribución automática)
create or replace function public.admin_resolve_operation(p_id uuid, p_decision text, p_note text)
returns void language plpgsql security definer set search_path = public as $$
declare o public.operations; nt text := nullif(btrim(coalesce(p_note, '')), '');
begin
  if not public.is_admin() then raise exception 'Solo administradores' using errcode = '42501'; end if;
  if nt is null then raise exception 'Escribe el motivo de la decisión (queda en el historial)'; end if;
  select * into o from public.operations where id = p_id and status in ('en_revision', 'pendiente_interesado') for update;
  if not found then raise exception 'Operación no encontrada o ya resuelta'; end if;
  update public.operations set admin_note = nt, resolved_by = auth.uid(), resolved_at = now() where id = o.id;
  if p_decision = 'confirmar' then perform public._confirm_operation(o.id, true);
  elsif p_decision = 'sin_comision' then perform public._confirm_operation(o.id, false);
  elsif p_decision = 'rechazar' then
    update public.operations set status = 'rechazada' where id = o.id;
    perform public._op_log(o.id, 'admin', 'rechazada', o.status, 'rechazada', jsonb_build_object('note', nt));
    return;
  else raise exception 'Decisión inválida'; end if;
  perform public._op_log(o.id, 'admin', 'resuelta_' || p_decision, o.status, 'confirmada', jsonb_build_object('note', nt));
end $$;

-- 9) Pago de la comisión (mismo circuito que la tarifa de conexión)
create or replace function public.attach_operation_proof(p_id uuid, p_path text)
returns void language plpgsql security definer set search_path = public as $$
declare o public.operations; uid uuid := auth.uid();
begin
  if uid is null or not public.is_active_user() then raise exception 'No autorizado' using errcode = '42501'; end if;
  if p_path is null or char_length(p_path) > 300 or p_path not like uid::text || '/%' or p_path like '%..%' then raise exception 'Comprobante inválido'; end if;
  select * into o from public.operations where id = p_id and titular_id = uid for update;
  if not found or o.commission_status not in ('exigible', 'comprobante_enviado') then raise exception 'Esta operación no espera un comprobante'; end if;
  update public.operations set proof_path = p_path, proof_at = now(), commission_status = 'comprobante_enviado', review_note = null where id = o.id;
  perform public._op_log(o.id, 'titular', 'comprobante_enviado', o.commission_status, 'comprobante_enviado', jsonb_build_object('path', p_path));
end $$;

create or replace function public.admin_review_operation_proof(p_id uuid, p_approve boolean, p_note text default null)
returns void language plpgsql security definer set search_path = public as $$
declare o public.operations; nt text := nullif(btrim(coalesce(p_note, '')), '');
begin
  if not public.is_admin() then raise exception 'Solo administradores' using errcode = '42501'; end if;
  select * into o from public.operations where id = p_id and commission_status = 'comprobante_enviado' for update;
  if not found then raise exception 'No hay un comprobante por revisar en esta operación'; end if;
  if p_approve then
    update public.operations set commission_status = 'pagada', paid_at = now(), review_note = nt where id = o.id;
    perform public._op_log(o.id, 'admin', 'comision_pagada', 'comprobante_enviado', 'pagada', jsonb_build_object('bs', o.commission_bs, 'note', nt));
  else
    if nt is null then raise exception 'Escribe el motivo del rechazo para que el titular pueda corregirlo'; end if;
    update public.operations set commission_status = 'exigible', proof_path = null, proof_at = null, review_note = nt where id = o.id;
    perform public._op_log(o.id, 'admin', 'comprobante_rechazado', 'comprobante_enviado', 'exigible', jsonb_build_object('note', nt, 'path', o.proof_path));
  end if;
end $$;

-- 10) Desistimiento: declaración jurada digital para retirar una propiedad con conexiones
create or replace function public.desist_property(p_property uuid, p_accept boolean, p_reason text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); prop record; s public.connection_settings; oid uuid; cd text; rs text := nullif(btrim(coalesce(p_reason, '')), ''); tries int := 0;
begin
  if uid is null or not public.is_active_user() then raise exception 'No autorizado' using errcode = '42501'; end if;
  select * into s from public.connection_settings where id = 1;
  if not s.enabled then raise exception 'El cierre de operaciones todavía no está activo'; end if;
  if char_length(btrim(s.desist_text)) = 0 then raise exception 'La declaración jurada de desistimiento todavía no está disponible. Escribe a Bastet para retirar esta propiedad.'; end if;
  select id, owner_id, status, coalesce(operation, 'venta') as operation into prop from public.properties where id = p_property for update;
  if not found or prop.owner_id is distinct from uid then raise exception 'Propiedad no encontrada'; end if;
  if prop.status <> 'available' then raise exception 'La propiedad ya no está disponible'; end if;
  if p_accept is not true then raise exception 'Debes aceptar la declaración jurada para retirar la propiedad'; end if;
  if rs is null then raise exception 'Cuéntanos brevemente el motivo del retiro'; end if;
  if exists (select 1 from public.operations where property_id = p_property and status in ('pendiente_interesado', 'en_revision')) then raise exception 'Hay una confirmación en curso para esta propiedad'; end if;
  loop
    cd := upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 10));
    begin
      insert into public.operations (code, property_id, titular_id, kind, status, reason, declaration_version, declaration_text, declaration_at, property_snapshot, resolved_at)
      select cd, p_property, uid, 'desistimiento', 'desistida', rs, s.desist_version, s.desist_text, now(),
             jsonb_build_object('title', p.title, 'code_number', p.code_number, 'location', p.location, 'operation', p.operation), now() from public.properties p where p.id = p_property returning id into oid;
      exit;
    exception when unique_violation then tries := tries + 1; if tries > 5 then raise; end if;
    end;
  end loop;
  perform set_config('uno.closure_rpc', '1', true);
  update public.properties set status = 'withdrawn' where id = p_property;
  perform public._op_log(oid, 'titular', 'desistimiento', null, 'desistida', jsonb_build_object('version', s.desist_version, 'reason', rs));
  return jsonb_build_object('id', oid, 'code', cd);
end $$;

-- 11) Listas
create or replace function public.my_operations()
returns jsonb language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); adm boolean; s public.connection_settings;
begin
  if uid is null or not public.is_active_user() then raise exception 'No autorizado' using errcode = '42501'; end if;
  adm := public.is_admin();
  select * into s from public.connection_settings where id = 1;
  return jsonb_build_object('enabled', s.enabled, 'pay_instructions', s.pay_instructions, 'pay_qr_url', s.pay_qr_url,
    'desist_text', case when adm then s.desist_text end, 'desist_version', s.desist_version,
    'items', coalesce((select jsonb_agg(jsonb_build_object(
        'id', o.id, 'code', o.code, 'number', o.number, 'cert_code', o.cert_code, 'kind', o.kind, 'status', o.status, 'property_id', o.property_id,
        'title', coalesce(p.title, o.property_snapshot ->> 'title'), 'counterparty_name', o.counterparty_name, 'to_interested', o.to_interested,
        'amount', o.amount, 'currency', o.currency, 'signed_date', o.signed_date, 'interested_token', case when o.status = 'pendiente_interesado' then o.interested_token end,
        'interested_confirmed', o.interested_confirmed, 'commission_percent', o.commission_percent, 'commission_amount', o.commission_amount,
        'commission_bs', o.commission_bs, 'commission_status', o.commission_status, 'proof_at', o.proof_at, 'paid_at', o.paid_at, 'review_note', o.review_note,
        'proof_path', case when adm then o.proof_path end, 'reason', o.reason, 'admin_note', o.admin_note, 'created_at', o.created_at, 'declaration_version', o.declaration_version,
        'titular_name', case when adm then (select display_name from public.profiles where id = o.titular_id) end,
        'connection_number', (select number from public.connections where id = o.connection_id),
        'interested_phone', (select c.interested_phone from public.connections c where c.id = o.connection_id and c.status = 'conexion_generada' and (adm or c.titular_id = uid))) order by o.created_at desc)
      from public.operations o left join public.properties p on p.id = o.property_id
      where (adm or o.titular_id = uid) and o.created_at > now() - interval '36 months'), '[]'::jsonb));
end $$;

create or replace function public.operation_events(p_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Solo administradores' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('actor', e.actor, 'event', e.event, 'from', e.from_status, 'to', e.to_status, 'data', e.data, 'at', e.created_at) order by e.created_at, e.id)
                     from public.operation_events e where e.operation_id = p_id), '[]'::jsonb);
end $$;

create or replace function public.admin_update_desist_text(p_text text)
returns void language plpgsql security definer set search_path = public as $$
declare cur public.connection_settings; tx text := btrim(coalesce(p_text, ''));
begin
  if not public.is_admin() then raise exception 'Solo administradores' using errcode = '42501'; end if;
  select * into cur from public.connection_settings where id = 1;
  update public.connection_settings set desist_text = tx, desist_version = case when tx is distinct from cur.desist_text then cur.desist_version + 1 else cur.desist_version end, updated_at = now() where id = 1;
end $$;

-- 12) Permisos
revoke all on function public.protect_closed_properties(), public.closure_state(uuid), public.start_property_closure(uuid, text, uuid, text, numeric, text, date),
  public.cancel_property_closure(uuid), public.get_operation_confirmation(text), public.respond_operation_confirmation(text, boolean),
  public.admin_resolve_operation(uuid, text, text), public.attach_operation_proof(uuid, text), public.admin_review_operation_proof(uuid, boolean, text),
  public.desist_property(uuid, boolean, text), public.my_operations(), public.operation_events(uuid), public.admin_update_desist_text(text) from public, anon;
grant execute on function public.get_operation_confirmation(text), public.respond_operation_confirmation(text, boolean) to anon, authenticated;
grant execute on function public.closure_state(uuid), public.start_property_closure(uuid, text, uuid, text, numeric, text, date), public.cancel_property_closure(uuid),
  public.admin_resolve_operation(uuid, text, text), public.attach_operation_proof(uuid, text), public.admin_review_operation_proof(uuid, boolean, text),
  public.desist_property(uuid, boolean, text), public.my_operations(), public.operation_events(uuid), public.admin_update_desist_text(text) to authenticated;

notify pgrst, 'reload schema';

-- =====================================================================
-- Bastet · Verificación, reputación, actas y certificado público (fase 4)   — correr DESPUÉS de operations.sql
-- Idempotente: se puede correr completo más de una vez. Implementa docs/ESPECIFICACION_MAESTRA.md, secciones 5, 7 y 9.5.
--
--  · TRES DISTINTIVOS INDEPENDIENTES (no equivalen a reputación):
--      Agente verificado por Bastet  = identidad, teléfono, documentación profesional y contrato directo con Bastet, revisados.
--      Propietario verificado        = identidad y documentación revisadas.
--      Propiedad verificada          = identidad del propietario, documentación legal y existencia física revisadas.
--    Solo un administrador los concede, tras una solicitud con documentos y una lista de comprobaciones COMPLETA; todo queda en un historial.
--    Si la dirección o el dueño de una propiedad verificada cambian, la verificación se pierde.
--  · «Propiedad pendiente de verificación»: con connection_settings.require_property_verification = true, una propiedad sin verificar se puede publicar
--    pero NO recibe solicitudes de contacto (conexiones) hasta verificarse.
--  · RESEÑAS de agentes y propietarios: solo la persona de una operación concretada mediante una conexión de Bastet (la que confirmó la operación)
--    puede reseñar, una vez, con estrellas y comentario; la reseña queda ligada a esa operación.
--  · CERTIFICADO PÚBLICO de cada operación confirmada (código OP-XXXXXXXX) y acta digital (para el titular y administración); consulta pública de
--    propiedades (BST-####) y agentes (AG-XXXXXX) en «Verificar». El certificado NO expone nombres, montos ni datos del contrato.
-- La FIRMA y la validez probatoria del acta, y los datos que puede divulgar el certificado, requieren revisión jurídica en Bolivia.
-- =====================================================================

do $$
begin
  if to_regclass('public.operations') is null then raise exception 'Primero corre supabase/operations.sql'; end if;
end $$;

-- 1) Marcas públicas y ajustes
alter table public.connection_settings add column if not exists require_property_verification boolean not null default false;
alter table public.properties add column if not exists verified boolean not null default false;
alter table public.profiles add column if not exists agent_verified boolean not null default false;
alter table public.profiles add column if not exists owner_verified boolean not null default false;
alter table public.profiles add column if not exists public_code text;
create unique index if not exists profiles_public_code_idx on public.profiles (public_code) where public_code is not null;

grant select (verified) on public.properties to anon, authenticated;
grant select (agent_verified, owner_verified, public_code) on public.profiles to anon;

create or replace function public.verification_required()
returns boolean language sql security definer set search_path = public stable as $$ select coalesce((select require_property_verification and enabled from public.connection_settings where id = 1), false) $$;
revoke all on function public.verification_required() from public;
grant execute on function public.verification_required() to anon, authenticated;

-- Nadie se concede un distintivo a sí mismo; y una propiedad verificada pierde la verificación si cambian su dirección, su ubicación o su dueño
create or replace function public.protect_property_verified()
returns trigger language plpgsql security definer set search_path = public as $$
declare ok boolean := coalesce(current_setting('uno.verif_rpc', true), '') = '1' or auth.uid() is null or public.is_admin();
begin
  if TG_OP = 'INSERT' then
    if not ok then new.verified := false; end if;
    return new;
  end if;
  if coalesce(current_setting('uno.verif_rpc', true), '') <> '1' then
    if not ok then new.verified := old.verified; end if;
    if old.verified and (new.address is distinct from old.address or new.owner_id is distinct from old.owner_id
                         or new.latitude is distinct from old.latitude or new.longitude is distinct from old.longitude) then
      new.verified := false;
    end if;
  end if;
  return new;
end $$;
drop trigger if exists protect_property_verified on public.properties;
create trigger protect_property_verified before insert or update on public.properties for each row execute function public.protect_property_verified();

create or replace function public.protect_profile_verified()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if not (coalesce(current_setting('uno.verif_rpc', true), '') = '1' or auth.uid() is null or public.is_admin()) then
    new.agent_verified := old.agent_verified; new.owner_verified := old.owner_verified; new.public_code := old.public_code;
  end if;
  return new;
end $$;
drop trigger if exists protect_profile_verified on public.profiles;
create trigger protect_profile_verified before update on public.profiles for each row execute function public.protect_profile_verified();

-- Una propiedad pendiente de verificación no genera conexiones (cuando el ajuste está activo)
create or replace function public.require_verified_for_connection()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if public.verification_required() and not coalesce((select verified from public.properties where id = new.property_id), false) then
    raise exception 'Esta propiedad está pendiente de verificación: todavía no recibe solicitudes de contacto.';
  end if;
  return new;
end $$;
drop trigger if exists require_verified_for_connection on public.connections;
create trigger require_verified_for_connection before insert on public.connections for each row execute function public.require_verified_for_connection();

-- 2) Solicitudes de verificación y su historial
create table if not exists public.verification_requests (
  id          uuid primary key default gen_random_uuid(),
  kind        text not null check (kind in ('agente', 'propietario', 'propiedad')),
  user_id     uuid not null references auth.users(id) on delete cascade,
  property_id uuid references public.properties(id) on delete set null,
  status      text not null default 'borrador' check (status in ('borrador', 'en_revision', 'aprobada', 'rechazada', 'revocada')),
  docs        jsonb not null default '[]'::jsonb,                 -- [{label, path}]
  checks      jsonb not null default '{}'::jsonb,
  note        text check (note is null or char_length(note) <= 500),
  admin_note  text check (admin_note is null or char_length(admin_note) <= 800),
  submitted_at timestamptz,
  decided_by  uuid references auth.users(id) on delete set null,
  decided_at  timestamptz,
  created_at  timestamptz not null default now()
);
create unique index if not exists verification_open_idx on public.verification_requests (user_id, kind, coalesce(property_id, '00000000-0000-0000-0000-000000000000'::uuid)) where status in ('borrador', 'en_revision');
alter table public.verification_requests enable row level security;
revoke all on public.verification_requests from anon, authenticated;

create table if not exists public.verification_events (
  id          bigint generated always as identity primary key,
  request_id  uuid not null references public.verification_requests(id) on delete cascade,
  actor       text not null, actor_id uuid, event text not null, data jsonb,
  created_at  timestamptz not null default now()
);
alter table public.verification_events enable row level security;
revoke all on public.verification_events from anon, authenticated;
create or replace function public._ver_log(p_req uuid, p_actor text, p_event text, p_data jsonb default null)
returns void language sql security definer set search_path = public as $$
  insert into public.verification_events (request_id, actor, actor_id, event, data) values (p_req, p_actor, auth.uid(), p_event, p_data);
$$;
revoke all on function public._ver_log(uuid, text, text, jsonb) from public, anon, authenticated;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('verification-docs', 'verification-docs', false, 8388608, array['application/pdf', 'image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do update set public = false, file_size_limit = 8388608, allowed_mime_types = array['application/pdf', 'image/jpeg', 'image/png', 'image/webp'];
drop policy if exists "owner uploads verification docs" on storage.objects;
create policy "owner uploads verification docs" on storage.objects for insert to authenticated
  with check (bucket_id = 'verification-docs' and (storage.foldername(name))[1] = auth.uid()::text and public.is_active_user());
drop policy if exists "owner reads own verification docs" on storage.objects;
create policy "owner reads own verification docs" on storage.objects for select to authenticated
  using (bucket_id = 'verification-docs' and (storage.foldername(name))[1] = auth.uid()::text);
drop policy if exists "admin reads verification docs" on storage.objects;
create policy "admin reads verification docs" on storage.objects for select to authenticated using (bucket_id = 'verification-docs' and public.is_admin());
drop policy if exists "admin deletes verification docs" on storage.objects;
create policy "admin deletes verification docs" on storage.objects for delete to authenticated using (bucket_id = 'verification-docs' and public.is_admin());

-- Qué se debe comprobar para cada distintivo (sección 5.3)
create or replace function public._ver_required_checks(p_kind text)
returns text[] language sql immutable as $$
  select case p_kind when 'agente' then array['identidad', 'telefono', 'documentacion_profesional', 'contrato_bastet']
                     when 'propietario' then array['identidad', 'documentacion']
                     else array['identidad_propietario', 'documentacion_legal', 'existencia_fisica'] end;
$$;

create or replace function public.request_verification(p_kind text, p_property uuid default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); rid uuid;
begin
  if uid is null or not public.is_active_user() then raise exception 'No autorizado' using errcode = '42501'; end if;
  if p_kind not in ('agente', 'propietario', 'propiedad') then raise exception 'Tipo de verificación inválido'; end if;
  if p_kind = 'propiedad' then
    if p_property is null or not exists (select 1 from public.properties where id = p_property and owner_id = uid) then raise exception 'Elige una de tus propiedades'; end if;
    if exists (select 1 from public.properties where id = p_property and verified) then raise exception 'Esta propiedad ya está verificada'; end if;
  else p_property := null; end if;
  if p_kind = 'agente' and exists (select 1 from public.profiles where id = uid and agent_verified) then raise exception 'Ya eres agente verificado'; end if;
  if p_kind = 'propietario' and exists (select 1 from public.profiles where id = uid and owner_verified) then raise exception 'Ya eres propietario verificado'; end if;
  select id into rid from public.verification_requests where user_id = uid and kind = p_kind and coalesce(property_id, '00000000-0000-0000-0000-000000000000'::uuid) = coalesce(p_property, '00000000-0000-0000-0000-000000000000'::uuid) and status in ('borrador', 'en_revision');
  if rid is not null then return rid; end if;
  insert into public.verification_requests (kind, user_id, property_id) values (p_kind, uid, p_property) returning id into rid;
  perform public._ver_log(rid, 'usuario', 'solicitud_creada', jsonb_build_object('kind', p_kind));
  return rid;
end $$;

create or replace function public.attach_verification_doc(p_id uuid, p_path text, p_label text)
returns void language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); r public.verification_requests; lb text := btrim(coalesce(p_label, ''));
begin
  if uid is null or not public.is_active_user() then raise exception 'No autorizado' using errcode = '42501'; end if;
  if p_path is null or char_length(p_path) > 300 or p_path not like uid::text || '/%' or p_path like '%..%' then raise exception 'Documento inválido'; end if;
  if char_length(lb) not between 2 and 80 then raise exception 'Describe el documento (por ejemplo: «Cédula de identidad, anverso»)'; end if;
  select * into r from public.verification_requests where id = p_id and user_id = uid and status in ('borrador', 'en_revision') for update;
  if not found then raise exception 'Solicitud no encontrada o ya resuelta'; end if;
  if jsonb_array_length(r.docs) >= 12 then raise exception 'Máximo 12 documentos por solicitud'; end if;
  update public.verification_requests set docs = docs || jsonb_build_array(jsonb_build_object('label', lb, 'path', p_path, 'at', now())) where id = r.id;
  perform public._ver_log(r.id, 'usuario', 'documento_agregado', jsonb_build_object('label', lb));
end $$;

create or replace function public.submit_verification(p_id uuid, p_note text default null)
returns void language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); r public.verification_requests;
begin
  if uid is null or not public.is_active_user() then raise exception 'No autorizado' using errcode = '42501'; end if;
  select * into r from public.verification_requests where id = p_id and user_id = uid and status = 'borrador' for update;
  if not found then raise exception 'Solicitud no encontrada o ya enviada'; end if;
  if jsonb_array_length(r.docs) < 1 then raise exception 'Adjunta al menos un documento'; end if;
  update public.verification_requests set status = 'en_revision', submitted_at = now(), note = nullif(btrim(coalesce(p_note, '')), '') where id = r.id;
  perform public._ver_log(r.id, 'usuario', 'enviada_a_revision', null);
end $$;

create or replace function public.my_verifications()
returns jsonb language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); adm boolean;
begin
  if uid is null or not public.is_active_user() then raise exception 'No autorizado' using errcode = '42501'; end if;
  adm := public.is_admin();
  return jsonb_build_object('required', jsonb_build_object('agente', public._ver_required_checks('agente'), 'propietario', public._ver_required_checks('propietario'), 'propiedad', public._ver_required_checks('propiedad')),
    'me', (select jsonb_build_object('agent_verified', agent_verified, 'owner_verified', owner_verified, 'public_code', public_code) from public.profiles where id = uid),
    'items', coalesce((select jsonb_agg(jsonb_build_object('id', v.id, 'kind', v.kind, 'status', v.status, 'property_id', v.property_id,
        'property_title', (select title from public.properties where id = v.property_id), 'docs', v.docs, 'checks', v.checks, 'note', v.note, 'admin_note', v.admin_note,
        'submitted_at', v.submitted_at, 'decided_at', v.decided_at, 'created_at', v.created_at,
        'user_name', case when adm then (select coalesce(nullif(btrim(full_name), ''), display_name, email) from public.profiles where id = v.user_id) end) order by v.created_at desc)
      from public.verification_requests v where adm or v.user_id = uid), '[]'::jsonb));
end $$;

create or replace function public.admin_review_verification(p_id uuid, p_decision text, p_checks jsonb, p_note text)
returns void language plpgsql security definer set search_path = public as $$
declare r public.verification_requests; nt text := nullif(btrim(coalesce(p_note, '')), ''); req text[]; k text; code text; alpha constant text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
begin
  if not public.is_admin() then raise exception 'Solo administradores' using errcode = '42501'; end if;
  select * into r from public.verification_requests where id = p_id and status = 'en_revision' for update;
  if not found then raise exception 'No hay una solicitud en revisión con ese identificador'; end if;
  update public.verification_requests set checks = coalesce(p_checks, '{}'::jsonb) where id = r.id;
  if p_decision = 'aprobar' then
    req := public._ver_required_checks(r.kind);
    foreach k in array req loop
      if coalesce(p_checks ->> k, 'false') <> 'true' then raise exception 'Para aprobar hay que completar TODAS las comprobaciones (falta: %)', k; end if;
    end loop;
    perform set_config('uno.verif_rpc', '1', true);
    if r.kind = 'agente' then
      loop
        code := 'AG-' || (select string_agg(substr(alpha, 1 + floor(random() * 32)::integer, 1), '') from generate_series(1, 6));
        exit when not exists (select 1 from public.profiles where public_code = code);
      end loop;
      update public.profiles set agent_verified = true, public_code = coalesce(public_code, code) where id = r.user_id;
    elsif r.kind = 'propietario' then update public.profiles set owner_verified = true where id = r.user_id;
    else update public.properties set verified = true where id = r.property_id; end if;
    update public.verification_requests set status = 'aprobada', decided_by = auth.uid(), decided_at = now(), admin_note = nt where id = r.id;
    perform public._ver_log(r.id, 'admin', 'aprobada', jsonb_build_object('checks', p_checks, 'note', nt));
  elsif p_decision = 'rechazar' then
    if nt is null then raise exception 'Escribe el motivo del rechazo para que la persona pueda corregirlo'; end if;
    update public.verification_requests set status = 'rechazada', decided_by = auth.uid(), decided_at = now(), admin_note = nt where id = r.id;
    perform public._ver_log(r.id, 'admin', 'rechazada', jsonb_build_object('note', nt));
  else raise exception 'Decisión inválida'; end if;
end $$;

create or replace function public.admin_revoke_verification(p_id uuid, p_note text)
returns void language plpgsql security definer set search_path = public as $$
declare r public.verification_requests; nt text := nullif(btrim(coalesce(p_note, '')), '');
begin
  if not public.is_admin() then raise exception 'Solo administradores' using errcode = '42501'; end if;
  if nt is null then raise exception 'Escribe el motivo de la revocación'; end if;
  select * into r from public.verification_requests where id = p_id and status = 'aprobada' for update;
  if not found then raise exception 'La verificación no está vigente'; end if;
  perform set_config('uno.verif_rpc', '1', true);
  if r.kind = 'agente' then update public.profiles set agent_verified = false where id = r.user_id;
  elsif r.kind = 'propietario' then update public.profiles set owner_verified = false where id = r.user_id;
  else update public.properties set verified = false where id = r.property_id; end if;
  update public.verification_requests set status = 'revocada', admin_note = nt, decided_at = now() where id = r.id;
  perform public._ver_log(r.id, 'admin', 'revocada', jsonb_build_object('note', nt));
end $$;

create or replace function public.verification_events(p_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Solo administradores' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('actor', e.actor, 'event', e.event, 'data', e.data, 'at', e.created_at) order by e.created_at, e.id) from public.verification_events e where e.request_id = p_id), '[]'::jsonb);
end $$;

create or replace function public.admin_set_property_verification_required(p_required boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Solo administradores' using errcode = '42501'; end if;
  update public.connection_settings set require_property_verification = coalesce(p_required, false), updated_at = now() where id = 1;
end $$;

-- 3) Reseñas de agentes y propietarios (solo tras una operación concretada con una conexión de Bastet)
create table if not exists public.profile_reviews (
  id            uuid primary key default gen_random_uuid(),
  operation_id  uuid not null unique references public.operations(id) on delete cascade,
  reviewed_id   uuid not null references auth.users(id) on delete cascade,
  reviewer_name text not null check (char_length(reviewer_name) between 1 and 80),
  rating        smallint not null check (rating between 1 and 5),
  comment       text check (comment is null or char_length(comment) <= 1200),
  reply         text check (reply is null or char_length(reply) <= 800),
  replied_at    timestamptz,
  status        text not null default 'published' check (status in ('published', 'hidden')),
  created_at    timestamptz not null default now()
);
create index if not exists profile_reviews_idx on public.profile_reviews (reviewed_id, status, created_at desc);
alter table public.profile_reviews enable row level security;
revoke all on public.profile_reviews from anon, authenticated;

create or replace function public.get_operation_review(p_token text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare o public.operations;
begin
  perform public._throttle('operation_review', 30, 60);
  select * into o from public.operations where interested_token = lower(btrim(coalesce(p_token, ''))) and status = 'confirmada' and interested_confirmed is true;
  if not found then return jsonb_build_object('can_review', false); end if;
  return jsonb_build_object('can_review', not exists (select 1 from public.profile_reviews where operation_id = o.id), 'already', exists (select 1 from public.profile_reviews where operation_id = o.id),
    'title', o.property_snapshot ->> 'title', 'reviewed', (select split_part(coalesce(nullif(btrim(display_name), ''), 'el agente'), ' ', 1) from public.profiles where id = o.titular_id));
end $$;

create or replace function public.submit_operation_review(p_token text, p_rating integer, p_comment text)
returns void language plpgsql security definer set search_path = public as $$
declare o public.operations; cm text := nullif(btrim(coalesce(p_comment, '')), ''); nm text;
begin
  perform public._throttle('operation_review', 8, 600);
  select * into o from public.operations where interested_token = lower(btrim(coalesce(p_token, ''))) and status = 'confirmada' and interested_confirmed is true for update;
  if not found then raise exception 'Solo puede reseñar quien confirmó una operación concretada con Bastet'; end if;
  if exists (select 1 from public.profile_reviews where operation_id = o.id) then raise exception 'Ya enviaste tu reseña. ¡Gracias!'; end if;
  if p_rating is null or p_rating not between 1 and 5 then raise exception 'Elige de 1 a 5 estrellas'; end if;
  if cm is not null and char_length(cm) > 1200 then raise exception 'La reseña es demasiado larga (máximo 1200 caracteres)'; end if;
  select split_part(btrim(c.interested_name), ' ', 1) || coalesce(' ' || upper(left(nullif(split_part(btrim(c.interested_name), ' ', 2), ''), 1)) || '.', '') into nm from public.connections c where c.id = o.connection_id;
  insert into public.profile_reviews (operation_id, reviewed_id, reviewer_name, rating, comment) values (o.id, o.titular_id, coalesce(nm, 'Cliente verificado'), p_rating, cm);
end $$;

create or replace function public.list_profile_reviews(p_profile uuid, p_limit integer default 20)
returns table (id uuid, reviewer_name text, rating smallint, comment text, reply text, created_at timestamptz)
language plpgsql security definer set search_path = public as $$
begin
  perform public._throttle('profile_reviews', 60, 60);
  return query select r.id, r.reviewer_name, r.rating, r.comment, r.reply, r.created_at from public.profile_reviews r
    where r.reviewed_id = p_profile and r.status = 'published' order by r.created_at desc limit least(greatest(coalesce(p_limit, 20), 1), 50);
end $$;

create or replace function public.profile_reputation(p_ids uuid[])
returns table (profile_id uuid, avg_rating numeric, review_count integer, verified_operations integer, agent_verified boolean, owner_verified boolean)
language plpgsql security definer set search_path = public as $$
begin
  perform public._throttle('profile_reputation', 60, 60);
  if coalesce(array_length(p_ids, 1), 0) > 100 then raise exception 'Demasiados perfiles'; end if;
  return query select p.id,
    (select round(avg(r.rating)::numeric, 2) from public.profile_reviews r where r.reviewed_id = p.id and r.status = 'published'),
    (select count(*)::integer from public.profile_reviews r where r.reviewed_id = p.id and r.status = 'published'),
    (select count(*)::integer from public.operations o where o.titular_id = p.id and o.status = 'confirmada' and o.kind <> 'desistimiento'),
    p.agent_verified, p.owner_verified
   from public.profiles p where p.id = any (coalesce(p_ids, '{}'::uuid[])) and p.is_active;
end $$;

create or replace function public.reply_profile_review(p_id uuid, p_reply text)
returns void language plpgsql security definer set search_path = public as $$
declare rp text := nullif(btrim(coalesce(p_reply, '')), '');
begin
  if auth.uid() is null or not public.is_active_user() then raise exception 'No autorizado' using errcode = '42501'; end if;
  if rp is not null and char_length(rp) > 800 then raise exception 'La respuesta es demasiado larga (máximo 800 caracteres)'; end if;
  update public.profile_reviews set reply = rp, replied_at = case when rp is null then null else now() end where id = p_id and (reviewed_id = auth.uid() or public.is_admin());
  if not found then raise exception 'Reseña no encontrada'; end if;
end $$;

create or replace function public.admin_set_profile_review_status(p_id uuid, p_status text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Solo administradores' using errcode = '42501'; end if;
  if p_status not in ('published', 'hidden') then raise exception 'Estado inválido'; end if;
  update public.profile_reviews set status = p_status where id = p_id;
  if not found then raise exception 'Reseña no encontrada'; end if;
end $$;

create or replace function public.my_profile_reviews()
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null or not public.is_active_user() then raise exception 'No autorizado' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id', r.id, 'reviewer_name', r.reviewer_name, 'rating', r.rating, 'comment', r.comment, 'reply', r.reply, 'status', r.status, 'created_at', r.created_at,
                    'reviewed', case when public.is_admin() then (select display_name from public.profiles where id = r.reviewed_id) end) order by r.created_at desc)
                     from public.profile_reviews r where r.reviewed_id = auth.uid() or public.is_admin()), '[]'::jsonb);
end $$;

-- 4) Consulta pública en «Verificar» (propiedad, agente, certificado de operación). Nunca nombres de particulares, montos ni datos del contrato.
create or replace function public.verify_property_code(p_code text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare n integer; p record;
begin
  perform public._throttle('verify_public', 30, 60);
  n := nullif(regexp_replace(coalesce(p_code, ''), '[^0-9]', '', 'g'), '')::integer;
  select p2.code_number, p2.verified, p2.status, p2.property_type, coalesce(p2.operation, 'venta') as operation, split_part(coalesce(p2.location, ''), ',', 1) as city,
         pr.agent_verified, pr.owner_verified into p
    from public.properties p2 left join public.profiles pr on pr.id = p2.owner_id where p2.code_number = n;
  if not found then return jsonb_build_object('found', false); end if;
  return jsonb_build_object('found', true, 'code', 'BST-' || p.code_number, 'verified', p.verified, 'status', p.status, 'property_type', p.property_type, 'operation', p.operation, 'city', btrim(p.city),
    'agent_verified', p.agent_verified, 'owner_verified', p.owner_verified);
end $$;

create or replace function public.verify_agent_code(p_code text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare p public.profiles; rep record;
begin
  perform public._throttle('verify_public', 30, 60);
  select * into p from public.profiles where public_code = upper(btrim(coalesce(p_code, ''))) and is_active;
  if not found then return jsonb_build_object('found', false); end if;
  select * into rep from public.profile_reputation(array[p.id]);
  return jsonb_build_object('found', true, 'code', p.public_code, 'name', coalesce(nullif(btrim(p.display_name), ''), 'Agente de Bastet'), 'agent_verified', p.agent_verified, 'owner_verified', p.owner_verified,
    'avg_rating', rep.avg_rating, 'review_count', rep.review_count, 'verified_operations', rep.verified_operations);
end $$;

create or replace function public.verify_operation_certificate(p_code text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare o public.operations; pr public.profiles;
begin
  perform public._throttle('verify_public', 30, 60);
  select * into o from public.operations where cert_code = upper(btrim(coalesce(p_code, ''))) and status = 'confirmada';
  if not found then return jsonb_build_object('found', false); end if;
  select * into pr from public.profiles where id = o.titular_id;
  return jsonb_build_object('found', true, 'code', o.cert_code, 'kind', o.kind, 'month', to_char(coalesce(o.signed_date, o.resolved_at::date), 'YYYY-MM'),
    'property_code', 'BST-' || (o.property_snapshot ->> 'code_number'), 'city', btrim(split_part(coalesce(o.property_snapshot ->> 'location', ''), ',', 1)),
    'origin', case when o.connection_id is not null then 'conexion_bastet' else 'revision_administrativa' end, 'agent_verified', pr.agent_verified, 'owner_verified', pr.owner_verified);
end $$;

-- 5) Acta digital de la operación (para el titular y administración): datos de las partes, aceptaciones registradas y numeración
create or replace function public.get_operation_acta(p_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare o public.operations; uid uuid := auth.uid(); c public.connections; pr public.profiles;
begin
  if uid is null or not public.is_active_user() then raise exception 'No autorizado' using errcode = '42501'; end if;
  select * into o from public.operations where id = p_id and status = 'confirmada';
  if not found or (o.titular_id is distinct from uid and not public.is_admin()) then raise exception 'Operación no encontrada'; end if;
  select * into pr from public.profiles where id = o.titular_id;
  select * into c from public.connections where id = o.connection_id;
  return jsonb_build_object('number', o.number, 'cert_code', o.cert_code, 'kind', o.kind, 'signed_date', o.signed_date, 'confirmed_at', o.resolved_at,
    'property', o.property_snapshot, 'amount', o.amount, 'currency', o.currency,
    'titular', jsonb_build_object('name', coalesce(nullif(btrim(pr.full_name), ''), pr.display_name), 'whatsapp', pr.whatsapp, 'agent_verified', pr.agent_verified, 'owner_verified', pr.owner_verified),
    'counterparty', jsonb_build_object('name', o.counterparty_name, 'to_interested', o.to_interested, 'confirmed', o.interested_confirmed, 'confirmed_at', o.interested_at),
    'connection', case when o.connection_id is null then null else jsonb_build_object('number', c.number, 'accepted_at', c.accepted_at, 'verified_at', c.verified_at, 'framework_version', c.framework_version) end,
    'commission', jsonb_build_object('percent', o.commission_percent, 'amount', o.commission_amount, 'bs', o.commission_bs, 'rate', o.bob_per_usd_used, 'status', o.commission_status),
    'admin_note', case when public.is_admin() then o.admin_note end);
end $$;

-- 6) Permisos
revoke all on function public.protect_property_verified(), public.protect_profile_verified(), public.require_verified_for_connection(), public._ver_required_checks(text),
  public.request_verification(text, uuid), public.attach_verification_doc(uuid, text, text), public.submit_verification(uuid, text), public.my_verifications(),
  public.admin_review_verification(uuid, text, jsonb, text), public.admin_revoke_verification(uuid, text), public.verification_events(uuid), public.admin_set_property_verification_required(boolean),
  public.get_operation_review(text), public.submit_operation_review(text, integer, text), public.list_profile_reviews(uuid, integer), public.profile_reputation(uuid[]),
  public.reply_profile_review(uuid, text), public.admin_set_profile_review_status(uuid, text), public.my_profile_reviews(),
  public.verify_property_code(text), public.verify_agent_code(text), public.verify_operation_certificate(text), public.get_operation_acta(uuid) from public, anon;
grant execute on function public.get_operation_review(text), public.submit_operation_review(text, integer, text), public.list_profile_reviews(uuid, integer), public.profile_reputation(uuid[]),
  public.verify_property_code(text), public.verify_agent_code(text), public.verify_operation_certificate(text) to anon, authenticated;
grant execute on function public.request_verification(text, uuid), public.attach_verification_doc(uuid, text, text), public.submit_verification(uuid, text), public.my_verifications(),
  public.admin_review_verification(uuid, text, jsonb, text), public.admin_revoke_verification(uuid, text), public.verification_events(uuid), public.admin_set_property_verification_required(boolean),
  public.reply_profile_review(uuid, text), public.admin_set_profile_review_status(uuid, text), public.my_profile_reviews(), public.get_operation_acta(uuid) to authenticated;

notify pgrst, 'reload schema';

-- =====================================================================
-- Bastet · Investigaciones y sanciones (fase 5)   — correr DESPUÉS de verification.sql
-- Idempotente: se puede correr completo más de una vez. Implementa docs/ESPECIFICACION_MAESTRA.md, secciones 1.6 y 9.4.
--
-- Ocultar una operación originada por una conexión de Bastet es una falta grave. Este módulo da a ADMINISTRACIÓN las herramientas para investigarla
-- con garantías y NO ejecuta nada irreversible por su cuenta:
--   · abrir la investigación (desde una operación, conexión o reserva) y registrar evidencia y notas con su cronología;
--   · SUSPENDER la cuenta mientras dura (reversible) — una cuenta suspendida no recibe nuevas conexiones;
--   · DESCARGOS: se abre un plazo y la persona investigada los presenta por un enlace propio (aunque su cuenta esté suspendida);
--   · REVISIÓN JURÍDICA: se registra quién revisó y su concepto;
--   · RESOLUCIÓN escrita. La penalización (2,25 % del precio de la operación = 3 veces la comisión de venta, en Bs con el tipo de cambio interno,
--     congelada) o la eliminación de la cuenta SOLO se pueden resolver con descargos cumplidos Y revisión jurídica registrada.
--   · La ELIMINACIÓN de la cuenta solo queda AUTORIZADA en el registro: no se ejecuta aquí (se hace a mano en Usuarios), nunca de forma automática.
-- La cláusula penal, el procedimiento y la sanción deben revisarse con un abogado en Bolivia ANTES de aplicarlos a una persona real.
-- =====================================================================

do $$
begin
  if to_regclass('public.operations') is null or to_regprocedure('public._throttle(text, integer, integer)') is null then raise exception 'Primero corre supabase/operations.sql y supabase/security-hardening.sql'; end if;
end $$;

alter table public.connection_settings add column if not exists penalty_percent numeric(6,3) not null default 2.25 check (penalty_percent between 0 and 20);
alter table public.connection_settings add column if not exists descargos_days  integer not null default 5 check (descargos_days between 1 and 30);

create table if not exists public.investigation_counters (year integer primary key, last_number integer not null);
alter table public.investigation_counters enable row level security;
revoke all on public.investigation_counters from anon, authenticated;

create table if not exists public.investigations (
  id               uuid primary key default gen_random_uuid(),
  code             text not null unique,
  kind             text not null check (kind in ('ocultamiento_operacion', 'falta_anfitrion', 'otra')),
  subject_id       uuid references auth.users(id) on delete set null,
  operation_id     uuid references public.operations(id) on delete set null,
  connection_id    uuid references public.connections(id) on delete set null,
  stay_booking_id  uuid references public.stay_bookings(id) on delete set null,
  property_id      uuid references public.properties(id) on delete set null,
  summary          text not null check (char_length(summary) between 10 and 2000),
  status           text not null default 'abierta' check (status in ('abierta', 'descargos', 'revision_juridica', 'resuelta', 'archivada')),
  suspended        boolean not null default false,
  suspended_at     timestamptz,
  suspension_reason text check (suspension_reason is null or char_length(suspension_reason) <= 500),
  descargos_token  text unique,
  descargos_opened_at timestamptz,
  descargos_until  timestamptz,
  basis_amount     numeric(16,2),                         -- precio de la operación sobre el que se calcula la penalización
  basis_currency   text check (basis_currency in ('USD', 'BOB')),
  penalty_percent  numeric(6,3),
  bob_per_usd_used numeric(8,4),
  penalty_bs       numeric(16,2),                         -- congelada, en bolivianos
  penalty_status   text not null default 'no_aplica' check (penalty_status in ('no_aplica', 'propuesta', 'impuesta', 'pagada', 'anulada')),
  legal_reviewer   text check (legal_reviewer is null or char_length(legal_reviewer) <= 120),
  legal_reviewed_at timestamptz,
  legal_concept    text check (legal_concept is null or char_length(legal_concept) <= 4000),
  decision         text check (decision in ('sin_falta', 'amonestacion', 'penalizacion', 'suspension', 'eliminacion_cuenta')),
  decision_note    text check (decision_note is null or char_length(decision_note) <= 4000),
  decided_by       uuid references auth.users(id) on delete set null,
  decided_at       timestamptz,
  deletion_authorized boolean not null default false,
  created_by       uuid references auth.users(id) on delete set null,
  created_at       timestamptz not null default now()
);
create index if not exists investigations_subject_idx on public.investigations (subject_id, status);
alter table public.investigations enable row level security;
revoke all on public.investigations from anon, authenticated;

create table if not exists public.investigation_items (
  id               bigint generated always as identity primary key,
  investigation_id uuid not null references public.investigations(id) on delete cascade,
  author           text not null check (author in ('admin', 'titular')),
  kind             text not null check (kind in ('evidencia', 'descargo', 'nota')),
  body             text not null check (char_length(body) between 1 and 4000),
  file_path        text check (file_path is null or char_length(file_path) <= 300),
  created_at       timestamptz not null default now()
);
create index if not exists investigation_items_idx on public.investigation_items (investigation_id, created_at);
alter table public.investigation_items enable row level security;
revoke all on public.investigation_items from anon, authenticated;

create table if not exists public.investigation_events (
  id               bigint generated always as identity primary key,
  investigation_id uuid not null references public.investigations(id) on delete cascade,
  actor            text not null, actor_id uuid, event text not null, data jsonb,
  created_at       timestamptz not null default now()
);
alter table public.investigation_events enable row level security;
revoke all on public.investigation_events from anon, authenticated;
create or replace function public._inv_log(p_inv uuid, p_actor text, p_event text, p_data jsonb default null)
returns void language sql security definer set search_path = public as $$
  insert into public.investigation_events (investigation_id, actor, actor_id, event, data) values (p_inv, p_actor, auth.uid(), p_event, p_data);
$$;
revoke all on function public._inv_log(uuid, text, text, jsonb) from public, anon, authenticated;

-- Carpeta privada de evidencia: solo administración
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('investigation-docs', 'investigation-docs', false, 10485760, array['application/pdf', 'image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do update set public = false, file_size_limit = 10485760, allowed_mime_types = array['application/pdf', 'image/jpeg', 'image/png', 'image/webp'];
drop policy if exists "admin manages investigation docs" on storage.objects;
create policy "admin manages investigation docs" on storage.objects for all to authenticated
  using (bucket_id = 'investigation-docs' and public.is_admin()) with check (bucket_id = 'investigation-docs' and public.is_admin());

-- Una cuenta suspendida (inactiva) no recibe nuevas conexiones
create or replace function public.block_suspended_owner_connection()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if exists (select 1 from public.profiles p where p.id = new.titular_id and not p.is_active) then
    raise exception 'Esta propiedad no está disponible por ahora.';
  end if;
  return new;
end $$;
drop trigger if exists block_suspended_owner_connection on public.connections;
create trigger block_suspended_owner_connection before insert on public.connections for each row execute function public.block_suspended_owner_connection();

-- 1) Abrir la investigación
create or replace function public.admin_open_investigation(p_kind text, p_subject uuid, p_operation uuid, p_connection uuid, p_booking uuid, p_property uuid, p_summary text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare s public.connection_settings; subj uuid := p_subject; op public.operations; yr integer; seq integer; cd text; iid uuid; rate numeric; pen numeric; sm text := btrim(coalesce(p_summary, ''));
begin
  if not public.is_admin() then raise exception 'Solo administradores' using errcode = '42501'; end if;
  if p_kind not in ('ocultamiento_operacion', 'falta_anfitrion', 'otra') then raise exception 'Tipo de investigación inválido'; end if;
  if char_length(sm) not between 10 and 2000 then raise exception 'Describe los hechos (entre 10 y 2000 caracteres)'; end if;
  select * into s from public.connection_settings where id = 1;
  select bob_per_usd into rate from public.stay_settings where id = 1; rate := coalesce(rate, 6.96);
  if p_operation is not null then
    select * into op from public.operations where id = p_operation;
    if not found then raise exception 'Operación no encontrada'; end if;
    subj := coalesce(subj, op.titular_id);
  end if;
  if subj is null and p_connection is not null then select titular_id into subj from public.connections where id = p_connection; end if;
  if subj is null and p_booking is not null then select host_id into subj from public.stay_bookings where id = p_booking; end if;
  if subj is null then raise exception 'Indica la persona investigada'; end if;
  if exists (select 1 from public.profiles where id = subj and role = 'admin') then raise exception 'No se investiga a una cuenta de administración desde aquí'; end if;
  yr := extract(year from ((now() at time zone 'UTC') - interval '4 hours'))::integer;
  insert into public.investigation_counters (year, last_number) values (yr, 1) on conflict (year) do update set last_number = public.investigation_counters.last_number + 1 returning last_number into seq;
  cd := 'INV-' || yr || '-' || lpad(seq::text, 4, '0');
  insert into public.investigations (code, kind, subject_id, operation_id, connection_id, stay_booking_id, property_id, summary, created_by)
  values (cd, p_kind, subj, p_operation, p_connection, p_booking, coalesce(p_property, op.property_id), sm, auth.uid()) returning id into iid;
  if p_kind = 'ocultamiento_operacion' and op.id is not null and op.amount is not null then
    pen := round(op.amount * s.penalty_percent / 100, 2);
    update public.investigations set basis_amount = op.amount, basis_currency = op.currency, penalty_percent = s.penalty_percent, bob_per_usd_used = rate,
           penalty_bs = round(case when op.currency = 'BOB' then pen else pen * rate end, 2), penalty_status = 'propuesta' where id = iid;
  end if;
  perform public._inv_log(iid, 'admin', 'abierta', jsonb_build_object('kind', p_kind, 'operation', p_operation, 'connection', p_connection, 'booking', p_booking));
  return jsonb_build_object('id', iid, 'code', cd);
end $$;

-- Si no hay operación de la que tomar el precio, se fija a mano
create or replace function public.admin_set_investigation_basis(p_inv uuid, p_amount numeric, p_currency text)
returns void language plpgsql security definer set search_path = public as $$
declare s public.connection_settings; rate numeric; pen numeric; i public.investigations;
begin
  if not public.is_admin() then raise exception 'Solo administradores' using errcode = '42501'; end if;
  select * into i from public.investigations where id = p_inv and status not in ('resuelta', 'archivada') for update;
  if not found then raise exception 'Investigación no encontrada o ya cerrada'; end if;
  if p_amount is null or p_amount <= 0 or p_currency not in ('USD', 'BOB') then raise exception 'Indica el precio de la operación y su moneda'; end if;
  select * into s from public.connection_settings where id = 1;
  select bob_per_usd into rate from public.stay_settings where id = 1; rate := coalesce(rate, 6.96);
  pen := round(p_amount * s.penalty_percent / 100, 2);
  update public.investigations set basis_amount = p_amount, basis_currency = p_currency, penalty_percent = s.penalty_percent, bob_per_usd_used = rate,
         penalty_bs = round(case when p_currency = 'BOB' then pen else pen * rate end, 2), penalty_status = 'propuesta' where id = i.id;
  perform public._inv_log(i.id, 'admin', 'base_de_penalizacion', jsonb_build_object('amount', p_amount, 'currency', p_currency));
end $$;

-- 2) Suspender / reponer la cuenta mientras dura (reversible)
create or replace function public.admin_set_suspension(p_inv uuid, p_suspend boolean, p_reason text)
returns void language plpgsql security definer set search_path = public as $$
declare i public.investigations; rs text := nullif(btrim(coalesce(p_reason, '')), '');
begin
  if not public.is_admin() then raise exception 'Solo administradores' using errcode = '42501'; end if;
  if rs is null then raise exception 'Escribe el motivo (queda en el historial)'; end if;
  select * into i from public.investigations where id = p_inv for update;
  if not found or i.subject_id is null then raise exception 'Investigación no encontrada'; end if;
  if p_suspend then
    if i.suspended then raise exception 'La cuenta ya está suspendida por esta investigación'; end if;
    update public.profiles set is_active = false where id = i.subject_id and role <> 'admin';
    update public.investigations set suspended = true, suspended_at = now(), suspension_reason = rs where id = i.id;
    perform public._inv_log(i.id, 'admin', 'cuenta_suspendida', jsonb_build_object('reason', rs));
  else
    if not i.suspended then raise exception 'La cuenta no está suspendida por esta investigación'; end if;
    update public.profiles set is_active = true where id = i.subject_id;
    update public.investigations set suspended = false where id = i.id;
    perform public._inv_log(i.id, 'admin', 'cuenta_repuesta', jsonb_build_object('reason', rs));
  end if;
end $$;

-- 3) Descargos: plazo y enlace propio de la persona investigada
create or replace function public.admin_open_descargos(p_inv uuid, p_days integer default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare s public.connection_settings; i public.investigations; d integer; tok text;
begin
  if not public.is_admin() then raise exception 'Solo administradores' using errcode = '42501'; end if;
  select * into s from public.connection_settings where id = 1;
  d := coalesce(p_days, s.descargos_days);
  if d not between 1 and 30 then raise exception 'El plazo debe ser de 1 a 30 días'; end if;
  select * into i from public.investigations where id = p_inv and status in ('abierta', 'descargos', 'revision_juridica') for update;
  if not found then raise exception 'Investigación no encontrada o ya cerrada'; end if;
  tok := coalesce(i.descargos_token, lower(replace(gen_random_uuid()::text, '-', '')));
  update public.investigations set descargos_token = tok, descargos_opened_at = coalesce(descargos_opened_at, now()), descargos_until = now() + make_interval(days => d), status = case when status = 'abierta' then 'descargos' else status end where id = i.id;
  perform public._inv_log(i.id, 'admin', 'plazo_de_descargos', jsonb_build_object('days', d));
  return jsonb_build_object('token', tok, 'until', now() + make_interval(days => d));
end $$;

create or replace function public.get_descargos_public(p_token text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare i public.investigations;
begin
  perform public._throttle('descargos', 30, 60);
  select * into i from public.investigations where descargos_token = lower(btrim(coalesce(p_token, '')));
  if not found then return jsonb_build_object('valid', false); end if;
  return jsonb_build_object('valid', true, 'code', i.code, 'summary', i.summary, 'status', i.status, 'until', i.descargos_until,
    'open', i.descargos_until is not null and i.descargos_until >= now() and i.status in ('abierta', 'descargos', 'revision_juridica'),
    'sent', coalesce((select jsonb_agg(jsonb_build_object('body', x.body, 'at', x.created_at) order by x.created_at) from public.investigation_items x where x.investigation_id = i.id and x.kind = 'descargo'), '[]'::jsonb));
end $$;

create or replace function public.submit_descargo_public(p_token text, p_text text)
returns void language plpgsql security definer set search_path = public as $$
declare i public.investigations; tx text := btrim(coalesce(p_text, ''));
begin
  perform public._throttle('descargos', 8, 600);
  select * into i from public.investigations where descargos_token = lower(btrim(coalesce(p_token, ''))) for update;
  if not found then raise exception 'Este enlace no es válido'; end if;
  if i.descargos_until is null or i.descargos_until < now() or i.status not in ('abierta', 'descargos', 'revision_juridica') then raise exception 'El plazo para presentar descargos terminó'; end if;
  if char_length(tx) not between 10 and 4000 then raise exception 'Escribe tus descargos (entre 10 y 4000 caracteres)'; end if;
  if (select count(*) from public.investigation_items where investigation_id = i.id and kind = 'descargo') >= 5 then raise exception 'Ya enviaste el máximo de 5 descargos'; end if;
  insert into public.investigation_items (investigation_id, author, kind, body) values (i.id, 'titular', 'descargo', tx);
  perform public._inv_log(i.id, 'titular', 'descargo_presentado', jsonb_build_object('chars', char_length(tx)));
end $$;

-- 4) Evidencia, notas y revisión jurídica
create or replace function public.admin_add_investigation_item(p_inv uuid, p_kind text, p_body text, p_path text default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Solo administradores' using errcode = '42501'; end if;
  if p_kind not in ('evidencia', 'nota') then raise exception 'Tipo inválido'; end if;
  if p_path is not null and (char_length(p_path) > 300 or p_path like '%..%') then raise exception 'Archivo inválido'; end if;
  if not exists (select 1 from public.investigations where id = p_inv) then raise exception 'Investigación no encontrada'; end if;
  insert into public.investigation_items (investigation_id, author, kind, body, file_path) values (p_inv, 'admin', p_kind, btrim(coalesce(p_body, '')), nullif(btrim(coalesce(p_path, '')), ''));
  perform public._inv_log(p_inv, 'admin', 'evidencia_o_nota', jsonb_build_object('kind', p_kind));
end $$;

create or replace function public.admin_record_legal_review(p_inv uuid, p_reviewer text, p_concept text)
returns void language plpgsql security definer set search_path = public as $$
declare i public.investigations; rv text := btrim(coalesce(p_reviewer, '')); cp text := btrim(coalesce(p_concept, ''));
begin
  if not public.is_admin() then raise exception 'Solo administradores' using errcode = '42501'; end if;
  if char_length(rv) < 3 then raise exception 'Indica quién hizo la revisión jurídica'; end if;
  if char_length(cp) < 20 then raise exception 'Resume el concepto jurídico (mínimo 20 caracteres)'; end if;
  select * into i from public.investigations where id = p_inv and status not in ('resuelta', 'archivada') for update;
  if not found then raise exception 'Investigación no encontrada o ya cerrada'; end if;
  update public.investigations set legal_reviewer = rv, legal_concept = cp, legal_reviewed_at = now(), status = 'revision_juridica' where id = i.id;
  perform public._inv_log(i.id, 'admin', 'revision_juridica', jsonb_build_object('reviewer', rv));
end $$;

-- 5) Resolución: las sanciones exigen descargos cumplidos Y revisión jurídica registrada. Nada irreversible se ejecuta aquí.
create or replace function public.admin_resolve_investigation(p_inv uuid, p_decision text, p_note text)
returns void language plpgsql security definer set search_path = public as $$
declare i public.investigations; nt text := btrim(coalesce(p_note, '')); desc_ok boolean; grave boolean;
begin
  if not public.is_admin() then raise exception 'Solo administradores' using errcode = '42501'; end if;
  if p_decision not in ('sin_falta', 'amonestacion', 'penalizacion', 'suspension', 'eliminacion_cuenta') then raise exception 'Decisión inválida'; end if;
  if char_length(nt) < 20 then raise exception 'Documenta la decisión (mínimo 20 caracteres): queda en el historial'; end if;
  select * into i from public.investigations where id = p_inv and status not in ('resuelta', 'archivada') for update;
  if not found then raise exception 'Investigación no encontrada o ya cerrada'; end if;
  desc_ok := exists (select 1 from public.investigation_items where investigation_id = i.id and kind = 'descargo') or (i.descargos_until is not null and i.descargos_until < now());
  grave := p_decision in ('penalizacion', 'suspension', 'eliminacion_cuenta');
  if p_decision <> 'sin_falta' and not desc_ok then raise exception 'Antes de decidir hay que dar a la persona la oportunidad de presentar descargos (abrir el plazo y esperar sus descargos o su vencimiento)'; end if;
  if grave and i.legal_reviewed_at is null then raise exception 'Esta decisión exige una revisión jurídica registrada (quién revisó y su concepto)'; end if;
  if p_decision = 'penalizacion' and i.penalty_bs is null then raise exception 'Falta la base de la penalización: indica el precio de la operación'; end if;
  if p_decision = 'sin_falta' then
    update public.investigations set penalty_status = case when penalty_status = 'no_aplica' then 'no_aplica' else 'anulada' end where id = i.id;
    if i.suspended then update public.profiles set is_active = true where id = i.subject_id; update public.investigations set suspended = false where id = i.id; end if;
  elsif p_decision = 'penalizacion' then update public.investigations set penalty_status = 'impuesta' where id = i.id;
  elsif p_decision = 'suspension' then
    update public.profiles set is_active = false where id = i.subject_id and role <> 'admin';
    update public.investigations set suspended = true, suspended_at = coalesce(suspended_at, now()), suspension_reason = coalesce(suspension_reason, nt) where id = i.id;
  elsif p_decision = 'eliminacion_cuenta' then update public.investigations set deletion_authorized = true where id = i.id;
  end if;
  update public.investigations set status = 'resuelta', decision = p_decision, decision_note = nt, decided_by = auth.uid(), decided_at = now() where id = i.id;
  perform public._inv_log(i.id, 'admin', 'resuelta', jsonb_build_object('decision', p_decision, 'note', nt, 'penalty_bs', case when p_decision = 'penalizacion' then i.penalty_bs end));
end $$;

create or replace function public.admin_mark_penalty_paid(p_inv uuid, p_note text)
returns void language plpgsql security definer set search_path = public as $$
declare i public.investigations;
begin
  if not public.is_admin() then raise exception 'Solo administradores' using errcode = '42501'; end if;
  select * into i from public.investigations where id = p_inv and penalty_status = 'impuesta' for update;
  if not found then raise exception 'No hay una penalización impuesta pendiente de pago'; end if;
  update public.investigations set penalty_status = 'pagada' where id = i.id;
  perform public._inv_log(i.id, 'admin', 'penalizacion_pagada', jsonb_build_object('bs', i.penalty_bs, 'note', p_note));
end $$;

create or replace function public.admin_archive_investigation(p_inv uuid, p_note text)
returns void language plpgsql security definer set search_path = public as $$
declare i public.investigations; nt text := btrim(coalesce(p_note, ''));
begin
  if not public.is_admin() then raise exception 'Solo administradores' using errcode = '42501'; end if;
  if char_length(nt) < 10 then raise exception 'Explica por qué se archiva'; end if;
  select * into i from public.investigations where id = p_inv and status not in ('resuelta', 'archivada') for update;
  if not found then raise exception 'Investigación no encontrada o ya cerrada'; end if;
  if i.suspended then update public.profiles set is_active = true where id = i.subject_id; end if;
  update public.investigations set status = 'archivada', suspended = false, decision_note = nt, decided_by = auth.uid(), decided_at = now() where id = i.id;
  perform public._inv_log(i.id, 'admin', 'archivada', jsonb_build_object('note', nt));
end $$;

-- 6) Listas (solo administración)
create or replace function public.admin_investigations()
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Solo administradores' using errcode = '42501'; end if;
  return jsonb_build_object('penalty_percent', (select penalty_percent from public.connection_settings where id = 1), 'descargos_days', (select descargos_days from public.connection_settings where id = 1),
    'items', coalesce((select jsonb_agg(jsonb_build_object('id', i.id, 'code', i.code, 'kind', i.kind, 'status', i.status, 'summary', i.summary, 'subject_id', i.subject_id,
        'subject_name', (select coalesce(nullif(btrim(full_name), ''), display_name, email) from public.profiles where id = i.subject_id), 'subject_active', (select is_active from public.profiles where id = i.subject_id),
        'operation_id', i.operation_id, 'operation_number', (select number from public.operations where id = i.operation_id), 'connection_id', i.connection_id, 'stay_booking_id', i.stay_booking_id, 'property_id', i.property_id,
        'suspended', i.suspended, 'suspended_at', i.suspended_at, 'suspension_reason', i.suspension_reason, 'descargos_token', i.descargos_token, 'descargos_until', i.descargos_until,
        'basis_amount', i.basis_amount, 'basis_currency', i.basis_currency, 'penalty_percent', i.penalty_percent, 'penalty_bs', i.penalty_bs, 'penalty_status', i.penalty_status,
        'legal_reviewer', i.legal_reviewer, 'legal_reviewed_at', i.legal_reviewed_at, 'legal_concept', i.legal_concept, 'decision', i.decision, 'decision_note', i.decision_note, 'decided_at', i.decided_at,
        'deletion_authorized', i.deletion_authorized, 'created_at', i.created_at,
        'items', coalesce((select jsonb_agg(jsonb_build_object('author', x.author, 'kind', x.kind, 'body', x.body, 'file_path', x.file_path, 'at', x.created_at) order by x.created_at) from public.investigation_items x where x.investigation_id = i.id), '[]'::jsonb))
        order by i.created_at desc) from public.investigations i), '[]'::jsonb));
end $$;

create or replace function public.investigation_events(p_inv uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Solo administradores' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('actor', e.actor, 'event', e.event, 'data', e.data, 'at', e.created_at) order by e.created_at, e.id) from public.investigation_events e where e.investigation_id = p_inv), '[]'::jsonb);
end $$;

-- 7) Permisos
revoke all on function public.block_suspended_owner_connection(), public.admin_open_investigation(text, uuid, uuid, uuid, uuid, uuid, text), public.admin_set_investigation_basis(uuid, numeric, text),
  public.admin_set_suspension(uuid, boolean, text), public.admin_open_descargos(uuid, integer), public.get_descargos_public(text), public.submit_descargo_public(text, text),
  public.admin_add_investigation_item(uuid, text, text, text), public.admin_record_legal_review(uuid, text, text), public.admin_resolve_investigation(uuid, text, text),
  public.admin_mark_penalty_paid(uuid, text), public.admin_archive_investigation(uuid, text), public.admin_investigations(), public.investigation_events(uuid) from public, anon;
grant execute on function public.get_descargos_public(text), public.submit_descargo_public(text, text) to anon, authenticated;
grant execute on function public.admin_open_investigation(text, uuid, uuid, uuid, uuid, uuid, text), public.admin_set_investigation_basis(uuid, numeric, text), public.admin_set_suspension(uuid, boolean, text),
  public.admin_open_descargos(uuid, integer), public.admin_add_investigation_item(uuid, text, text, text), public.admin_record_legal_review(uuid, text, text), public.admin_resolve_investigation(uuid, text, text),
  public.admin_mark_penalty_paid(uuid, text), public.admin_archive_investigation(uuid, text), public.admin_investigations(), public.investigation_events(uuid) to authenticated;

notify pgrst, 'reload schema';

-- =====================================================================
-- Bastet · Tipo «Habitación» y estadías temporales sin trámites de venta   — correr DESPUÉS de run-pending.sql
-- =====================================================================
-- 1) Nuevo tipo de inmueble «habitacion» (propiedades, solicitudes de venta y búsquedas de inmueble).
-- 2) Una estadía temporal no es venta, alquiler ni anticrético: no exige contrato marco para publicar
--    (es el de conexiones y comisiones) ni admite la verificación de la propiedad (documentos de propiedad).
-- Idempotente: se puede correr más de una vez.

do $$
declare r record; t text;
begin
  foreach t in array array['properties', 'sell_requests', 'property_requests'] loop
    if to_regclass('public.' || t) is null then continue; end if;
    for r in select c.conname from pg_constraint c
              where c.conrelid = ('public.' || t)::regclass and c.contype = 'c'
                and pg_get_constraintdef(c.oid) ilike '%property_type%' and pg_get_constraintdef(c.oid) not ilike '%habitacion%' loop
      execute format('alter table public.%I drop constraint %I', t, r.conname);
    end loop;
  end loop;
  if to_regclass('public.properties') is not null and not exists (select 1 from pg_constraint where conname = 'properties_property_type_room_check') then
    alter table public.properties add constraint properties_property_type_room_check
      check (property_type is null or property_type in ('casa', 'departamento', 'habitacion', 'terreno'));
  end if;
  if to_regclass('public.sell_requests') is not null and not exists (select 1 from pg_constraint where conname = 'sell_requests_property_type_room_check') then
    alter table public.sell_requests add constraint sell_requests_property_type_room_check
      check (property_type in ('casa', 'departamento', 'habitacion', 'terreno', 'otro'));
  end if;
  if to_regclass('public.property_requests') is not null and not exists (select 1 from pg_constraint where conname = 'property_requests_property_type_room_check') then
    alter table public.property_requests add constraint property_requests_property_type_room_check
      check (property_type in ('casa', 'departamento', 'habitacion', 'terreno', 'oficina', 'local', 'otro'));
  end if;
end $$;

-- Contrato marco: las estadías temporales no lo requieren (no hay conexión ni comisión de venta)
create or replace function public.require_framework_on_publish()
returns trigger language plpgsql security definer set search_path = public as $$
declare s public.connection_settings; uid uuid := auth.uid();
begin
  if uid is null or public.is_admin() or new.operation = 'temporal' then return new; end if;
  select * into s from public.connection_settings where id = 1;
  if s.enabled and char_length(btrim(s.framework_text)) > 0
     and not exists (select 1 from public.framework_acceptances a where a.user_id = uid and a.version = s.framework_version) then
    raise exception 'Antes de publicar debes aceptar el contrato marco de Bastet' using errcode = 'P0403', hint = 'framework';
  end if;
  return new;
end $$;

-- Verificación de propiedad: no se ofrece para estadías temporales
create or replace function public.request_verification(p_kind text, p_property uuid default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); rid uuid;
begin
  if uid is null or not public.is_active_user() then raise exception 'No autorizado' using errcode = '42501'; end if;
  if p_kind not in ('agente', 'propietario', 'propiedad') then raise exception 'Tipo de verificación inválido'; end if;
  if p_kind = 'propiedad' then
    if p_property is null or not exists (select 1 from public.properties where id = p_property and owner_id = uid) then raise exception 'Elige una de tus propiedades'; end if;
    if exists (select 1 from public.properties where id = p_property and operation = 'temporal') then raise exception 'Las estadías temporales no necesitan verificación de propiedad ni documentos de propiedad'; end if;
    if exists (select 1 from public.properties where id = p_property and verified) then raise exception 'Esta propiedad ya está verificada'; end if;
  else p_property := null; end if;
  if p_kind = 'agente' and exists (select 1 from public.profiles where id = uid and agent_verified) then raise exception 'Ya eres agente verificado'; end if;
  if p_kind = 'propietario' and exists (select 1 from public.profiles where id = uid and owner_verified) then raise exception 'Ya eres propietario verificado'; end if;
  select id into rid from public.verification_requests where user_id = uid and kind = p_kind and coalesce(property_id, '00000000-0000-0000-0000-000000000000'::uuid) = coalesce(p_property, '00000000-0000-0000-0000-000000000000'::uuid) and status in ('borrador', 'en_revision');
  if rid is not null then return rid; end if;
  insert into public.verification_requests (kind, user_id, property_id) values (p_kind, uid, p_property) returning id into rid;
  perform public._ver_log(rid, 'usuario', 'solicitud_creada', jsonb_build_object('kind', p_kind));
  return rid;
end $$;

notify pgrst, 'reload schema';

-- =====================================================================
-- Bastet · Acuerdo de anfitrión de estadías temporales   — correr DESPUÉS de room-type.sql
-- =====================================================================
-- Quien publique una estadía temporal (operación «temporal») acepta, una vez por versión, el acuerdo de anfitrión.
-- Es distinto del contrato marco de conexiones (venta, alquiler, anticrético): no habla de comisiones de operación.
-- El texto se pega en el panel (Reservas → Acuerdo de anfitrión) y debe revisarlo un abogado en Bolivia.
-- Sin texto no se exige nada (apagado por defecto). Si se cambia el texto sube la versión y todos deben volver a aceptar.
-- Idempotente: se puede correr más de una vez.

do $$ begin
  if to_regclass('public.stay_settings') is null then raise exception 'Primero corre supabase/stay-bookings.sql'; end if;
end $$;

create table if not exists public.host_agreement_settings (
  id         integer primary key check (id = 1),
  version    integer not null default 1,
  text       text not null default '' check (char_length(text) <= 60000),
  updated_at timestamptz not null default now()
);
insert into public.host_agreement_settings (id) values (1) on conflict (id) do nothing;
alter table public.host_agreement_settings enable row level security;
revoke all on public.host_agreement_settings from anon, authenticated;

create table if not exists public.host_agreement_acceptances (
  user_id     uuid not null references auth.users(id) on delete cascade,
  version     integer not null,
  accepted_at timestamptz not null default now(),
  primary key (user_id, version)
);
alter table public.host_agreement_acceptances enable row level security;
revoke all on public.host_agreement_acceptances from anon, authenticated;

-- ¿Debe este usuario aceptar el acuerdo? (hay texto y no es administrador)
create or replace function public.my_host_agreement()
returns jsonb language plpgsql security definer set search_path = public stable as $$
declare s public.host_agreement_settings; uid uuid := auth.uid(); req boolean;
begin
  if uid is null or not public.is_active_user() then raise exception 'No autorizado' using errcode = '42501'; end if;
  select * into s from public.host_agreement_settings where id = 1;
  req := char_length(btrim(s.text)) > 0 and not public.is_admin();
  return jsonb_build_object('required', req, 'version', s.version, 'text', case when req then s.text end,
    'accepted', not req or exists (select 1 from public.host_agreement_acceptances a where a.user_id = uid and a.version = s.version));
end $$;

create or replace function public.accept_host_agreement(p_version integer)
returns void language plpgsql security definer set search_path = public as $$
declare s public.host_agreement_settings;
begin
  if auth.uid() is null or not public.is_active_user() then raise exception 'No autorizado' using errcode = '42501'; end if;
  select * into s from public.host_agreement_settings where id = 1;
  if char_length(btrim(s.text)) = 0 then return; end if;
  if p_version is distinct from s.version then raise exception 'El acuerdo de anfitrión cambió. Vuelve a leerlo y acéptalo.'; end if;
  insert into public.host_agreement_acceptances (user_id, version) values (auth.uid(), s.version) on conflict do nothing;
end $$;

-- Administración: leer y guardar el texto (vacío = apagado; cambiar el texto sube la versión)
create or replace function public.admin_get_host_agreement()
returns jsonb language plpgsql security definer set search_path = public stable as $$
declare s public.host_agreement_settings;
begin
  if not public.is_admin() then raise exception 'Solo administradores' using errcode = '42501'; end if;
  select * into s from public.host_agreement_settings where id = 1;
  return jsonb_build_object('text', s.text, 'version', s.version, 'accepted_count', (select count(*) from public.host_agreement_acceptances a where a.version = s.version));
end $$;

create or replace function public.admin_update_host_agreement(p_text text)
returns void language plpgsql security definer set search_path = public as $$
declare cur public.host_agreement_settings; t text := btrim(coalesce(p_text, ''));
begin
  if not public.is_admin() then raise exception 'Solo administradores' using errcode = '42501'; end if;
  if char_length(t) > 0 and char_length(t) < 100 then raise exception 'El acuerdo es demasiado corto: pega el texto completo (revisado por un abogado) o déjalo vacío para apagarlo'; end if;
  select * into cur from public.host_agreement_settings where id = 1;
  update public.host_agreement_settings set text = t,
         version = case when t is distinct from cur.text and char_length(t) > 0 then cur.version + 1 else cur.version end, updated_at = now() where id = 1;
end $$;

-- Publicar (o convertir) una propiedad en estadía temporal exige haber aceptado la versión vigente
create or replace function public.require_host_agreement()
returns trigger language plpgsql security definer set search_path = public as $$
declare s public.host_agreement_settings; uid uuid := auth.uid();
begin
  if new.operation is distinct from 'temporal' or (tg_op = 'UPDATE' and old.operation is not distinct from 'temporal') then return new; end if;
  if uid is null or public.is_admin() then return new; end if;
  select * into s from public.host_agreement_settings where id = 1;
  if char_length(btrim(s.text)) > 0
     and not exists (select 1 from public.host_agreement_acceptances a where a.user_id = uid and a.version = s.version) then
    raise exception 'Antes de publicar una estadía debes aceptar el acuerdo de anfitrión de Bastet' using errcode = 'P0403', hint = 'host_agreement';
  end if;
  return new;
end $$;
drop trigger if exists require_host_agreement on public.properties;
create trigger require_host_agreement before insert or update of operation on public.properties for each row execute function public.require_host_agreement();

revoke execute on function public.my_host_agreement(), public.accept_host_agreement(integer), public.admin_get_host_agreement(), public.admin_update_host_agreement(text) from public, anon;
grant execute on function public.my_host_agreement(), public.accept_host_agreement(integer), public.admin_get_host_agreement(), public.admin_update_host_agreement(text) to authenticated;

notify pgrst, 'reload schema';

-- =====================================================================
-- Bastet · Eliminar mi cuenta (desde «Mi cuenta»)   — correr DESPUÉS de host-agreement.sql
-- =====================================================================
-- Quien tiene cuenta puede eliminarla SOLO si no tiene pagos pendientes ni disputas abiertas:
--   · conexiones con pago por hacer o por verificar; inmuebles con conexiones de Bastet sin cerrar la operación;
--   · operaciones por confirmar o comisiones por pagar;
--   · investigaciones abiertas o penalizaciones propuestas / impuestas;
--   · reservas de estadías en curso, con pago por verificar o en disputa;
--   · cobranzas y pedidos de servicios legales sin resolver.
-- Las cuentas de administración no se eliminan por aquí (se retiran desde «Usuarios»).
-- Al eliminar: se retiran sus inmuebles disponibles, se borran sus datos personales (perfil, favoritos, búsquedas, datos legales,
-- solicitudes de verificación) y se cierra su acceso (la cuenta de acceso queda anonimizada y bloqueada; el correo y el ingreso con Google
-- quedan libres). Se CONSERVAN, por obligación contractual y de prueba, los registros de conexiones, operaciones, actas, reservas,
-- aceptaciones de contratos e investigaciones (con los datos de las partes que ya contenían).
-- Idempotente: se puede correr más de una vez.

-- El perfil protege is_active y email frente a quien no es admin; la eliminación de cuenta (única vía) pasa por un permiso interno
create or replace function public.protect_profile_privileged_columns()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is not null and not public.is_admin() and coalesce(current_setting('uno.account_rpc', true), '') <> '1' then
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
end $$;

-- Motivos que impiden eliminar la cuenta de un usuario (vacío = puede eliminarla)
create or replace function public._account_blockers(p_user uuid)
returns text[] language plpgsql security definer set search_path = public as $$
declare r text[] := '{}'; n integer;
begin
  if exists (select 1 from public.profiles where id = p_user and role = 'admin') then
    r := array_append(r, 'Las cuentas de administración no se eliminan desde aquí: se retiran desde «Usuarios».');
  end if;
  if to_regclass('public.connections') is not null then
    select count(*) into n from public.connections where titular_id = p_user and status in ('aceptada_pendiente_pago', 'comprobante_enviado');
    if n > 0 then r := array_append(r, n || ' conexión(es) con el pago de la tarifa pendiente o en revisión.'); end if;
    select count(*) into n from public.properties p where p.owner_id = p_user and p.status = 'available'
       and exists (select 1 from public.connections c where c.property_id = p.id and c.status in ('aceptada_pendiente_pago', 'comprobante_enviado', 'conexion_generada'));
    if n > 0 then r := array_append(r, n || ' inmueble(s) con conexiones de Bastet: primero cierra la operación (vendida, alquilada) o firma el desistimiento en «Cerrar operación».'); end if;
  end if;
  if to_regclass('public.operations') is not null then
    select count(*) into n from public.operations where titular_id = p_user and (status in ('pendiente_interesado', 'en_revision') or commission_status in ('exigible', 'comprobante_enviado'));
    if n > 0 then r := array_append(r, n || ' operación(es) por confirmar o con la comisión pendiente de pago.'); end if;
  end if;
  if to_regclass('public.investigations') is not null then
    select count(*) into n from public.investigations where subject_id = p_user and (status in ('abierta', 'descargos', 'revision_juridica') or penalty_status in ('propuesta', 'impuesta'));
    if n > 0 then r := array_append(r, n || ' investigación(es) abierta(s) o penalización(es) sin resolver.'); end if;
  end if;
  if to_regclass('public.stay_bookings') is not null then
    select count(*) into n from public.stay_bookings where host_id = p_user
       and (status in ('pendiente_respuesta_anfitrion', 'aceptada_pendiente_pago', 'comprobante_enviado', 'pago_en_revision', 'pago_verificado', 'en_disputa')
            or (status = 'conexion_generada' and check_out >= current_date));
    if n > 0 then r := array_append(r, n || ' reserva(s) de estadías en curso, con pago por verificar o en disputa.'); end if;
  end if;
  if to_regclass('public.collections') is not null then
    select count(*) into n from public.collections where agent_id = p_user and status in ('pending', 'in_process');
    if n > 0 then r := array_append(r, n || ' cobranza(s) sin pagar.'); end if;
  end if;
  if to_regclass('public.legal_requests') is not null then
    select count(*) into n from public.legal_requests where user_id = p_user and status in ('pending', 'in_review', 'in_progress');
    if n > 0 then r := array_append(r, n || ' pedido(s) de servicios legales sin terminar.'); end if;
  end if;
  return r;
end $$;

-- La propia persona consulta si puede eliminar su cuenta y qué se lo impide
create or replace function public.my_account_deletion_check()
returns jsonb language plpgsql security definer set search_path = public stable as $$
declare uid uuid := auth.uid(); b text[];
begin
  if uid is null or not public.is_active_user() then raise exception 'No autorizado' using errcode = '42501'; end if;
  b := public._account_blockers(uid);
  return jsonb_build_object('can_delete', coalesce(array_length(b, 1), 0) = 0, 'blockers', to_jsonb(b));
end $$;

-- Elimina (anonimiza y cierra) la cuenta de quien la pide. Hay que escribir ELIMINAR para confirmar.
create or replace function public.delete_my_account(p_confirm text)
returns void language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); b text[]; anon_email text;
begin
  if uid is null or not public.is_active_user() then raise exception 'No autorizado' using errcode = '42501'; end if;
  if upper(btrim(coalesce(p_confirm, ''))) <> 'ELIMINAR' then raise exception 'Escribe ELIMINAR para confirmar'; end if;
  b := public._account_blockers(uid);
  if coalesce(array_length(b, 1), 0) > 0 then raise exception 'No puedes eliminar tu cuenta todavía: %', b[1] using errcode = 'P0403', hint = 'blockers'; end if;

  -- 1) Sus inmuebles disponibles dejan de publicarse
  update public.properties set status = 'withdrawn' where owner_id = uid and status = 'available';
  -- 2) Contactos de terceros que recibió: pasan a administración (sin agente)
  if to_regclass('public.property_leads') is not null then update public.property_leads set agent_id = null where agent_id = uid; end if;
  -- 3) Datos personales
  if to_regclass('public.property_favorites') is not null then delete from public.property_favorites where user_id = uid; end if;
  if to_regclass('public.property_requests') is not null then delete from public.property_requests where user_id = uid; end if;
  if to_regclass('public.agent_legal_profiles') is not null then delete from public.agent_legal_profiles where user_id = uid; end if;
  if to_regclass('public.verification_requests') is not null then delete from public.verification_requests where user_id = uid; end if;
  anon_email := 'cuenta-eliminada-' || uid::text || '@bastet.invalid';
  perform set_config('uno.account_rpc', '1', true); perform set_config('uno.verif_rpc', '1', true);
  update public.profiles set is_active = false, email = anon_email, display_name = 'Cuenta eliminada', avatar_url = null,
         facebook_url = null, instagram_url = null, tiktok_url = null, contact_whatsapp = null, full_name = null, whatsapp = null, city = null,
         company = null, agent_verified = false, owner_verified = false where id = uid;
  -- 4) Acceso: la cuenta de acceso queda anonimizada y bloqueada; el correo y el ingreso con Google quedan libres
  if to_regclass('auth.identities') is not null then delete from auth.identities where user_id = uid; end if;
  update auth.users set email = anon_email, raw_user_meta_data = '{}'::jsonb where id = uid;
  if exists (select 1 from information_schema.columns where table_schema = 'auth' and table_name = 'users' and column_name = 'banned_until') then
    update auth.users set banned_until = 'infinity' where id = uid;
  end if;
  if exists (select 1 from information_schema.columns where table_schema = 'auth' and table_name = 'users' and column_name = 'phone') then
    update auth.users set phone = null where id = uid;
  end if;
  if to_regclass('auth.sessions') is not null then delete from auth.sessions where user_id = uid; end if;
  if to_regclass('auth.refresh_tokens') is not null then delete from auth.refresh_tokens where user_id::text = uid::text; end if;
end $$;

revoke execute on function public._account_blockers(uuid) from public, anon, authenticated;
revoke execute on function public.my_account_deletion_check(), public.delete_my_account(text) from public, anon;
grant execute on function public.my_account_deletion_check(), public.delete_my_account(text) to authenticated;

notify pgrst, 'reload schema';

-- =====================================================================
-- Bastet · Verificar una solicitud de contacto (conexión) por su código   — correr DESPUÉS de account-deletion.sql
-- =====================================================================
-- Quien pide un contacto recibe un código de 10 caracteres. Con él (o con el número de constancia BST-CX-AAAA-NNNN) puede comprobar en
-- «Verificar» en qué estado está su solicitud. La respuesta es pública pero mínima: nunca incluye nombres, teléfonos, correos ni mensajes.
-- Idempotente: se puede correr más de una vez.

create or replace function public.verify_connection_code(p_code text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare cd text := upper(btrim(coalesce(p_code, ''))); c public.connections; p record;
begin
  perform public._throttle('verify_public', 30, 60);
  if cd = '' or char_length(cd) > 24 then return jsonb_build_object('found', false); end if;
  select * into c from public.connections where code = cd or number = cd limit 1;
  if not found then return jsonb_build_object('found', false); end if;
  select code_number, property_type, split_part(coalesce(location, ''), ',', 1) as city into p from public.properties where id = c.property_id;
  return jsonb_build_object('found', true, 'code', c.code, 'number', c.number, 'status', c.status, 'operation', c.operation,
    'property_code', case when p.code_number is not null then 'BST-' || p.code_number end, 'property_type', p.property_type, 'city', btrim(coalesce(p.city, '')),
    'requested_on', to_char(c.created_at, 'YYYY-MM-DD'), 'accepted_on', to_char(c.accepted_at, 'YYYY-MM-DD'), 'connected_on', to_char(c.verified_at, 'YYYY-MM-DD'),
    'framework_version', c.framework_version);
end $$;

revoke execute on function public.verify_connection_code(text) from public;
grant execute on function public.verify_connection_code(text) to anon, authenticated;

notify pgrst, 'reload schema';

-- =====================================================================
-- Bastet · Cuentas de cliente (comprar, alquilar, anticrético o reservar estadías) y contratos solo para agentes   — correr DESPUÉS de verify-connection.sql
-- =====================================================================
-- · Nuevo tipo de cuenta «cliente» (profiles.interest = 'cliente'): busca inmuebles, pide contactos y reserva estadías. No publica
--   inmuebles ni usa herramientas de agente (contratos de exclusividad, comisiones, ofertas). Puede pasar a propietario, agente o empresa
--   desde «Mi cuenta» (nunca al revés: eso lo gestiona la administración).
-- · Los contratos de exclusividad son solo para cuentas de agente o de empresa (y administración): la base de datos lo exige también
--   para propietarios y clientes.
-- · Las solicitudes de contacto y las reservas hechas con la sesión iniciada quedan ligadas a la cuenta (siguen pudiendo hacerse sin cuenta).
--   El cliente ve «Mis solicitudes» y «Mis reservas»; los contactos solo se muestran cuando la conexión fue generada.
-- Idempotente: se puede correr más de una vez.

alter table public.profiles drop constraint if exists profiles_interest_check;
alter table public.profiles add constraint profiles_interest_check check (interest is null or interest in ('propietario', 'agente', 'empresa', 'cliente'));

-- El tipo de cuenta (interest) solo cambia con las funciones de registro (complete_registration, change_account_type); nadie lo edita a mano
create or replace function public.protect_profile_privileged_columns()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is not null and not public.is_admin() and coalesce(current_setting('uno.account_rpc', true), '') <> '1' then
    new.role := old.role;
    new.is_active := old.is_active;
    new.email := old.email;
    if coalesce(current_setting('uno.reg_rpc', true), '') <> '1' then
      new.registered_at := old.registered_at;
      new.trial_used_at := old.trial_used_at;
      new.age_confirmed_at := old.age_confirmed_at;
      new.interest := old.interest;
    end if;
  end if;
  -- Desde 2026-09-29 no se crean administradores nuevos desde la app: el rol solo se cambia desde el SQL Editor
  if auth.uid() is not null then
    new.role := old.role;
  end if;
  return new;
end $$;

-- Estado de la cuenta para el panel: agent_tools solo para agente, empresa y administración
create or replace function public.my_account()
returns jsonb language plpgsql security definer set search_path = public stable as $$
declare uid uuid := auth.uid(); p record; adm boolean; it text;
begin
  if uid is null or not public.is_active_user() then raise exception 'No autorizado' using errcode = '42501'; end if;
  adm := public.is_admin();
  select registered_at, interest into p from public.profiles where id = uid;
  it := case when adm then 'admin' else coalesce(p.interest, 'agente') end;
  return jsonb_build_object('exempt', adm, 'registered', adm or p.registered_at is not null, 'interest', p.interest,
    'account', jsonb_build_object('type', it, 'agent_tools', adm or it in ('agente', 'empresa'), 'client', it = 'cliente',
      'name', case it when 'propietario' then 'Propietario' when 'empresa' then 'Empresa' when 'admin' then 'Administrador' when 'cliente' then 'Cliente' else 'Agente' end),
    'active_properties', public._count_active_properties(uid));
end $$;

-- Registro: ahora también acepta «cliente»
create or replace function public.complete_registration(p_full_name text, p_whatsapp text, p_city text, p_company text, p_interest text, p_consent boolean, p_start_trial boolean default false, p_adult boolean default false)
returns jsonb language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); nm text := btrim(coalesce(p_full_name, '')); wa text := btrim(coalesce(p_whatsapp, ''));
begin
  if uid is null or not public.is_active_user() then raise exception 'No autorizado' using errcode = '42501'; end if;
  if public.is_admin() then raise exception 'Los administradores no necesitan registro'; end if;
  if char_length(nm) not between 3 and 120 then raise exception 'Escribe tu nombre completo'; end if;
  if wa !~ '^\+?[0-9 ()-]{7,30}$' then raise exception 'Escribe un WhatsApp válido (solo números, con código de país si es de otro país)'; end if;
  if char_length(btrim(coalesce(p_city, ''))) > 80 or char_length(btrim(coalesce(p_company, ''))) > 120 then raise exception 'Ciudad o empresa demasiado largas'; end if;
  if p_interest is null or p_interest not in ('cliente', 'propietario', 'agente', 'empresa') then raise exception 'Elige cómo usarás Bastet: cliente, propietario, agente o empresa'; end if;
  if p_adult is not true then raise exception 'Debes confirmar que tienes 18 años o más para crear una cuenta'; end if;
  if p_consent is not true then raise exception 'Debes aceptar el uso de tus datos para continuar'; end if;

  perform set_config('uno.reg_rpc', '1', true);
  update public.profiles
     set full_name = nm, whatsapp = wa, city = nullif(btrim(coalesce(p_city, '')), ''),
         company = case when p_interest = 'cliente' then null else nullif(btrim(coalesce(p_company, '')), '') end,
         interest = p_interest, registered_at = coalesce(registered_at, now()), age_confirmed_at = coalesce(age_confirmed_at, now()),
         display_name = coalesce(nullif(btrim(coalesce(display_name, '')), ''), nm)
   where id = uid;
  return public.my_account();
end $$;

-- Un cliente que quiere publicar pasa a propietario, agente o empresa (solo desde cliente; el resto lo gestiona la administración)
create or replace function public.change_account_type(p_type text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); cur text;
begin
  if uid is null or not public.is_active_user() then raise exception 'No autorizado' using errcode = '42501'; end if;
  if public.is_admin() then raise exception 'Las cuentas de administración no cambian de tipo'; end if;
  if p_type is null or p_type not in ('propietario', 'agente', 'empresa') then raise exception 'Elige propietario, agente o empresa'; end if;
  select interest into cur from public.profiles where id = uid;
  if cur is distinct from 'cliente' then raise exception 'Para cambiar el tipo de tu cuenta escríbenos a inmobiliaria@bastet.uno' using errcode = 'P0403'; end if;
  perform set_config('uno.reg_rpc', '1', true);
  update public.profiles set interest = p_type where id = uid;
  return public.my_account();
end $$;

-- Datos para precargar los formularios de contacto y de reserva (solo los de la propia persona)
create or replace function public.my_prefill()
returns jsonb language plpgsql security definer set search_path = public stable as $$
declare uid uuid := auth.uid(); p record;
begin
  if uid is null then return jsonb_build_object('signed_in', false); end if;
  select coalesce(nullif(btrim(full_name), ''), nullif(btrim(display_name), '')) as name, nullif(btrim(whatsapp), '') as phone, nullif(btrim(email), '') as email, is_active
    into p from public.profiles where id = uid;
  if not found or p.is_active is not true then return jsonb_build_object('signed_in', false); end if;
  return jsonb_build_object('signed_in', true, 'name', p.name, 'phone', p.phone, 'email', p.email);
end $$;

-- Las cuentas de cliente no publican inmuebles
create or replace function public.block_client_publishing()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is not null and not public.is_admin()
     and coalesce((select interest from public.profiles where id = auth.uid()), '') = 'cliente' then
    raise exception 'Las cuentas de cliente no publican inmuebles. Cambia tu cuenta a propietario, agente o empresa en «Mi cuenta».' using errcode = 'P0403', hint = 'client_account';
  end if;
  return new;
end $$;
drop trigger if exists block_client_publishing on public.properties;
create trigger block_client_publishing before insert on public.properties for each row execute function public.block_client_publishing();

-- Los contratos de exclusividad son solo para agentes y empresas (y administración)
create or replace function public.require_agent_for_contracts()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is not null and not public.is_admin()
     and coalesce((select interest from public.profiles where id = auth.uid()), 'agente') not in ('agente', 'empresa') then
    raise exception 'El contrato de exclusividad es solo para cuentas de agente o de empresa' using errcode = 'P0403', hint = 'account_tools';
  end if;
  return new;
end $$;
drop trigger if exists require_agent_for_contracts on public.exclusivity_contracts;
create trigger require_agent_for_contracts before insert on public.exclusivity_contracts for each row execute function public.require_agent_for_contracts();

-- Solicitudes de contacto y reservas ligadas a la cuenta de quien las hace (si tiene sesión)
alter table public.connections add column if not exists interested_user_id uuid references auth.users(id) on delete set null;
create index if not exists connections_interested_idx on public.connections (interested_user_id, created_at desc);
alter table public.stay_bookings add column if not exists guest_user_id uuid references auth.users(id) on delete set null;
create index if not exists stay_bookings_guest_idx on public.stay_bookings (guest_user_id, created_at desc);

create or replace function public.link_connection_to_account()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  new.interested_user_id := auth.uid();
  return new;
end $$;
drop trigger if exists link_connection_to_account on public.connections;
create trigger link_connection_to_account before insert on public.connections for each row execute function public.link_connection_to_account();

create or replace function public.link_booking_to_account()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  new.guest_user_id := auth.uid();
  return new;
end $$;
drop trigger if exists link_booking_to_account on public.stay_bookings;
create trigger link_booking_to_account before insert on public.stay_bookings for each row execute function public.link_booking_to_account();

-- «Mis solicitudes»: las conexiones pedidas con mi cuenta. El contacto de quien publica solo aparece cuando la conexión fue generada.
create or replace function public.my_client_requests()
returns jsonb language plpgsql security definer set search_path = public stable as $$
declare uid uuid := auth.uid();
begin
  if uid is null or not public.is_active_user() then raise exception 'No autorizado' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(to_jsonb(x) order by x.created_at desc) from (
    select c.id, c.code, c.number, c.status, c.operation, c.created_at, c.accepted_at, c.verified_at, c.property_id,
           case when c.status = 'conexion_generada'
                then coalesce((select nullif(btrim(pr.contact_whatsapp), '') from public.profiles pr where pr.id = p.owner_id and pr.is_active), nullif(btrim(p.whatsapp), '')) end as contact_phone
      from public.connections c left join public.properties p on p.id = c.property_id
     where c.interested_user_id = uid and c.created_at > now() - interval '24 months'
     order by c.created_at desc limit 100) x), '[]'::jsonb);
end $$;

-- «Mis reservas»: las estadías reservadas con mi cuenta (el detalle completo se abre con el código, como siempre)
create or replace function public.my_client_bookings()
returns jsonb language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid();
begin
  if uid is null or not public.is_active_user() then raise exception 'No autorizado' using errcode = '42501'; end if;
  perform public.stay_expire_pending();
  return coalesce((select jsonb_agg(to_jsonb(x) order by x.created_at desc) from (
    select b.code, b.status, b.property_id, b.check_in, b.check_out, b.nights, b.guests, b.total, b.currency, b.created_at, b.respond_by, b.accepted_at,
           case when b.status = 'aceptada_pendiente_pago' and s.pay_window_hours is not null then b.accepted_at + make_interval(hours => s.pay_window_hours) end as pay_by
      from public.stay_bookings b cross join public.stay_settings s
     where s.id = 1 and b.guest_user_id = uid and b.created_at > now() - interval '18 months'
     order by b.created_at desc limit 100) x), '[]'::jsonb);
end $$;

revoke execute on function public.my_account(), public.complete_registration(text, text, text, text, text, boolean, boolean, boolean), public.change_account_type(text),
  public.my_client_requests(), public.my_client_bookings() from public, anon;
grant execute on function public.my_account(), public.complete_registration(text, text, text, text, text, boolean, boolean, boolean), public.change_account_type(text),
  public.my_client_requests(), public.my_client_bookings() to authenticated;
revoke execute on function public.my_prefill() from public;
grant execute on function public.my_prefill() to anon, authenticated;

notify pgrst, 'reload schema';

-- =====================================================================
-- Bastet · Solicitudes de publicación de estadías temporales sin documentos de propiedad   — correr DESPUÉS de client-accounts.sql
-- =====================================================================
-- El formulario «Publicar mi inmueble» del Inicio pide documentos que respalden la propiedad en venta, alquiler y anticrético. Una estadía
-- temporal no es una de esas operaciones: no se piden documentos de propiedad. Para eso doc_status admite el valor 'no_aplica', que solo vale
-- cuando la operación es «temporal» (y las solicitudes de las demás operaciones siguen exigiendo uno de los tres estados de siempre).
-- Idempotente: se puede correr más de una vez.

do $$
declare r record;
begin
  if to_regclass('public.sell_requests') is null then raise exception 'Primero corre supabase/sell-requests.sql'; end if;
  for r in select c.conname from pg_constraint c
            where c.conrelid = 'public.sell_requests'::regclass and c.contype = 'c'
              and pg_get_constraintdef(c.oid) ilike '%doc_status%' and c.conname not in ('sell_requests_doc_status_v2', 'sell_requests_no_docs_need_legal_v2', 'sell_requests_no_aplica_only_temporal') loop
    execute format('alter table public.sell_requests drop constraint %I', r.conname);
  end loop;
  if not exists (select 1 from pg_constraint where conname = 'sell_requests_doc_status_v2') then
    alter table public.sell_requests add constraint sell_requests_doc_status_v2 check (doc_status in ('en_regla', 'por_regularizar', 'sin_documentos', 'no_aplica'));
  end if;
  if not exists (select 1 from pg_constraint where conname = 'sell_requests_no_docs_need_legal_v2') then
    alter table public.sell_requests add constraint sell_requests_no_docs_need_legal_v2 check (doc_status <> 'sin_documentos' or needs_legal_support);
  end if;
  if not exists (select 1 from pg_constraint where conname = 'sell_requests_no_aplica_only_temporal') then
    alter table public.sell_requests add constraint sell_requests_no_aplica_only_temporal check (doc_status <> 'no_aplica' or operation = 'temporal');
  end if;
end $$;

notify pgrst, 'reload schema';

-- =====================================================================
-- Bastet · El huésped ve el WhatsApp del dueño de la publicación al confirmarse su reserva   — correr DESPUÉS de sell-temporal.sql
-- =====================================================================
-- Antes, al confirmarse el pago, la reserva mostraba el botón «Escribir al anfitrión» solo si el perfil del anfitrión tenía WhatsApp de contacto
-- o la propiedad tenía WhatsApp de agente (campo que ya no se pide). Ahora se usa primero el «WhatsApp del dueño de la publicación»
-- (properties.owner_whatsapp), luego el del perfil y al final el de la propiedad. Solo se entrega cuando la reserva está confirmada y verificada
-- (igual que antes). Reescribe get_stay_booking, verify_stay_booking y my_stay_bookings a partir de su definición actual.
-- Idempotente.

do $$
declare fn text; def text; newdef text;
begin
  foreach fn in array array['get_stay_booking(text)', 'verify_stay_booking(text)', 'my_stay_bookings()'] loop
    def := pg_get_functiondef(('public.' || fn)::regprocedure);
    newdef := replace(def, 'coalesce(contact, prop.whatsapp)', 'coalesce(nullif(btrim((select owner_whatsapp from public.properties where id = b.property_id)), ''''), contact, prop.whatsapp)');
    newdef := replace(newdef, 'coalesce((select contact_whatsapp from public.profiles where id = b.host_id), p.whatsapp)', 'coalesce(nullif(btrim(p.owner_whatsapp), ''''), (select contact_whatsapp from public.profiles where id = b.host_id), p.whatsapp)');
    if newdef <> def then execute newdef; end if;
  end loop;
end $$;

notify pgrst, 'reload schema';

-- =====================================================================
-- Bastet · Empresas aliadas: alojamiento para los trabajadores con atención preferencial y tarifa corporativa   — correr DESPUÉS de host-contact.sql
-- =====================================================================
-- · Una cuenta de tipo «empresa» (profiles.interest = 'empresa') pide la afiliación corporativa desde su panel («Mi empresa»): razón social, NIT, contacto
--   y cuántos trabajadores viajan. La administración la revisa y la activa fijando el descuento corporativo (por defecto el de corporate_settings).
-- · Una empresa activa registra a sus trabajadores y envía solicitudes de alojamiento (ciudad, fechas, cuántos viajan, presupuesto). La administración las
--   atiende primero, cotiza (tarifa corporativa) y coordina por WhatsApp. NO toca el cobro de las reservas normales: la cotización es manual.
-- · Todo apagado por defecto: corporate_settings.enabled = false. Se enciende desde /admin → Empresas.
-- · Las tablas no tienen políticas públicas: todo pasa por funciones SECURITY DEFINER.
-- Idempotente: se puede correr más de una vez.

do $$
begin
  if to_regprocedure('public.is_active_user()') is null or to_regprocedure('public.bo_today()') is null then raise exception 'Primero corre las fases anteriores (schema.sql y stay-bookings.sql)'; end if;
end $$;

create table if not exists public.corporate_settings (
  id               integer primary key default 1 check (id = 1),
  enabled          boolean not null default false,
  discount_default numeric(5,2) not null default 10 check (discount_default between 0 and 100),
  perks_text       text not null default '',
  updated_at       timestamptz not null default now()
);
insert into public.corporate_settings (id) values (1) on conflict (id) do nothing;

create table if not exists public.company_accounts (
  id               uuid primary key default gen_random_uuid(),
  owner_id         uuid not null unique references public.profiles(id) on delete cascade,
  company_name     text not null check (char_length(btrim(company_name)) between 2 and 120),
  nit              text not null check (char_length(btrim(nit)) between 5 and 20),
  contact_name     text not null check (char_length(btrim(contact_name)) between 3 and 120),
  contact_role     text check (contact_role is null or char_length(contact_role) <= 80),
  whatsapp         text not null check (whatsapp ~ '^\+?[0-9 ()-]{7,30}$'),
  email            text check (email is null or char_length(email) <= 160),
  city             text check (city is null or char_length(city) <= 80),
  workers_estimate integer check (workers_estimate is null or workers_estimate between 1 and 100000),
  travel_notes     text check (travel_notes is null or char_length(travel_notes) <= 1000),
  status           text not null default 'solicitada' check (status in ('solicitada', 'activa', 'suspendida', 'rechazada')),
  discount_percent numeric(5,2) not null default 0 check (discount_percent between 0 and 100),
  admin_notes      text check (admin_notes is null or char_length(admin_notes) <= 2000),
  consent_at       timestamptz not null default now(),
  created_at       timestamptz not null default now(),
  approved_at      timestamptz
);

create table if not exists public.company_workers (
  id         uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.company_accounts(id) on delete cascade,
  full_name  text not null check (char_length(btrim(full_name)) between 3 and 120),
  ci         text check (ci is null or char_length(ci) <= 20),
  phone      text check (phone is null or phone ~ '^\+?[0-9 ()-]{7,30}$'),
  job_title  text check (job_title is null or char_length(job_title) <= 80),
  created_at timestamptz not null default now()
);
create index if not exists company_workers_company_idx on public.company_workers (company_id);

create table if not exists public.company_requests (
  id            uuid primary key default gen_random_uuid(),
  code          text not null unique,
  company_id    uuid not null references public.company_accounts(id) on delete cascade,
  city          text not null check (char_length(btrim(city)) between 2 and 80),
  from_date     date not null,
  to_date       date not null check (to_date > from_date),
  workers_count integer not null check (workers_count between 1 and 200),
  budget_text   text check (budget_text is null or char_length(budget_text) <= 120),
  notes         text check (notes is null or char_length(notes) <= 1000),
  status        text not null default 'nueva' check (status in ('nueva', 'en_gestion', 'cotizada', 'confirmada', 'cerrada', 'cancelada')),
  admin_quote   text check (admin_quote is null or char_length(admin_quote) <= 3000),
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);
create index if not exists company_requests_company_idx on public.company_requests (company_id, created_at desc);

alter table public.corporate_settings enable row level security;
alter table public.company_accounts enable row level security;
alter table public.company_workers enable row level security;
alter table public.company_requests enable row level security;
revoke all on public.corporate_settings, public.company_accounts, public.company_workers, public.company_requests from anon, authenticated, public;

-- Público: ¿está encendido? (para la página /empresas y el panel)
create or replace function public.corporate_public()
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object('enabled', enabled, 'discount_default', discount_default, 'perks_text', perks_text) from public.corporate_settings where id = 1
$$;

-- Estado de MI empresa (empresa, trabajadores y solicitudes)
create or replace function public.my_company()
returns jsonb language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); c public.company_accounts; s public.corporate_settings;
begin
  if uid is null or not public.is_active_user() then raise exception 'No autorizado' using errcode = '42501'; end if;
  select * into s from public.corporate_settings where id = 1;
  select * into c from public.company_accounts where owner_id = uid;
  if not found then return jsonb_build_object('enabled', s.enabled, 'discount_default', s.discount_default, 'perks_text', s.perks_text, 'company', null); end if;
  return jsonb_build_object('enabled', s.enabled, 'discount_default', s.discount_default, 'perks_text', s.perks_text, 'company', to_jsonb(c) - 'admin_notes',
    'workers', coalesce((select jsonb_agg(to_jsonb(w) order by w.created_at) from public.company_workers w where w.company_id = c.id), '[]'::jsonb),
    'requests', coalesce((select jsonb_agg(to_jsonb(r) order by r.created_at desc) from public.company_requests r where r.company_id = c.id), '[]'::jsonb));
end $$;

create or replace function public.request_company_affiliation(p jsonb)
returns void language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); it text; ex public.company_accounts; wa text;
begin
  if uid is null or not public.is_active_user() then raise exception 'No autorizado' using errcode = '42501'; end if;
  if not (select enabled from public.corporate_settings where id = 1) then raise exception 'La afiliación de empresas aún no está disponible'; end if;
  select interest into it from public.profiles where id = uid;
  if it is distinct from 'empresa' then raise exception 'Solo las cuentas de tipo empresa pueden afiliarse'; end if;
  if coalesce((p->>'consent')::boolean, false) is not true then raise exception 'Debes aceptar el uso de los datos de la empresa'; end if;
  wa := btrim(coalesce(p->>'whatsapp', ''));
  select * into ex from public.company_accounts where owner_id = uid;
  if found and ex.status <> 'rechazada' then raise exception 'Tu empresa ya tiene una solicitud de afiliación'; end if;
  begin
    if found then
      update public.company_accounts set company_name = btrim(p->>'company_name'), nit = btrim(p->>'nit'), contact_name = btrim(p->>'contact_name'), contact_role = nullif(btrim(coalesce(p->>'contact_role', '')), ''),
        whatsapp = wa, email = nullif(btrim(coalesce(p->>'email', '')), ''), city = nullif(btrim(coalesce(p->>'city', '')), ''), workers_estimate = nullif(p->>'workers_estimate', '')::integer,
        travel_notes = nullif(btrim(coalesce(p->>'travel_notes', '')), ''), status = 'solicitada', consent_at = now() where id = ex.id;
    else
      insert into public.company_accounts (owner_id, company_name, nit, contact_name, contact_role, whatsapp, email, city, workers_estimate, travel_notes)
      values (uid, btrim(p->>'company_name'), btrim(p->>'nit'), btrim(p->>'contact_name'), nullif(btrim(coalesce(p->>'contact_role', '')), ''), wa,
              nullif(btrim(coalesce(p->>'email', '')), ''), nullif(btrim(coalesce(p->>'city', '')), ''), nullif(p->>'workers_estimate', '')::integer, nullif(btrim(coalesce(p->>'travel_notes', '')), ''));
    end if;
  exception when check_violation or not_null_violation or invalid_text_representation or numeric_value_out_of_range then
    raise exception 'Revisa los datos de la empresa: hay un campo incompleto o con un valor no válido.';
  end;
end $$;

create or replace function public.company_add_worker(p_name text, p_ci text default null, p_phone text default null, p_job text default null)
returns void language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); c public.company_accounts;
begin
  if uid is null or not public.is_active_user() then raise exception 'No autorizado' using errcode = '42501'; end if;
  select * into c from public.company_accounts where owner_id = uid;
  if not found or c.status <> 'activa' then raise exception 'Tu empresa aún no está activa'; end if;
  if (select count(*) from public.company_workers where company_id = c.id) >= 500 then raise exception 'Llegaste al máximo de 500 trabajadores'; end if;
  begin
    insert into public.company_workers (company_id, full_name, ci, phone, job_title)
    values (c.id, btrim(coalesce(p_name, '')), nullif(btrim(coalesce(p_ci, '')), ''), nullif(btrim(coalesce(p_phone, '')), ''), nullif(btrim(coalesce(p_job, '')), ''));
  exception when check_violation then raise exception 'Revisa los datos del trabajador (nombre completo y teléfono válido).';
  end;
end $$;

create or replace function public.company_remove_worker(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null or not public.is_active_user() then raise exception 'No autorizado' using errcode = '42501'; end if;
  delete from public.company_workers w using public.company_accounts c where w.id = p_id and w.company_id = c.id and c.owner_id = auth.uid();
end $$;

create or replace function public.company_submit_request(p jsonb)
returns text language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); c public.company_accounts; cd text; f date; t date;
begin
  if uid is null or not public.is_active_user() then raise exception 'No autorizado' using errcode = '42501'; end if;
  select * into c from public.company_accounts where owner_id = uid;
  if not found or c.status <> 'activa' then raise exception 'Tu empresa aún no está activa'; end if;
  if (select count(*) from public.company_requests where company_id = c.id and status in ('nueva', 'en_gestion', 'cotizada')) >= 20 then raise exception 'Tienes demasiadas solicitudes abiertas; espera a que Bastet responda alguna'; end if;
  begin
    f := (p->>'from_date')::date; t := (p->>'to_date')::date;
    if f < public.bo_today() then raise exception 'La fecha de llegada ya pasó'; end if;
    cd := 'CORP-' || upper(substr(md5(random()::text || clock_timestamp()::text), 1, 6));
    insert into public.company_requests (code, company_id, city, from_date, to_date, workers_count, budget_text, notes)
    values (cd, c.id, btrim(coalesce(p->>'city', '')), f, t, (p->>'workers_count')::integer, nullif(btrim(coalesce(p->>'budget_text', '')), ''), nullif(btrim(coalesce(p->>'notes', '')), ''));
  exception when check_violation or invalid_datetime_format or invalid_text_representation or datetime_field_overflow then
    raise exception 'Revisa la ciudad, las fechas (la salida va después de la llegada) y la cantidad de trabajadores.';
  end;
  return cd;
end $$;

create or replace function public.company_cancel_request(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null or not public.is_active_user() then raise exception 'No autorizado' using errcode = '42501'; end if;
  update public.company_requests r set status = 'cancelada', updated_at = now() from public.company_accounts c
   where r.id = p_id and r.company_id = c.id and c.owner_id = auth.uid() and r.status in ('nueva', 'en_gestion', 'cotizada');
end $$;

-- Administración
create or replace function public.admin_corporate_overview()
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Solo administración' using errcode = '42501'; end if;
  return jsonb_build_object('settings', (select to_jsonb(s) from public.corporate_settings s where s.id = 1),
    'companies', coalesce((select jsonb_agg(to_jsonb(c) || jsonb_build_object('workers', (select count(*) from public.company_workers w where w.company_id = c.id),
        'owner_email', (select email from public.profiles where id = c.owner_id)) order by (c.status = 'solicitada') desc, c.created_at desc) from public.company_accounts c), '[]'::jsonb),
    'requests', coalesce((select jsonb_agg(to_jsonb(r) || jsonb_build_object('company_name', c.company_name, 'whatsapp', c.whatsapp, 'discount_percent', c.discount_percent)
        order by (r.status = 'nueva') desc, r.created_at desc) from public.company_requests r join public.company_accounts c on c.id = r.company_id), '[]'::jsonb));
end $$;

create or replace function public.admin_set_company(p_id uuid, p_status text, p_discount numeric default null, p_notes text default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Solo administración' using errcode = '42501'; end if;
  if p_status not in ('solicitada', 'activa', 'suspendida', 'rechazada') then raise exception 'Estado no válido'; end if;
  update public.company_accounts set status = p_status,
    discount_percent = coalesce(p_discount, case when p_status = 'activa' and discount_percent = 0 then (select discount_default from public.corporate_settings where id = 1) else discount_percent end),
    admin_notes = coalesce(p_notes, admin_notes),
    approved_at = case when p_status = 'activa' then coalesce(approved_at, now()) else approved_at end
   where id = p_id;
  if not found then raise exception 'Empresa no encontrada'; end if;
end $$;

create or replace function public.admin_update_company_request(p_id uuid, p_status text, p_quote text default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Solo administración' using errcode = '42501'; end if;
  if p_status not in ('nueva', 'en_gestion', 'cotizada', 'confirmada', 'cerrada', 'cancelada') then raise exception 'Estado no válido'; end if;
  update public.company_requests set status = p_status, admin_quote = coalesce(p_quote, admin_quote), updated_at = now() where id = p_id;
  if not found then raise exception 'Solicitud no encontrada'; end if;
end $$;

create or replace function public.admin_set_corporate_settings(p_enabled boolean, p_discount_default numeric, p_perks text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Solo administración' using errcode = '42501'; end if;
  update public.corporate_settings set enabled = coalesce(p_enabled, enabled), discount_default = coalesce(p_discount_default, discount_default), perks_text = coalesce(p_perks, perks_text), updated_at = now() where id = 1;
end $$;

revoke execute on function public.my_company(), public.request_company_affiliation(jsonb), public.company_add_worker(text, text, text, text), public.company_remove_worker(uuid),
  public.company_submit_request(jsonb), public.company_cancel_request(uuid), public.admin_corporate_overview(), public.admin_set_company(uuid, text, numeric, text),
  public.admin_update_company_request(uuid, text, text), public.admin_set_corporate_settings(boolean, numeric, text) from public, anon;
grant execute on function public.corporate_public() to anon, authenticated;
grant execute on function public.my_company(), public.request_company_affiliation(jsonb), public.company_add_worker(text, text, text, text), public.company_remove_worker(uuid),
  public.company_submit_request(jsonb), public.company_cancel_request(uuid), public.admin_corporate_overview(), public.admin_set_company(uuid, text, numeric, text),
  public.admin_update_company_request(uuid, text, text), public.admin_set_corporate_settings(boolean, numeric, text) to authenticated;

notify pgrst, 'reload schema';
