-- ═══════════════════════════════════════════════════════════════════
-- OrthoConnect — génération du sitemap
-- ═══════════════════════════════════════════════════════════════════
--
-- À relancer dans Supabase > SQL Editor chaque fois que du contenu est
-- publié ou dépublié. La requête ne modifie rien : elle rend le fichier
-- sitemap.xml entier, dans une seule cellule, à copier tel quel dans le
-- dépôt à la place du fichier actuel.
--
-- Suppose slugs_et_urls.sql passé : sans la colonne slug, il n'y a pas
-- d'URL à écrire.
--
-- CE QUI Y ENTRE
--   les pages fixes, le catalogue des formations publiées, les fiches
--   produits visibles, les annonces publiées et non expirées.
--
-- CE QUI N'Y ENTRE PAS
--   /mon-espace et /admin, privées et déjà en noindex ; /partenaires,
--   hors ligne le temps d'être réécrite et en noindex elle aussi ; les
--   fiches produits masquées, que le comparatif n'affiche pas ; les
--   annonces expirées, qui ne répondent plus.
--
-- La date est celle du contenu quand il en porte une : une annonce
-- prend sa date de publication, une formation sa date de vérification.
-- ═══════════════════════════════════════════════════════════════════

with entrees as (
  -- Pages fixes. La date du jour convient : ce sont des index, ils
  -- bougent dès qu'un contenu arrive.
                select 'https://orthoconnect.fr/'            as loc, current_date as maj, 'weekly'  as freq, '1.0' as prio, 1 as rang
  union all     select 'https://orthoconnect.fr/formations',      current_date,      'weekly',        '0.9',       2
  union all     select 'https://orthoconnect.fr/emploi',          current_date,      'daily',         '0.9',       3
  union all     select 'https://orthoconnect.fr/produits',        current_date,      'weekly',        '0.8',       4

  -- Pages legales. Elles ne bougent pas quand un contenu arrive : leur
  -- date est celle de leur derniere revision, ecrite en toutes lettres
  -- en tete de chaque page, et non la date du jour.
  union all     select 'https://orthoconnect.fr/mentions-legales', date '2026-09-11', 'yearly',        '0.3',       6
  union all     select 'https://orthoconnect.fr/cgu',              date '2026-09-11', 'yearly',        '0.3',       6
  union all     select 'https://orthoconnect.fr/confidentialite',  date '2026-09-12', 'yearly',        '0.3',       6

  union all
  select 'https://orthoconnect.fr/formations/' || f.slug,
         coalesce(f.verifie_le::date, current_date),
         'monthly', '0.8', 7
  from public.formations f
  where f.statut = 'publie' and f.slug is not null and f.slug <> ''

  union all
  select 'https://orthoconnect.fr/produits/' || p.slug,
         coalesce(p.modifie_le::date, p.cree_le::date, current_date),
         'monthly', '0.6', 8
  from public.produits p
  where p.visible and p.slug is not null and p.slug <> ''

  union all
  select 'https://orthoconnect.fr/emploi/' || j.slug,
         coalesce(j.publie_le::date, j.created_at::date, current_date),
         'weekly', '0.7', 9
  from public.offres_emploi j
  where j.statut = 'publiee' and j.expire_le > now()
    and j.slug is not null and j.slug <> ''
)
select '<?xml version="1.0" encoding="UTF-8"?>' || chr(10) ||
       '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">' || chr(10) ||
       string_agg(
         '  <url>' || chr(10) ||
         '    <loc>' || loc || '</loc>' || chr(10) ||
         '    <lastmod>' || to_char(maj, 'YYYY-MM-DD') || '</lastmod>' || chr(10) ||
         '    <changefreq>' || freq || '</changefreq>' || chr(10) ||
         '    <priority>' || prio || '</priority>' || chr(10) ||
         '  </url>',
         chr(10) order by rang, loc) || chr(10) ||
       '</urlset>' as sitemap_xml
from entrees;


-- ───────────────────────────────────────────────────────────────────
-- Contrôles
-- ───────────────────────────────────────────────────────────────────

-- Combien d'URL le sitemap contiendra, par famille :
-- select 'formations' as famille, count(*) from public.formations
--   where statut = 'publie' and slug is not null
-- union all select 'produits', count(*) from public.produits
--   where visible and slug is not null
-- union all select 'annonces', count(*) from public.offres_emploi
--   where statut = 'publiee' and expire_le > now() and slug is not null
-- union all select 'pages fixes', 7;

-- Contenus publiés sans slug : ils manqueraient au sitemap.
-- Repasse la section 4 de slugs_et_urls.sql s'il en sort quelque chose.
-- select 'formations' as source, id, titre from public.formations
--   where statut = 'publie' and (slug is null or slug = '')
-- union all select 'produits', id::text, nom from public.produits
--   where visible and (slug is null or slug = '')
-- union all select 'offres_emploi', id::text, titre from public.offres_emploi
--   where statut = 'publiee' and expire_le > now() and (slug is null or slug = '');
