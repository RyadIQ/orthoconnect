-- ═══════════════════════════════════════════════════════════════════
-- OrthoConnect — création automatique du profil praticien
-- ═══════════════════════════════════════════════════════════════════
--
-- À exécuter à la main dans Supabase > SQL Editor, qui tourne avec un
-- rôle propriétaire : c'est nécessaire, un trigger sur auth.users ne
-- peut pas être posé par anon ni par authenticated.
--
-- CONTEXTE
-- Le front n'insère plus lui-même dans public.praticiens. Il transmet
-- nom / ville / statut / rpps / faculte dans options.data du signUp,
-- que GoTrue range dans auth.users.raw_user_meta_data. Le trigger
-- ci-dessous lit ces métadonnées et crée la ligne correspondante.
--
-- POURQUOI SECURITY DEFINER
-- Le trigger s'exécute dans la transaction d'inscription, à un moment
-- où il n'y a pas encore de session : auth.uid() est NULL et toute
-- policy RLS de type « id = auth.uid() » refuserait l'insertion.
-- SECURITY DEFINER fait tourner la fonction avec les droits de son
-- propriétaire, qui contourne RLS.
--
-- HYPOTHÈSE SUR LE SCHÉMA
-- On suppose public.praticiens (id uuid primary key référençant
-- auth.users, nom text, email text, ville text, statut text,
-- rpps text, faculte text). Ce sont les colonnes que le front
-- écrivait jusqu'ici. Adapte les noms si ta table diffère.
-- ═══════════════════════════════════════════════════════════════════


-- ───────────────────────────────────────────────────────────────────
-- 1. La fonction
-- ───────────────────────────────────────────────────────────────────
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
-- search_path figé : sans ça, une fonction SECURITY DEFINER peut être
-- détournée en plaçant une table homonyme dans un schéma prioritaire.
set search_path = public, pg_temp
as $$
begin
  insert into public.praticiens (id, nom, email, ville, statut, rpps, faculte)
  values (
    new.id,
    nullif(btrim(coalesce(new.raw_user_meta_data ->> 'nom', '')), ''),
    new.email,
    nullif(btrim(coalesce(new.raw_user_meta_data ->> 'ville', '')), ''),
    coalesce(nullif(new.raw_user_meta_data ->> 'statut', ''), 'liberal'),
    nullif(btrim(coalesce(new.raw_user_meta_data ->> 'rpps', '')), ''),
    nullif(btrim(coalesce(new.raw_user_meta_data ->> 'faculte', '')), '')
  )
  on conflict (id) do nothing;

  return new;

exception
  -- Volontairement non bloquant. Un trigger AFTER INSERT sur auth.users
  -- qui lève annule TOUTE l'inscription : le praticien ne pourrait même
  -- plus créer son compte, ce qui est pire que l'absence de profil.
  -- On journalise (visible dans Supabase > Logs > Postgres) et on laisse
  -- passer. C'est exactement ce cas que ensureProfile() rattrape côté
  -- client, à la première connexion.
  when others then
    raise warning 'handle_new_user: profil non créé pour % (%) : % / %',
      new.id, new.email, sqlstate, sqlerrm;
    return new;
end;
$$;

comment on function public.handle_new_user() is
  'Crée public.praticiens à partir des métadonnées du signUp. Non bloquant : en cas d''échec, ensureProfile() côté client prend le relais.';


-- ───────────────────────────────────────────────────────────────────
-- 2. Le trigger
-- ───────────────────────────────────────────────────────────────────
drop trigger if exists on_auth_user_created on auth.users;

create trigger on_auth_user_created
  after insert on auth.users
  for each row
  execute function public.handle_new_user();


-- ───────────────────────────────────────────────────────────────────
-- 3. Policies RLS indispensables au filet ensureProfile()
--
-- Le trigger contourne RLS, mais ensureProfile() insère depuis le
-- navigateur avec le rôle authenticated : sans policy INSERT, le filet
-- de sécurité échouerait silencieusement.
--
-- Ces deux policies sont strictement limitées à la ligne du praticien
-- connecté. Elles s'ajoutent à tes policies existantes sans les
-- remplacer (les policies permissives se cumulent en OR).
-- ───────────────────────────────────────────────────────────────────
alter table public.praticiens enable row level security;

drop policy if exists "praticiens_select_own" on public.praticiens;
create policy "praticiens_select_own"
  on public.praticiens
  for select
  to authenticated
  using (auth.uid() = id);

drop policy if exists "praticiens_insert_own" on public.praticiens;
create policy "praticiens_insert_own"
  on public.praticiens
  for insert
  to authenticated
  with check (auth.uid() = id);

-- Rappel : saveProfile() fait un UPDATE. Si tu n'as pas déjà une policy
-- UPDATE, décommente celle-ci, sinon la fiche cabinet ne s'enregistrera
-- plus.
--
-- drop policy if exists "praticiens_update_own" on public.praticiens;
-- create policy "praticiens_update_own"
--   on public.praticiens
--   for update
--   to authenticated
--   using (auth.uid() = id)
--   with check (auth.uid() = id);


-- ───────────────────────────────────────────────────────────────────
-- 4. Rattrapage des comptes déjà créés sans profil  [OPTIONNEL]
--
-- À lancer une fois si des comptes orphelins existent déjà (le bug que
-- ce trigger corrige a pu en produire). Idempotent : relançable sans
-- risque. Inspecte d'abord avec le SELECT, puis lance l'INSERT.
-- ───────────────────────────────────────────────────────────────────

-- Inspection :
-- select u.id, u.email, u.created_at, u.raw_user_meta_data
-- from auth.users u
-- left join public.praticiens p on p.id = u.id
-- where p.id is null
-- order by u.created_at desc;

-- Rattrapage :
-- insert into public.praticiens (id, nom, email, ville, statut, rpps, faculte)
-- select
--   u.id,
--   nullif(btrim(coalesce(u.raw_user_meta_data ->> 'nom', '')), ''),
--   u.email,
--   nullif(btrim(coalesce(u.raw_user_meta_data ->> 'ville', '')), ''),
--   coalesce(nullif(u.raw_user_meta_data ->> 'statut', ''), 'liberal'),
--   nullif(btrim(coalesce(u.raw_user_meta_data ->> 'rpps', '')), ''),
--   nullif(btrim(coalesce(u.raw_user_meta_data ->> 'faculte', '')), '')
-- from auth.users u
-- left join public.praticiens p on p.id = u.id
-- where p.id is null
-- on conflict (id) do nothing;


-- ───────────────────────────────────────────────────────────────────
-- 5. Vérification après exécution
-- ───────────────────────────────────────────────────────────────────

-- Le trigger est bien posé :
-- select tgname, tgenabled
-- from pg_trigger
-- where tgrelid = 'auth.users'::regclass and not tgisinternal;

-- La fonction est bien SECURITY DEFINER (prosecdef doit valoir true)
-- et son search_path est figé :
-- select proname, prosecdef, proconfig
-- from pg_proc
-- where proname = 'handle_new_user';

-- Test de bout en bout : crée un compte depuis le site, puis
-- select id, nom, email, ville, statut, rpps, faculte
-- from public.praticiens order by id desc limit 5;
--
-- Si la ligne manque, la raison est dans Supabase > Logs > Postgres,
-- au niveau WARNING, préfixée « handle_new_user: ».
