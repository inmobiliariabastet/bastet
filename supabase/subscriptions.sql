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
