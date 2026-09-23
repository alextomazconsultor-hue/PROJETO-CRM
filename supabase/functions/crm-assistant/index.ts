import "jsr:@supabase/functions-js/edge-runtime.d.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const OPENAI_API_KEY = Deno.env.get("OPENAI_API_KEY") || "";
const OPENAI_MODEL = Deno.env.get("OPENAI_MODEL") || "gpt-6-luna";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), {
  status,
  headers: { ...corsHeaders, "Content-Type": "application/json" },
});

function serviceHeaders(extra: Record<string, string> = {}) {
  return {
    apikey: SERVICE_KEY,
    Authorization: `Bearer ${SERVICE_KEY}`,
    "Content-Type": "application/json",
    ...extra,
  };
}

async function rest(path: string, init: RequestInit = {}) {
  const response = await fetch(`${SUPABASE_URL}/rest/v1/${path}`, {
    ...init,
    headers: { ...serviceHeaders(), ...(init.headers || {}) },
  });
  const text = await response.text();
  const data = text ? JSON.parse(text) : null;
  if (!response.ok) throw new Error(data?.message || data?.error || `Supabase ${response.status}`);
  return data;
}

async function authenticate(req: Request) {
  const authorization = req.headers.get("Authorization") || "";
  if (!authorization.startsWith("Bearer ")) throw new Error("Sessão ausente");
  const response = await fetch(`${SUPABASE_URL}/auth/v1/user`, {
    headers: { apikey: SERVICE_KEY, Authorization: authorization },
  });
  if (!response.ok) throw new Error("Sessão inválida ou expirada");
  const authUser = await response.json();
  const profiles = await rest(`usuarios?id=eq.${encodeURIComponent(authUser.id)}&select=id,nome,email,perfil,corretor_ref&limit=1`);
  if (!profiles?.[0]) throw new Error("Usuário sem perfil no CRM");
  return profiles[0];
}

async function getContextLists() {
  const [stages, brokers, projects] = await Promise.all([
    rest("etapas?select=id,nome&order=ordem.asc"),
    rest("corretores?select=nome&order=nome.asc"),
    rest("empreendimentos?select=nome&order=nome.asc"),
  ]);
  return { stages, brokers, projects };
}

async function getMessages(threadId: string) {
  return await rest(`assistant_messages?thread_id=eq.${encodeURIComponent(threadId)}&select=role,author_name,content,created_at&order=created_at.desc&limit=30`)
    .then((rows: any[]) => rows.reverse());
}

function safeTerm(value: unknown) {
  return String(value || "").replace(/[,*()]/g, " ").trim().slice(0, 80);
}

async function searchLeads(args: any, profile: any) {
  const filters = ["select=id,nome,telefone,email,origem,empreendimento,cidade,corretor,status,observacoes,created_at", "order=created_at.desc", `limit=${Math.min(Number(args.limit) || 20, 50)}`];
  if (args.nome) filters.push(`nome=ilike.*${encodeURIComponent(safeTerm(args.nome))}*`);
  if (args.telefone) filters.push(`telefone=ilike.*${encodeURIComponent(safeTerm(args.telefone).replace(/\D/g, ""))}*`);
  if (args.status) filters.push(`status=eq.${encodeURIComponent(safeTerm(args.status))}`);
  if (args.empreendimento) filters.push(`empreendimento=eq.${encodeURIComponent(safeTerm(args.empreendimento))}`);
  if (args.corretor && ["admin", "gestor"].includes(profile.perfil)) filters.push(`corretor=eq.${encodeURIComponent(safeTerm(args.corretor))}`);
  if (profile.perfil === "corretor") filters.push(`corretor=eq.${encodeURIComponent(profile.corretor_ref || profile.nome)}`);
  return await rest(`leads?${filters.join("&")}`);
}

async function crmSummary(profile: any) {
  const query = ["select=id,status,empreendimento,corretor,created_at", "limit=1000"];
  if (profile.perfil === "corretor") query.push(`corretor=eq.${encodeURIComponent(profile.corretor_ref || profile.nome)}`);
  const leads = await rest(`leads?${query.join("&")}`);
  const byStatus: Record<string, number> = {};
  const byProject: Record<string, number> = {};
  for (const lead of leads) {
    byStatus[lead.status || "sem etapa"] = (byStatus[lead.status || "sem etapa"] || 0) + 1;
    byProject[lead.empreendimento || "sem empreendimento"] = (byProject[lead.empreendimento || "sem empreendimento"] || 0) + 1;
  }
  return { total: leads.length, por_etapa: byStatus, por_empreendimento: byProject };
}

const tools = [
  {
    type: "function", name: "search_leads",
    description: "Localiza leads do CRM por nome, telefone, etapa, empreendimento ou corretor.",
    parameters: { type: "object", properties: {
      nome: { type: "string" }, telefone: { type: "string" }, status: { type: "string" },
      empreendimento: { type: "string" }, corretor: { type: "string" }, limit: { type: "integer" },
    }, additionalProperties: false },
  },
  {
    type: "function", name: "get_crm_summary",
    description: "Obtém um resumo dos leads por etapa e empreendimento.",
    parameters: { type: "object", properties: {}, additionalProperties: false },
  },
  {
    type: "function", name: "create_lead",
    description: "Propõe cadastrar um lead. A ação só será executada após confirmação humana.",
    parameters: { type: "object", properties: {
      nome: { type: "string" }, telefone: { type: "string" }, email: { type: "string" },
      origem: { type: "string" }, empreendimento: { type: "string" }, cidade: { type: "string" },
      observacoes: { type: "string" }, corretor: { type: "string" }, status: { type: "string" },
    }, required: ["nome"], additionalProperties: false },
  },
  {
    type: "function", name: "update_lead",
    description: "Propõe alterar dados ou etapa de um lead identificado por UUID. A ação só será executada após confirmação humana.",
    parameters: { type: "object", properties: {
      lead_id: { type: "string" }, nome: { type: "string" }, telefone: { type: "string" },
      email: { type: "string" }, origem: { type: "string" }, empreendimento: { type: "string" },
      cidade: { type: "string" }, observacoes: { type: "string" }, corretor: { type: "string" }, status: { type: "string" },
    }, required: ["lead_id"], additionalProperties: false },
  },
  {
    type: "function", name: "create_task",
    description: "Propõe criar uma tarefa no CRM. A ação só será executada após confirmação humana.",
    parameters: { type: "object", properties: {
      titulo: { type: "string" }, lead_rel: { type: "string" }, data_hora: { type: "string" },
      prioridade: { type: "string", enum: ["alta", "media", "baixa"] }, notas: { type: "string" }, corretor: { type: "string" },
    }, required: ["titulo"], additionalProperties: false },
  },
];

function describeAction(type: string, args: any, lists: any) {
  if (type === "create_lead") return `Cadastrar o lead “${args.nome}” em ${args.empreendimento || "empreendimento não informado"}, etapa ${lists.stages.find((s: any) => s.id === (args.status || "novo"))?.nome || args.status || "Novo Lead"}.`;
  if (type === "update_lead") return `Alterar o lead ${args.lead_id}${args.status ? ` para a etapa ${lists.stages.find((s: any) => s.id === args.status)?.nome || args.status}` : ""}.`;
  if (type === "create_task") return `Criar a tarefa “${args.titulo}”${args.data_hora ? ` para ${args.data_hora}` : ""}.`;
  return "Executar a ação solicitada.";
}

async function validateAction(type: string, args: any, profile: any, lists: any) {
  const stageIds = lists.stages.map((s: any) => s.id);
  const projectNames = lists.projects.map((p: any) => p.nome);
  const brokerNames = lists.brokers.map((b: any) => b.nome);
  if (args.status && !stageIds.includes(args.status)) throw new Error("Etapa inválida");
  if (args.empreendimento && !projectNames.includes(args.empreendimento)) throw new Error("Empreendimento inválido");
  if (args.corretor && !brokerNames.includes(args.corretor)) throw new Error("Corretor inválido");
  if (profile.perfil === "corretor") args.corretor = profile.corretor_ref || profile.nome;
  if (type === "update_lead") {
    const found = await searchLeads({ limit: 50 }, profile);
    if (!found.some((lead: any) => lead.id === args.lead_id)) throw new Error("Lead não encontrado ou sem permissão");
  }
}

async function executeAction(type: string, args: any, profile: any, lists: any) {
  await validateAction(type, args, profile, lists);
  if (type === "create_lead") {
    const phone = String(args.telefone || "").replace(/\D/g, "");
    if (phone) {
      const existing = await rest(`leads?telefone=ilike.*${encodeURIComponent(phone)}*&select=id,nome,telefone&limit=1`);
      if (existing.length) return { ok: false, duplicate: existing[0], message: `Lead já existente: ${existing[0].nome}.` };
    }
    const payload = { ...args, corretor: args.corretor || profile.corretor_ref || profile.nome, status: args.status || "novo" };
    const rows = await rest("leads", { method: "POST", headers: { Prefer: "return=representation" }, body: JSON.stringify(payload) });
    return { ok: true, lead: rows[0], message: `Lead ${rows[0].nome} cadastrado com sucesso.` };
  }
  if (type === "update_lead") {
    const { lead_id, ...changes } = args;
    const rows = await rest(`leads?id=eq.${encodeURIComponent(lead_id)}`, { method: "PATCH", headers: { Prefer: "return=representation" }, body: JSON.stringify(changes) });
    if (!rows.length) throw new Error("Nenhum lead foi alterado");
    await rest("historico", { method: "POST", body: JSON.stringify({ lead_id, texto: `Alteração confirmada pelo Agente IA por ${profile.nome}`, tipo: "update" }) });
    return { ok: true, lead: rows[0], message: `Lead ${rows[0].nome} atualizado com sucesso.` };
  }
  if (type === "create_task") {
    const payload = { ...args, corretor: args.corretor || profile.corretor_ref || profile.nome, prioridade: args.prioridade || "media", concluida: false };
    const rows = await rest("tarefas", { method: "POST", headers: { Prefer: "return=representation" }, body: JSON.stringify(payload) });
    return { ok: true, task: rows[0], message: `Tarefa “${rows[0].titulo}” criada com sucesso.` };
  }
  throw new Error("Ação não suportada");
}

async function saveMessage(threadId: string, role: "user" | "assistant", authorName: string, content: string, userId: string | null, action: any = null) {
  const rows = await rest("assistant_messages", {
    method: "POST", headers: { Prefer: "return=representation" },
    body: JSON.stringify({ thread_id: threadId, role, author_name: authorName, content, user_id: userId, action }),
  });
  await rest(`assistant_threads?id=eq.${encodeURIComponent(threadId)}`, { method: "PATCH", body: JSON.stringify({ updated_at: new Date().toISOString() }) });
  return rows[0];
}

function outputText(response: any) {
  return (response.output || [])
    .filter((item: any) => item.type === "message")
    .flatMap((item: any) => item.content || [])
    .filter((part: any) => part.type === "output_text")
    .map((part: any) => part.text)
    .join("\n").trim();
}

async function callOpenAI(input: any[], instructions: string) {
  const response = await fetch("https://api.openai.com/v1/responses", {
    method: "POST",
    headers: { Authorization: `Bearer ${OPENAI_API_KEY}`, "Content-Type": "application/json" },
    body: JSON.stringify({ model: OPENAI_MODEL, reasoning: { effort: "low" }, instructions, input, tools, tool_choice: "auto", max_output_tokens: 1200 }),
  });
  const data = await response.json();
  if (!response.ok) throw new Error(data?.error?.message || `OpenAI ${response.status}`);
  return data;
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "Método não permitido" }, 405);
  try {
    const profile = await authenticate(req);
    const body = await req.json();
    const threadId = String(body.thread_id || "");
    if (!threadId) return json({ error: "Conversa não informada" }, 400);
    const threads = await rest(`assistant_threads?id=eq.${encodeURIComponent(threadId)}&select=id&limit=1`);
    if (!threads.length) return json({ error: "Conversa não encontrada" }, 404);
    const lists = await getContextLists();

    if (body.confirm_action?.message_id) {
      const rows = await rest(`assistant_messages?id=eq.${encodeURIComponent(body.confirm_action.message_id)}&thread_id=eq.${encodeURIComponent(threadId)}&select=id,action&limit=1`);
      const pending = rows[0];
      if (!pending?.action || pending.action.status !== "pending") return json({ error: "Ação já executada ou inválida" }, 409);
      const result = await executeAction(pending.action.type, pending.action.args, profile, lists);
      await rest(`assistant_messages?id=eq.${pending.id}`, { method: "PATCH", body: JSON.stringify({ action: { ...pending.action, status: result.ok ? "executed" : "blocked", result } }) });
      const saved = await saveMessage(threadId, "assistant", "Assistente 3Ps", result.message, null);
      return json({ message: saved, action_result: result });
    }

    const message = String(body.message || "").trim().slice(0, 4000);
    if (!message) return json({ error: "Digite uma mensagem" }, 400);
    await saveMessage(threadId, "user", profile.nome, message, profile.id);

    if (!OPENAI_API_KEY) {
      const saved = await saveMessage(threadId, "assistant", "Assistente 3Ps", "A estrutura do chat está pronta, mas a chave da OpenAI ainda precisa ser configurada no servidor.", null);
      return json({ message: saved, needs_openai_key: true }, 503);
    }

    const history = await getMessages(threadId);
    const input: any[] = history.map((m: any) => ({ role: m.role, content: m.role === "user" ? `${m.author_name}: ${m.content}` : m.content }));
    const instructions = `Você é o Assistente 3Ps, colaborador do CRM imobiliário de Alex Tomaz. Responda em português do Brasil, de forma curta, clara e profissional. O usuário atual é ${profile.nome}, perfil ${profile.perfil}, corretor ${profile.corretor_ref || profile.nome}. Data atual: ${new Date().toISOString().slice(0, 10)}. Empreendimentos válidos: ${lists.projects.map((p: any) => p.nome).join(", ")}. Corretores válidos: ${lists.brokers.map((b: any) => b.nome).join(", ")}. Etapas válidas (use sempre o ID nas ferramentas): ${lists.stages.map((s: any) => `${s.id}=${s.nome}`).join("; ")}. Consulte o CRM antes de afirmar dados. Para alterar um lead, primeiro localize-o e use o UUID retornado. Nunca invente registros. Ações de escrita precisam de confirmação humana e serão apenas propostas. Não ofereça exclusão de dados.`;

    let response = await callOpenAI(input, instructions);
    for (let round = 0; round < 3; round++) {
      const calls = (response.output || []).filter((item: any) => item.type === "function_call");
      if (!calls.length) break;
      input.push(...response.output);
      let pending: any = null;
      for (const call of calls) {
        const args = JSON.parse(call.arguments || "{}");
        if (["create_lead", "update_lead", "create_task"].includes(call.name)) {
          await validateAction(call.name, args, profile, lists);
          pending = { id: crypto.randomUUID(), type: call.name, args, status: "pending" };
          break;
        }
        const result = call.name === "search_leads" ? await searchLeads(args, profile) : await crmSummary(profile);
        input.push({ type: "function_call_output", call_id: call.call_id, output: JSON.stringify(result) });
      }
      if (pending) {
        const content = `Confirma esta ação? ${describeAction(pending.type, pending.args, lists)}`;
        const saved = await saveMessage(threadId, "assistant", "Assistente 3Ps", content, null, pending);
        return json({ message: saved, pending_action: pending });
      }
      response = await callOpenAI(input, instructions);
    }
    const content = outputText(response) || "Não consegui concluir essa solicitação. Tente informar o nome ou telefone do lead.";
    const saved = await saveMessage(threadId, "assistant", "Assistente 3Ps", content, null);
    return json({ message: saved });
  } catch (error) {
    console.error(error);
    return json({ error: error instanceof Error ? error.message : "Erro inesperado" }, 500);
  }
});
