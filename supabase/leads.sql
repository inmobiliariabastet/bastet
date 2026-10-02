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
