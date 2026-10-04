begin;
create table public.followup_sequencias (
  id uuid primary key default gen_random_uuid(),
  nome text not null check (char_length(nome) between 1 and 180),
  descricao text not null default '',
  passos jsonb not null default '[]'::jsonb check (jsonb_typeof(passos)='array'),
  ativa boolean not null default false,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now()
);
create table public.followup_leads (
  lead_id uuid primary key references public.leads(id) on delete cascade,
  sequencia_id uuid not null references public.followup_sequencias(id),
  estado text not null default 'ativo' check (estado in ('ativo','pausado','concluido')),
  etapa_atual integer not null default 0 check (etapa_atual>=0),
  iniciado_em timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index followup_leads_sequencia_idx on public.followup_leads(sequencia_id);
create index followup_sequencias_creator_idx on public.followup_sequencias(created_by);
alter table public.followup_sequencias enable row level security;
alter table public.followup_leads enable row level security;
grant select,insert,update,delete on public.followup_sequencias,public.followup_leads to authenticated;
revoke all on public.followup_sequencias,public.followup_leads from anon;
create policy followup_sequences_read on public.followup_sequencias for select to authenticated using (private.current_crm_role() in ('admin','gestor','corretor'));
create policy followup_sequences_insert on public.followup_sequencias for insert to authenticated with check (private.current_crm_role() in ('admin','gestor') and created_by=auth.uid());
create policy followup_sequences_update on public.followup_sequencias for update to authenticated using (private.current_crm_role() in ('admin','gestor')) with check (private.current_crm_role() in ('admin','gestor'));
create policy followup_sequences_delete on public.followup_sequencias for delete to authenticated using (private.current_crm_role() in ('admin','gestor'));
create policy followup_leads_read on public.followup_leads for select to authenticated using (exists(select 1 from public.leads l where l.id=lead_id));
create policy followup_leads_insert on public.followup_leads for insert to authenticated with check (exists(select 1 from public.leads l where l.id=lead_id) and exists(select 1 from public.followup_sequencias s where s.id=sequencia_id and s.ativa and jsonb_array_length(s.passos)>0));
create policy followup_leads_update on public.followup_leads for update to authenticated using (exists(select 1 from public.leads l where l.id=lead_id)) with check (exists(select 1 from public.leads l where l.id=lead_id) and exists(select 1 from public.followup_sequencias s where s.id=sequencia_id));
create policy followup_leads_delete on public.followup_leads for delete to authenticated using (exists(select 1 from public.leads l where l.id=lead_id));
commit;