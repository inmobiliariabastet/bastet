#!/usr/bin/env python3
"""Genera supabase/blog.sql: tabla del blog, permisos, bucket de fotos y las 3 entradas iniciales (salen de content/blog/*.md).

Uso:  python tools/build_blog_sql.py   y luego   python tools/sync_sql.py blog.sql
Las entradas iniciales usan uuid fijo + «on conflict (slug) do nothing»: correr el SQL otra vez NO pisa lo que se edite en el panel.
"""
import glob
import sys
import uuid
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import blog_md as B  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent

HEAD = """-- =====================================================================
-- Bastet · Blog (compra segura, anticrético y verificación de títulos)  — corre en el SQL Editor de Supabase
-- =====================================================================
-- · Tabla blog_posts: las entradas se escriben en el panel (Admin → Blog). El público solo ve las PUBLICADAS; solo administración crea, edita y borra.
-- · Bucket público «blog-images» para las fotos de las entradas (solo administración sube).
-- · La página pública (/blog/) se genera con tools/gen_property_pages.py (tarea diaria de GitHub o «Run workflow»).
-- · Incluye 3 entradas iniciales; volver a correr este SQL no pisa lo que edites.
-- Idempotente: se puede correr más de una vez.

do $$
begin
  if to_regprocedure('public.is_admin()') is null then raise exception 'Primero corre supabase/schema.sql (falta is_admin)'; end if;
end $$;

create table if not exists public.blog_posts (
  id           uuid primary key default gen_random_uuid(),
  slug         text not null unique check (slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$' and char_length(slug) between 3 and 100),
  title        text not null check (char_length(btrim(title)) between 5 and 150),
  excerpt      text not null check (char_length(btrim(excerpt)) between 40 and 320),
  body_md      text not null check (char_length(btrim(body_md)) >= 200),
  cover_url    text check (cover_url is null or char_length(cover_url) <= 600),
  cover_alt    text check (cover_alt is null or char_length(cover_alt) <= 200),
  category     text not null default 'general' check (category in ('compra-segura', 'anticretico', 'verificacion', 'general')),
  author_name  text not null default 'Equipo Bastet' check (char_length(btrim(author_name)) between 2 and 80),
  status       text not null default 'draft' check (status in ('draft', 'published')),
  published_at timestamptz,
  created_by   uuid default auth.uid(),
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);

create index if not exists blog_posts_status_published_idx on public.blog_posts (status, published_at desc);

-- Fechas automáticas: updated_at siempre; published_at se llena al publicar por primera vez.
create or replace function public.blog_posts_touch()
returns trigger language plpgsql as $$
begin
  new.updated_at := now();
  if new.status = 'published' and new.published_at is null then new.published_at := now(); end if;
  return new;
end $$;
drop trigger if exists blog_posts_touch on public.blog_posts;
create trigger blog_posts_touch before insert or update on public.blog_posts for each row execute function public.blog_posts_touch();

alter table public.blog_posts enable row level security;

drop policy if exists "public can read published blog posts" on public.blog_posts;
create policy "public can read published blog posts" on public.blog_posts for select to anon, authenticated
  using (status = 'published' and published_at <= now());

drop policy if exists "admin can read all blog posts" on public.blog_posts;
create policy "admin can read all blog posts" on public.blog_posts for select to authenticated using (public.is_admin());

drop policy if exists "admin can insert blog posts" on public.blog_posts;
create policy "admin can insert blog posts" on public.blog_posts for insert to authenticated with check (public.is_admin());

drop policy if exists "admin can update blog posts" on public.blog_posts;
create policy "admin can update blog posts" on public.blog_posts for update to authenticated using (public.is_admin()) with check (public.is_admin());

drop policy if exists "admin can delete blog posts" on public.blog_posts;
create policy "admin can delete blog posts" on public.blog_posts for delete to authenticated using (public.is_admin());

-- ── Storage: fotos del blog ──
insert into storage.buckets (id, name, public) values ('blog-images', 'blog-images', true) on conflict (id) do nothing;

drop policy if exists "public can view blog images" on storage.objects;
create policy "public can view blog images" on storage.objects for select to public using (bucket_id = 'blog-images');

drop policy if exists "admin can upload blog images" on storage.objects;
create policy "admin can upload blog images" on storage.objects for insert to authenticated with check (bucket_id = 'blog-images' and public.is_admin());

drop policy if exists "admin can update blog images" on storage.objects;
create policy "admin can update blog images" on storage.objects for update to authenticated using (bucket_id = 'blog-images' and public.is_admin());

drop policy if exists "admin can delete blog images" on storage.objects;
create policy "admin can delete blog images" on storage.objects for delete to authenticated using (bucket_id = 'blog-images' and public.is_admin());

-- ── Entradas iniciales ──
"""

TAIL = """
notify pgrst, 'reload schema';
"""


def main():
    rows = []
    for f in sorted(glob.glob(str(ROOT / 'content' / 'blog' / '*.md'))):
        meta, body = B.parse_front_matter(Path(f).read_text(encoding='utf-8'))
        assert '$md$' not in body and '$md$' not in ''.join(meta.values()), f
        pid = uuid.uuid5(uuid.NAMESPACE_URL, 'https://bastet.uno/blog/' + meta['slug'])
        q = lambda s: "$md$" + s + "$md$"
        rows.append(
            f"  ('{pid}', '{meta['slug']}', {q(meta['title'])}, {q(meta['excerpt'])}, {q(body.strip())}, '{meta['cover']}', {q(meta['cover_alt'])}, "
            f"'{meta['category']}', {q(meta.get('author', 'Equipo Bastet'))}, 'published', '{meta['published_at']} 12:00:00-04')")
    seed = ("insert into public.blog_posts (id, slug, title, excerpt, body_md, cover_url, cover_alt, category, author_name, status, published_at) values\n"
            + ',\n'.join(rows) + "\non conflict (slug) do nothing;\n")
    (ROOT / 'supabase' / 'blog.sql').write_text(HEAD + seed + TAIL, encoding='utf-8', newline='\n')
    print(f'supabase/blog.sql generado con {len(rows)} entradas')


if __name__ == '__main__':
    main()
