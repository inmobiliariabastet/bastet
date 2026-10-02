-- =====================================================================
-- UNO · Publicaciones gratis al mes y cobro por publicación extra   — agregar al final de supabase/schema.sql
-- Idempotente: se puede correr completo más de una vez.
-- Regla: cada agente tiene 3 publicaciones (crear propiedades) gratis por mes. El contador se renueva el día 1 de cada mes
-- (hora de Bolivia, UTC-4) y vuelve a 3, se hayan usado o no (no se acumulan). Después de las 3, cada propiedad nueva cuesta 8 créditos.
-- El cobro lo hace la base de datos con un disparador al crear la propiedad: no se puede saltar desde el navegador.
-- Los administradores no pagan ni consumen cupo. Borrar una propiedad NO devuelve la publicación gratis ni los créditos.
-- Supone el bloque de créditos (credit_wallets / credit_ledger) y public.is_admin()/is_active_user() ya aplicados.
-- =====================================================================

-- 1) Valores de la regla (editables por un admin; el navegador solo los lee)
create table if not exists public.app_settings (
  key   text primary key,
  value integer not null check (value >= 0)
);
insert into public.app_settings (key, value) values
  ('free_publications_per_month', 3),
  ('publication_cost_credits', 8)
on conflict (key) do nothing;

-- 2) Registro de publicaciones (la cuenta de gratis usadas sale de aquí, no de contar propiedades:
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

-- 3) Mes de Bolivia (UTC-4, sin horario de verano)
create or replace function public.bolivia_month_start(ts timestamptz default now())
returns date language sql immutable as $$
  select date_trunc('month', (ts at time zone 'UTC') - interval '4 hours')::date;
$$;

-- 4) Disparador: al crear una propiedad se consume una publicación gratis o se cobran los créditos
create or replace function public.charge_property_publication()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  uid        uuid := auth.uid();
  m          date := public.bolivia_month_start();
  free_total integer;
  cost       integer;
  used       integer;
  bal        integer;
begin
  -- Sin sesión (SQL Editor, importaciones) o administrador: sin cobro ni cupo
  if uid is null or public.is_admin() then return new; end if;

  -- Dos propiedades creadas a la vez por la misma persona se procesan una detrás de otra
  perform pg_advisory_xact_lock(hashtext('publication:' || uid::text));

  select value into free_total from public.app_settings where key = 'free_publications_per_month';
  select value into cost       from public.app_settings where key = 'publication_cost_credits';
  free_total := coalesce(free_total, 3);
  cost       := coalesce(cost, 8);

  select count(*) into used from public.property_publications where user_id = uid and month = m and kind = 'free';

  if used < free_total then
    insert into public.property_publications (user_id, property_id, month, kind) values (uid, new.id, m, 'free');
    return new;
  end if;

  update public.credit_wallets w set balance = w.balance - cost, updated_at = now()
   where w.user_id = uid and w.balance >= cost
   returning w.balance into bal;
  if not found then
    select balance into bal from public.credit_wallets where user_id = uid;
    raise exception 'Saldo insuficiente' using errcode = 'P0402', detail = 'balance=' || coalesce(bal, 0), hint = 'cost=' || cost;
  end if;

  insert into public.property_publications (user_id, property_id, month, kind, credits_charged) values (uid, new.id, m, 'paid', cost);
  insert into public.credit_ledger (user_id, kind, amount, description, property_id)
  values (uid, 'spend', -cost, 'Publicación de propiedad: ' || left(coalesce(new.title, ''), 80), new.id);
  return new;
end $$;

drop trigger if exists charge_property_publication on public.properties;
create trigger charge_property_publication
  before insert on public.properties
  for each row execute function public.charge_property_publication();

-- 5) Contador para el panel: cuántas gratis quedan, cuándo se renuevan, cuánto cuesta la siguiente y el saldo
create or replace function public.my_publication_quota()
returns jsonb language plpgsql security definer set search_path = public stable as $$
declare
  uid        uuid := auth.uid();
  m          date := public.bolivia_month_start();
  free_total integer;
  cost       integer;
  used       integer;
  bal        integer;
begin
  if uid is null or not public.is_active_user() then raise exception 'No autorizado' using errcode = '42501'; end if;
  select value into free_total from public.app_settings where key = 'free_publications_per_month';
  select value into cost       from public.app_settings where key = 'publication_cost_credits';
  free_total := coalesce(free_total, 3);
  cost       := coalesce(cost, 8);
  select count(*) into used from public.property_publications where user_id = uid and month = m and kind = 'free';
  select balance into bal from public.credit_wallets where user_id = uid;
  return jsonb_build_object(
    'exempt', public.is_admin(),
    'free_total', free_total,
    'free_used', least(used, free_total),
    'free_left', greatest(free_total - used, 0),
    'cost', cost,
    'balance', coalesce(bal, 0),
    'resets_on', (m + interval '1 month')::date
  );
end $$;

revoke all on function public.charge_property_publication() from public, anon;
revoke all on function public.my_publication_quota() from public, anon;
grant execute on function public.my_publication_quota() to authenticated;
