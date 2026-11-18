-- Etapas editáveis do funil Grupo VIP AYRA.
create table if not exists public.vip_ayra_etapas (
  id text primary key,
  nome text not null,
  cor text not null default '#8b5cf6',
  ordem integer not null default 0,
  created_at timestamptz not null default now()
);

alter table public.vip_ayra_etapas enable row level security;

drop policy if exists vip_ayra_etapas_select on public.vip_ayra_etapas;
create policy vip_ayra_etapas_select
  on public.vip_ayra_etapas for select to authenticated
  using (true);

drop policy if exists vip_ayra_etapas_insert on public.vip_ayra_etapas;
create policy vip_ayra_etapas_insert
  on public.vip_ayra_etapas for insert to authenticated
  with check (private.current_crm_role() = any (array['admin'::text, 'gestor'::text]));

drop policy if exists vip_ayra_etapas_update on public.vip_ayra_etapas;
create policy vip_ayra_etapas_update
  on public.vip_ayra_etapas for update to authenticated
  using (private.current_crm_role() = any (array['admin'::text, 'gestor'::text]))
  with check (private.current_crm_role() = any (array['admin'::text, 'gestor'::text]));

drop policy if exists vip_ayra_etapas_delete on public.vip_ayra_etapas;
create policy vip_ayra_etapas_delete
  on public.vip_ayra_etapas for delete to authenticated
  using (private.current_crm_role() = any (array['admin'::text, 'gestor'::text]));

insert into public.vip_ayra_etapas (id, nome, cor, ordem) values
  ('aceitou', 'Aceitou o convite', '#3b82f6', 0),
  ('adicionado', 'Adicionado ao grupo', '#10b981', 1),
  ('acompanhamento', 'Em acompanhamento', '#f59e0b', 2),
  ('interesse', 'Interesse em unidade', '#8b5cf6', 3),
  ('negociacao', 'Encaminhado para negociação', '#ec4899', 4)
on conflict (id) do nothing;
