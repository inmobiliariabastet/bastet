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
