const CLIENT_DOCUMENT_BUCKET = 'crm-documentos';
let clientDocumentRequest = 0;
let clientDocumentBusy = false;
function clientDocumentName(name) {
  return name.replace(/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}--/i, '');
}
async function loadClientDocuments(leadId) {
  const request = ++clientDocumentRequest;
  const list = document.getElementById('clientDocumentList');
  const status = document.getElementById('clientDocumentStatus');
  list.replaceChildren();
  status.textContent = 'Carregando documentos...';
  if (!APP.supabase || !APP.sbConnected) { status.textContent = 'Conecte o CRM para consultar os documentos.'; return; }
  try {
    const files = [];
    for (let offset = 0;; offset += 100) {
      const { data, error } = await APP.supabase.storage.from(CLIENT_DOCUMENT_BUCKET).list(leadId, { limit:100, offset, sortBy:{column:'created_at',order:'desc'} });
      if (error) throw error;
      files.push(...data.filter(file => file.id));
      if (data.length < 100) break;
    }
    if (request !== clientDocumentRequest || APP.currentLead !== leadId) return;
    status.textContent = files.length ? '' : 'Nenhum documento anexado.';
    files.forEach(file => {
      const row = document.createElement('div');
      row.style.cssText = 'display:flex;gap:8px;align-items:center;flex-wrap:wrap;padding:10px 0;border-bottom:1px solid var(--border)';
      const label = document.createElement('span');
      label.style.cssText = 'flex:1;min-width:140px;overflow-wrap:anywhere;font-size:14px';
      label.textContent = clientDocumentName(file.name);
      row.append(label);
      [['Abrir',false],['Baixar',true]].forEach(([title,download]) => {
        const button = document.createElement('button');
        button.className = 'btn btn-secondary btn-sm'; button.textContent = title;
        button.onclick = () => accessClientDocument(leadId, file.name, download, button);
        row.append(button);
      });
      const remove = document.createElement('button');
      remove.className = 'btn btn-secondary btn-sm'; remove.textContent = 'Excluir';
      remove.onclick = () => deleteClientDocument(leadId, file.name, remove);
      row.append(remove); list.append(row);
    });
  } catch (error) {
    if (request === clientDocumentRequest) status.textContent = 'Não foi possível carregar os documentos. ' + error.message;
  }
}
async function uploadClientDocuments(input) {
  const leadId = APP.currentLead;
  const files = Array.from(input.files || []); input.value = '';
  if (!files.length || clientDocumentBusy) return;
  if (!APP.supabase || !APP.sbConnected) { toast('Conecte o CRM para anexar documentos.','error'); return; }
  const types = {pdf:'application/pdf',jpg:'image/jpeg',jpeg:'image/jpeg',png:'image/png',webp:'image/webp'};
  for (const file of files) {
    const ext = file.name.split('.').pop().toLowerCase();
    if (!types[ext] || (file.type && file.type !== types[ext]) || !file.size || file.size > 20*1024*1024) {
      toast('Arquivo inválido: '+file.name+'. Use PDF ou imagens de até 20 MB.','error'); return;
    }
  }
  clientDocumentBusy = true; input.disabled = true;
  let saved = 0;
  try {
    for (const file of files) {
      if (APP.currentLead === leadId) document.getElementById('clientDocumentStatus').textContent = 'Enviando '+file.name+'...';
      const name = file.name.normalize('NFKD').replace(/[\u0300-\u036f]/g,'').replace(/[^a-zA-Z0-9._-]/g,'_').slice(-160);
      const ext = file.name.split('.').pop().toLowerCase();
      const { error } = await APP.supabase.storage.from(CLIENT_DOCUMENT_BUCKET).upload(leadId+'/'+crypto.randomUUID()+'--'+name,file,{contentType:types[ext],upsert:false});
      if (error) throw error;
      saved++;
    }
    toast(saved+' documento(s) anexado(s).','success');
  } catch (error) { toast(saved+' documento(s) salvo(s). Falha no envio: '+error.message,'error'); }
  finally {
    clientDocumentBusy = false; input.disabled = false;
    if (APP.currentLead === leadId) await loadClientDocuments(leadId);
  }
}
async function accessClientDocument(leadId, name, download, button) {
  button.disabled = true;
  const popup = download ? null : window.open('about:blank','_blank');
  if (popup) popup.opener = null;
  try {
    const { data, error } = await APP.supabase.storage.from(CLIENT_DOCUMENT_BUCKET).createSignedUrl(leadId+'/'+name,60,download?{download:clientDocumentName(name)}:{});
    if (error) throw error;
    if (popup) popup.location.href = data.signedUrl;
    else { const link=document.createElement('a'); link.href=data.signedUrl; link.target='_blank'; link.rel='noopener'; document.body.append(link); link.click(); link.remove(); }
  } catch (error) { popup?.close(); toast('Não foi possível abrir o documento: '+error.message,'error'); }
  finally { button.disabled = false; }
}
async function deleteClientDocument(leadId,name,button) {
  if (!confirm('Excluir o documento "'+clientDocumentName(name)+'"?')) return;
  button.disabled = true;
  try {
    const { error } = await APP.supabase.storage.from(CLIENT_DOCUMENT_BUCKET).remove([leadId+'/'+name]);
    if (error) throw error;
    toast('Documento excluído.','success');
    if (APP.currentLead === leadId) await loadClientDocuments(leadId);
  } catch (error) { toast('Não foi possível excluir: '+error.message,'error'); button.disabled=false; }
}
