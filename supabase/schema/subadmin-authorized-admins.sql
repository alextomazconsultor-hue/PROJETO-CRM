-- Sub-administrator role with an admin-managed, one-time promotion allowlist.
create table if not exists public.subadmin_authorized_users (
  target_user_id uuid primary key references public.usuarios(id) on delete cascade,
  authorized_by uuid references public.usuarios(id) on delete set null,
  created_at timestamptz not null default now()
);

create table if not exists public.subadmin_role_promotions (
  id uuid primary key default gen_random_uuid(),
  actor_id uuid not null references public.usuarios(id) on delete restrict,
  target_user_id uuid not null references public.usuarios(id) on delete restrict,
  previous_profile text not null,
  promoted_at timestamptz not null default now()
);

alter table public.subadmin_authorized_users enable row level security;
alter table public.subadmin_role_promotions enable row level security;

grant select on public.subadmin_authorized_users to authenticated;
grant select on public.subadmin_role_promotions to authenticated;

create policy subadmin_authorizations_admin_read
  on public.subadmin_authorized_users for select to authenticated
  using (private.current_crm_role() = 'admin');

create policy subadmin_authorizations_admin_insert
  on public.subadmin_authorized_users for insert to authenticated
  with check (private.current_crm_role() = 'admin' and authorized_by = auth.uid());

create policy subadmin_authorizations_admin_delete
  on public.subadmin_authorized_users for delete to authenticated
  using (private.current_crm_role() = 'admin');

create policy subadmin_promotions_admin_read
  on public.subadmin_role_promotions for select to authenticated
  using (private.current_crm_role() = 'admin');

create or replace function public.admin_set_subadmin_authorizations(p_target_user_ids uuid[])
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_admin_id uuid := auth.uid();
begin
  if v_admin_id is null or private.current_crm_role() <> 'admin' then
    raise exception 'Apenas um administrador pode alterar a lista autorizada';
  end if;

  if exists (
    select 1
    from unnest(coalesce(p_target_user_ids, '{}'::uuid[])) as requested(id)
    left join public.usuarios u on u.id = requested.id
    where u.id is null or u.perfil in ('admin', 'subadmin')
  ) then
    raise exception 'A lista pode incluir apenas usuários existentes que ainda não sejam administradores ou sub-administradores';
  end if;

  delete from public.subadmin_authorized_users;

  insert into public.subadmin_authorized_users (target_user_id, authorized_by)
  select distinct requested.id, v_admin_id
  from unnest(coalesce(p_target_user_ids, '{}'::uuid[])) as requested(id);
end;
$$;

create or replace function public.subadmin_list_authorized_users()
returns table (id uuid, nome text, email text, perfil text)
language plpgsql
security definer
set search_path = ''
as $$
begin
  if auth.uid() is null or private.current_crm_role() <> 'subadmin' then
    raise exception 'Apenas sub-administradores podem consultar a lista de promoção';
  end if;

  return query
  select u.id, u.nome, u.email, u.perfil
  from public.subadmin_authorized_users a
  join public.usuarios u on u.id = a.target_user_id
  order by u.nome;
end;
$$;

create or replace function public.subadmin_promote_authorized_user(p_target_user_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor_id uuid := auth.uid();
  v_previous_profile text;
begin
  if v_actor_id is null or private.current_crm_role() <> 'subadmin' then
    raise exception 'Apenas sub-administradores podem promover usuários autorizados';
  end if;

  select u.perfil into v_previous_profile
  from public.usuarios u
  where u.id = p_target_user_id
  for update;

  if not found or v_previous_profile not in ('corretor', 'gestor') then
    raise exception 'O usuário não pode ser promovido por esta ação';
  end if;

  if not exists (
    select 1 from public.subadmin_authorized_users a
    where a.target_user_id = p_target_user_id
  ) then
    raise exception 'Este usuário não está na lista autorizada pelo administrador';
  end if;

  update public.usuarios set perfil = 'admin' where id = p_target_user_id;

  insert into public.subadmin_role_promotions (actor_id, target_user_id, previous_profile)
  values (v_actor_id, p_target_user_id, v_previous_profile);

  delete from public.subadmin_authorized_users where target_user_id = p_target_user_id;
end;
$$;

revoke all on function public.admin_set_subadmin_authorizations(uuid[]) from public;
revoke all on function public.subadmin_list_authorized_users() from public;
revoke all on function public.subadmin_promote_authorized_user(uuid) from public;

grant execute on function public.admin_set_subadmin_authorizations(uuid[]) to authenticated;
grant execute on function public.subadmin_list_authorized_users() to authenticated;
grant execute on function public.subadmin_promote_authorized_user(uuid) to authenticated;
