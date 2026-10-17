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
