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
  intitule text;
  ancien   text;
  base     text;
  essai    text;
  n        int := 1;
  pris     boolean;
begin
  intitule := case tg_table_name when 'produits' then new.nom else new.titre end;

  if tg_op = 'UPDATE' then
    ancien := case tg_table_name when 'produits' then old.nom else old.titre end;

    -- Slug déjà là, titre inchangé, ou slug modifié à la main : on sort.
    if new.slug is distinct from old.slug then
      return new;
    end if;
    if new.slug is not null and new.slug <> '' and intitule is not distinct from ancien then
      return new;
    end if;
  end if;

  -- Slug fourni explicitement à l'insertion : on le respecte, quitte à
  -- le passer par la même normalisation.
  if tg_op = 'INSERT' and new.slug is not null and new.slug <> '' then
    base := public.slugifier(new.slug);
  else
    base := public.slugifier(intitule);
  end if;

  essai := base;

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
-- Écrit directement plutôt que par un UPDATE qui déclencherait le
-- trigger : ça évite de toucher updated_at sur toutes les lignes,
-- donc de fausser les dates du sitemap.
--
-- Deux temps : le slug nu, puis un suffixe pour les doublons — la
-- ligne la plus ancienne garde l'adresse courte.
-- ───────────────────────────────────────────────────────────────────

update public.formations    set slug = public.slugifier(titre) where slug is null or slug = '';
update public.offres_emploi set slug = public.slugifier(titre) where slug is null or slug = '';
update public.produits      set slug = public.slugifier(nom)   where slug is null or slug = '';

with doublons as (
  select id, slug, row_number() over (partition by slug order by id) as rang
  from public.formations where slug is not null)
update public.formations f set slug = f.slug || '-' || d.rang
from doublons d where d.id = f.id and d.rang > 1;

with doublons as (
  select id, slug, row_number() over (partition by slug order by id) as rang
  from public.offres_emploi where slug is not null)
update public.offres_emploi j set slug = j.slug || '-' || d.rang
from doublons d where d.id = j.id and d.rang > 1;

with doublons as (
  select id, slug, row_number() over (partition by slug order by id) as rang
  from public.produits where slug is not null)
update public.produits p set slug = p.slug || '-' || d.rang
from doublons d where d.id = p.id and d.rang > 1;


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
