-- ═══════════════════════════════════════════════════════════════════
-- OrthoConnect — fiche formation détaillée
-- ═══════════════════════════════════════════════════════════════════
--
-- À exécuter à la main dans Supabase > SQL Editor, APRÈS
-- admin_et_organismes.sql (ce fichier s'appuie sur formations.statut
-- et sur la fonction public.is_admin()).
--
-- Relançable sans dégât : ajouts de colonnes en « if not exists »,
-- policies précédées d'un « drop policy if exists ».
--
-- ORDRE DE LECTURE
--   1. nouvelles colonnes de formations
--   2. table programme_sections
--   3. table programme_sequences
--   4. policies RLS
--   5. vérifications
--
-- PARTI PRIS SUR LE PROGRAMME
-- La structure ne présuppose aucun découpage. Une section n'a pas de
-- type, pas de numéro, et son titre est facultatif :
--   — trois sections « Jour 1 / Jour 2 / Jour 3 » pour un présentiel,
--   — une seule section sans titre pour une formation courte, dont on
--     n'affiche alors que les séquences,
--   — « Module 1 / Module 2 » pour du e-learning,
--   — « Année 1 / Année 2 » pour un DU.
-- C'est l'admin qui nomme, la base ne fait que garder l'ordre.
-- ═══════════════════════════════════════════════════════════════════


-- ───────────────────────────────────────────────────────────────────
-- 1. Nouvelles colonnes de formations
-- ───────────────────────────────────────────────────────────────────

alter table public.formations
  add column if not exists objectifs        text[],
  add column if not exists inclus           text[],
  add column if not exists participants_max integer,
  add column if not exists formateur_nom    text,
  add column if not exists formateur_titre  text,
  add column if not exists formateur_bio    text,
  add column if not exists url_inscription  text;

alter table public.formations
  drop constraint if exists formations_participants_check;
alter table public.formations
  add constraint formations_participants_check
  check (participants_max is null or participants_max > 0);

comment on column public.formations.objectifs is
  'Objectifs pédagogiques, un par entrée. Affichés en liste sur la fiche.';
comment on column public.formations.inclus is
  'Ce qui est fourni (support, repas, attestation...), un par entrée.';
comment on column public.formations.url_inscription is
  'Inscription au niveau de la formation. Une session peut avoir la sienne, qui prime.';


-- ───────────────────────────────────────────────────────────────────
-- 2. programme_sections
--
-- titre volontairement nullable : une formation peut n'avoir qu'une
-- section anonyme servant de simple contenant à ses séquences.
-- ───────────────────────────────────────────────────────────────────

create table if not exists public.programme_sections (
  id           bigint generated always as identity primary key,
  formation_id bigint      not null,
  titre        text,
  ordre        integer     not null default 0,
  created_at   timestamptz not null default now(),

  constraint programme_sections_formation_fk
    foreign key (formation_id) references public.formations (id) on delete cascade
);

comment on table public.programme_sections is
  'Découpage de premier niveau du programme. Le titre est libre et facultatif : Jour 1, Module 2, Année 1, ou rien.';

create index if not exists programme_sections_formation_idx
  on public.programme_sections (formation_id, ordre);


-- ───────────────────────────────────────────────────────────────────
-- 3. programme_sequences
--
-- duree en texte libre : le secteur annonce « 2h30 », « une demi-
-- journée », « 45 min environ ». Un intervalle numérique obligerait à
-- trahir ce que publie l'organisme.
-- ───────────────────────────────────────────────────────────────────

create table if not exists public.programme_sequences (
  id         bigint generated always as identity primary key,
  section_id bigint      not null,
  titre      text        not null,
  duree      text,
  contenu    text,
  ordre      integer     not null default 0,
  created_at timestamptz not null default now(),

  constraint programme_sequences_section_fk
    foreign key (section_id) references public.programme_sections (id) on delete cascade
);

comment on column public.programme_sequences.duree is
  'Durée approximative, texte libre : 2h30, une demi-journée, 45 min.';

create index if not exists programme_sequences_section_idx
  on public.programme_sequences (section_id, ordre);


-- ───────────────────────────────────────────────────────────────────
-- 4. Policies RLS
--
-- Lecture publique uniquement si la formation porteuse est publiée :
-- le programme d'un brouillon ne doit pas fuiter avant publication.
-- Écriture réservée à l'admin.
-- ───────────────────────────────────────────────────────────────────

alter table public.programme_sections  enable row level security;
alter table public.programme_sequences enable row level security;

drop policy if exists "sections des formations publiees" on public.programme_sections;
create policy "sections des formations publiees"
  on public.programme_sections
  for select
  to anon, authenticated
  using (
    exists (
      select 1
      from public.formations f
      where f.id = programme_sections.formation_id
        and f.statut = 'publie'
    )
  );

drop policy if exists "admin gere les sections" on public.programme_sections;
create policy "admin gere les sections"
  on public.programme_sections
  for all
  to authenticated
  using (public.is_admin())
  with check (public.is_admin());

-- Les séquences remontent à la formation en passant par leur section.
drop policy if exists "sequences des formations publiees" on public.programme_sequences;
create policy "sequences des formations publiees"
  on public.programme_sequences
  for select
  to anon, authenticated
  using (
    exists (
      select 1
      from public.programme_sections s
      join public.formations f on f.id = s.formation_id
      where s.id = programme_sequences.section_id
        and f.statut = 'publie'
    )
  );

drop policy if exists "admin gere les sequences" on public.programme_sequences;
create policy "admin gere les sequences"
  on public.programme_sequences
  for all
  to authenticated
  using (public.is_admin())
  with check (public.is_admin());


-- ───────────────────────────────────────────────────────────────────
-- 5. Vérifications
-- ───────────────────────────────────────────────────────────────────

-- Les colonnes sont bien là :
-- select column_name, data_type
-- from information_schema.columns
-- where table_schema = 'public' and table_name = 'formations'
--   and column_name in ('objectifs','inclus','participants_max',
--                       'formateur_nom','formateur_titre','formateur_bio',
--                       'url_inscription')
-- order by column_name;

-- Les policies des deux nouvelles tables :
-- select tablename, policyname, cmd, roles
-- from pg_policies
-- where schemaname = 'public'
--   and tablename in ('programme_sections', 'programme_sequences')
-- order by tablename, policyname;

-- Programme d'une formation, à plat, dans l'ordre d'affichage :
-- select s.ordre as ordre_section, coalesce(s.titre, '(sans titre)') as section,
--        q.ordre as ordre_sequence, q.titre as sequence, q.duree
-- from public.programme_sections s
-- left join public.programme_sequences q on q.section_id = s.id
-- where s.formation_id = 1          -- ← l'id de la formation à inspecter
-- order by s.ordre, q.ordre;

-- Contrôle d'étanchéité : exécuté depuis une session anonyme, ceci ne
-- doit renvoyer que des sections de formations publiées.
-- select count(*) from public.programme_sections;
