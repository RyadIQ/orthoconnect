-- ═══════════════════════════════════════════════════════════════════
-- OrthoConnect — la carte de l'emploi
-- ═══════════════════════════════════════════════════════════════════
--
-- À exécuter à la main dans Supabase > SQL Editor, APRÈS emploi.sql et
-- emploi_cabinet_masque.sql : la section 5 recrée la vue publique des
-- annonces telle que ce dernier l'a laissée, en y ajoutant lat et lng.
--
-- Relançable sans dégât : rien n'est détruit, aucune donnée existante
-- n'est modifiée, les colonnes sont toutes ajoutées en « if not exists ».
--
-- ORDRE DE LECTURE
--   1. colonnes de recherche sur praticiens
--   2. lat / lng sur offres_emploi
--   3. contraintes et index
--   4. le décalage déterministe
--   5. offres_emploi_publiques, avec les coordonnées
--   6. praticiens_recherche_publique      ← anonyme, sans identité
--   7. praticiens_recherche_contact       ← connectés, avec identité
--   8. droits
--   9. vérifications
--
-- CE QUI NE DOIT PAS FUIR
-- Même principe que pour les coordonnées d'une annonce et pour le nom
-- du cabinet : masquer un nom à l'écran ne suffit pas, il partirait
-- quand même dans la réponse JSON, lisible par un appel direct à
-- l'API. Un praticien en recherche est donc servi par DEUX vues
-- distinctes, et la table praticiens reste fermée à anon :
--
--   praticiens_recherche_publique  → anon + authenticated
--       ville, position décalée, rayon, statut, types, disponibilité,
--       message, techniques. Ni nom, ni prénom, ni email, ni téléphone,
--       ni position exacte.
--
--   praticiens_recherche_contact   → authenticated SEULEMENT
--       la même chose, plus nom et email, pour la prise de contact
--       entre praticiens.
--
-- LA POSITION EXACTE NE SORT DANS AUCUNE DES DEUX. Le point affiché
-- est décalé de 250 à 700 m par une fonction déterministe : le même
-- praticien retombe toujours au même endroit, mais l'endroit n'est pas
-- le sien. Il indique une zone, pas une adresse.
--
-- Si ton Postgres est antérieur à la 15, retire les clauses « with
-- (security_invoker = false) », le comportement par défaut est le même.
-- ═══════════════════════════════════════════════════════════════════


-- ───────────────────────────────────────────────────────────────────
-- 1. Les colonnes de recherche, sur praticiens
--
-- Elles vivent sur la fiche du praticien plutôt que dans une table à
-- part : un praticien n'a qu'une recherche à la fois, et la bascule
-- en_recherche doit pouvoir se faire sans créer ni détruire de ligne.
--
-- recherche_ville et recherche_lat / lng sont indépendantes de ville
-- et de cabinet_ville : on cherche souvent ailleurs que là où on
-- exerce. Le front pré-remplit avec la ville du profil, sans l'imposer.
-- ───────────────────────────────────────────────────────────────────

alter table public.praticiens
  add column if not exists en_recherche           boolean not null default false,
  add column if not exists recherche_ville        text,
  add column if not exists recherche_lat          double precision,
  add column if not exists recherche_lng          double precision,
  add column if not exists recherche_rayon_km     integer not null default 30,
  add column if not exists recherche_departements text[],
  add column if not exists recherche_types        text[],
  add column if not exists recherche_disponibilite text,
  add column if not exists recherche_message      text,
  add column if not exists recherche_maj_le       timestamptz;

comment on column public.praticiens.en_recherche is
  'Le praticien se déclare en recherche et accepte de figurer sur la carte publique. Il peut le désactiver à tout moment : la ligne reste, les critères aussi, seul le booléen retombe à false.';
comment on column public.praticiens.recherche_lat is
  'Coordonnée réelle de la ville de recherche. NE SORT JAMAIS : les vues publient une position décalée, calculée par decalage_carte().';
comment on column public.praticiens.recherche_departements is
  'Départements supplémentaires acceptés, en plus du rayon autour de la ville. Codes à deux ou trois caractères : 69, 01, 2A, 974.';
comment on column public.praticiens.recherche_maj_le is
  'Date de la dernière activation. Sert à repérer les recherches qui traînent : un profil activé il y a un an n''est probablement plus d''actualité.';


-- ───────────────────────────────────────────────────────────────────
-- 2. lat / lng sur offres_emploi
--
-- Géocodées à la publication depuis la ville saisie, par l'API Adresse
-- du gouvernement. C'est un centre de commune, jamais une adresse de
-- cabinet : le décalage de la section 4 leur est quand même appliqué,
-- pour une autre raison — sans lui, deux annonces déposées dans la
-- même ville se superposeraient exactement sur la carte et la seconde
-- serait inatteignable au clic.
-- ───────────────────────────────────────────────────────────────────

alter table public.offres_emploi
  add column if not exists lat double precision,
  add column if not exists lng double precision;

comment on column public.offres_emploi.lat is
  'Latitude du centre de la commune, géocodée à la publication. Nulle sur les annonces antérieures à la carte : elles restent dans la liste, elles n''ont simplement pas de point.';


-- ───────────────────────────────────────────────────────────────────
-- 3. Contraintes et index
--
-- La contrainte de localisation est la seule barrière côté base : sans
-- coordonnées, un praticien « en recherche » serait invisible sur la
-- carte sans savoir pourquoi. Mieux vaut refuser l'activation.
-- ───────────────────────────────────────────────────────────────────

alter table public.praticiens
  drop constraint if exists praticiens_recherche_types_check;
alter table public.praticiens
  add constraint praticiens_recherche_types_check
  check (recherche_types is null or recherche_types <@ array[
    'collaboration_liberale',
    'collaboration_salariee',
    'remplacement',
    'association'
  ]::text[]);

alter table public.praticiens
  drop constraint if exists praticiens_recherche_rayon_check;
alter table public.praticiens
  add constraint praticiens_recherche_rayon_check
  check (recherche_rayon_km between 5 and 300);

alter table public.praticiens
  drop constraint if exists praticiens_recherche_localisee_check;
alter table public.praticiens
  add constraint praticiens_recherche_localisee_check
  check (
    not en_recherche
    or (recherche_ville is not null and recherche_lat is not null and recherche_lng is not null)
  );

-- Index partiel : la carte ne lit que les lignes à true, et elles
-- resteront une petite minorité de la table.
create index if not exists praticiens_en_recherche_idx
  on public.praticiens (en_recherche) where en_recherche;

create index if not exists offres_emploi_geo_idx
  on public.offres_emploi (lat, lng) where lat is not null;


-- ───────────────────────────────────────────────────────────────────
-- 4. Le décalage déterministe
--
-- Rend un array [lat, lng] déplacé de 250 à 700 m dans une direction
-- tirée de la clé. Deux propriétés comptent :
--
--   déterministe — même clé, même résultat, à jamais. Le praticien ne
--     se déplace pas d'un chargement de carte à l'autre, ce qui serait
--     à la fois déroutant et, par recoupement de plusieurs tirages,
--     une façon de retrouver le centre exact.
--
--   non réversible en pratique — le décalage vient d'un md5 de
--     l'identifiant, pas d'un aléa stocké : il n'existe nulle part de
--     colonne « écart appliqué » qui fuirait avec le reste.
--
-- La distance reste inférieure au rayon de recherche le plus petit
-- (5 km) : le point garde son sens, il désigne la bonne commune.
--
-- 111 320 m est la longueur d'un degré de latitude ; en longitude elle
-- se resserre avec le cosinus de la latitude. Le greatest() évite la
-- division par zéro aux pôles, hors de portée de nos communes mais
-- gratuit à écrire.
--
-- IMMUTABLE : indispensable pour que la fonction soit utilisable dans
-- une vue sans recalcul imprévisible, et pour indexer si besoin.
-- ───────────────────────────────────────────────────────────────────

create or replace function public.decalage_carte(
  p_lat double precision,
  p_lng double precision,
  p_cle text
)
returns double precision[]
language sql
immutable
as $$
  select case
    when p_lat is null or p_lng is null then null
    else array[
      p_lat + (t.dist / 111320.0) * cos(t.angle),
      p_lng + (t.dist / (111320.0 * greatest(cos(radians(p_lat)), 0.2))) * sin(t.angle)
    ]
  end
  from (
    select
      -- 'x0' + 7 chiffres hexadécimaux : 28 bits, toujours positifs.
      -- Sur 32 bits, le cast rendrait un entier signé, donc négatif une
      -- fois sur deux, et le modulo suivant serait faux.
      (('x0' || substr(md5('orthoconnect-carte:' || coalesce(p_cle, '')), 1, 7))::bit(32)::int % 3600)
        * pi() / 1800.0 as angle,
      250 + (('x0' || substr(md5('orthoconnect-carte:' || coalesce(p_cle, '')), 9, 7))::bit(32)::int % 451)
        as dist
  ) t;
$$;

comment on function public.decalage_carte(double precision, double precision, text) is
  'Déplace un point de 250 à 700 m dans une direction déterminée par la clé. Déterministe : même clé, même point. Sert à publier une zone plutôt qu''une adresse.';


-- ───────────────────────────────────────────────────────────────────
-- 5. offres_emploi_publiques, avec les coordonnées
--
-- Reprise à l'identique de emploi_cabinet_masque.sql — ni cabinet ni
-- contact_* — avec lat et lng décalés en plus. Si tu as modifié cette
-- vue depuis, reporte tes changements ici : c'est cette définition-là
-- qui restera en place.
-- ───────────────────────────────────────────────────────────────────

drop view if exists public.offres_emploi_publiques;

create view public.offres_emploi_publiques
with (security_invoker = false) as
select
  id,
  titre,
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
  (public.decalage_carte(lat, lng, 'offre-' || id::text))[1] as lat,
  (public.decalage_carte(lat, lng, 'offre-' || id::text))[2] as lng,
  (cabinet is not null) as a_cabinet,
  (coalesce(contact_email, contact_tel, contact_nom) is not null) as a_contact
from public.offres_emploi
where statut = 'publiee'
  and expire_le > now();

comment on view public.offres_emploi_publiques is
  'Annonces lisibles sans être connecté. N''expose ni le nom du cabinet ni aucune coordonnée, seulement les booléens a_cabinet et a_contact. lat / lng sont décalés, comme sur la carte des praticiens.';


-- ───────────────────────────────────────────────────────────────────
-- 6. praticiens_recherche_publique
--
-- Ce que voit un visiteur non connecté. Les colonnes absentes sont
-- aussi importantes que celles présentes : ni nom, ni email, ni
-- téléphone, ni rpps, ni cabinet_nom, ni recherche_lat / lng brutes.
--
-- L'identifiant sort, lui : il est nécessaire au clic sur un point, et
-- il ne désigne personne tant que la table reste fermée à anon
-- (section 8). C'est le même compromis que sur les annonces.
--
-- La position exacte ne sert qu'au calcul du décalage, à l'intérieur
-- de la vue, et n'apparaît dans aucune colonne rendue.
-- ───────────────────────────────────────────────────────────────────

drop view if exists public.praticiens_recherche_publique;

create view public.praticiens_recherche_publique
with (security_invoker = false) as
select
  p.id,
  p.recherche_ville                                                as ville,
  (public.decalage_carte(p.recherche_lat, p.recherche_lng, 'praticien-' || p.id::text))[1] as lat,
  (public.decalage_carte(p.recherche_lat, p.recherche_lng, 'praticien-' || p.id::text))[2] as lng,
  p.recherche_rayon_km                                             as rayon_km,
  p.statut,
  p.recherche_departements                                         as departements,
  p.recherche_types                                                as types,
  p.recherche_disponibilite                                        as disponibilite,
  p.recherche_message                                              as message,
  p.techniques,
  p.recherche_maj_le                                               as maj_le
from public.praticiens p
where p.en_recherche
  and p.recherche_lat is not null
  and p.recherche_lng is not null;

comment on view public.praticiens_recherche_publique is
  'Praticiens en recherche, vus par un visiteur non connecté. Aucun nom, aucune coordonnée, aucune position exacte : lat / lng sont décalés de quelques centaines de mètres, de façon stable.';


-- ───────────────────────────────────────────────────────────────────
-- 7. praticiens_recherche_contact
--
-- La même chose pour un praticien connecté, nom et email en plus :
-- c'est par là que passe la mise en relation. Mêmes colonnes, mêmes
-- noms, dans le même ordre, pour que le front puisse basculer d'une
-- source à l'autre sans rien changer à son rendu.
--
-- Le téléphone n'y est pas : l'email suffit à une première prise de
-- contact, et un praticien qui se déclare en recherche ne s'attend pas
-- à être appelé par des inconnus. Il donnera son numéro s'il le veut,
-- dans sa réponse.
--
-- La position reste décalée ici aussi. Être connecté donne le droit de
-- joindre quelqu'un, pas celui de savoir où il habite.
-- ───────────────────────────────────────────────────────────────────

drop view if exists public.praticiens_recherche_contact;

create view public.praticiens_recherche_contact
with (security_invoker = false) as
select
  p.id,
  p.recherche_ville                                                as ville,
  (public.decalage_carte(p.recherche_lat, p.recherche_lng, 'praticien-' || p.id::text))[1] as lat,
  (public.decalage_carte(p.recherche_lat, p.recherche_lng, 'praticien-' || p.id::text))[2] as lng,
  p.recherche_rayon_km                                             as rayon_km,
  p.statut,
  p.recherche_departements                                         as departements,
  p.recherche_types                                                as types,
  p.recherche_disponibilite                                        as disponibilite,
  p.recherche_message                                              as message,
  p.techniques,
  p.recherche_maj_le                                               as maj_le,
  p.nom,
  p.email
from public.praticiens p
where p.en_recherche
  and p.recherche_lat is not null
  and p.recherche_lng is not null;

comment on view public.praticiens_recherche_contact is
  'Praticiens en recherche, vus par un praticien connecté : nom et email en plus. Réservée à authenticated, jamais accordée à anon. La position reste décalée.';


-- ───────────────────────────────────────────────────────────────────
-- 8. DROITS
--
-- État actuel, à regarder d'abord :
--
--   select grantee, table_name, privilege_type
--   from information_schema.role_table_grants
--   where table_schema = 'public' and grantee in ('anon', 'authenticated')
--     and table_name like 'praticiens%'
--   order by grantee, table_name;
-- ───────────────────────────────────────────────────────────────────

-- 8.a  La table reste fermée à anon. RLS la couvrait déjà — les
--      policies existantes tiennent toutes sur auth.uid(), nul pour un
--      visiteur — mais un droit retiré est plus solide qu'une policy
--      qu'un ajout maladroit rouvrirait.
revoke select on public.praticiens from anon;

-- 8.b  Les deux vues, chacune à son public. Le revoke sur la vue de
--      contact est explicite plutôt que sous-entendu : c'est la ligne
--      qui empêche un visiteur d'obtenir les noms par un appel direct
--      à /rest/v1/praticiens_recherche_contact.
grant select on public.praticiens_recherche_publique to anon, authenticated;

revoke all on public.praticiens_recherche_contact from anon;
grant select on public.praticiens_recherche_contact to authenticated;

-- 8.c  Rien à ajouter côté RLS : « praticien modifie son profil »
--      (auth.uid() = id) couvre déjà l'activation et les critères, et
--      « admin gere les praticiens » couvre le suivi en administration.


-- ───────────────────────────────────────────────────────────────────
-- 9. Vérifications
-- ───────────────────────────────────────────────────────────────────

-- Les colonnes de la vue publique. Aucun nom, aucun email, aucun
-- recherche_lat : si l'un d'eux apparaît, ne déploie pas.
-- select column_name from information_schema.columns
-- where table_schema = 'public' and table_name = 'praticiens_recherche_publique'
-- order by column_name;

-- Qui a le droit de lire quoi. anon ne doit apparaître que sur
-- praticiens_recherche_publique :
-- select grantee, table_name, privilege_type
-- from information_schema.role_table_grants
-- where table_schema = 'public' and grantee in ('anon', 'authenticated')
--   and table_name in ('praticiens', 'praticiens_recherche_publique',
--                      'praticiens_recherche_contact')
-- order by grantee, table_name;

-- Le décalage est bien stable et de l'ordre annoncé. La distance doit
-- tomber entre 250 et 700 m, et deux exécutions doivent donner le même
-- point :
-- select p.id, p.recherche_ville,
--        round((6371000 * acos(least(1,
--          sin(radians(p.recherche_lat)) * sin(radians(v.lat)) +
--          cos(radians(p.recherche_lat)) * cos(radians(v.lat)) *
--          cos(radians(v.lng - p.recherche_lng))
--        )))::numeric) as ecart_m
-- from public.praticiens p
-- join public.praticiens_recherche_publique v on v.id = p.id
-- where p.en_recherche;

-- Combien de praticiens en recherche, et depuis quand :
-- select count(*) as en_recherche,
--        count(*) filter (where recherche_maj_le < now() - interval '6 months') as a_relancer
-- from public.praticiens where en_recherche;

-- Les annonces publiées qui n'ont pas de point sur la carte, faute
-- d'avoir été géocodées — celles d'avant la carte, essentiellement.
-- Les rouvrir et les réenregistrer suffit à les localiser :
-- select id, titre, ville from public.offres_emploi
-- where statut = 'publiee' and expire_le > now() and lat is null;

-- LE TEST QUI COMPTE, hors SQL Editor, en navigation privée :
--   .../rest/v1/praticiens?select=*                        -> refusé
--   .../rest/v1/praticiens_recherche_contact?select=*      -> refusé
--   .../rest/v1/praticiens_recherche_publique?select=*     -> répond,
--       sans nom, sans email, et avec des lat / lng qui ne sont
--       celles d'aucune mairie.
