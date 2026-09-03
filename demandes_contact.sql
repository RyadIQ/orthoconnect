-- ═══════════════════════════════════════════════════════════════════
-- OrthoConnect — mise en relation praticien / organisme partenaire
-- ═══════════════════════════════════════════════════════════════════
--
-- À exécuter à la main dans Supabase > SQL Editor, APRÈS
-- admin_et_organismes.sql (dépend de public.is_admin() et de
-- public.organismes).
--
-- Relançable sans dégât.
--
-- ORDRE DE LECTURE
--   1. téléphone du praticien
--   2. table demandes_contact
--   3. policies
--   4. vérifications
--
-- POURQUOI UNE COLONNE TÉLÉPHONE
-- Le formulaire de mise en relation pré-remplit nom, email et
-- téléphone depuis le profil. Les deux premiers existent déjà sur
-- praticiens, le troisième non : sans lui, le champ serait
-- systématiquement vide et l'organisme ne recevrait aucun moyen de
-- rappeler. Le numéro est stocké sur le praticien et pas sur la
-- demande, pour qu'il serve à toutes ses demandes et reste modifiable
-- au même endroit que le reste de son profil.
-- ═══════════════════════════════════════════════════════════════════


-- ───────────────────────────────────────────────────────────────────
-- 1. Téléphone du praticien
-- ───────────────────────────────────────────────────────────────────

alter table public.praticiens
  add column if not exists telephone text;

comment on column public.praticiens.telephone is
  'Téléphone de contact, saisi dans la fiche cabinet ou lors d''une demande de mise en relation.';


-- ───────────────────────────────────────────────────────────────────
-- 2. Table demandes_contact
--
-- Aucune contrainte d'unicité sur (praticien_id, formation_id) : un
-- praticien peut légitimement relancer une demande restée sans suite,
-- avec un message différent. Les doublons éventuels se traitent à
-- l'écran, via le statut, plutôt qu'en refusant l'écriture.
--
-- Les clés vers formations et organismes sont en « on delete set
-- null » : supprimer une formation ne doit pas effacer la trace d'une
-- demande déjà transmise à un partenaire.
-- ───────────────────────────────────────────────────────────────────

create table if not exists public.demandes_contact (
  id           bigint      generated always as identity primary key,
  formation_id bigint,
  organisme_id bigint,
  praticien_id uuid        not null,
  message      text,
  statut       text        not null default 'nouvelle',
  created_at   timestamptz not null default now(),

  constraint demandes_contact_formation_fk
    foreign key (formation_id) references public.formations (id) on delete set null,
  constraint demandes_contact_organisme_fk
    foreign key (organisme_id) references public.organismes (id) on delete set null,
  constraint demandes_contact_praticien_fk
    foreign key (praticien_id) references public.praticiens (id) on delete cascade,
  constraint demandes_contact_statut_check
    check (statut in ('nouvelle', 'transmise', 'traitee'))
);

comment on table public.demandes_contact is
  'Demande d''un praticien à être recontacté par un organisme partenaire, au sujet d''une formation.';
comment on column public.demandes_contact.statut is
  'nouvelle : reçue, rien de fait. transmise : envoyée à l''organisme. traitee : l''organisme a donné suite.';

create index if not exists demandes_contact_statut_idx    on public.demandes_contact (statut, created_at desc);
create index if not exists demandes_contact_praticien_idx on public.demandes_contact (praticien_id);
create index if not exists demandes_contact_organisme_idx on public.demandes_contact (organisme_id);


-- ───────────────────────────────────────────────────────────────────
-- 3. Policies
--
-- Le praticien insère et relit ses propres demandes, rien de plus :
-- pas d'UPDATE pour lui, le statut appartient au suivi admin.
-- L'admin lit et modifie tout.
-- ───────────────────────────────────────────────────────────────────

alter table public.demandes_contact enable row level security;

drop policy if exists "praticien cree sa demande" on public.demandes_contact;
create policy "praticien cree sa demande"
  on public.demandes_contact
  for insert
  to authenticated
  with check (praticien_id = auth.uid());

drop policy if exists "praticien lit ses demandes" on public.demandes_contact;
create policy "praticien lit ses demandes"
  on public.demandes_contact
  for select
  to authenticated
  using (praticien_id = auth.uid());

drop policy if exists "admin gere les demandes" on public.demandes_contact;
create policy "admin gere les demandes"
  on public.demandes_contact
  for all
  to authenticated
  using (public.is_admin())
  with check (public.is_admin());


-- ───────────────────────────────────────────────────────────────────
-- 4. Vérifications
-- ───────────────────────────────────────────────────────────────────

-- Les policies posées :
-- select policyname, cmd, roles
-- from pg_policies
-- where schemaname = 'public' and tablename = 'demandes_contact'
-- order by policyname;

-- Les demandes, telles que l'admin les voit :
-- select d.created_at, d.statut,
--        p.nom, p.email, p.telephone, p.ville,
--        f.titre as formation, o.nom as organisme,
--        d.message
-- from public.demandes_contact d
-- left join public.praticiens p on p.id = d.praticien_id
-- left join public.formations f on f.id = d.formation_id
-- left join public.organismes o on o.id = d.organisme_id
-- order by d.created_at desc;

-- Volume par statut :
-- select statut, count(*) from public.demandes_contact group by statut;

-- Contrôle d'étanchéité : connecté en simple praticien, ceci ne doit
-- renvoyer que ses propres demandes.
-- select count(*) from public.demandes_contact;

-- Rappel : le bouton n'apparaît que sur les formations dont
-- l'organisme a partenaire = true. Pour vérifier qui est concerné :
-- select id, nom, partenaire, niveau_offre from public.organismes
-- where partenaire order by nom;
