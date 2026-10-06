-- Follow-up execution: invoker functions preserve existing CRM row permissions.
alter table public.followup_leads add column if not exists run_id uuid default gen_random_uuid();
alter table public.followup_leads add column if not exists passos_snapshot jsonb not null default '[]';
alter table public.followup_leads add column if not exists nome_snapshot text;
alter table public.tarefas add column if not exists followup_lead_id uuid references public.leads(id) on delete cascade;
alter table public.tarefas add column if not exists followup_run uuid;
alter table public.tarefas add column if not exists followup_step integer;
create index if not exists tarefas_followup_lead_idx on public.tarefas(followup_lead_id);
create unique index if not exists tarefas_followup_step_unique on public.tarefas(followup_run,followup_step) where followup_run is not null;
alter policy followup_sequences_insert on public.followup_sequencias with check (private.current_crm_role() in ('admin','gestor') and created_by=(select auth.uid()));

create or replace function public.crm_followup_start(p_lead uuid,p_sequence uuid,p_date timestamptz)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare l public.leads; s public.followup_sequencias; e public.followup_leads; t public.tarefas;
begin
 select * into l from public.leads where id=p_lead for update;
 if not found then raise exception 'Lead indisponível'; end if;
 select * into s from public.followup_sequencias where id=p_sequence and ativa;
 if not found or jsonb_array_length(s.passos)=0 then raise exception 'Sequência indisponível'; end if;
 select * into e from public.followup_leads where lead_id=p_lead for update;
 if found and e.sequencia_id=p_sequence and e.estado='ativo' and jsonb_array_length(e.passos_snapshot)>0 then return to_jsonb(e); end if;
 if p_date is null or p_date<=now() then raise exception 'Escolha uma data futura'; end if;
 if nullif(l.corretor,'') is null then raise exception 'Defina o corretor responsável antes de iniciar'; end if;
 update public.tarefas set concluida=true,resultado='Cancelada: substituição da sequência',concluida_em=now() where followup_lead_id=p_lead and not concluida;
 insert into public.followup_leads(lead_id,sequencia_id,estado,etapa_atual,iniciado_em,updated_at,run_id,passos_snapshot,nome_snapshot)
 values(p_lead,p_sequence,'ativo',0,now(),now(),gen_random_uuid(),s.passos,s.nome)
 on conflict(lead_id) do update set sequencia_id=excluded.sequencia_id,estado='ativo',etapa_atual=0,iniciado_em=now(),updated_at=now(),run_id=excluded.run_id,passos_snapshot=excluded.passos_snapshot,nome_snapshot=excluded.nome_snapshot returning * into e;
 insert into public.tarefas(titulo,lead_rel,corretor,data_hora,prioridade,notas,followup_lead_id,followup_run,followup_step)
 values(s.passos->0->>'titulo',p_lead::text,l.corretor,p_date,'media',coalesce(s.passos->0->>'orientacao',''),p_lead,e.run_id,0) returning * into t;
 if l.status<>'followup' then
  update public.leads set status='followup' where id=p_lead;
  insert into public.historico(lead_id,texto,tipo) values(p_lead,'Movido para Follow-up ao iniciar sequência','move');
 end if;
 insert into public.historico(lead_id,texto,tipo) values(p_lead,'Iniciada sequência: '||s.nome||'. Primeira tarefa: '||t.titulo,'note');
 return to_jsonb(e);
end $$;

create or replace function public.crm_followup_state(p_lead uuid,p_state text,p_date timestamptz default null)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare l public.leads; e public.followup_leads;
begin
 select * into l from public.leads where id=p_lead for update;
 if not found then raise exception 'Lead indisponível'; end if;
 select * into e from public.followup_leads where lead_id=p_lead for update;
 if not found or p_state not in ('ativo','pausado','concluido') then raise exception 'Acompanhamento indisponível'; end if;
 if e.estado=p_state then return to_jsonb(e); end if;
 if p_state='ativo' then
  if e.estado='concluido' or e.etapa_atual>=jsonb_array_length(e.passos_snapshot) then raise exception 'Inicie uma nova sequência'; end if;
  if p_date is null or p_date<=now() then raise exception 'Escolha uma data futura'; end if;
  if l.status<>'followup' then raise exception 'Volte o lead para Follow-up antes de retomar'; end if;
  update public.tarefas set concluida=false,resultado=null,concluida_em=null,data_hora=p_date,corretor=l.corretor where followup_run=e.run_id and followup_step=e.etapa_atual;
 else
  update public.tarefas set concluida=true,resultado='Cancelada: acompanhamento '||p_state,concluida_em=now() where followup_run=e.run_id and not concluida;
 end if;
 update public.followup_leads set estado=p_state,updated_at=now() where lead_id=p_lead returning * into e;
 insert into public.historico(lead_id,texto,tipo) values(p_lead,'Sequência '||coalesce(e.nome_snapshot,'')||': '||p_state,'note');
 return to_jsonb(e);
end $$;

create or replace function public.crm_followup_complete(p_task uuid,p_outcome text,p_action text,p_note text default '',p_date timestamptz default null,p_stage text default 'atendimento')
returns jsonb language plpgsql security invoker set search_path='' as $$
declare l public.leads; e public.followup_leads; t public.tarefas; step integer; due timestamptz; target text;
begin
 select * into t from public.tarefas where id=p_task;
 if not found or t.followup_lead_id is null then raise exception 'Tarefa indisponível'; end if;
 select * into l from public.leads where id=t.followup_lead_id for update;
 if not found then raise exception 'Lead indisponível'; end if;
 select * into e from public.followup_leads where lead_id=l.id for update;
 select * into t from public.tarefas where id=p_task for update;
 if t.concluida then return jsonb_build_object('already_completed',true); end if;
 if e.estado<>'ativo' or e.run_id<>t.followup_run or e.etapa_atual<>t.followup_step or l.status<>'followup' then raise exception 'Esta tarefa não pertence ao acompanhamento ativo em Follow-up'; end if;
 if p_outcome not in ('Não respondeu','Respondeu','Pediu mais tempo','Sem interesse') or p_action not in ('call','message','audio','visit','contact') then raise exception 'Selecione ação e resultado'; end if;
 if length(coalesce(p_note,''))>4000 then raise exception 'Anotação muito longa'; end if;
 if p_outcome='Sem interesse' and nullif(trim(p_note),'') is null then raise exception 'Informe o motivo do descarte'; end if;
 if p_outcome='Pediu mais tempo' and (p_date is null or p_date<=now()) then raise exception 'Escolha uma data futura'; end if;
 if p_outcome='Respondeu' and p_stage not in ('atendimento','visita','proposta') then raise exception 'Etapa inválida'; end if;
 update public.tarefas set concluida=true,resultado=p_outcome||case when coalesce(p_note,'')<>'' then ' · '||p_note else '' end,concluida_em=now() where id=p_task;
 insert into public.historico(lead_id,texto,tipo) values(l.id,t.titulo||'. Resultado: '||p_outcome||case when coalesce(p_note,'')<>'' then '. '||p_note else '' end,p_action);
 if p_outcome in ('Respondeu','Sem interesse') then
  target:=case when p_outcome='Sem interesse' then 'perdido' else p_stage end;
  update public.leads set status=target where id=l.id;
  update public.followup_leads set estado=case when p_outcome='Sem interesse' then 'concluido' else 'pausado' end,updated_at=now() where lead_id=l.id;
  insert into public.historico(lead_id,texto,tipo) values(l.id,'Movido de Follow-up para '||target||case when p_outcome='Sem interesse' then '. Motivo: '||p_note else '' end,'move');
 else
  step:=e.etapa_atual+1;
  if p_outcome='Pediu mais tempo' then
   step:=e.etapa_atual;
   -- A nova data reabre o passo atual; o contato permanece no histórico.
   update public.tarefas set concluida=false,resultado=null,concluida_em=null,data_hora=p_date,corretor=l.corretor where id=p_task;
  elsif step<jsonb_array_length(e.passos_snapshot) then
   due:=now()+make_interval(days=>greatest(1,(e.passos_snapshot->step->>'dias')::integer));
   insert into public.tarefas(titulo,lead_rel,corretor,data_hora,prioridade,notas,followup_lead_id,followup_run,followup_step)
   values(e.passos_snapshot->step->>'titulo',l.id::text,l.corretor,due,'media',coalesce(e.passos_snapshot->step->>'orientacao',''),l.id,e.run_id,step);
  else
   insert into public.historico(lead_id,texto,tipo) values(l.id,'Sequência concluída sem resposta. Revisar o próximo acompanhamento.','note');
  end if;
  update public.followup_leads set etapa_atual=step,estado=case when step>=jsonb_array_length(e.passos_snapshot) then 'concluido' else 'ativo' end,updated_at=now() where lead_id=l.id;
 end if;
 return jsonb_build_object('ok',true,'lead_id',l.id);
end $$;
revoke all on function public.crm_followup_start(uuid,uuid,timestamptz) from public,anon;
revoke all on function public.crm_followup_state(uuid,text,timestamptz) from public,anon;
revoke all on function public.crm_followup_complete(uuid,text,text,text,timestamptz,text) from public,anon;
grant execute on function public.crm_followup_start(uuid,uuid,timestamptz),public.crm_followup_state(uuid,text,timestamptz),public.crm_followup_complete(uuid,text,text,text,timestamptz,text) to authenticated;

create or replace function public.crm_followup_on_stage_change()
returns trigger language plpgsql security invoker set search_path='' as $$
begin
 if old.corretor is distinct from new.corretor and nullif(new.corretor,'') is not null then
  update public.tarefas set corretor=new.corretor where followup_lead_id=new.id and not concluida;
 end if;
 if old.status='followup' and new.status<>'followup' then
  update public.followup_leads set estado=case when new.status in ('fechada','perdido') then 'concluido' else 'pausado' end,updated_at=now() where lead_id=new.id and estado='ativo';
  update public.tarefas set concluida=true,resultado='Cancelada: lead saiu de Follow-up',concluida_em=now() where followup_lead_id=new.id and not concluida;
 end if;
 return new;
end $$;
revoke all on function public.crm_followup_on_stage_change() from public,anon;
drop trigger if exists crm_followup_stage_change on public.leads;
create trigger crm_followup_stage_change after update of status,corretor on public.leads for each row execute function public.crm_followup_on_stage_change();

insert into public.followup_sequencias(nome,descricao,ativa,passos)
select v.nome,v.descricao,true,v.passos::jsonb from (values
 ('Sem resposta','Tentativas nos dias 1, 3, 7 e 14, se os contatos forem realizados no prazo.', '[{"titulo":"Retomar contato","dias":1,"orientacao":"Mensagem curta para iniciar uma conversa."},{"titulo":"Tentar ligação","dias":2,"orientacao":"Tente outro canal de contato."},{"titulo":"Enviar informação útil","dias":4,"orientacao":"Compartilhe algo relacionado ao interesse do lead."},{"titulo":"Última tentativa da sequência","dias":7,"orientacao":"Pergunte se deseja continuar recebendo informações."}]'),
 ('Compra futura','Primeiro contato na data combinada; revisões a cada 30 dias.', '[{"titulo":"Retorno na data combinada","dias":1,"orientacao":"Confira o momento de compra e o que mudou."},{"titulo":"Revisar planejamento de compra","dias":30,"orientacao":"Atualize o prazo e o perfil de imóvel."},{"titulo":"Apresentar opções atuais","dias":30,"orientacao":"Envie opções compatíveis com o planejamento."},{"titulo":"Revisar interesse de compra","dias":30,"orientacao":"Combine a próxima data ou encerre o acompanhamento."}]'),
 ('Aguardando oportunidade','Escolha a primeira data; revisões a cada 30 dias. Antecipe a tarefa quando surgir a oportunidade.', '[{"titulo":"Verificar oportunidade buscada","dias":1,"orientacao":"Confira unidade, condição ou lançamento esperado."},{"titulo":"Revisar oportunidades disponíveis","dias":30,"orientacao":"Apresente novidades compatíveis com o interesse."},{"titulo":"Atualizar critérios da busca","dias":30,"orientacao":"Confirme se a busca permanece igual."},{"titulo":"Revisar continuidade da busca","dias":30,"orientacao":"Combine o próximo acompanhamento."}]')
) as v(nome,descricao,passos) where not exists(select 1 from public.followup_sequencias s where s.nome=v.nome);
