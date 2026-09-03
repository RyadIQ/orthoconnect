-- ═══════════════════════════════════════════════════════════════════
-- OrthoConnect — le nom du cabinet quitte la vue publique
-- ═══════════════════════════════════════════════════════════════════
--
-- À exécuter à la main dans Supabase > SQL Editor, APRÈS emploi.sql,
-- dont ce fichier ne fait que remplacer la vue de la section 5.
-- Relançable sans dégât : rien n'est détruit, aucune donnée n'est
-- modifiée, la colonne cabinet reste sur la table.
--
-- POURQUOI
-- Un visiteur non connecté voyait le nom du cabinet, sur la carte
-- comme sur la fiche. Même principe que pour les coordonnées et pour
-- le tarif négocié : le masquer à l'affichage ne suffit pas, il
-- partirait quand même dans la réponse JSON, lisible par un appel
-- direct à l'API. La vue cesse donc de l'exposer.
--
-- CE QUI RESTE PUBLIC
--   titre, type_contrat, ville, departement, publie_le,
--   description, profil_recherche, conditions
--
-- CE QUI NE SORT PLUS
--   cabinet, contact_nom, contact_email, contact_tel
--
-- a_cabinet remplace le nom, comme a_contact remplace les
-- coordonnées : le front sait qu'il y a un cabinet à nommer sans
-- pouvoir le nommer, et n'affiche la mention « Cabinet réservé aux
-- praticiens inscrits » que sur les annonces qui en portent un.
--
-- LIMITE CONNUE, hors de portée du SQL
-- L'intitulé de l'annonce reste public : un praticien qui écrit
-- « Collab chez Dupont Orthodontie » contourne ce masquage de
-- lui-même. Le formulaire de publication l'en dissuade par une note,
-- c'est tout ce qu'on peut faire sans réécrire ce qu'il a saisi.
--
-- Si ton Postgres est antérieur à la 15, retire la clause « with
-- (security_invoker = false) », le comportement par défaut est le même.
-- ═══════════════════════════════════════════════════════════════════


-- ───────────────────────────────────────────────────────────────────
-- 1. La vue publique, sans le nom du cabinet
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
  (cabinet is not null) as a_cabinet,
  (coalesce(contact_email, contact_tel, contact_nom) is not null) as a_contact
from public.offres_emploi
where statut = 'publiee'
  and expire_le > now();

comment on view public.offres_emploi_publiques is
  'Annonces lisibles sans être connecté. N''expose ni le nom du cabinet ni aucune coordonnée, seulement les booléens a_cabinet et a_contact.';

grant select on public.offres_emploi_publiques to anon, authenticated;


-- ───────────────────────────────────────────────────────────────────
-- 2. Vérifications
-- ───────────────────────────────────────────────────────────────────

-- Ni cabinet ni contact_* dans la vue, a_cabinet et a_contact présents :
-- select column_name from information_schema.columns
-- where table_schema = 'public' and table_name = 'offres_emploi_publiques'
-- order by column_name;

-- anon lit la vue et rien d'autre (emploi.sql section 6.a lui a retiré
-- la table ; si cette ligne manque, le nom du cabinet reste joignable) :
-- select table_name, privilege_type
-- from information_schema.role_table_grants
-- where grantee = 'anon' and table_schema = 'public'
--   and table_name in ('offres_emploi', 'offres_emploi_publiques');

-- Combien d'annonces publiées portent un nom de cabinet, donc
-- afficheront la mention :
-- select count(*) filter (where a_cabinet) as avec_cabinet, count(*) as total
-- from public.offres_emploi_publiques;

-- Les intitulés qui contiennent déjà le nom du cabinet saisi à côté :
-- c'est le contournement que le SQL ne peut pas couvrir.
-- select id, titre, cabinet from public.offres_emploi
-- where cabinet is not null and statut = 'publiee'
--   and titre ilike '%' || cabinet || '%';

-- LE TEST QUI COMPTE, hors SQL Editor, en navigation privée :
--   .../rest/v1/offres_emploi?select=*            -> refusé
--   .../rest/v1/offres_emploi_publiques?select=*  -> répond, sans
--                                                    cabinet ni contact_*
