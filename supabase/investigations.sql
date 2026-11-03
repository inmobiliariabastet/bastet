-- =====================================================================
-- Bastet · Investigaciones y sanciones (fase 5)   — correr DESPUÉS de verification.sql
-- Idempotente: se puede correr completo más de una vez. Implementa docs/ESPECIFICACION_MAESTRA.md, secciones 1.6 y 9.4.
--
-- Ocultar una operación originada por una conexión de Bastet es una falta grave. Este módulo da a ADMINISTRACIÓN las herramientas para investigarla
-- con garantías y NO ejecuta nada irreversible por su cuenta:
--   · abrir la investigación (desde una operación, conexión o reserva) y registrar evidencia y notas con su cronología;
--   · SUSPENDER la cuenta mientras dura (reversible) — una cuenta suspendida no recibe nuevas conexiones;
--   · DESCARGOS: se abre un plazo y la persona investigada los presenta por un enlace propio (aunque su cuenta esté suspendida);
--   · REVISIÓN JURÍDICA: se registra quién revisó y su concepto;
--   · RESOLUCIÓN escrita. La penalización (2,25 % del precio de la operación = 3 veces la comisión de venta, en Bs con el tipo de cambio interno,
--     congelada) o la eliminación de la cuenta SOLO se pueden resolver con descargos cumplidos Y revisión jurídica registrada.
--   · La ELIMINACIÓN de la cuenta solo queda AUTORIZADA en el registro: no se ejecuta aquí (se hace a mano en Usuarios), nunca de forma automática.
-- La cláusula penal, el procedimiento y la sanción deben revisarse con un abogado en Bolivia ANTES de aplicarlos a una persona real.
-- =====================================================================

do $$
begin
  if to_regclass('public.operations') is null or to_regprocedure('public._throttle(text, integer, integer)') is null then raise exception 'Primero corre supabase/operations.sql y supabase/security-hardening.sql'; end if;
end $$;

alter table public.connection_settings add column if not exists penalty_percent numeric(6,3) not null default 2.25 check (penalty_percent between 0 and 20);
alter table public.connection_settings add column if not exists descargos_days  integer not null default 5 check (descargos_days between 1 and 30);

create table if not exists public.investigation_counters (year integer primary key, last_number integer not null);
alter table public.investigation_counters enable row level security;
revoke all on public.investigation_counters from anon, authenticated;

create table if not exists public.investigations (
  id               uuid primary key default gen_random_uuid(),
  code             text not null unique,
  kind             text not null check (kind in ('ocultamiento_operacion', 'falta_anfitrion', 'otra')),
  subject_id       uuid references auth.users(id) on delete set null,
  operation_id     uuid references public.operations(id) on delete set null,
  connection_id    uuid references public.connections(id) on delete set null,
  stay_booking_id  uuid references public.stay_bookings(id) on delete set null,
  property_id      uuid references public.properties(id) on delete set null,
  summary          text not null check (char_length(summary) between 10 and 2000),
  status           text not null default 'abierta' check (status in ('abierta', 'descargos', 'revision_juridica', 'resuelta', 'archivada')),
  suspended        boolean not null default false,
  suspended_at     timestamptz,
  suspension_reason text check (suspension_reason is null or char_length(suspension_reason) <= 500),
  descargos_token  text unique,
  descargos_opened_at timestamptz,
  descargos_until  timestamptz,
  basis_amount     numeric(16,2),                         -- precio de la operación sobre el que se calcula la penalización
  basis_currency   text check (basis_currency in ('USD', 'BOB')),
  penalty_percent  numeric(6,3),
  bob_per_usd_used numeric(8,4),
  penalty_bs       numeric(16,2),                         -- congelada, en bolivianos
  penalty_status   text not null default 'no_aplica' check (penalty_status in ('no_aplica', 'propuesta', 'impuesta', 'pagada', 'anulada')),
  legal_reviewer   text check (legal_reviewer is null or char_length(legal_reviewer) <= 120),
  legal_reviewed_at timestamptz,
  legal_concept    text check (legal_concept is null or char_length(legal_concept) <= 4000),
  decision         text check (decision in ('sin_falta', 'amonestacion', 'penalizacion', 'suspension', 'eliminacion_cuenta')),
  decision_note    text check (decision_note is null or char_length(decision_note) <= 4000),
  decided_by       uuid references auth.users(id) on delete set null,
  decided_at       timestamptz,
  deletion_authorized boolean not null default false,
  created_by       uuid references auth.users(id) on delete set null,
  created_at       timestamptz not null default now()
);
create index if not exists investigations_subject_idx on public.investigations (subject_id, status);
alter table public.investigations enable row level security;
revoke all on public.investigations from anon, authenticated;

create table if not exists public.investigation_items (
  id               bigint generated always as identity primary key,
  investigation_id uuid not null references public.investigations(id) on delete cascade,
  author           text not null check (author in ('admin', 'titular')),
  kind             text not null check (kind in ('evidencia', 'descargo', 'nota')),
  body             text not null check (char_length(body) between 1 and 4000),
  file_path        text check (file_path is null or char_length(file_path) <= 300),
  created_at       timestamptz not null default now()
);
create index if not exists investigation_items_idx on public.investigation_items (investigation_id, created_at);
alter table public.investigation_items enable row level security;
revoke all on public.investigation_items from anon, authenticated;

create table if not exists public.investigation_events (
  id               bigint generated always as identity primary key,
  investigation_id uuid not null references public.investigations(id) on delete cascade,
  actor            text not null, actor_id uuid, event text not null, data jsonb,
  created_at       timestamptz not null default now()
);
alter table public.investigation_events enable row level security;
revoke all on public.investigation_events from anon, authenticated;
create or replace function public._inv_log(p_inv uuid, p_actor text, p_event text, p_data jsonb default null)
returns void language sql security definer set search_path = public as $$
  insert into public.investigation_events (investigation_id, actor, actor_id, event, data) values (p_inv, p_actor, auth.uid(), p_event, p_data);
$$;
revoke all on function public._inv_log(uuid, text, text, jsonb) from public, anon, authenticated;

-- Carpeta privada de evidencia: solo administración
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('investigation-docs', 'investigation-docs', false, 10485760, array['application/pdf', 'image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do update set public = false, file_size_limit = 10485760, allowed_mime_types = array['application/pdf', 'image/jpeg', 'image/png', 'image/webp'];
drop policy if exists "admin manages investigation docs" on storage.objects;
create policy "admin manages investigation docs" on storage.objects for all to authenticated
  using (bucket_id = 'investigation-docs' and public.is_admin()) with check (bucket_id = 'investigation-docs' and public.is_admin());

-- Una cuenta suspendida (inactiva) no recibe nuevas conexiones
create or replace function public.block_suspended_owner_connection()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if exists (select 1 from public.profiles p where p.id = new.titular_id and not p.is_active) then
    raise exception 'Esta propiedad no está disponible por ahora.';
  end if;
  return new;
end $$;
drop trigger if exists block_suspended_owner_connection on public.connections;
create trigger block_suspended_owner_connection before insert on public.connections for each row execute function public.block_suspended_owner_connection();

-- 1) Abrir la investigación
create or replace function public.admin_open_investigation(p_kind text, p_subject uuid, p_operation uuid, p_connection uuid, p_booking uuid, p_property uuid, p_summary text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare s public.connection_settings; subj uuid := p_subject; op public.operations; yr integer; seq integer; cd text; iid uuid; rate numeric; pen numeric; sm text := btrim(coalesce(p_summary, ''));
begin
  if not public.is_admin() then raise exception 'Solo administradores' using errcode = '42501'; end if;
  if p_kind not in ('ocultamiento_operacion', 'falta_anfitrion', 'otra') then raise exception 'Tipo de investigación inválido'; end if;
  if char_length(sm) not between 10 and 2000 then raise exception 'Describe los hechos (entre 10 y 2000 caracteres)'; end if;
  select * into s from public.connection_settings where id = 1;
  select bob_per_usd into rate from public.stay_settings where id = 1; rate := coalesce(rate, 6.96);
  if p_operation is not null then
    select * into op from public.operations where id = p_operation;
    if not found then raise exception 'Operación no encontrada'; end if;
    subj := coalesce(subj, op.titular_id);
  end if;
  if subj is null and p_connection is not null then select titular_id into subj from public.connections where id = p_connection; end if;
  if subj is null and p_booking is not null then select host_id into subj from public.stay_bookings where id = p_booking; end if;
  if subj is null then raise exception 'Indica la persona investigada'; end if;
  if exists (select 1 from public.profiles where id = subj and role = 'admin') then raise exception 'No se investiga a una cuenta de administración desde aquí'; end if;
  yr := extract(year from ((now() at time zone 'UTC') - interval '4 hours'))::integer;
  insert into public.investigation_counters (year, last_number) values (yr, 1) on conflict (year) do update set last_number = public.investigation_counters.last_number + 1 returning last_number into seq;
  cd := 'INV-' || yr || '-' || lpad(seq::text, 4, '0');
  insert into public.investigations (code, kind, subject_id, operation_id, connection_id, stay_booking_id, property_id, summary, created_by)
  values (cd, p_kind, subj, p_operation, p_connection, p_booking, coalesce(p_property, op.property_id), sm, auth.uid()) returning id into iid;
  if p_kind = 'ocultamiento_operacion' and op.id is not null and op.amount is not null then
    pen := round(op.amount * s.penalty_percent / 100, 2);
    update public.investigations set basis_amount = op.amount, basis_currency = op.currency, penalty_percent = s.penalty_percent, bob_per_usd_used = rate,
           penalty_bs = round(case when op.currency = 'BOB' then pen else pen * rate end, 2), penalty_status = 'propuesta' where id = iid;
  end if;
  perform public._inv_log(iid, 'admin', 'abierta', jsonb_build_object('kind', p_kind, 'operation', p_operation, 'connection', p_connection, 'booking', p_booking));
  return jsonb_build_object('id', iid, 'code', cd);
end $$;

-- Si no hay operación de la que tomar el precio, se fija a mano
create or replace function public.admin_set_investigation_basis(p_inv uuid, p_amount numeric, p_currency text)
returns void language plpgsql security definer set search_path = public as $$
declare s public.connection_settings; rate numeric; pen numeric; i public.investigations;
begin
  if not public.is_admin() then raise exception 'Solo administradores' using errcode = '42501'; end if;
  select * into i from public.investigations where id = p_inv and status not in ('resuelta', 'archivada') for update;
  if not found then raise exception 'Investigación no encontrada o ya cerrada'; end if;
  if p_amount is null or p_amount <= 0 or p_currency not in ('USD', 'BOB') then raise exception 'Indica el precio de la operación y su moneda'; end if;
  select * into s from public.connection_settings where id = 1;
  select bob_per_usd into rate from public.stay_settings where id = 1; rate := coalesce(rate, 6.96);
  pen := round(p_amount * s.penalty_percent / 100, 2);
  update public.investigations set basis_amount = p_amount, basis_currency = p_currency, penalty_percent = s.penalty_percent, bob_per_usd_used = rate,
         penalty_bs = round(case when p_currency = 'BOB' then pen else pen * rate end, 2), penalty_status = 'propuesta' where id = i.id;
  perform public._inv_log(i.id, 'admin', 'base_de_penalizacion', jsonb_build_object('amount', p_amount, 'currency', p_currency));
end $$;

-- 2) Suspender / reponer la cuenta mientras dura (reversible)
create or replace function public.admin_set_suspension(p_inv uuid, p_suspend boolean, p_reason text)
returns void language plpgsql security definer set search_path = public as $$
declare i public.investigations; rs text := nullif(btrim(coalesce(p_reason, '')), '');
begin
  if not public.is_admin() then raise exception 'Solo administradores' using errcode = '42501'; end if;
  if rs is null then raise exception 'Escribe el motivo (queda en el historial)'; end if;
  select * into i from public.investigations where id = p_inv for update;
  if not found or i.subject_id is null then raise exception 'Investigación no encontrada'; end if;
  if p_suspend then
    if i.suspended then raise exception 'La cuenta ya está suspendida por esta investigación'; end if;
    update public.profiles set is_active = false where id = i.subject_id and role <> 'admin';
    update public.investigations set suspended = true, suspended_at = now(), suspension_reason = rs where id = i.id;
    perform public._inv_log(i.id, 'admin', 'cuenta_suspendida', jsonb_build_object('reason', rs));
  else
    if not i.suspended then raise exception 'La cuenta no está suspendida por esta investigación'; end if;
    update public.profiles set is_active = true where id = i.subject_id;
    update public.investigations set suspended = false where id = i.id;
    perform public._inv_log(i.id, 'admin', 'cuenta_repuesta', jsonb_build_object('reason', rs));
  end if;
end $$;

-- 3) Descargos: plazo y enlace propio de la persona investigada
create or replace function public.admin_open_descargos(p_inv uuid, p_days integer default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare s public.connection_settings; i public.investigations; d integer; tok text;
begin
  if not public.is_admin() then raise exception 'Solo administradores' using errcode = '42501'; end if;
  select * into s from public.connection_settings where id = 1;
  d := coalesce(p_days, s.descargos_days);
  if d not between 1 and 30 then raise exception 'El plazo debe ser de 1 a 30 días'; end if;
  select * into i from public.investigations where id = p_inv and status in ('abierta', 'descargos', 'revision_juridica') for update;
  if not found then raise exception 'Investigación no encontrada o ya cerrada'; end if;
  tok := coalesce(i.descargos_token, lower(replace(gen_random_uuid()::text, '-', '')));
  update public.investigations set descargos_token = tok, descargos_opened_at = coalesce(descargos_opened_at, now()), descargos_until = now() + make_interval(days => d), status = case when status = 'abierta' then 'descargos' else status end where id = i.id;
  perform public._inv_log(i.id, 'admin', 'plazo_de_descargos', jsonb_build_object('days', d));
  return jsonb_build_object('token', tok, 'until', now() + make_interval(days => d));
end $$;

create or replace function public.get_descargos_public(p_token text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare i public.investigations;
begin
  perform public._throttle('descargos', 30, 60);
  select * into i from public.investigations where descargos_token = lower(btrim(coalesce(p_token, '')));
  if not found then return jsonb_build_object('valid', false); end if;
  return jsonb_build_object('valid', true, 'code', i.code, 'summary', i.summary, 'status', i.status, 'until', i.descargos_until,
    'open', i.descargos_until is not null and i.descargos_until >= now() and i.status in ('abierta', 'descargos', 'revision_juridica'),
    'sent', coalesce((select jsonb_agg(jsonb_build_object('body', x.body, 'at', x.created_at) order by x.created_at) from public.investigation_items x where x.investigation_id = i.id and x.kind = 'descargo'), '[]'::jsonb));
end $$;

create or replace function public.submit_descargo_public(p_token text, p_text text)
returns void language plpgsql security definer set search_path = public as $$
declare i public.investigations; tx text := btrim(coalesce(p_text, ''));
begin
  perform public._throttle('descargos', 8, 600);
  select * into i from public.investigations where descargos_token = lower(btrim(coalesce(p_token, ''))) for update;
  if not found then raise exception 'Este enlace no es válido'; end if;
  if i.descargos_until is null or i.descargos_until < now() or i.status not in ('abierta', 'descargos', 'revision_juridica') then raise exception 'El plazo para presentar descargos terminó'; end if;
  if char_length(tx) not between 10 and 4000 then raise exception 'Escribe tus descargos (entre 10 y 4000 caracteres)'; end if;
  if (select count(*) from public.investigation_items where investigation_id = i.id and kind = 'descargo') >= 5 then raise exception 'Ya enviaste el máximo de 5 descargos'; end if;
  insert into public.investigation_items (investigation_id, author, kind, body) values (i.id, 'titular', 'descargo', tx);
  perform public._inv_log(i.id, 'titular', 'descargo_presentado', jsonb_build_object('chars', char_length(tx)));
end $$;

-- 4) Evidencia, notas y revisión jurídica
create or replace function public.admin_add_investigation_item(p_inv uuid, p_kind text, p_body text, p_path text default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Solo administradores' using errcode = '42501'; end if;
  if p_kind not in ('evidencia', 'nota') then raise exception 'Tipo inválido'; end if;
  if p_path is not null and (char_length(p_path) > 300 or p_path like '%..%') then raise exception 'Archivo inválido'; end if;
  if not exists (select 1 from public.investigations where id = p_inv) then raise exception 'Investigación no encontrada'; end if;
  insert into public.investigation_items (investigation_id, author, kind, body, file_path) values (p_inv, 'admin', p_kind, btrim(coalesce(p_body, '')), nullif(btrim(coalesce(p_path, '')), ''));
  perform public._inv_log(p_inv, 'admin', 'evidencia_o_nota', jsonb_build_object('kind', p_kind));
end $$;

create or replace function public.admin_record_legal_review(p_inv uuid, p_reviewer text, p_concept text)
returns void language plpgsql security definer set search_path = public as $$
declare i public.investigations; rv text := btrim(coalesce(p_reviewer, '')); cp text := btrim(coalesce(p_concept, ''));
begin
  if not public.is_admin() then raise exception 'Solo administradores' using errcode = '42501'; end if;
  if char_length(rv) < 3 then raise exception 'Indica quién hizo la revisión jurídica'; end if;
  if char_length(cp) < 20 then raise exception 'Resume el concepto jurídico (mínimo 20 caracteres)'; end if;
  select * into i from public.investigations where id = p_inv and status not in ('resuelta', 'archivada') for update;
  if not found then raise exception 'Investigación no encontrada o ya cerrada'; end if;
  update public.investigations set legal_reviewer = rv, legal_concept = cp, legal_reviewed_at = now(), status = 'revision_juridica' where id = i.id;
  perform public._inv_log(i.id, 'admin', 'revision_juridica', jsonb_build_object('reviewer', rv));
end $$;

-- 5) Resolución: las sanciones exigen descargos cumplidos Y revisión jurídica registrada. Nada irreversible se ejecuta aquí.
create or replace function public.admin_resolve_investigation(p_inv uuid, p_decision text, p_note text)
returns void language plpgsql security definer set search_path = public as $$
declare i public.investigations; nt text := btrim(coalesce(p_note, '')); desc_ok boolean; grave boolean;
begin
  if not public.is_admin() then raise exception 'Solo administradores' using errcode = '42501'; end if;
  if p_decision not in ('sin_falta', 'amonestacion', 'penalizacion', 'suspension', 'eliminacion_cuenta') then raise exception 'Decisión inválida'; end if;
  if char_length(nt) < 20 then raise exception 'Documenta la decisión (mínimo 20 caracteres): queda en el historial'; end if;
  select * into i from public.investigations where id = p_inv and status not in ('resuelta', 'archivada') for update;
  if not found then raise exception 'Investigación no encontrada o ya cerrada'; end if;
  desc_ok := exists (select 1 from public.investigation_items where investigation_id = i.id and kind = 'descargo') or (i.descargos_until is not null and i.descargos_until < now());
  grave := p_decision in ('penalizacion', 'suspension', 'eliminacion_cuenta');
  if p_decision <> 'sin_falta' and not desc_ok then raise exception 'Antes de decidir hay que dar a la persona la oportunidad de presentar descargos (abrir el plazo y esperar sus descargos o su vencimiento)'; end if;
  if grave and i.legal_reviewed_at is null then raise exception 'Esta decisión exige una revisión jurídica registrada (quién revisó y su concepto)'; end if;
  if p_decision = 'penalizacion' and i.penalty_bs is null then raise exception 'Falta la base de la penalización: indica el precio de la operación'; end if;
  if p_decision = 'sin_falta' then
    update public.investigations set penalty_status = case when penalty_status = 'no_aplica' then 'no_aplica' else 'anulada' end where id = i.id;
    if i.suspended then update public.profiles set is_active = true where id = i.subject_id; update public.investigations set suspended = false where id = i.id; end if;
  elsif p_decision = 'penalizacion' then update public.investigations set penalty_status = 'impuesta' where id = i.id;
  elsif p_decision = 'suspension' then
    update public.profiles set is_active = false where id = i.subject_id and role <> 'admin';
    update public.investigations set suspended = true, suspended_at = coalesce(suspended_at, now()), suspension_reason = coalesce(suspension_reason, nt) where id = i.id;
  elsif p_decision = 'eliminacion_cuenta' then update public.investigations set deletion_authorized = true where id = i.id;
  end if;
  update public.investigations set status = 'resuelta', decision = p_decision, decision_note = nt, decided_by = auth.uid(), decided_at = now() where id = i.id;
  perform public._inv_log(i.id, 'admin', 'resuelta', jsonb_build_object('decision', p_decision, 'note', nt, 'penalty_bs', case when p_decision = 'penalizacion' then i.penalty_bs end));
end $$;

create or replace function public.admin_mark_penalty_paid(p_inv uuid, p_note text)
returns void language plpgsql security definer set search_path = public as $$
declare i public.investigations;
begin
  if not public.is_admin() then raise exception 'Solo administradores' using errcode = '42501'; end if;
  select * into i from public.investigations where id = p_inv and penalty_status = 'impuesta' for update;
  if not found then raise exception 'No hay una penalización impuesta pendiente de pago'; end if;
  update public.investigations set penalty_status = 'pagada' where id = i.id;
  perform public._inv_log(i.id, 'admin', 'penalizacion_pagada', jsonb_build_object('bs', i.penalty_bs, 'note', p_note));
end $$;

create or replace function public.admin_archive_investigation(p_inv uuid, p_note text)
returns void language plpgsql security definer set search_path = public as $$
declare i public.investigations; nt text := btrim(coalesce(p_note, ''));
begin
  if not public.is_admin() then raise exception 'Solo administradores' using errcode = '42501'; end if;
  if char_length(nt) < 10 then raise exception 'Explica por qué se archiva'; end if;
  select * into i from public.investigations where id = p_inv and status not in ('resuelta', 'archivada') for update;
  if not found then raise exception 'Investigación no encontrada o ya cerrada'; end if;
  if i.suspended then update public.profiles set is_active = true where id = i.subject_id; end if;
  update public.investigations set status = 'archivada', suspended = false, decision_note = nt, decided_by = auth.uid(), decided_at = now() where id = i.id;
  perform public._inv_log(i.id, 'admin', 'archivada', jsonb_build_object('note', nt));
end $$;

-- 6) Listas (solo administración)
create or replace function public.admin_investigations()
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Solo administradores' using errcode = '42501'; end if;
  return jsonb_build_object('penalty_percent', (select penalty_percent from public.connection_settings where id = 1), 'descargos_days', (select descargos_days from public.connection_settings where id = 1),
    'items', coalesce((select jsonb_agg(jsonb_build_object('id', i.id, 'code', i.code, 'kind', i.kind, 'status', i.status, 'summary', i.summary, 'subject_id', i.subject_id,
        'subject_name', (select coalesce(nullif(btrim(full_name), ''), display_name, email) from public.profiles where id = i.subject_id), 'subject_active', (select is_active from public.profiles where id = i.subject_id),
        'operation_id', i.operation_id, 'operation_number', (select number from public.operations where id = i.operation_id), 'connection_id', i.connection_id, 'stay_booking_id', i.stay_booking_id, 'property_id', i.property_id,
        'suspended', i.suspended, 'suspended_at', i.suspended_at, 'suspension_reason', i.suspension_reason, 'descargos_token', i.descargos_token, 'descargos_until', i.descargos_until,
        'basis_amount', i.basis_amount, 'basis_currency', i.basis_currency, 'penalty_percent', i.penalty_percent, 'penalty_bs', i.penalty_bs, 'penalty_status', i.penalty_status,
        'legal_reviewer', i.legal_reviewer, 'legal_reviewed_at', i.legal_reviewed_at, 'legal_concept', i.legal_concept, 'decision', i.decision, 'decision_note', i.decision_note, 'decided_at', i.decided_at,
        'deletion_authorized', i.deletion_authorized, 'created_at', i.created_at,
        'items', coalesce((select jsonb_agg(jsonb_build_object('author', x.author, 'kind', x.kind, 'body', x.body, 'file_path', x.file_path, 'at', x.created_at) order by x.created_at) from public.investigation_items x where x.investigation_id = i.id), '[]'::jsonb))
        order by i.created_at desc) from public.investigations i), '[]'::jsonb));
end $$;

create or replace function public.investigation_events(p_inv uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Solo administradores' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('actor', e.actor, 'event', e.event, 'data', e.data, 'at', e.created_at) order by e.created_at, e.id) from public.investigation_events e where e.investigation_id = p_inv), '[]'::jsonb);
end $$;

-- 7) Permisos
revoke all on function public.block_suspended_owner_connection(), public.admin_open_investigation(text, uuid, uuid, uuid, uuid, uuid, text), public.admin_set_investigation_basis(uuid, numeric, text),
  public.admin_set_suspension(uuid, boolean, text), public.admin_open_descargos(uuid, integer), public.get_descargos_public(text), public.submit_descargo_public(text, text),
  public.admin_add_investigation_item(uuid, text, text, text), public.admin_record_legal_review(uuid, text, text), public.admin_resolve_investigation(uuid, text, text),
  public.admin_mark_penalty_paid(uuid, text), public.admin_archive_investigation(uuid, text), public.admin_investigations(), public.investigation_events(uuid) from public, anon;
grant execute on function public.get_descargos_public(text), public.submit_descargo_public(text, text) to anon, authenticated;
grant execute on function public.admin_open_investigation(text, uuid, uuid, uuid, uuid, uuid, text), public.admin_set_investigation_basis(uuid, numeric, text), public.admin_set_suspension(uuid, boolean, text),
  public.admin_open_descargos(uuid, integer), public.admin_add_investigation_item(uuid, text, text, text), public.admin_record_legal_review(uuid, text, text), public.admin_resolve_investigation(uuid, text, text),
  public.admin_mark_penalty_paid(uuid, text), public.admin_archive_investigation(uuid, text), public.admin_investigations(), public.investigation_events(uuid) to authenticated;

notify pgrst, 'reload schema';
