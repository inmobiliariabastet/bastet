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
