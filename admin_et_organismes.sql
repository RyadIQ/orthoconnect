-- ═══════════════════════════════════════════════════════════════════
-- OrthoConnect — rôle admin, organismes, refonte des formations
-- ═══════════════════════════════════════════════════════════════════
--
-- À exécuter à la main dans Supabase > SQL Editor.
-- Le fichier est écrit pour être relançable sans dégât : chaque ajout
-- de colonne est en « if not exists », chaque policy est précédée d'un
-- « drop policy if exists », et les UPDATE de migration ne touchent que
-- les lignes pas encore migrées.
--
-- ORDRE DE LECTURE
--   1. rôle admin + is_admin()
--   2. table organismes
--   3. refonte de formations
--   4. table sessions_formation
--   5. policies RLS
--   6. migration des formations existantes
--   7. bootstrap du premier admin        <- À FAIRE, sinon personne
--                                           n'a accès à l'admin
--   8. vérifications
--
-- CE QUI N'EST PAS TOUCHÉ
-- Les policies existantes de praticiens (lecture / création /
-- modification de son propre profil) sont conservées telles quelles.
-- La section 5 ne fait qu'ajouter une policy admin à côté : les
-- policies permissives se cumulent en OR, un praticien garde donc
-- exactement les mêmes droits qu'aujourd'hui.
-- ═══════════════════════════════════════════════════════════════════


-- ───────────────────────────────────────────────────────────────────
-- 1. Identifier les admins
-- ───────────────────────────────────────────────────────────────────

alter table public.praticiens
  add column if not exists role text not null default 'praticien';

alter table public.praticiens
  drop constraint if exists praticiens_role_check;
alter table public.praticiens
  add constraint praticiens_role_check check (role in ('praticien', 'admin'));

-- Le répertoire des inscrits affiche une date d'inscription. On la
-- garantit ici plutôt que de supposer qu'elle existe déjà.
alter table public.praticiens
  add column if not exists created_at timestamptz not null default now();

create index if not exists praticiens_role_idx on public.praticiens (role);


-- is_admin() DOIT être SECURITY DEFINER, et pas seulement pour
-- contourner RLS : la fonction est utilisée dans une policy DE la table
-- praticiens. En SECURITY INVOKER, lire praticiens depuis la policy de
-- praticiens déclencherait une récursion infinie (erreur 42P17). Le
-- mode DEFINER fait tourner la lecture hors RLS et casse le cycle.
--
-- stable : le résultat ne change pas dans une même requête, Postgres
-- peut donc n'évaluer la fonction qu'une fois par requête au lieu
-- d'une fois par ligne du répertoire.
create or replace function public.is_admin()
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select exists (
    select 1
    from public.praticiens
    where id = auth.uid()
      and role = 'admin'
  );
$$;

comment on function public.is_admin() is
  'true si l''utilisateur courant a le rôle admin. SECURITY DEFINER pour éviter la récursion RLS dans les policies de praticiens.';

revoke all on function public.is_admin() from public, anon;
grant execute on function public.is_admin() to authenticated;


-- ───────────────────────────────────────────────────────────────────
-- 2. Table organismes
--
-- Un même organisme peut former ET vendre du matériel (Invisalign,
-- Ormco...), d'où le type 'les_deux' plutôt que deux tables séparées.
-- ───────────────────────────────────────────────────────────────────

create table if not exists public.organismes (
  id            bigint generated always as identity primary key,
  nom           text        not null,
  type          text        not null default 'formation',
  site_web      text,
  logo_url      text,
  qualiopi      boolean     not null default false,
  partenaire    boolean     not null default false,
  niveau_offre  text        not null default 'aucun',
  description   text,
  contact_nom   text,
  contact_email text,
  contact_tel   text,
  actif         boolean     not null default true,
  created_at    timestamptz not null default now(),

  constraint organismes_nom_unique  unique (nom),
  constraint organismes_type_check  check (type in ('formation', 'fournisseur', 'les_deux')),
  constraint organismes_niveau_check
    check (niveau_offre in ('aucun', 'starter', 'pro', 'premium'))
);

comment on table  public.organismes is 'Organismes de formation et fournisseurs de matériel.';
comment on column public.organismes.type is 'formation | fournisseur | les_deux';
comment on column public.organismes.niveau_offre is 'Offre partenaire souscrite : aucun | starter | pro | premium';

create index if not exists organismes_type_idx       on public.organismes (type);
create index if not exists organismes_partenaire_idx on public.organismes (partenaire) where partenaire;


-- ───────────────────────────────────────────────────────────────────
-- 3. Refonte de formations
--
-- La colonne texte « organisme » est conservée pour l'instant : elle
-- sert de source à la migration de la section 6 et de filet si un
-- rattachement s'avère faux. Sa suppression est proposée, commentée,
-- tout en bas de cette section.
-- ───────────────────────────────────────────────────────────────────

alter table public.formations add column if not exists organisme_id bigint;
alter table public.formations add column if not exists thematique   text;
alter table public.formations add column if not exists niveau       text;
alter table public.formations add column if not exists dpc_numero   text;
alter table public.formations add column if not exists prerequis    text;
alter table public.formations add column if not exists url_source   text;
alter table public.formations add column if not exists verifie_le   date;

alter table public.formations
  drop constraint if exists formations_organisme_fk;
alter table public.formations
  add constraint formations_organisme_fk
  foreign key (organisme_id) references public.organismes (id) on delete set null;

-- statut ajouté sans valeur par défaut, le temps de le déduire de
-- « actif » à la section 6 ; le défaut et le not null sont posés juste
-- après. Faire l'inverse remplirait toutes les lignes de 'brouillon'
-- et on perdrait l'information portée par actif.
alter table public.formations add column if not exists statut text;

alter table public.formations
  drop constraint if exists formations_statut_check;
alter table public.formations
  add constraint formations_statut_check
  check (statut is null or statut in ('brouillon', 'publie', 'archive'));

alter table public.formations
  drop constraint if exists formations_niveau_check;
alter table public.formations
  add constraint formations_niveau_check
  check (niveau is null or niveau in ('initiation', 'perfectionnement', 'expert'));

create index if not exists formations_organisme_idx  on public.formations (organisme_id);
create index if not exists formations_statut_idx     on public.formations (statut);
create index if not exists formations_thematique_idx on public.formations (thematique);


-- ───────────────────────────────────────────────────────────────────
-- 4. Table sessions_formation
--
-- Une formation a plusieurs dates : on sort les sessions dans leur
-- propre table plutôt que de dupliquer la formation par date.
-- ───────────────────────────────────────────────────────────────────

create table if not exists public.sessions_formation (
  id              bigint generated always as identity primary key,
  formation_id    bigint      not null,
  date_debut      date        not null,
  date_fin        date,
  ville           text,
  places          integer,
  url_inscription text,
  actif           boolean     not null default true,
  created_at      timestamptz not null default now(),

  constraint sessions_formation_fk
    foreign key (formation_id) references public.formations (id) on delete cascade,
  constraint sessions_dates_check  check (date_fin is null or date_fin >= date_debut),
  constraint sessions_places_check check (places is null or places >= 0)
);

comment on table public.sessions_formation is 'Dates concrètes d''une formation. Une formation peut en avoir plusieurs.';

create index if not exists sessions_formation_idx on public.sessions_formation (formation_id);
create index if not exists sessions_date_idx      on public.sessions_formation (date_debut);


-- ───────────────────────────────────────────────────────────────────
-- 5. Policies RLS
-- ───────────────────────────────────────────────────────────────────

-- 5.a  praticiens : on AJOUTE l'accès admin, sans toucher aux trois
--      policies existantes du praticien sur sa propre ligne.
drop policy if exists "admin gere les praticiens" on public.praticiens;
create policy "admin gere les praticiens"
  on public.praticiens
  for all
  to authenticated
  using (public.is_admin())
  with check (public.is_admin());


-- 5.b  organismes : table nouvelle, RLS activée d'office.
--      Lecture publique des organismes actifs (le catalogue public
--      affiche leur nom), écriture réservée à l'admin.
alter table public.organismes enable row level security;

drop policy if exists "organismes lisibles par tous" on public.organismes;
create policy "organismes lisibles par tous"
  on public.organismes
  for select
  to anon, authenticated
  using (actif);

drop policy if exists "admin gere les organismes" on public.organismes;
create policy "admin gere les organismes"
  on public.organismes
  for all
  to authenticated
  using (public.is_admin())
  with check (public.is_admin());


-- 5.c  sessions_formation : idem.
alter table public.sessions_formation enable row level security;

drop policy if exists "sessions lisibles par tous" on public.sessions_formation;
create policy "sessions lisibles par tous"
  on public.sessions_formation
  for select
  to anon, authenticated
  using (actif);

drop policy if exists "admin gere les sessions" on public.sessions_formation;
create policy "admin gere les sessions"
  on public.sessions_formation
  for all
  to authenticated
  using (public.is_admin())
  with check (public.is_admin());


-- 5.d  formations : table préexistante, dont je ne connais pas l'état
--      RLS. On se contente d'AJOUTER la policy admin, sans toucher à
--      l'activation ni à la lecture publique déjà en place.
drop policy if exists "admin gere les formations" on public.formations;
create policy "admin gere les formations"
  on public.formations
  for all
  to authenticated
  using (public.is_admin())
  with check (public.is_admin());

-- À vérifier une fois, car le catalogue public lit formations sans être
-- connecté et filtre désormais sur statut = 'publie' :
--
--   select relrowsecurity from pg_class
--   where oid = 'public.formations'::regclass;
--
--   select policyname, cmd, roles, qual
--   from pg_policies
--   where schemaname = 'public' and tablename = 'formations';
--
-- Si RLS est active et qu'aucune policy ne laisse anon lire, le
-- catalogue public est vide. Dans ce cas, et dans ce cas seulement :
--
-- drop policy if exists "formations publiees lisibles par tous" on public.formations;
-- create policy "formations publiees lisibles par tous"
--   on public.formations
--   for select
--   to anon, authenticated
--   using (statut = 'publie');


-- ───────────────────────────────────────────────────────────────────
-- 6. Migration des formations existantes
--
-- Piloté par les données : les organismes sont créés à partir des
-- valeurs réellement présentes dans formations.organisme, quelles
-- qu'elles soient. Rien n'est codé en dur.
--
-- Les trois étapes sont idempotentes : relancer ne crée pas de
-- doublon et n'écrase pas un rattachement déjà fait à la main.
-- ───────────────────────────────────────────────────────────────────

-- 6.a  Un organisme par valeur distincte.
insert into public.organismes (nom, type)
select distinct btrim(f.organisme), 'formation'
from public.formations f
where coalesce(btrim(f.organisme), '') <> ''
on conflict (nom) do nothing;

-- 6.b  Rattachement, uniquement pour les formations pas encore liées.
update public.formations f
set organisme_id = o.id
from public.organismes o
where o.nom = btrim(f.organisme)
  and f.organisme_id is null;

-- 6.c  statut déduit de actif, uniquement pour les lignes pas encore
--      migrées (statut is null), puis on fige défaut et not null.
update public.formations
set statut = case when coalesce(actif, true) then 'publie' else 'archive' end
where statut is null;

alter table public.formations alter column statut set default 'brouillon';
alter table public.formations alter column statut set not null;


-- Contrôle de la migration : doit renvoyer 0 ligne.
-- select id, titre, organisme
-- from public.formations
-- where organisme_id is null and coalesce(btrim(organisme), '') <> '';


-- Une fois la migration vérifiée et le site repassé en revue, la
-- colonne texte devenue redondante peut partir. Irréversible : à ne
-- lancer qu'après avoir confirmé que tout s'affiche correctement.
--
-- alter table public.formations drop column organisme;


-- ───────────────────────────────────────────────────────────────────
-- 7. Bootstrap du premier admin        ← À FAIRE, SINON PAS D'ACCÈS
--
-- Aucun compte n'est admin par défaut.
--
-- ⚠ À FAIRE D'ABORD : inscris-toi sur le site avec
-- ryad.bouharaoua@gmail.com. Tant que ce compte n'existe pas, il n'y a
-- aucune ligne à passer en admin et l'UPDATE ci-dessous ne fera rien
-- (il ne renverra pas d'erreur, juste « UPDATE 0 » — d'où le contrôle
-- juste après, qui doit renvoyer exactement une ligne).
--
-- Vérifier que la ligne existe avant de lancer l'UPDATE :
-- select id, nom, email, role
-- from public.praticiens
-- where email = 'ryad.bouharaoua@gmail.com';
-- ───────────────────────────────────────────────────────────────────

-- update public.praticiens
-- set role = 'admin'
-- where email = 'ryad.bouharaoua@gmail.com';

-- Contrôle : doit renvoyer ta ligne, et elle seule.
-- select id, nom, email, role from public.praticiens where role = 'admin';

-- Note : après ce passage en admin, déconnecte-toi et reconnecte-toi
-- sur le site. Le front lit le rôle au chargement du profil, un onglet
-- déjà ouvert continue de te voir en 'praticien'.


-- ───────────────────────────────────────────────────────────────────
-- 8. Vérifications
-- ───────────────────────────────────────────────────────────────────

-- is_admin() est bien SECURITY DEFINER (prosecdef = true) et stable :
-- select proname, prosecdef, provolatile, proconfig
-- from pg_proc where proname = 'is_admin';

-- Les policies en place sur les quatre tables :
-- select tablename, policyname, cmd, roles
-- from pg_policies
-- where schemaname = 'public'
--   and tablename in ('praticiens', 'organismes', 'formations', 'sessions_formation')
-- order by tablename, policyname;

-- Répartition des formations après migration :
-- select statut, count(*) from public.formations group by statut;
-- select o.nom, count(f.id) as formations
-- from public.organismes o
-- left join public.formations f on f.organisme_id = o.id
-- group by o.nom order by formations desc;
