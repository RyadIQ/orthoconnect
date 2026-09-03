-- ═══════════════════════════════════════════════════════════════════
-- OrthoConnect — refonte de l'emploi
-- ═══════════════════════════════════════════════════════════════════
--
-- À exécuter à la main dans Supabase > SQL Editor, APRÈS
-- admin_et_organismes.sql (dépend de is_admin() et de praticiens).
--
-- Relançable sans dégât, à une exception près, signalée : le DELETE
-- de la section 2 vide la table.
--
-- ORDRE DE LECTURE
--   1. colonnes
--   2. suppression des annonces fictives     ← destructif
--   3. contraintes et index
--   4. updated_at
--   5. vue publique sans coordonnées
--   6. POLICIES ET DROITS
--   7. vérifications
--
-- LES COORDONNÉES NE DOIVENT PAS FUIR
-- Même principe que pour le tarif négocié : masquer les coordonnées à
-- l'affichage ne suffit pas, elles partiraient dans la réponse JSON.
-- La vue de la section 5 ne les expose pas, et la section 6 retire à
-- anon le droit de lire la table.
-- ═══════════════════════════════════════════════════════════════════


-- ───────────────────────────────────────────────────────────────────
-- 1. Colonnes
--
-- auteur_id est nullable : une annonce saisie en admin n'a pas de
-- praticien derrière. « on delete set null » plutôt que cascade, pour
-- qu'un compte supprimé n'emporte pas les annonces déjà diffusées.
--
-- publie_le existait déjà et reste la date d'affichage. created_at
-- enregistre la création de la ligne, les deux diffèrent dès qu'une
-- annonce est rédigée en brouillon avant d'être publiée.
-- ───────────────────────────────────────────────────────────────────

alter table public.offres_emploi
  add column if not exists auteur_id        uuid,
  add column if not exists departement      text,
  add column if not exists profil_recherche text,
  add column if not exists conditions       text,
  add column if not exists contact_nom      text,
  add column if not exists contact_email    text,
  add column if not exists contact_tel      text,
  add column if not exists statut           text        not null default 'brouillon',
  add column if not exists expire_le        timestamptz not null default now() + interval '90 days',
  add column if not exists created_at       timestamptz not null default now(),
  add column if not exists updated_at       timestamptz not null default now();

alter table public.offres_emploi
  drop constraint if exists offres_emploi_auteur_fk;
alter table public.offres_emploi
  add constraint offres_emploi_auteur_fk
  foreign key (auteur_id) references public.praticiens (id) on delete set null;


-- ───────────────────────────────────────────────────────────────────
-- 2. Suppression des annonces fictives          ⚠ DESTRUCTIF
--
-- Regarde ce qui va partir avant de lancer le DELETE :
--
--   select id, titre, cabinet, ville, publie_le from public.offres_emploi
--   order by id;
--
-- La table ne contient que les cinq annonces de démonstration. Si tu
-- as déjà saisi de vraies annonces, remplace par un DELETE cible sur
-- leurs identifiants.
-- ───────────────────────────────────────────────────────────────────

delete from public.offres_emploi;


-- ───────────────────────────────────────────────────────────────────
-- 3. Contraintes et index
--
-- Posés APRÈS le DELETE : les anciennes lignes portaient des libellés
-- de contrat en texte libre, qui auraient fait échouer la contrainte.
-- ───────────────────────────────────────────────────────────────────

alter table public.offres_emploi
  drop constraint if exists offres_emploi_type_check;
alter table public.offres_emploi
  add constraint offres_emploi_type_check
  check (type_contrat in (
    'collaboration_liberale',
    'collaboration_salariee',
    'remplacement',
    'association',
    'cession',
    'assistant_dentaire',
    'autre'
  ));

alter table public.offres_emploi
  drop constraint if exists offres_emploi_statut_check;
alter table public.offres_emploi
  add constraint offres_emploi_statut_check
  check (statut in ('brouillon', 'publiee', 'pourvue', 'expiree'));

comment on column public.offres_emploi.statut is
  'brouillon | publiee | pourvue | expiree. Une annonce dont expire_le est dépassé est traitée comme expirée à la lecture, sans attendre une mise à jour du statut.';

create index if not exists offres_emploi_auteur_idx  on public.offres_emploi (auteur_id);
create index if not exists offres_emploi_statut_idx  on public.offres_emploi (statut, expire_le desc);
create index if not exists offres_emploi_dept_idx    on public.offres_emploi (departement);
create index if not exists offres_emploi_type_idx    on public.offres_emploi (type_contrat);


-- ───────────────────────────────────────────────────────────────────
-- 4. updated_at
--
-- Une colonne updated_at sans trigger ne dit pas la vérité : elle
-- garderait la date de création. Le trigger la tient à jour.
-- ───────────────────────────────────────────────────────────────────

create or replace function public.touch_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

drop trigger if exists offres_emploi_updated_at on public.offres_emploi;
create trigger offres_emploi_updated_at
  before update on public.offres_emploi
  for each row
  execute function public.touch_updated_at();


-- ───────────────────────────────────────────────────────────────────
-- 5. Vue publique, sans coordonnées
--
-- Le visiteur non connecté voit l'annonce entière : intitulé, cabinet,
-- ville, description, profil recherché, conditions. Seules les trois
-- colonnes de contact manquent, remplacées par un booléen a_contact
-- qui permet de n'afficher le bloc que s'il y a quelque chose à
-- montrer une fois connecté.
--
-- Le filtre d'expiration est écrit ici : une annonce périmée
-- disparaît d'elle-même du catalogue public, sans tâche planifiée.
--
-- Si ton Postgres est antérieur à la 15, retire la clause « with
-- (security_invoker = false) », le comportement par défaut est le même.
-- ───────────────────────────────────────────────────────────────────

drop view if exists public.offres_emploi_publiques;

create view public.offres_emploi_publiques
with (security_invoker = false) as
select
  id,
  titre,
  cabinet,
  ville,
  departement,
  type_contrat,
  description,
  profil_recherche,
  conditions,
  statut,
  publie_le,
  expire_le,
  created_at,
  (coalesce(contact_email, contact_tel, contact_nom) is not null) as a_contact
from public.offres_emploi
where statut = 'publiee'
  and expire_le > now();

comment on view public.offres_emploi_publiques is
  'Annonces lisibles sans être connecté. N''expose aucune coordonnée, seulement le booléen a_contact.';

grant select on public.offres_emploi_publiques to anon, authenticated;


-- ───────────────────────────────────────────────────────────────────
-- 6. POLICIES ET DROITS
--
-- État actuel, à regarder d'abord :
--
--   select relrowsecurity from pg_class
--   where oid = 'public.offres_emploi'::regclass;
--
--   select policyname, cmd, roles, qual
--   from pg_policies
--   where schemaname = 'public' and tablename = 'offres_emploi';
-- ───────────────────────────────────────────────────────────────────

-- 6.a  Couper la lecture anonyme de la TABLE : c'est ce qui empêche
--      /rest/v1/offres_emploi?select=* de renvoyer les coordonnées.
revoke select on public.offres_emploi from anon;

-- Toute policy de lecture ouverte à anon rouvrirait le chemin. Adapte
-- le nom si la tienne s'appelle autrement.
drop policy if exists "offres lisibles par tous" on public.offres_emploi;
drop policy if exists "offres_emploi lisibles par tous" on public.offres_emploi;

-- ⚠ Si relrowsecurity vaut false, l'activer restreint la table aux
-- seules lignes couvertes par une policy. Les trois qui suivent
-- couvrent les cas connus : praticien lecteur, praticien auteur, admin.
alter table public.offres_emploi enable row level security;

-- 6.b  Tout praticien connecté lit les annonces publiées et non
--      expirées, coordonnées comprises. C'est là que passent les
--      contacts.
drop policy if exists "annonces publiees lisibles par les praticiens" on public.offres_emploi;
create policy "annonces publiees lisibles par les praticiens"
  on public.offres_emploi
  for select
  to authenticated
  using (statut = 'publiee' and expire_le > now());

-- 6.c  Un praticien gère les siennes, quel que soit leur statut :
--      c'est ce qui lui donne accès à ses brouillons et à ses annonces
--      pourvues, invisibles pour les autres.
drop policy if exists "praticien gere ses annonces" on public.offres_emploi;
create policy "praticien gere ses annonces"
  on public.offres_emploi
  for all
  to authenticated
  using (auteur_id = auth.uid())
  with check (auteur_id = auth.uid());

-- 6.d  L'admin gère tout, y compris les annonces sans auteur.
drop policy if exists "admin gere les annonces" on public.offres_emploi;
create policy "admin gere les annonces"
  on public.offres_emploi
  for all
  to authenticated
  using (public.is_admin())
  with check (public.is_admin());


-- ───────────────────────────────────────────────────────────────────
-- 7. Vérifications
-- ───────────────────────────────────────────────────────────────────

-- La vue n'expose aucune coordonnée (contact_* ne doit PAS y être) :
-- select column_name from information_schema.columns
-- where table_schema = 'public' and table_name = 'offres_emploi_publiques'
-- order by column_name;

-- anon n'a plus de droit sur la table, et garde le select sur la vue :
-- select table_name, privilege_type
-- from information_schema.role_table_grants
-- where grantee = 'anon' and table_schema = 'public'
--   and table_name in ('offres_emploi', 'offres_emploi_publiques');

-- La table est bien vide après le DELETE :
-- select count(*) from public.offres_emploi;

-- Répartition une fois des annonces saisies :
-- select statut, count(*) from public.offres_emploi group by statut;
-- select type_contrat, count(*) from public.offres_emploi
-- where statut = 'publiee' group by type_contrat order by 2 desc;

-- Annonces qui expirent dans moins de 15 jours :
-- select id, titre, expire_le from public.offres_emploi
-- where statut = 'publiee' and expire_le between now() and now() + interval '15 days'
-- order by expire_le;

-- Alignement des statuts sur les dates. L'affichage traite déjà ces
-- annonces comme expirées ; cet UPDATE ne fait que ranger la base.
-- update public.offres_emploi set statut = 'expiree'
-- where statut = 'publiee' and expire_le <= now();

-- LE TEST QUI COMPTE, hors SQL Editor, en navigation privée :
--   .../rest/v1/offres_emploi?select=*            -> refusé
--   .../rest/v1/offres_emploi_publiques?select=*  -> répond, sans
--                                                    aucun contact_*
