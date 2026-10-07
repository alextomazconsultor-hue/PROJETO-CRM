-- Explicit client links: existing cards each retain their own identity.
alter table public.leads add column if not exists cliente_grupo uuid not null default gen_random_uuid();
create index if not exists leads_cliente_grupo_idx on public.leads(cliente_grupo);
create or replace function public.crm_new_deal(p_source uuid,p_id uuid,p_enterprise text,p_broker text,p_stage text default 'novo',p_value numeric default 0,p_note text default '')
returns public.leads language plpgsql security invoker set search_path='' as $$
declare source public.leads; created public.leads;
begin
 select * into source from public.leads where id=p_source for update;
 if not found then raise exception 'Negócio original indisponível'; end if;
 if p_id is null or p_id=p_source then raise exception 'Identificador inválido'; end if;
 select * into created from public.leads where id=p_id;
 if found then
  if created.cliente_grupo=source.cliente_grupo then return created; end if;
  raise exception 'Identificador já utilizado';
 end if;
 if nullif(trim(p_enterprise),'') is null or not exists(select 1 from public.empreendimentos where nome=p_enterprise) then raise exception 'Selecione o empreendimento'; end if;
 if nullif(trim(p_broker),'') is null or not exists(select 1 from public.corretores where nome=p_broker) then raise exception 'Selecione o corretor'; end if;
 if not exists(select 1 from public.etapas where id=p_stage) then raise exception 'Selecione a etapa'; end if;
 if p_value is null or p_value<0 or p_value>999999999999.99 then raise exception 'Valor da negociação inválido'; end if;
 if length(coalesce(p_note,''))>4000 then raise exception 'Observação muito longa'; end if;
 -- Preserve unambiguous legacy tasks before adding a second card with the same name.
 if (select count(*) from public.leads where nome=source.nome)=1 then
  update public.tarefas set lead_rel=source.id::text where lead_rel=source.nome and corretor=source.corretor;
 end if;
 insert into public.leads(id,nome,telefone,email,cidade,origem,empreendimento,corretor,status,valor_negociacao,observacoes,cliente_grupo)
 values(p_id,source.nome,source.telefone,source.email,source.cidade,source.origem,p_enterprise,p_broker,p_stage,p_value,coalesce(p_note,''),source.cliente_grupo) returning * into created;
 insert into public.historico(lead_id,texto,tipo) values(created.id,'Novo negócio criado para o mesmo cliente. Empreendimento: '||p_enterprise,'create');
 -- The source record stays unchanged; only an audit note is added.
 insert into public.historico(lead_id,texto,tipo) values(source.id,'Novo negócio vinculado ao cliente: '||p_enterprise,'note');
 return created;
end $$;
revoke all on function public.crm_new_deal(uuid,uuid,text,text,text,numeric,text) from public,anon;
grant execute on function public.crm_new_deal(uuid,uuid,text,text,text,numeric,text) to authenticated;
