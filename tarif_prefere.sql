-- ═══════════════════════════════════════════════════════════════════
-- OrthoConnect — tarif préférentiel et codes de réduction
-- ═══════════════════════════════════════════════════════════════════
--
-- À exécuter à la main dans Supabase > SQL Editor, APRÈS
-- admin_et_organismes.sql (dépend de is_admin(), organismes,
-- formations.statut).
--
-- Relançable sans dégât.
--
-- ORDRE DE LECTURE
--   1. retrait de demandes_contact
--   2. colonnes tarif_prefere et conditions_tarif
--   3. table codes_reduction
--   4. generer_code_reduction()
--   5. policies
--   6. vérifications
-- ═══════════════════════════════════════════════════════════════════


-- ───────────────────────────────────────────────────────────────────
-- 1. Retrait du mécanisme précédent
--
-- La mise en relation par formulaire est remplacée par les codes.
-- « if exists » : sans effet si demandes_contact.sql n'a jamais été
-- passé. La colonne praticiens.telephone est CONSERVÉE : elle peut
-- déjà contenir des numéros saisis dans la fiche cabinet, et reste un
-- champ de profil valable.
-- ───────────────────────────────────────────────────────────────────

drop table if exists public.demandes_contact cascade;


-- ───────────────────────────────────────────────────────────────────
-- 2. Tarif préférentiel sur formations
-- ───────────────────────────────────────────────────────────────────

alter table public.formations
  add column if not exists tarif_prefere   integer,
  add column if not exists conditions_tarif text;

-- Un tarif préférentiel supérieur ou égal au tarif public est
-- toujours une erreur de saisie : autant la refuser à l'écriture.
alter table public.formations
  drop constraint if exists formations_tarif_prefere_check;
alter table public.formations
  add constraint formations_tarif_prefere_check
  check (
    tarif_prefere is null
    or (tarif_prefere >= 0 and (prix is null or tarif_prefere < prix))
  );

comment on column public.formations.tarif_prefere is
  'Tarif négocié pour les praticiens OrthoConnect. Ne s''affiche que si l''organisme est aussi partenaire.';
comment on column public.formations.conditions_tarif is
  'Ce que le praticien doit faire pour en bénéficier.';


-- ───────────────────────────────────────────────────────────────────
-- 3. Table codes_reduction
-- ───────────────────────────────────────────────────────────────────

create table if not exists public.codes_reduction (
  id           bigint      generated always as identity primary key,
  code         text        not null,
  formation_id bigint,
  praticien_id uuid        not null,
  statut       text        not null default 'genere',
  created_at   timestamptz not null default now(),
  expire_le    timestamptz not null default now() + interval '90 days',

  constraint codes_reduction_code_unique unique (code),
  constraint codes_reduction_code_format check (code ~ '^OC-[A-Z0-9]{4}$'),
  constraint codes_reduction_statut_check check (statut in ('genere', 'utilise', 'expire')),
  constraint codes_reduction_formation_fk
    foreign key (formation_id) references public.formations (id) on delete cascade,
  constraint codes_reduction_praticien_fk
    foreign key (praticien_id) references public.praticiens (id) on delete cascade
);

comment on table public.codes_reduction is
  'Code donné par le praticien à l''organisme pour obtenir le tarif préférentiel.';
comment on column public.codes_reduction.statut is
  'genere : émis. utilise : l''organisme l''a honoré. expire : clos sans usage. Un code dont expire_le est dépassé est traité comme expiré à l''affichage, sans attendre une mise à jour du statut.';

create index if not exists codes_reduction_praticien_idx on public.codes_reduction (praticien_id, created_at desc);
create index if not exists codes_reduction_formation_idx on public.codes_reduction (formation_id);
create index if not exists codes_reduction_statut_idx    on public.codes_reduction (statut, created_at desc);


-- ───────────────────────────────────────────────────────────────────
-- 4. Génération du code
--
-- Passer par une fonction plutôt que par un INSERT depuis le
-- navigateur n'est pas un détail : c'est ici, et seulement ici, que
-- les DEUX conditions sont vérifiées (tarif_prefere renseigné ET
-- organisme partenaire). Un praticien ne peut donc pas se fabriquer
-- un code sur une formation qui n'en propose pas.
--
-- L'alphabet exclut I, O, 0, 1 et L : ces codes sont dictés au
-- téléphone ou recopiés dans un mail.
-- ───────────────────────────────────────────────────────────────────

create or replace function public.generer_code_reduction(p_formation_id bigint)
returns public.codes_reduction
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_alphabet constant text := 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';
  v_praticien uuid := auth.uid();
  v_ligne     public.codes_reduction;
  v_code      text;
  v_essais    integer := 0;
begin
  if v_praticien is null then
    raise exception 'Connectez-vous pour obtenir un code.' using errcode = '28000';
  end if;

  if not exists (
    select 1
    from public.formations f
    join public.organismes o on o.id = f.organisme_id
    where f.id = p_formation_id
      and f.statut = 'publie'
      and f.tarif_prefere is not null
      and o.partenaire
  ) then
    raise exception 'Cette formation ne propose pas de tarif préférentiel.' using errcode = 'P0001';
  end if;

  -- Un code encore valide est renvoyé tel quel : recliquer sur le
  -- bouton ne doit pas multiplier les codes pour la même formation.
  select * into v_ligne
  from public.codes_reduction
  where praticien_id = v_praticien
    and formation_id = p_formation_id
    and statut = 'genere'
    and expire_le > now()
  order by created_at desc
  limit 1;

  if found then
    return v_ligne;
  end if;

  loop
    v_essais := v_essais + 1;
    v_code := 'OC-';
    for i in 1..4 loop
      v_code := v_code || substr(v_alphabet, 1 + floor(random() * length(v_alphabet))::integer, 1);
    end loop;

    exit when not exists (select 1 from public.codes_reduction where code = v_code);

    if v_essais > 25 then
      raise exception 'Impossible de générer un code disponible, réessayez.';
    end if;
  end loop;

  insert into public.codes_reduction (code, formation_id, praticien_id)
  values (v_code, p_formation_id, v_praticien)
  returning * into v_ligne;

  return v_ligne;
end;
$$;

comment on function public.generer_code_reduction(bigint) is
  'Émet un code OC-XXXX pour le praticien connecté, après vérification que la formation a un tarif préférentiel ET un organisme partenaire.';

revoke all on function public.generer_code_reduction(bigint) from public, anon;
grant execute on function public.generer_code_reduction(bigint) to authenticated;


-- ───────────────────────────────────────────────────────────────────
-- 5. Policies
-- ───────────────────────────────────────────────────────────────────

alter table public.codes_reduction enable row level security;

drop policy if exists "praticien cree son code" on public.codes_reduction;
create policy "praticien cree son code"
  on public.codes_reduction
  for insert
  to authenticated
  with check (praticien_id = auth.uid());

drop policy if exists "praticien lit ses codes" on public.codes_reduction;
create policy "praticien lit ses codes"
  on public.codes_reduction
  for select
  to authenticated
  using (praticien_id = auth.uid());

drop policy if exists "admin gere les codes" on public.codes_reduction;
create policy "admin gere les codes"
  on public.codes_reduction
  for all
  to authenticated
  using (public.is_admin())
  with check (public.is_admin());


-- ───────────────────────────────────────────────────────────────────
-- 6. Vérifications
-- ───────────────────────────────────────────────────────────────────

-- demandes_contact a bien disparu (doit renvoyer 0 ligne) :
-- select table_name from information_schema.tables
-- where table_schema = 'public' and table_name = 'demandes_contact';

-- Les formations qui afficheront un tarif préférentiel, c'est-à-dire
-- celles qui remplissent les DEUX conditions :
-- select f.id, f.titre, o.nom as organisme, f.prix, f.tarif_prefere,
--        f.prix - f.tarif_prefere as economie
-- from public.formations f
-- join public.organismes o on o.id = f.organisme_id
-- where f.tarif_prefere is not null and o.partenaire and f.statut = 'publie'
-- order by o.nom, f.titre;

-- Les formations avec un tarif saisi mais dont l'organisme n'est PAS
-- partenaire : le tarif y reste invisible, à vérifier si c'est voulu.
-- select f.id, f.titre, o.nom as organisme, f.tarif_prefere
-- from public.formations f
-- join public.organismes o on o.id = f.organisme_id
-- where f.tarif_prefere is not null and not o.partenaire;

-- Les codes émis :
-- select c.code, c.statut, c.created_at, c.expire_le,
--        p.nom as praticien, f.titre as formation, o.nom as organisme
-- from public.codes_reduction c
-- left join public.praticiens p on p.id = c.praticien_id
-- left join public.formations f on f.id = c.formation_id
-- left join public.organismes o on o.id = f.organisme_id
-- order by c.created_at desc;

-- Codes du mois en cours :
-- select count(*) from public.codes_reduction
-- where created_at >= date_trunc('month', now());

-- Codes périmés encore marqués « genere ». L'affichage les traite
-- déjà comme expirés ; cet UPDATE ne sert qu'à aligner la base.
-- update public.codes_reduction set statut = 'expire'
-- where statut = 'genere' and expire_le <= now();
