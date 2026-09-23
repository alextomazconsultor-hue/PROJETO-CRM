create schema if not exists private;

create or replace function private.current_crm_role()
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select u.perfil
  from public.usuarios u
  where u.id = auth.uid()
  limit 1
$$;

create or replace function private.current_crm_broker()
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(u.corretor_ref, u.nome)
  from public.usuarios u
  where u.id = auth.uid()
  limit 1
$$;

revoke all on function private.current_crm_role() from public;
revoke all on function private.current_crm_broker() from public;
grant usage on schema private to authenticated;
grant execute on function private.current_crm_role() to authenticated;
grant execute on function private.current_crm_broker() to authenticated;

create table if not exists public.assistant_threads (
  id uuid primary key default gen_random_uuid(),
  title text not null default 'Conversa da equipe',
  created_by uuid not null references auth.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.assistant_messages (
  id bigint generated always as identity primary key,
  thread_id uuid not null references public.assistant_threads(id) on delete cascade,
  user_id uuid references auth.users(id),
  role text not null check (role in ('user', 'assistant')),
  author_name text not null,
  content text not null,
  action jsonb,
  created_at timestamptz not null default now()
);

create index if not exists assistant_messages_thread_created_idx
  on public.assistant_messages(thread_id, created_at);
create index if not exists assistant_messages_user_id_idx
  on public.assistant_messages(user_id);
create index if not exists assistant_threads_created_by_idx
  on public.assistant_threads(created_by);

alter table public.assistant_threads enable row level security;
alter table public.assistant_messages enable row level security;

drop policy if exists assistant_threads_team_select on public.assistant_threads;
drop policy if exists assistant_threads_team_insert on public.assistant_threads;
drop policy if exists assistant_messages_team_select on public.assistant_messages;

create policy assistant_threads_team_select
on public.assistant_threads for select to authenticated
using (private.current_crm_role() is not null);

create policy assistant_threads_team_insert
on public.assistant_threads for insert to authenticated
with check (created_by = (select auth.uid()) and private.current_crm_role() is not null);

create policy assistant_messages_team_select
on public.assistant_messages for select to authenticated
using (private.current_crm_role() is not null);

grant select, insert on public.assistant_threads to authenticated;
grant select on public.assistant_messages to authenticated;

-- Protege os dados principais do CRM. Gestores e administradores veem a equipe;
-- corretores veem e alteram somente os próprios registros.
alter table public.leads enable row level security;
alter table public.tarefas enable row level security;
alter table public.historico enable row level security;

drop policy if exists acesso_leads on public.leads;
drop policy if exists acesso_tarefas on public.tarefas;
drop policy if exists acesso_historico on public.historico;

create policy leads_team_select on public.leads for select to authenticated
using (
  private.current_crm_role() in ('admin', 'gestor')
  or corretor = private.current_crm_broker()
);
create policy leads_team_insert on public.leads for insert to authenticated
with check (
  private.current_crm_role() in ('admin', 'gestor')
  or corretor = private.current_crm_broker()
);
create policy leads_team_update on public.leads for update to authenticated
using (
  private.current_crm_role() in ('admin', 'gestor')
  or corretor = private.current_crm_broker()
)
with check (
  private.current_crm_role() in ('admin', 'gestor')
  or corretor = private.current_crm_broker()
);
create policy leads_team_delete on public.leads for delete to authenticated
using (private.current_crm_role() in ('admin', 'gestor'));

create policy tarefas_team_select on public.tarefas for select to authenticated
using (
  private.current_crm_role() in ('admin', 'gestor')
  or corretor = private.current_crm_broker()
  or corretor is null
);
create policy tarefas_team_insert on public.tarefas for insert to authenticated
with check (
  private.current_crm_role() in ('admin', 'gestor')
  or corretor = private.current_crm_broker()
);
create policy tarefas_team_update on public.tarefas for update to authenticated
using (
  private.current_crm_role() in ('admin', 'gestor')
  or corretor = private.current_crm_broker()
)
with check (
  private.current_crm_role() in ('admin', 'gestor')
  or corretor = private.current_crm_broker()
);
create policy tarefas_team_delete on public.tarefas for delete to authenticated
using (private.current_crm_role() in ('admin', 'gestor'));

create policy historico_team_select on public.historico for select to authenticated
using (
  private.current_crm_role() in ('admin', 'gestor')
  or exists (
    select 1 from public.leads l
    where l.id = historico.lead_id
      and l.corretor = private.current_crm_broker()
  )
);
create policy historico_team_insert on public.historico for insert to authenticated
with check (
  private.current_crm_role() in ('admin', 'gestor')
  or exists (
    select 1 from public.leads l
    where l.id = historico.lead_id
      and l.corretor = private.current_crm_broker()
  )
);

grant select, insert, update, delete on public.leads to authenticated;
grant select, insert, update, delete on public.tarefas to authenticated;
grant select, insert on public.historico to authenticated;
