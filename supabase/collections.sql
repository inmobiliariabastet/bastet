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
