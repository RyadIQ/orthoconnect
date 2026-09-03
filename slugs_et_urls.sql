-- ═══════════════════════════════════════════════════════════════════
-- OrthoConnect — slugs et vraies URL
-- ═══════════════════════════════════════════════════════════════════
--
-- À exécuter à la main dans Supabase > SQL Editor, APRÈS
-- vue_formations_publiques.sql, emploi.sql et emploi_cabinet_masque.sql :
-- ce fichier recrée les deux vues publiques pour y ajouter le slug, en
-- reprenant leur définition en vigueur.
--
-- Relançable sans dégât : rien n'est détruit, le rattrapage de la
-- section 4 ne touche que les lignes dont le slug manque.
--
-- ORDRE DE LECTURE
--   1. la fonction slugifier()
--   2. la colonne slug et son index unique
--   3. le trigger de génération
--   4. rattrapage des contenus déjà en base
--   5. les vues publiques exposent le slug
--   6. vérifications
--
-- CE QUE LE FRONT EN FAIT
-- /formations/<slug> et /emploi/<slug>. Tant que ce fichier n'est pas
-- passé, le site fabrique le slug depuis le titre au moment d'écrire
-- l'URL, avec la même règle qu'ici : les liens fonctionnent déjà, ils
-- deviennent seulement stables et uniques une fois la colonne remplie.
--
-- produits reçoit la colonne comme les autres, mais aucune URL ne
-- l'utilise aujourd'hui : il n'y a pas de fiche produit. La colonne
-- est là pour le jour où il y en aura une.
-- ═══════════════════════════════════════════════════════════════════


-- ───────────────────────────────────────────────────────────────────
-- 1. slugifier()
--
-- Minuscules, accents retirés, ponctuation supprimée, espaces en
-- tirets. Pas d'extension unaccent : translate() suffit et évite une
-- dépendance à installer sur le projet Supabase.
--
-- La même règle est écrite en JavaScript dans index.html
-- (fonction slugifier). Si tu touches à l'une, touche à l'autre :
-- c'est ce qui garantit qu'une URL fabriquée par le front avant le
-- passage de ce SQL tombera sur le slug généré ici.
--
-- Une nuance sans conséquence en français : le front retire les
-- diacritiques de tout l'alphabet latin, la liste ci-dessous s'arrête
-- à ceux qu'on écrit ici. Un « ș » roumain deviendrait « s » côté
-- front et « - » côté base ; le slug en base fait foi dès que ce
-- fichier est passé.
-- ───────────────────────────────────────────────────────────────────

create or replace function public.slugifier(source text)
returns text
language sql
immutable
as $$
  select coalesce(
    nullif(
      trim(both '-' from
        left(
          regexp_replace(
            lower(
              translate(
                replace(replace(replace(replace(coalesce(source, ''),
                  'œ', 'oe'), 'Œ', 'oe'), 'æ', 'ae'), 'Æ', 'ae'),
                'ÀÁÂÃÄÅàáâãäåÈÉÊËèéêëÌÍÎÏìíîïÒÓÔÕÖØòóôõöøÙÚÛÜùúûüÝýÿÑñÇç',
                'AAAAAAaaaaaaEEEEeeeeIIIIiiiiOOOOOOooooooUUUUuuuuYyyNnCc')),
            '[^a-z0-9]+', '-', 'g'),
          80)),
      ''),
    'sans-titre');
$$;

comment on function public.slugifier(text) is
  'Titre -> slug d''URL. Règle jumelle de la fonction slugifier() du front, à tenir alignée.';


-- ───────────────────────────────────────────────────────────────────
-- 2. La colonne et son index
--
-- L'index est unique : c'est lui qui fait foi, le trigger ne fait que
-- proposer un suffixe pour l'éviter.
-- ───────────────────────────────────────────────────────────────────

alter table public.formations     add column if not exists slug text;
alter table public.offres_emploi  add column if not exists slug text;
alter table public.produits       add column if not exists slug text;

create unique index if not exists formations_slug_key    on public.formations (slug);
create unique index if not exists offres_emploi_slug_key on public.offres_emploi (slug);
create unique index if not exists produits_slug_key      on public.produits (slug);


-- ───────────────────────────────────────────────────────────────────
-- 3. Le trigger
--
-- Il génère à l'insertion, et à la mise à jour quand le titre a
-- changé ou que le slug manque. Une modification manuelle du slug est
-- respectée : si la requête change slug elle-même, le trigger n'y
-- touche pas.
--
-- Conséquence à connaître : renommer un contenu déplace son URL, et
-- l'ancienne ne répond plus. C'est le comportement demandé ; si un
-- jour une annonce diffusée doit garder son adresse, il faudra une
-- table de redirections plutôt qu'un slug figé.
--
-- La table produits porte son intitulé dans « nom », les deux autres
-- dans « titre » : c'est la seule différence entre les trois.
-- ───────────────────────────────────────────────────────────────────

create or replace function public.appliquer_slug()
returns trigger
language plpgsql
as $$
declare
  -- La ligne est lue en jsonb, jamais par new.<colonne> : PL/pgSQL
  -- résout ces références à l'exécution, y compris dans la branche
  -- non empruntée d'un case. Une fonction qui sert trois tables aux
  -- colonnes différentes échouerait donc sur new.nom dès qu'elle
  -- tourne sur formations. L'opérateur ->> accepte un champ absent et
  -- rend null.
  ligne    jsonb := to_jsonb(new);
  precedent jsonb;
  cle      text;
  intitule text;
  ancien   text;
  slug_neuf text;
  base     text;
  essai    text;
  n        int := 1;
  pris     boolean;
begin
  -- produits porte son intitulé dans « nom », les deux autres dans
  -- « titre » : c'est la seule différence entre les trois tables.
  cle := case tg_table_name when 'produits' then 'nom' else 'titre' end;

  intitule  := ligne ->> cle;
  slug_neuf := ligne ->> 'slug';

  if tg_op = 'UPDATE' then
    precedent := to_jsonb(old);
    ancien    := precedent ->> cle;

    -- Slug modifié à la main par la requête : on n'y touche pas.
    if slug_neuf is distinct from (precedent ->> 'slug') then
      return new;
    end if;
    -- Slug déjà là et titre inchangé : rien à refaire.
    if slug_neuf is not null and slug_neuf <> '' and intitule is not distinct from ancien then
      return new;
    end if;
  end if;

  -- Slug fourni explicitement à l'insertion : on le respecte, quitte à
  -- le passer par la même normalisation.
  if tg_op = 'INSERT' and slug_neuf is not null and slug_neuf <> '' then
    base := public.slugifier(slug_neuf);
  else
    base := public.slugifier(intitule);
  end if;

  essai := base;

  -- id et slug, eux, existent sur les trois tables — la section 2 pose
  -- la seconde — et l'id est comparé tel quel, sans passer par jsonb :
  -- il faudrait sinon le recaster vers le type de la colonne.
  loop
    execute format(
      'select exists (select 1 from public.%I where slug = $1 and id is distinct from $2)',
      tg_table_name)
    into pris
    using essai, new.id;

    exit when not pris;

    n := n + 1;
    essai := base || '-' || n;
  end loop;

  new.slug := essai;
  return new;
end;
$$;

drop trigger if exists formations_slug on public.formations;
create trigger formations_slug
  before insert or update on public.formations
  for each row execute function public.appliquer_slug();

drop trigger if exists offres_emploi_slug on public.offres_emploi;
create trigger offres_emploi_slug
  before insert or update on public.offres_emploi
  for each row execute function public.appliquer_slug();

drop trigger if exists produits_slug on public.produits;
create trigger produits_slug
  before insert or update on public.produits
  for each row execute function public.appliquer_slug();


-- ───────────────────────────────────────────────────────────────────
-- 4. Rattrapage des contenus déjà en base
--
-- L'UPDATE ne change rien par lui-même : il remet null là où le slug
-- manque déjà. C'est le trigger de la section 3 qu'il réveille, ligne
-- par ligne, et c'est lui qui pose le slug — donc la même règle et le
-- même suffixe anti-collision qu'à toute insertion future.
--
-- Écrire les slugs en masse puis dédoublonner ensuite ne marche pas :
-- deux titres qui donnent le même slug font échouer le premier UPDATE
-- sur l'index unique, avant que le dédoublonnage ait eu lieu.
--
-- Seule conséquence : sur offres_emploi, updated_at est touché pour
-- les lignes rattrapées. Le sitemap ne s'en sert pas — il lit
-- publie_le et verifie_le.
-- ───────────────────────────────────────────────────────────────────

do $$
declare
  cible text;
begin
  foreach cible in array array['formations', 'offres_emploi', 'produits'] loop
    execute format('update public.%I set slug = null where slug is null or slug = %L', cible, '');
  end loop;
end;
$$;


-- ───────────────────────────────────────────────────────────────────
-- 5. Les vues publiques exposent le slug
--
-- Recréées à l'identique de leur définition en vigueur, plus la
-- colonne slug. Sans elle, un visiteur non connecté n'aurait pas de
-- quoi résoudre /formations/<slug> ni /emploi/<slug>.
--
-- Si ton Postgres est antérieur à la 15, retire les clauses « with
-- (security_invoker = false) », le comportement par défaut est le même.
-- ───────────────────────────────────────────────────────────────────

drop view if exists public.formations_publiques;

create view public.formations_publiques
with (security_invoker = false) as
select
  f.id,
  f.slug,
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

  o.nom        as organisme_nom,
  o.logo_url   as organisme_logo_url,
  o.partenaire as organisme_partenaire,
  o.site_web   as organisme_site_web
from public.formations f
left join public.organismes o on o.id = f.organisme_id
where f.statut = 'publie';

comment on view public.formations_publiques is
  'Catalogue lisible sans être connecté. Porte le slug d''URL. N''expose ni tarif_prefere ni conditions_tarif, seulement le booléen a_tarif_prefere.';

grant select on public.formations_publiques to anon, authenticated;


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
  'Annonces lisibles sans être connecté. Porte le slug d''URL. N''expose ni le nom du cabinet ni aucune coordonnée, seulement les booléens a_cabinet et a_contact.';

grant select on public.offres_emploi_publiques to anon, authenticated;


-- ───────────────────────────────────────────────────────────────────
-- 6. Vérifications
-- ───────────────────────────────────────────────────────────────────

-- Ce que donne la règle sur quelques cas :
-- select public.slugifier('Module 1 : Fondamentaux de l''ONM'),
--        public.slugifier('Collab 2j/semaine - Toulouse Hyper Centre'),
--        public.slugifier('Élève & cœur — «essai»'),
--        public.slugifier('   ');

-- Les slugs générés, et l'URL qui va avec :
-- select id, titre, slug, 'https://orthoconnect.fr/formations/' || slug as url
-- from public.formations where statut = 'publie' order by id;
-- select id, titre, slug, 'https://orthoconnect.fr/emploi/' || slug as url
-- from public.offres_emploi where statut = 'publiee' order by id;

-- Aucun slug manquant, aucun doublon :
-- select 'formations' as table, count(*) filter (where slug is null or slug = '') as sans_slug,
--        count(*) - count(distinct slug) as doublons from public.formations
-- union all select 'offres_emploi', count(*) filter (where slug is null or slug = ''),
--        count(*) - count(distinct slug) from public.offres_emploi
-- union all select 'produits', count(*) filter (where slug is null or slug = ''),
--        count(*) - count(distinct slug) from public.produits;

-- Le slug est bien sorti dans les vues publiques :
-- select column_name from information_schema.columns
-- where table_schema = 'public'
--   and table_name in ('formations_publiques', 'offres_emploi_publiques')
--   and column_name = 'slug';

-- Le trigger suit un renommage :
-- update public.formations set titre = titre || ' (test)' where id = <id>;
-- select id, titre, slug from public.formations where id = <id>;
-- (puis remets le titre d'origine, le slug revient)
