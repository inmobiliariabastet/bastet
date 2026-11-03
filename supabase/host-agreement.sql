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
