// Netlify Scheduled Function. No secrets in the HTML or repository.
// Env vars (Netlify UI > Environment variables > Functions):
// SUPABASE_URL=https://<project>.supabase.co
// SUPABASE_SECRET_KEY=your NEW server-side key (rotate any key shared in chat)
const ARCHIDEKT_ID = '17877079';
const OWNERS = ['Anna','Dejan','Marcell','Martin','Norman','Trong'];
const clean = v => String(v ?? '').trim();
const norm = v => clean(v).normalize('NFKD').toLowerCase();
const slug = v => norm(v).normalize('NFKD').replace(/[\u0300-\u036f]/g,'').replace(/[^a-z0-9]+/g,'-').replace(/^-|-$/g,'').slice(0,70);
const key = c => norm(c.owner)+'::'+norm(c.name);
function parseDeck(json){
 if(!json || !Array.isArray(json.cards))throw Error('Archidekt liefert keine lesbare Kartenliste');
 const catMap=new Map((json.categories||[]).map(x=>[String(x.id),clean(x.name)]));
 const seen=new Set(),out=[];
 for(const row of json.cards){
  const name=clean(row.card?.oracleCard?.name||row.card?.name||row.name);
  const groups=[row.category,...(Array.isArray(row.categories)?row.categories:[])].map(x=>{
   if(typeof x==='object'&&x)return clean(x.name||catMap.get(String(x.id)));
   return catMap.get(String(x))||clean(x);
  });
  const owner=OWNERS.find(w=>groups.some(g=>norm(g)===norm(w)));
  if(!owner||!name)continue;
  const k=norm(owner)+'::'+norm(name);
  if(seen.has(k))continue;seen.add(k);out.push({name,owner});
 }
 if(out.length<10)throw Error('Weniger als 10 Besitzer/Commander erkannt – Abgleich gestoppt');
 return out;
}
async function fetchArchidekt(){
 const ctrl=new AbortController(),t=setTimeout(()=>ctrl.abort(),12000);
 try{
  const res=await fetch(`https://archidekt.com/api/decks/${ARCHIDEKT_ID}/`,{
   headers:{Accept:'application/json','User-Agent':'CommanderTierlistSync/1.0 (personal playgroup)'},
   signal:ctrl.signal});
  if(!res.ok)throw Error('Archidekt HTTP '+res.status);
  const data=await res.json();return parseDeck(data);
 }finally{clearTimeout(t)}
}
async function main(){
 const base=(process.env.SUPABASE_URL||'').replace(/\/$/,'');
 const secret=process.env.SUPABASE_SECRET_KEY;
 if(!/^https:\/\/[a-z0-9-]+\.supabase\.co$/.test(base)||!secret)throw Error('Fehlende Netlify-Umgebungsvariablen SUPABASE_URL / SUPABASE_SECRET_KEY');
 const headers={apikey:secret,Accept:'application/json','Content-Type':'application/json'};
 async function db(path,method='GET',body){
  const res=await fetch(base+'/rest/v1/'+path,{method,headers,body:body===undefined?undefined:JSON.stringify(body)});
  const data=await res.text();if(!res.ok)throw Error(`Supabase HTTP ${res.status}: ${data.slice(0,200)}`);
  return data?JSON.parse(data):null;
 }
 async function log(status,message,synced=false){
  const patch={checked_at:new Date().toISOString(),status,message:String(message).slice(0,400)};
  if(synced)patch.synced_at=patch.checked_at;
  await db('commander_sync_status?id=eq.1','PATCH',patch);
 }
 try{
  const fresh=await fetchArchidekt();
  const response=await db('commander_catalog?id=eq.1&select=cards');
  const old=response?.[0]?.cards;
  if(!Array.isArray(old)||old.length<10)throw Error('Supabase-Katalog fehlt/ist ungültig – kein Update');
  // Vor destruktiven API-/Kategorienfehlern schützen.
  const freshOwners=new Set(fresh.map(c=>c.owner));
  if(fresh.length<Math.max(10,Math.ceil(old.length*.70)) ||
     freshOwners.size<Math.max(2,Math.min(4,new Set(old.map(c=>c.owner)).size)))
   throw Error(`Sicherheitsstopp: ${fresh.length} von vorher ${old.length} Decks / ${freshOwners.size} Besitzer erkannt`);
  const index=new Map(old.map(c=>[key(c),c]));
  const cards=fresh.map(c=>({
    id:index.get(key(c))?.id||`deck-${slug(c.owner)}-${slug(c.name)}`,
    owner:c.owner,name:c.name
  }));
  if(new Set(cards.map(c=>c.id)).size!==cards.length)throw Error('Doppelte Commander-ID: Abgleich abgebrochen');
  const before=new Set(old.map(key)),after=new Set(cards.map(key));
  const added=cards.filter(c=>!before.has(key(c))).length;
  const removed=old.filter(c=>!after.has(key(c))).length;
  if(!added&&!removed){await log('unverändert',`${cards.length} Decks geprüft`);return}
  // Kein überschreiben von historischen Votings: sie referenzieren stabile Commander-IDs.
  await db('commander_catalog?id=eq.1','PATCH',{cards,updated_at:new Date().toISOString()});
  await log('aktualisiert',`+${added} neue, -${removed} aufgelöst, ${cards.length} aktiv`,true);
  console.log(`Archidekt sync: ${cards.length} active, +${added} -${removed}`);
 }catch(err){console.error('Archidekt sync failed:',err.message);try{await log('Fehler – Liste unverändert',err.message)}catch(e){console.error('Log failed:',e.message)}throw err;}
}
export default async () => {await main();};
export const config={schedule:'0 */6 * * *'};
export {parseDeck}; // exported for local unit tests
