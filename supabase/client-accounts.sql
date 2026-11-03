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
