-- ═══════════════════════════════════════════════════════════════════
-- OrthoConnect — le cabinet comme référence du filtre de rayon
-- ═══════════════════════════════════════════════════════════════════
--
-- À exécuter à la main dans Supabase > SQL Editor, APRÈS
-- carte_emploi.sql, dont ce fichier prolonge la carte. Il ne recrée
-- aucune vue et ne touche à aucun droit : il ajoute deux colonnes et
-- vérifie que rien ne les publie.
--
-- Relançable sans dégât : rien n'est détruit, aucune donnée n'est
-- modifiée.
--
-- POURQUOI
-- Le filtre « Rayon » de la carte mesurait ses distances depuis le
-- centre de la carte, faute de savoir où exerce le praticien connecté.
-- On ne le savait pas parce que cabinet_ville n'était qu'un texte,
-- jamais géocodé. Ces deux colonnes le sont, renseignées par l'API
-- Adresse au moment où le praticien enregistre sa fiche cabinet.
--
-- CES COORDONNÉES NE SORTENT PAS
-- C'est le point d'attention de ce lot. Elles disent où quelqu'un
-- exerce, à l'adresse de la commune près, et n'ont aucune raison
-- d'être lisibles par qui que ce soit d'autre que lui :
--
--   — les deux vues de la carte (praticiens_recherche_publique et
--     praticiens_recherche_contact) énumèrent leurs colonnes une par
--     une : elles ne les reprendront pas d'elles-mêmes, et la
--     vérification 3.a le confirme sur la base plutôt que sur parole ;
--   — la table praticiens reste fermée à anon (carte_emploi.sql
--     section 8.a, réaffirmé ici par sûreté) ;
--   — RLS ne laisse un praticien lire que sa propre ligne, et l'admin
--     ne les demande pas dans la liste des inscrits.
--
-- Elles ne servent qu'à une chose, dans le navigateur de leur
-- propriétaire : mesurer une distance et centrer la carte.
--
-- À NE PAS CONFONDRE avec recherche_lat / recherche_lng, qui sont la
-- ville où le praticien cherche un poste et qui, elles, sont publiées
-- — décalées de quelques centaines de mètres par decalage_carte().
-- Celles-ci ne sont ni publiées ni décalées : elles ne quittent pas
-- la ligne de leur propriétaire.
-- ═══════════════════════════════════════════════════════════════════


-- ───────────────────────────────────────────────────────────────────
-- 1. Les colonnes
-- ───────────────────────────────────────────────────────────────────

alter table public.praticiens
  add column if not exists cabinet_lat double precision,
  add column if not exists cabinet_lng double precision;

comment on column public.praticiens.cabinet_lat is
  'Latitude de la commune du cabinet, géocodée à l''enregistrement de la fiche. PRIVÉE : n''apparaît dans aucune vue publique, sert au seul praticien connecté à mesurer les distances de la carte depuis chez lui. À ne pas confondre avec recherche_lat, qui est publiée décalée.';

comment on column public.praticiens.cabinet_lng is
  'Longitude de la commune du cabinet. Mêmes règles que cabinet_lat.';


-- ───────────────────────────────────────────────────────────────────
-- 2. Droits
--
-- Rien de neuf : carte_emploi.sql a déjà retiré la table à anon, et
-- les policies RLS existantes limitent un praticien à sa propre ligne.
-- Le revoke est réaffirmé parce qu'une colonne qui apparaît est le bon
-- moment pour revérifier qui lit la table.
-- ───────────────────────────────────────────────────────────────────

revoke select on public.praticiens from anon;


-- ───────────────────────────────────────────────────────────────────
-- 3. Vérifications
-- ───────────────────────────────────────────────────────────────────

-- 3.a  LA VÉRIFICATION QUI COMPTE. Doit rendre ZÉRO ligne : aucune vue
--      du schéma public ne doit porter ces colonnes.
-- select table_name, column_name
-- from information_schema.columns
-- where table_schema = 'public'
--   and column_name in ('cabinet_lat', 'cabinet_lng')
--   and table_name in (select table_name from information_schema.views
--                      where table_schema = 'public');

-- 3.b  Les colonnes existent bien sur la table, elles :
-- select column_name, data_type from information_schema.columns
-- where table_schema = 'public' and table_name = 'praticiens'
--   and column_name like 'cabinet%'
-- order by column_name;

-- 3.c  Combien de fiches cabinet sont géocodées. Les anciennes ne le
--      seront qu'au prochain enregistrement de leur fiche : le filtre
--      retombe d'ici là sur le centre de la carte, et l'interface le
--      dit à qui est concerné.
-- select count(*) filter (where cabinet_ville is not null) as avec_ville,
--        count(*) filter (where cabinet_lat is not null)   as geocodees
-- from public.praticiens;

-- 3.d  Les villes de cabinet que l'API Adresse n'a pas su placer :
-- select id, cabinet_ville from public.praticiens
-- where cabinet_ville is not null and cabinet_lat is null;

-- LE TEST QUI COMPTE, hors SQL Editor, en navigation privée :
--   .../rest/v1/praticiens?select=cabinet_lat            -> refusé
--   .../rest/v1/praticiens_recherche_publique?select=*   -> répond, et
--       ne contient ni cabinet_lat ni cabinet_lng
-- Puis, connecté avec un autre compte que le sien :
--   .../rest/v1/praticiens_recherche_contact?select=*    -> répond, et
--       ne les contient pas davantage.
