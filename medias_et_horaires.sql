-- ═══════════════════════════════════════════════════════════════════
-- OrthoConnect — médias (photos, logos) et horaires de session
-- ═══════════════════════════════════════════════════════════════════
--
-- À exécuter à la main dans Supabase > SQL Editor, APRÈS
-- admin_et_organismes.sql et detail_formations.sql (ce fichier
-- s'appuie sur public.is_admin()).
--
-- Relançable sans dégât.
--
-- ORDRE DE LECTURE
--   1. colonne formateur_photo_url
--   2. colonne horaires sur sessions_formation
--   3. bucket de stockage « medias »
--   4. policies du bucket
--   5. vérifications
--
-- NOTE SUR logo_url
-- La colonne organismes.logo_url existe déjà (admin_et_organismes.sql,
-- section 2). Rien à faire de ce côté : seul son mode de remplissage
-- change, l'admin téléverse au lieu de coller une URL externe.
-- ═══════════════════════════════════════════════════════════════════


-- ───────────────────────────────────────────────────────────────────
-- 1. Photo du formateur
-- ───────────────────────────────────────────────────────────────────

alter table public.formations
  add column if not exists formateur_photo_url text;

comment on column public.formations.formateur_photo_url is
  'URL publique de la photo du formateur, dans le bucket medias. Vide = la fiche retombe sur les initiales.';


-- ───────────────────────────────────────────────────────────────────
-- 2. Horaires de session
--
-- Les horaires appartiennent à la session, pas à la formation : deux
-- sessions d'une même formation peuvent ne pas commencer à la même
-- heure. Texte libre, parce que le découpage réel est irrégulier
-- (demi-journées, dimanche écourté, pauses variables).
-- ───────────────────────────────────────────────────────────────────

alter table public.sessions_formation
  add column if not exists horaires text;

comment on column public.sessions_formation.horaires is
  'Horaires détaillés de la session, texte libre. Ex. : Vendredi 9h-12h30 / 14h-17h30, Samedi 9h-12h30 / 14h-17h30, Dimanche 9h-12h45.';


-- ───────────────────────────────────────────────────────────────────
-- 3. Bucket « medias »
--
-- file_size_limit et allowed_mime_types sont posés ICI, au niveau du
-- bucket : les contrôles côté navigateur sont du confort d'interface,
-- contournables par un appel direct à l'API. C'est cette contrainte-ci
-- qui garantit réellement les 2 Mo et les trois formats.
-- ───────────────────────────────────────────────────────────────────

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'medias',
  'medias',
  true,
  2097152,                                                  -- 2 Mo
  array['image/jpeg', 'image/png', 'image/webp']
)
on conflict (id) do update set
  public             = true,
  file_size_limit    = 2097152,
  allowed_mime_types = array['image/jpeg', 'image/png', 'image/webp'];


-- ───────────────────────────────────────────────────────────────────
-- 4. Policies du bucket
--
-- storage.objects a déjà RLS activée par Supabase : on n'ajoute que
-- des policies, portées uniquement sur bucket_id = 'medias'. Les
-- autres buckets ne sont pas touchés.
--
-- Lecture publique : les logos et photos s'affichent sur le site sans
-- authentification. Écriture, remplacement et suppression : admin seul.
-- ───────────────────────────────────────────────────────────────────

drop policy if exists "medias lisibles par tous" on storage.objects;
create policy "medias lisibles par tous"
  on storage.objects
  for select
  to anon, authenticated
  using (bucket_id = 'medias');

drop policy if exists "admin televerse dans medias" on storage.objects;
create policy "admin televerse dans medias"
  on storage.objects
  for insert
  to authenticated
  with check (bucket_id = 'medias' and public.is_admin());

drop policy if exists "admin remplace dans medias" on storage.objects;
create policy "admin remplace dans medias"
  on storage.objects
  for update
  to authenticated
  using (bucket_id = 'medias' and public.is_admin())
  with check (bucket_id = 'medias' and public.is_admin());

drop policy if exists "admin supprime dans medias" on storage.objects;
create policy "admin supprime dans medias"
  on storage.objects
  for delete
  to authenticated
  using (bucket_id = 'medias' and public.is_admin());


-- ───────────────────────────────────────────────────────────────────
-- 5. Vérifications
-- ───────────────────────────────────────────────────────────────────

-- Le bucket est public et correctement borné :
-- select id, public, file_size_limit, allowed_mime_types
-- from storage.buckets where id = 'medias';

-- Les quatre policies du bucket :
-- select policyname, cmd, roles
-- from pg_policies
-- where schemaname = 'storage' and tablename = 'objects'
--   and policyname like '%medias%'
-- order by policyname;

-- Les deux nouvelles colonnes :
-- select table_name, column_name
-- from information_schema.columns
-- where table_schema = 'public'
--   and (table_name = 'formations'          and column_name = 'formateur_photo_url')
--    or (table_name = 'sessions_formation'  and column_name = 'horaires');

-- Ce qui a été téléversé jusqu'ici :
-- select name, metadata ->> 'size' as octets, metadata ->> 'mimetype' as type, created_at
-- from storage.objects where bucket_id = 'medias' order by created_at desc;

-- Contrôle d'étanchéité : depuis une session anonyme, le SELECT
-- ci-dessus doit fonctionner, mais tout INSERT doit être refusé.
