-- ═══════════════════════════════════════════════════════════════════
-- OrthoConnect — le tarif négocié ne sort plus de la base
-- ═══════════════════════════════════════════════════════════════════
--
-- À exécuter à la main dans Supabase > SQL Editor, APRÈS
-- tarif_prefere.sql.
--
-- LE PROBLÈME
-- Le catalogue public faisait « select * » sur formations. Retirer le
-- montant du HTML ne changeait rien : la colonne tarif_prefere partait
-- quand même dans la réponse JSON, lisible dans l'onglet réseau. Et
-- lister les colonnes côté navigateur n'y aurait rien changé non plus,
-- puisque n'importe qui peut rappeler l'API REST avec select=*.
--
-- LA CORRECTION
-- Une vue qui n'expose pas la colonne, et le retrait du droit de
-- lecture anonyme sur la table. Le visiteur non connecté n'a plus
-- aucun chemin vers tarif_prefere ; le praticien connecté lit la
-- table et voit le montant.
--
-- La vue expose un booléen a_tarif_prefere : l'encart « un tarif
-- négocié existe » doit pouvoir s'afficher sans révéler le montant.
--
-- ORDRE DE LECTURE
--   1. vue formations_publiques
--   2. POLICIES QUI CHANGENT          ← la partie à lire
--   3. policies du programme, à réécrire
--   4. vérifications
-- ═══════════════════════════════════════════════════════════════════


-- ───────────────────────────────────────────────────────────────────
-- 1. La vue
--
-- security_invoker = false (le défaut) : la vue lit la table avec les
-- droits de son propriétaire, donc sans passer par la RLS de
-- formations. C'est voulu — c'est ce qui permet à anon de lire la vue
-- alors qu'on lui retire l'accès à la table juste après. Le filtre
-- « statut = 'publie' » écrit ici devient donc la seule barrière, et
-- il est le seul nécessaire.
--
-- Si ton Postgres est antérieur à la 15, l'option n'existe pas :
-- retire simplement la clause « with (...) », le comportement par
-- défaut est identique.
--
-- Colonnes volontairement ABSENTES : tarif_prefere et
-- conditions_tarif. Tout le reste de la fiche est public.
-- ───────────────────────────────────────────────────────────────────

drop view if exists public.formations_publiques;

create view public.formations_publiques
with (security_invoker = false) as
select
  f.id,
  f.titre,
  f.description,
  f.format,
  f.duree,
  f.prix,
  f.dpc,
  f.dpc_numero,
  f.thematique,
  f.niveau,
  f.prerequis,
  f.objectifs,
  f.inclus,
  f.participants_max,
  f.formateur_nom,
  f.formateur_titre,
  f.formateur_bio,
  f.formateur_photo_url,
  f.url_source,
  f.url_inscription,
  f.verifie_le,
  f.statut,
  f.organisme_id,

  -- Le fait qu'un tarif existe, jamais son montant.
  (f.tarif_prefere is not null) as a_tarif_prefere,

  -- L'organisme est aplati dans la vue plutôt que laissé à une
  -- jointure imbriquée : PostgREST sait parfois deviner la relation
  -- au travers d'une vue, mais ça dépend de sa version. Aplatir rend
  -- le résultat certain. Le front recompose l'objet.
  o.nom        as organisme_nom,
  o.logo_url   as organisme_logo_url,
  o.partenaire as organisme_partenaire,
  o.site_web   as organisme_site_web
from public.formations f
left join public.organismes o on o.id = f.organisme_id
where f.statut = 'publie';

comment on view public.formations_publiques is
  'Catalogue lisible sans être connecté. N''expose ni tarif_prefere ni conditions_tarif, seulement le booléen a_tarif_prefere.';

grant select on public.formations_publiques to anon, authenticated;


-- ───────────────────────────────────────────────────────────────────
-- 2. POLICIES ET DROITS QUI CHANGENT
--
-- Regarde d'abord l'état actuel, la suite en dépend :
--
--   select relrowsecurity from pg_class
--   where oid = 'public.formations'::regclass;
--
--   select policyname, cmd, roles, qual
--   from pg_policies
--   where schemaname = 'public' and tablename = 'formations';
--
-- Deux choses à faire, dans cet ordre.
-- ───────────────────────────────────────────────────────────────────

-- 2.a  Couper la lecture anonyme de la TABLE. C'est la correction qui
--      compte : sans elle, anon peut toujours appeler
--      /rest/v1/formations?select=* et récupérer le montant.
revoke select on public.formations from anon;

-- Toute policy de lecture ouverte à anon doit disparaître, sinon elle
-- rouvrirait le chemin dès qu'un grant serait rétabli. Adapte le nom
-- si la tienne s'appelle autrement (la requête pg_policies ci-dessus
-- te le dit).
drop policy if exists "formations publiees lisibles par tous" on public.formations;

-- 2.b  La table reste lisible par les praticiens connectés : c'est là
--      qu'ils obtiennent le tarif négocié.
--
-- ⚠ Si relrowsecurity vaut false, l'activer ci-dessous change le
-- comportement de la table : à partir de là, seules les lignes
-- couvertes par une policy sont visibles. Les deux policies qui
-- suivent couvrent les cas connus (praticien connecté, admin), mais
-- vérifie que rien d'autre ne lit formations dans ton projet.
alter table public.formations enable row level security;

drop policy if exists "formations publiees lisibles par les praticiens" on public.formations;
create policy "formations publiees lisibles par les praticiens"
  on public.formations
  for select
  to authenticated
  using (statut = 'publie');

-- Rappel : la policy admin « admin gere les formations » posée dans
-- admin_et_organismes.sql reste en place et s'ajoute en OR, donc
-- l'admin continue de voir brouillons et archives.


-- ───────────────────────────────────────────────────────────────────
-- 3. Policies du programme, à réécrire
--
-- Conséquence directe du 2.a : les policies de programme_sections et
-- programme_sequences testaient « exists (select 1 from formations
-- where statut = 'publie') ». Cette sous-requête s'exécute avec les
-- droits de l'appelant : pour anon, elle ne renvoie plus rien, et le
-- programme disparaîtrait des fiches publiques.
--
-- On les fait pointer vers la vue, qui elle reste lisible par anon.
-- ───────────────────────────────────────────────────────────────────

drop policy if exists "sections des formations publiees" on public.programme_sections;
create policy "sections des formations publiees"
  on public.programme_sections
  for select
  to anon, authenticated
  using (
    exists (
      select 1
      from public.formations_publiques v
      where v.id = programme_sections.formation_id
    )
  );

drop policy if exists "sequences des formations publiees" on public.programme_sequences;
create policy "sequences des formations publiees"
  on public.programme_sequences
  for select
  to anon, authenticated
  using (
    exists (
      select 1
      from public.programme_sections s
      join public.formations_publiques v on v.id = s.formation_id
      where s.id = programme_sequences.section_id
    )
  );


-- ───────────────────────────────────────────────────────────────────
-- 4. Vérifications
-- ───────────────────────────────────────────────────────────────────

-- La vue n'expose pas la colonne (tarif_prefere ne doit PAS y être) :
-- select column_name from information_schema.columns
-- where table_schema = 'public' and table_name = 'formations_publiques'
-- order by column_name;

-- anon n'a plus aucun droit sur la table, et garde le select sur la vue :
-- select table_name, privilege_type
-- from information_schema.role_table_grants
-- where grantee = 'anon' and table_schema = 'public'
--   and table_name in ('formations', 'formations_publiques');

-- LE TEST QUI COMPTE, à faire hors SQL Editor : depuis un navigateur
-- en navigation privée, avec la clé publishable du site.
--
--   .../rest/v1/formations?select=*            -> doit être refusé
--   .../rest/v1/formations_publiques?select=*  -> doit répondre, sans
--                                                 tarif_prefere
--
-- Et sur le site lui-même, déconnecté : la fiche d'une formation à
-- tarif négocié doit afficher l'encart, garder son programme, et
-- l'onglet réseau ne doit contenir aucun montant négocié.
