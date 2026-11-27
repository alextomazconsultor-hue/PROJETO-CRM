-- Scoped Sub-admin manager access to assigned broker accounts.
create table if not exists public.subadmin_managed_users (
  subadmin_user_id uuid not null references public.usuarios(id) on delete cascade,
  managed_user_id uuid not null references public.usuarios(id) on delete cascade,
  created_by uuid references public.usuarios(id) on delete set null,
  created_at timestamptz not null default now(),
  primary key (subadmin_user_id, managed_user_id),
  check (subadmin_user_id <> managed_user_id)
);

alter table public.subadmin_managed_users enable row level security;
grant select on public.subadmin_managed_users to authenticated;

drop policy if exists subadmin_managed_users_admin_read on public.subadmin_managed_users;
create policy subadmin_managed_users_admin_read
  on public.subadmin_managed_users for select to authenticated
  using (private.current_crm_role() = 'admin');

create or replace function private.subadmin_can_manage_broker(p_broker text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select auth.uid() is not null
    and private.current_crm_role() = 'subadmin'
    and p_broker is not null
    and exists (
      select 1
      from public.subadmin_managed_users scope
      join public.usuarios managed on managed.id = scope.managed_user_id
      where scope.subadmin_user_id = auth.uid()
        and coalesce(nullif(managed.corretor_ref, ''), managed.nome) = p_broker
    );
$$;

create or replace function private.subadmin_can_manage_task(
  p_broker text,
  p_followup_lead_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select auth.uid() is not null
    and private.current_crm_role() = 'subadmin'
    and (
      (p_broker is not null and private.subadmin_can_manage_broker(p_broker))
      or (
        p_followup_lead_id is not null
        and exists (
          select 1
          from public.leads l
          where l.id = p_followup_lead_id
            and private.subadmin_can_manage_broker(l.corretor)
        )
      )
    );
$$;

create or replace function public.admin_set_subadmin_managed_users(
  p_subadmin_user_id uuid,
  p_managed_user_ids uuid[]
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_admin_id uuid := auth.uid();
begin
  if v_admin_id is null or private.current_crm_role() <> 'admin' then
    raise exception 'Apenas um administrador pode configurar a equipe do Sub-adm';
  end if;

  if not exists (
    select 1 from public.usuarios
    where id = p_subadmin_user_id and perfil = 'subadmin'
  ) then
    raise exception 'Selecione um usuário com perfil Sub-adm';
  end if;

  if exists (
    select 1
    from unnest(coalesce(p_managed_user_ids, '{}'::uuid[])) as requested(id)
    left join public.usuarios u on u.id = requested.id
    where u.id is null or not exists (
      select 1 from public.corretores c
      where c.nome = coalesce(nullif(u.corretor_ref, ''), u.nome)
    )
  ) then
    raise exception 'A equipe do Sub-adm pode incluir apenas usuários associados a corretores cadastrados';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(9134, 4);

  delete from public.subadmin_managed_users
  where subadmin_user_id = p_subadmin_user_id;

  insert into public.subadmin_managed_users (subadmin_user_id, managed_user_id, created_by)
  select p_subadmin_user_id, requested.id, v_admin_id
  from (
    select distinct id
    from unnest(coalesce(p_managed_user_ids, '{}'::uuid[])) as requested(id)
  ) requested;
end;
$$;

create or replace function public.subadmin_list_managed_users()
returns table (id uuid, nome text, email text, perfil text, corretor_ref text)
language plpgsql
security definer
set search_path = ''
as $$
begin
  if auth.uid() is null or private.current_crm_role() <> 'subadmin' then
    raise exception 'Apenas Sub-adms podem consultar a equipe autorizada';
  end if;

  return query
  select u.id, u.nome, u.email, u.perfil,
         coalesce(nullif(u.corretor_ref, ''), u.nome)
  from public.subadmin_managed_users scope
  join public.usuarios u on u.id = scope.managed_user_id
  where scope.subadmin_user_id = auth.uid()
  order by u.nome;
end;
$$;

revoke all on function private.subadmin_can_manage_broker(text) from public;
revoke all on function private.subadmin_can_manage_task(text, uuid) from public;
revoke all on function public.admin_set_subadmin_managed_users(uuid, uuid[]) from public;
revoke all on function public.subadmin_list_managed_users() from public;
grant execute on function private.subadmin_can_manage_broker(text) to authenticated;
grant execute on function private.subadmin_can_manage_task(text, uuid) to authenticated;
grant execute on function public.admin_set_subadmin_managed_users(uuid, uuid[]) to authenticated;
grant execute on function public.subadmin_list_managed_users() to authenticated;

drop policy if exists leads_team_select on public.leads;
create policy leads_team_select on public.leads for select to authenticated
  using (
    private.current_crm_role() = any (array['admin', 'gestor'])
    or (private.current_crm_role() = 'subadmin' and private.subadmin_can_manage_broker(corretor))
    or corretor = private.current_crm_broker()
  );

drop policy if exists leads_team_insert on public.leads;
create policy leads_team_insert on public.leads for insert to authenticated
  with check (
    private.current_crm_role() = any (array['admin', 'gestor'])
    or (private.current_crm_role() = 'subadmin' and private.subadmin_can_manage_broker(corretor))
    or corretor = private.current_crm_broker()
  );

drop policy if exists leads_team_update on public.leads;
create policy leads_team_update on public.leads for update to authenticated
  using (
    private.current_crm_role() = any (array['admin', 'gestor'])
    or (private.current_crm_role() = 'subadmin' and private.subadmin_can_manage_broker(corretor))
    or corretor = private.current_crm_broker()
  )
  with check (
    private.current_crm_role() = any (array['admin', 'gestor'])
    or (private.current_crm_role() = 'subadmin' and private.subadmin_can_manage_broker(corretor))
    or corretor = private.current_crm_broker()
  );

drop policy if exists leads_team_delete on public.leads;
create policy leads_team_delete on public.leads for delete to authenticated
  using (
    private.current_crm_role() = any (array['admin', 'gestor'])
    or (private.current_crm_role() = 'subadmin' and private.subadmin_can_manage_broker(corretor))
  );

drop policy if exists tarefas_team_select on public.tarefas;
create policy tarefas_team_select on public.tarefas for select to authenticated
  using (
    private.current_crm_role() = any (array['admin', 'gestor'])
    or private.subadmin_can_manage_task(corretor, followup_lead_id)
    or (private.current_crm_role() = 'corretor' and (corretor = private.current_crm_broker() or corretor is null))
  );

drop policy if exists tarefas_team_insert on public.tarefas;
create policy tarefas_team_insert on public.tarefas for insert to authenticated
  with check (
    private.current_crm_role() = any (array['admin', 'gestor'])
    or private.subadmin_can_manage_task(corretor, followup_lead_id)
    or (private.current_crm_role() = 'corretor' and corretor = private.current_crm_broker())
  );

drop policy if exists tarefas_team_update on public.tarefas;
create policy tarefas_team_update on public.tarefas for update to authenticated
  using (
    private.current_crm_role() = any (array['admin', 'gestor'])
    or private.subadmin_can_manage_task(corretor, followup_lead_id)
    or (private.current_crm_role() = 'corretor' and corretor = private.current_crm_broker())
  )
  with check (
    private.current_crm_role() = any (array['admin', 'gestor'])
    or private.subadmin_can_manage_task(corretor, followup_lead_id)
    or (private.current_crm_role() = 'corretor' and corretor = private.current_crm_broker())
  );

drop policy if exists tarefas_team_delete on public.tarefas;
create policy tarefas_team_delete on public.tarefas for delete to authenticated
  using (
    private.current_crm_role() = any (array['admin', 'gestor'])
    or private.subadmin_can_manage_task(corretor, followup_lead_id)
  );

drop policy if exists historico_team_select on public.historico;
create policy historico_team_select on public.historico for select to authenticated
  using (
    private.current_crm_role() = any (array['admin', 'gestor'])
    or exists (
      select 1 from public.leads l
      where l.id = historico.lead_id
        and (
          l.corretor = private.current_crm_broker()
          or private.subadmin_can_manage_broker(l.corretor)
        )
    )
  );

drop policy if exists historico_team_insert on public.historico;
create policy historico_team_insert on public.historico for insert to authenticated
  with check (
    private.current_crm_role() = any (array['admin', 'gestor'])
    or exists (
      select 1 from public.leads l
      where l.id = historico.lead_id
        and (
          l.corretor = private.current_crm_broker()
          or private.subadmin_can_manage_broker(l.corretor)
        )
    )
  );

drop policy if exists simulacoes_team_select on public.simulacoes_pagamento;
create policy simulacoes_team_select on public.simulacoes_pagamento for select to authenticated
  using (
    private.current_crm_role() = any (array['admin', 'gestor'])
    or (private.current_crm_role() = 'subadmin' and private.subadmin_can_manage_broker(corretor))
    or corretor = private.current_crm_broker()
  );

drop policy if exists simulacoes_team_insert on public.simulacoes_pagamento;
create policy simulacoes_team_insert on public.simulacoes_pagamento for insert to authenticated
  with check (
    created_by = auth.uid()
    and (
      private.current_crm_role() = any (array['admin', 'gestor'])
      or (private.current_crm_role() = 'subadmin' and private.subadmin_can_manage_broker(corretor))
      or corretor = private.current_crm_broker()
    )
  );

drop policy if exists simulacoes_team_update on public.simulacoes_pagamento;
create policy simulacoes_team_update on public.simulacoes_pagamento for update to authenticated
  using (
    private.current_crm_role() = any (array['admin', 'gestor'])
    or (private.current_crm_role() = 'subadmin' and private.subadmin_can_manage_broker(corretor))
    or corretor = private.current_crm_broker()
  )
  with check (
    private.current_crm_role() = any (array['admin', 'gestor'])
    or (private.current_crm_role() = 'subadmin' and private.subadmin_can_manage_broker(corretor))
    or corretor = private.current_crm_broker()
  );

drop policy if exists simulacoes_team_delete on public.simulacoes_pagamento;
create policy simulacoes_team_delete on public.simulacoes_pagamento for delete to authenticated
  using (
    private.current_crm_role() = any (array['admin', 'gestor'])
    or (private.current_crm_role() = 'subadmin' and private.subadmin_can_manage_broker(corretor))
    or corretor = private.current_crm_broker()
  );

-- Keep the administrator's one-time promotion allowlist saveable.
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

  perform pg_catalog.pg_advisory_xact_lock(9134, 3);

  delete from public.subadmin_authorized_users
  where target_user_id is not null;

  insert into public.subadmin_authorized_users (target_user_id, authorized_by)
  select distinct requested.id, v_admin_id
  from unnest(coalesce(p_target_user_ids, '{}'::uuid[])) as requested(id);
end;
$$;


-- Keep these SECURITY DEFINER RPCs unavailable to anonymous callers.
revoke all on function public.admin_set_subadmin_authorizations(uuid[]) from public, anon;
revoke all on function public.admin_set_subadmin_managed_users(uuid, uuid[]) from public, anon;
revoke all on function public.subadmin_list_authorized_users() from public, anon, authenticated;
revoke all on function public.subadmin_list_managed_users() from public, anon;
revoke all on function public.subadmin_promote_authorized_user(uuid) from public, anon, authenticated;

grant execute on function public.admin_set_subadmin_authorizations(uuid[]) to authenticated;
grant execute on function public.admin_set_subadmin_managed_users(uuid, uuid[]) to authenticated;
grant execute on function public.subadmin_list_managed_users() to authenticated;
