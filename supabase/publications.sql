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
