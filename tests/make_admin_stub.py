# Genera _stub_admin.html + _stub_supabase.js en la raíz del repo para correr el panel real con un Supabase SIMULADO (sin tocar producción).
# Uso: python tests/make_admin_stub.py admin   (o agent | owner | none). BORRAR esos dos archivos antes de cada commit.
import re, sys
R = 'C:/Users/HP/Desktop/MATT FIRMA LEGAL/'
role = sys.argv[1] if len(sys.argv) > 1 else 'agent'     # agent | admin | owner
h = open(R + 'admin/index.html', encoding='utf-8').read()
# rutas relativas -> desde la raíz (el stub vive en la raíz del repo)
h = h.replace('href="../', 'href="').replace('src="../', 'src="')
h = h.replace('<script src="https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2/dist/umd/supabase.js"></script>', '')
h = h.replace('<script src="assets/js/supabase-config.js?v=20261014a"></script>', '<script src="_stub_supabase.js"></script>')
open(R + '_stub_admin.html', 'w', encoding='utf-8').write(h)

stub = r'''
(function(){
const ROLE = new URLSearchParams(location.search).get('role') || '%ROLE%';
const now = Date.now(), day = 864e5, iso = (d) => new Date(now + d * day).toISOString();
const plans = [{code:'propietario',name:'Propietario',price_bs:150,max_active_properties:3,max_featured_per_period:1,agent_tools:false,sort_order:1,active:true},{code:'agente',name:'Agente',price_bs:350,max_active_properties:15,max_featured_per_period:3,agent_tools:true,sort_order:2,active:true},{code:'empresa',name:'Empresa',price_bs:650,max_active_properties:50,max_featured_per_period:3,agent_tools:true,sort_order:3,active:true}];
const photo = (i) => ['https://images.unsplash.com/photo-1600585154340-be6161a56a0c?w=600','https://images.unsplash.com/photo-1512917774080-9991f1c4c750?w=600','https://images.unsplash.com/photo-1564013799919-ab600027ffc6?w=600'][i % 3];
const props = [0,1,2,3].map((i) => ({id:'p'+i,title:['Casa en Achumani','Departamento Sopocachi','Casa minimalista','Terreno en Calacoto'][i],location:['La Paz, Achumani','La Paz, Sopocachi','Cochabamba','La Paz, Calacoto'][i],address:'Calle 31',price:['600000','185000','100000','95000'][i],currency:['BOB','USD','USD','USD'][i],area:'250',rooms:'4 habitaciones',baths:'3',description:'Excelente propiedad.',photos:[photo(i)],whatsapp:'70012345',owner_id:'u1',featured:i===0,featured_until:i===1?iso(10):null,sort_order:i,status:i===3?'sold':'available',created_at:iso(-20),code_number:1001+i,property_type:['casa','departamento','casa','terreno'][i],operation:['venta','alquiler','venta','venta'][i],expires_at:iso(i===2?3:12),last_renewed_at:null,auto_renew:false}));
const sub = {
  agent:{exempt:false,status:'active',source:'payment',plan:plans[1],period_start:iso(-18),period_end:iso(12),cancel_at_period_end:false,usage:{active_properties:3,featured_used:1},pending_request:null},
  owner:{exempt:false,status:'active',source:'payment',plan:plans[0],period_start:iso(-18),period_end:iso(12),cancel_at_period_end:false,usage:{active_properties:2,featured_used:0},pending_request:null},
  admin:{exempt:true,status:'admin',plan:null,usage:{active_properties:3,featured_used:0},pending_request:null},
  none:{exempt:false,status:'none',registered:false,trial_eligible:true,plan:null,usage:{active_properties:0,featured_used:0},pending_request:null},
}[ROLE === 'admin' ? 'admin' : ROLE === 'owner' ? 'owner' : ROLE === 'none' ? 'none' : 'agent'];
const profile = {id:'u1',email:'ana@bastet.uno',role:ROLE==='admin'?'admin':'agent',is_active:true,display_name:'Ana Agente',avatar_url:null,facebook_url:null,instagram_url:null,tiktok_url:null};
const offer = (id,status) => ({id,doc_number:'BST-CO-2026-000'+id,status,created_at:iso(-2),responded_at:null,response_note:null,property_data:{title:'Casa en Achumani',location:'La Paz, Achumani',price:'600000',currency:'BOB',operation:'venta',code_number:1001},owner_data:{nombre:'María Mondaca',ci:'4764766',telefono:'70012345',email:'m@x.com'},agent_data:{nombre:'Ana Agente'},terms:{comision_porcentaje:3,plazo_dias:90,exclusividad:true,mensaje:'Visitas por la tarde'},agent_id:'u1',owner_id:'u9'});
const rows = {
  profiles:[profile,{id:'u2',email:'beto@x.com',role:'agent',is_active:true,display_name:'Beto'},{id:'u9',email:'maria@x.com',role:'agent',is_active:true,display_name:'María'}],
  properties:props, subscription_plans:plans,
  subscription_requests:[{id:5,user_id:'u2',plan_code:'agente',price_bs:350,method:'qr',reference:'TRX1',status:'pending',created_at:iso(-1)},{id:4,user_id:'u1',plan_code:'agente',price_bs:350,method:'transferencia',reference:null,status:'approved',created_at:iso(-18)}],
  subscriptions:[{user_id:'u1',plan_code:'agente',current_period_end:iso(12),source:'payment'},{user_id:'u2',plan_code:'propietario',current_period_end:iso(-3),source:'grace'}],
  credit_wallets:[{balance:12}],
  owner_offers:[offer(1,'pending'),offer(2,'accepted')],
  legal_service_types:[{code:'tramites',name:'Trámites inmobiliarios',active:true},{code:'saneamiento',name:'Saneamiento de documentos',active:true}],
  legal_requests:[{id:1,user_id:'u9',service_code:'tramites',property_title:'Casa en Achumani',description:'Necesito ayuda con el folio real de mi casa',status:'pending',admin_note:null,created_at:iso(-1)}],
  property_leads:[{id:1,property_id:'p0',agent_id:'u1',full_name:'Carlos Pérez',phone:'70011122',message:'Quisiera visitar',status:'new',created_at:iso(-1)},{id:2,property_id:'p1',agent_id:'u1',full_name:'Lucía Rojas',phone:'70033344',message:null,status:'contacted',created_at:iso(-3)}],
  exclusivity_contracts:[{id:'c1',agent_id:'u1',contract_number:'BST-CE-2026-0001',verification_code:'K7M2QX9A',template_version:'exclusividad-v2',data:{operacion:'venta',propietario_nombre:'María Mondaca',inmueble_tipo:'Casa',inmueble_direccion:'Calle 31',inmueble_zona:'Achumani',fecha_inicio:'2026-10-02',plazo_dias:120},created_at:iso(-5),voided_at:null}],
  collections:[], partners:[{id:1,name:'Remax',logo_url:null,sort_order:0}], testimonials:[], sell_requests:[], property_events:[], agent_legal_profiles:[],
};
function q(t){ let single=false; const o={then(r,j){ let d=rows[t]||[]; if(single) d=d[0]||null; return Promise.resolve({data:d,error:null,count:(rows[t]||[]).length}).then(r,j); }};
  ['select','eq','neq','order','limit','or','in','gt','lt','gte','lte','is','not','range','filter','match','ilike','like','insert','update','delete','upsert'].forEach(k=>o[k]=()=>o);
  o.maybeSingle=()=>{single=true;return o}; o.single=()=>{single=true;return o}; return o; }
const cl = {
  auth:{ getSession:async()=>({data:{session:{user:{id:'u1',email:'ana@bastet.uno'}}}}), getUser:async()=>({data:{user:{id:'u1',email:'ana@bastet.uno'}}}), onAuthStateChange(){return {data:{subscription:{unsubscribe(){}}}}}, signOut:async()=>({error:null}), signInWithOAuth:async()=>({error:null}) },
  from:q,
  rpc:async(n)=>{ if(n==='complete_registration'){ sub.registered=true; sub.trial_eligible=false; return {data:sub,error:null}; } if(n==='my_subscription') return {data:sub,error:null}; if(n==='list_agent_directory') return {data:[{id:'a1',display_name:'Ana Agente',plan_name:'Agente',active_properties:5},{id:'a2',display_name:'Beto Empresa',plan_name:'Empresa',active_properties:30}],error:null}; return {data:null,error:null}; },
  storage:{from:()=>({remove:async()=>({}),upload:async()=>({error:null}),getPublicUrl:()=>({data:{publicUrl:''}})})},
  functions:{invoke:async()=>({data:{ok:true},error:null})},
};
window.supabase = { createClient: () => cl };
window.supabaseClient = cl;
window.PROPERTY_PHOTOS_BUCKET='property-photos';
})();
'''.replace('%ROLE%', role)
open(R + '_stub_supabase.js', 'w', encoding='utf-8').write(stub)
print('listo')
