-- ═══════════════════════════════════════════════════════════════════
-- OrthoConnect — le détail d'une annonce passe derrière l'inscription
-- ═══════════════════════════════════════════════════════════════════
--
-- À exécuter à la main dans Supabase > SQL Editor. Ce fichier ne fait
-- que remplacer la vue offres_emploi_publiques : rien n'est détruit,
-- aucune donnée n'est modifiée, la table garde toutes ses colonnes.
--
-- PRÉREQUIS, parce que la vue les utilise
--   slugs_et_urls.sql   pour la colonne slug
--   carte_emploi.sql    pour la fonction decalage_carte()
--
-- POURQUOI
-- Masquer le cabinet et les coordonnées ne suffisait pas. Description,
-- profil recherché et conditions sont des textes libres : un praticien
-- y écrit « appelez-moi au 06... », « le cabinet Dupont recrute »,
-- « adresse : 12 rue de la Paix ». Tout ce qu'on avait retiré des
-- colonnes dédiées revenait par là, et partait dans la réponse JSON
-- servie à n'importe quel visiteur.
--
-- On cesse donc d'arbitrer texte par texte : le détail d'une annonce
-- devient réservé aux praticiens inscrits, et la vue publique s'arrête
-- à ce qui sert à repérer l'offre — de quoi la lister, la situer sur
-- la carte et lui donner une adresse.
--
-- CE QUI RESTE PUBLIC
--   id, slug, titre, ville, departement, type_contrat,
--   statut, publie_le, expire_le, created_at, lat, lng
--
-- CE QUI NE SORT PLUS
--   description, profil_recherche, conditions
--   a_cabinet, a_contact — ces deux booléens ne servaient qu'à poser
--     une mention sur la fiche publique, qui n'existe plus
--   et, depuis emploi_cabinet_masque.sql, cabinet et contact_*
--
-- LE SLUG REVIENT. carte_emploi.sql avait recréé cette vue à partir de
-- la définition d'emploi_cabinet_masque.sql, antérieure à
-- slugs_et_urls.sql : la colonne slug y avait été perdue. Un visiteur
-- non connecté retombait sur le slug calculé depuis le titre, ce qui
-- ne tombe juste que tant qu'aucun suffixe anti-collision n'a été
-- attribué. Elle est rétablie ici.
--
-- LA LIMITE, ASSUMÉE
-- Le titre reste public : c'est lui qui fait la liste et l'URL. Un
-- praticien qui écrit « Collab chez Dupont Orthodontie » se nomme
-- lui-même. Le formulaire de publication l'en dissuade par une note,
-- et cette note reste.
--
-- Si ton Postgres est antérieur à la 15, retire la clause « with
-- (security_invoker = false) », le comportement par défaut est le même.
-- ═══════════════════════════════════════════════════════════════════


-- ───────────────────────────────────────────────────────────────────
-- 1. La vue publique, réduite au repérage
--
-- Les praticiens connectés ne passent pas par ici : le front lit la
-- table pour eux, où la policy « annonces publiees lisibles par les
-- praticiens » (emploi.sql, section 6.b) leur donne l'annonce entière,
-- coordonnées comprises. Cette vue ne sert qu'aux visiteurs.
--
-- lat / lng restent décalés par decalage_carte(), comme sur la carte
-- des praticiens : deux annonces d'une même ville doivent rester
-- distinctes au clic.
-- ───────────────────────────────────────────────────────────────────

drop view if exists public.offres_emploi_publiques;

create view public.offres_emploi_publiques
with (security_invoker = false) as
select
  id,
  slug,
  titre,
  ville,
  departement,
  type_contrat,
  statut,
  publie_le,
  expire_le,
  created_at,
  (public.decalage_carte(lat, lng, 'offre-' || id::text))[1] as lat,
  (public.decalage_carte(lat, lng, 'offre-' || id::text))[2] as lng
from public.offres_emploi
where statut = 'publiee'
  and expire_le > now();

comment on view public.offres_emploi_publiques is
  'Annonces vues sans être connecté : de quoi les lister, les situer et leur donner une URL, rien de plus. Ni description, ni profil recherché, ni conditions — ces textes libres contenaient des coordonnées et des noms de cabinet. Ni cabinet, ni contact_*.';

grant select on public.offres_emploi_publiques to anon, authenticated;


-- ───────────────────────────────────────────────────────────────────
-- 2. Vérifications
-- ───────────────────────────────────────────────────────────────────

-- Les colonnes de la vue. description, profil_recherche, conditions,
-- cabinet et contact_* ne doivent PAS y figurer ; slug, lat et lng si.
-- select column_name from information_schema.columns
-- where table_schema = 'public' and table_name = 'offres_emploi_publiques'
-- order by column_name;

-- anon lit la vue et rien d'autre. Si offres_emploi apparaît ici, le
-- revoke d'emploi.sql (section 6.a) a sauté et tout le détail est
-- joignable par un appel direct :
-- select table_name, privilege_type
-- from information_schema.role_table_grants
-- where grantee = 'anon' and table_schema = 'public'
--   and table_name in ('offres_emploi', 'offres_emploi_publiques');

-- Les annonces publiées dont le slug est nul : elles retomberont sur
-- le slug calculé depuis le titre, ce qui reste juste tant qu'il n'y a
-- pas de collision. appliquer_slug() de slugs_et_urls.sql les rattrape.
-- select id, titre from public.offres_emploi
-- where statut = 'publiee' and expire_le > now() and slug is null;

-- Combien d'annonces publiées portent un détail désormais réservé :
-- select count(*) filter (where description is not null) as avec_description,
--        count(*) filter (where profil_recherche is not null) as avec_profil,
--        count(*) filter (where conditions is not null) as avec_conditions,
--        count(*) as total
-- from public.offres_emploi where statut = 'publiee' and expire_le > now();

-- Les intitulés qui nomment déjà le cabinet : c'est la limite que ce
-- fichier ne couvre pas, le titre restant public par construction.
-- select id, titre, cabinet from public.offres_emploi
-- where cabinet is not null and statut = 'publiee'
--   and titre ilike '%' || cabinet || '%';

-- LE TEST QUI COMPTE, hors SQL Editor, en navigation privée :
--   .../rest/v1/offres_emploi?select=*                        -> refusé
--   .../rest/v1/offres_emploi_publiques?select=*              -> répond,
--       sans description, sans profil_recherche, sans conditions
--   .../rest/v1/offres_emploi_publiques?select=description    -> refusé,
--       la colonne n'existe pas dans la vue
