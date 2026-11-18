-- Campos de acompanhamento de perdas do Grupo VIP AYRA.
alter table public.leads
  add column if not exists vip_ayra_perdido boolean not null default false,
  add column if not exists vip_ayra_perdido_motivo text,
  add column if not exists vip_ayra_perdido_em timestamptz;

comment on column public.leads.vip_ayra_perdido is 'Indica que o contato foi marcado como perdido no funil VIP AYRA; nao altera a etapa do funil.';
comment on column public.leads.vip_ayra_perdido_motivo is 'Motivo informado ao marcar o contato como perdido no funil VIP AYRA.';
comment on column public.leads.vip_ayra_perdido_em is 'Data em que o contato foi marcado como perdido no funil VIP AYRA.';
