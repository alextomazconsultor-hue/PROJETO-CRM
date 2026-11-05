const fs=require('fs'),vm=require('vm'),assert=require('assert');
const html=fs.readFileSync('simulador.html','utf8'),elements=new Map();
for(const m of html.matchAll(/<input[^>]*id="([^"]+)"[^>]*>/g)){const value=m[0].match(/value="([^"]*)"/);elements.set(m[1],{value:value?.[1]||'',checked:false,textContent:'',innerHTML:'',classList:{add(){},remove(){},toggle(){}},style:{}})}
const el=id=>{if(!elements.has(id))elements.set(id,{value:'',textContent:'',innerHTML:'',classList:{add(){},remove(){},toggle(){}},style:{}});return elements.get(id)};
const ctx={console,URLSearchParams,location:{search:''},document:{getElementById:el,querySelectorAll:()=>[],body:{classList:{add(){}}}},supabase:{createClient:()=>({})},localStorage:{getItem:()=>null},window:{scrollTo(){}},setTimeout:()=>{}};vm.createContext(ctx);
for(const m of html.matchAll(/<script[^>]*>([\s\S]*?)<\/script>/g))vm.runInContext(m[1].replace('init();',''),ctx);
function set(v){Object.entries(v).forEach(([id,x])=>el(id).value=String(x));}
set({valorTotal:553000,entradaValor:46000,entradaNum:2,parcelaValor:3500,parcelaNum:46,mensalInicio:2,mesChaves:48,percMinimo:35});
let v=ctx.compararVpl(ctx.calcular());assert(v.valid);assert(Math.abs(v.tabela-387607.17)<.01);assert(Math.abs(v.proposta-387654.977655)<.0001);assert.equal(ctx.calcular().totalPre,207000);
set({taxaVpl:0});v=ctx.compararVpl(ctx.calcular());assert(Math.abs(v.proposta-553000)<.001);assert(Math.abs(v.tabela-553000)<.001);
set({taxaVpl:1,entradaNum:1});assert(ctx.compararVpl(ctx.calcular()).proposta>387654.98);
set({entradaNum:2,tabelaEntrada:90,tabelaMensais:20});assert(!ctx.compararVpl(ctx.calcular()).valid);
set({tabelaEntrada:10,tabelaMensais:15,mesChaves:10});assert(!ctx.calcular().ready);
set({mesChaves:48,entradaNum:3});assert.equal(ctx.calcular().fluxo.filter(e=>e.tipo==='entrada').reduce((s,e)=>s+e.valor,0),46000);
const reforcos=ctx.gerarReforcos(48,[{valor:1000,inicio:7,intervalo:6,quantidade:2}]);assert.deepEqual(Array.from(reforcos.events,e=>e.mes),[7,13]);
set({mesChaves:48.5});assert(!ctx.calcular().ready);set({mesChaves:48,entradaValor:0,parcelaValor:0});v=ctx.compararVpl(ctx.calcular());assert(v.ajusteEntrada>0);assert(Math.abs(v.proposta+v.ajusteChaves/1.01**48-v.tabela)<.001);
const saved=ctx.formData().vplForm;ctx.resetVpl();assert.equal(el('entradaNum').value,'1');ctx.resetVpl(saved);assert.equal(el('entradaNum').value,'3');
ctx.atualizarStatus();assert(el('vplResultado').innerHTML.includes('Esperado'));
set({valorTotal:553000,entradaValor:46000,entradaNum:2,parcelaValor:3500,parcelaNum:46,mensalInicio:2,mesChaves:48,percMinimo:35,fluxoDataBase:'2026-11-05'});let periods=ctx.calcular().periodos;assert(periods.valid);assert(!periods.ok);assert.equal(periods.rows.length,9);assert(Math.abs(periods.rows[0].esperado-57065.06)<.001);assert.equal(periods.rows[0].falta,11065.06);assert(Math.abs(periods.esperado-35)<.0001);assert(!ctx.calcular().ready);
set({entradaValor:55300.17,entradaNum:1,parcelaValor:1764.89,parcelaNum:47,mensalInicio:1,mesChaves:48});ctx.getRefPlans=()=>[{valor:7900,inicio:7,intervalo:6,quantidade:7,periodo:'semestral'}];assert(ctx.calcular().periodos.ok);assert(ctx.calcular().ready);set({fluxoDataBase:''});assert(!ctx.calcular().ready);
console.log('Passed: Excel parity, 0% discount, earlier entry, invalid percentages and dates, cents reconciliation, reinforcement timing, equalization, save/restore and rendering.');
