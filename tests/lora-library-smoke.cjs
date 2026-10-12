// Run against an isolated workstation server with WORKSTATION_LORA_DATA set to a test directory.
// NODE_PATH must contain playwright; fixture media are supplied through LORA_FIXTURE_DIR.
const fs = require('fs');
const path = require('path');
const http = require('http');
const assert = require('assert/strict');
const { chromium } = require('playwright');
const BASE = process.env.LORA_TEST_BASE || 'http://127.0.0.1:8907';
const COMFY = 'http://127.0.0.1:8908';
const DIR = path.resolve(process.env.LORA_FIXTURE_DIR || '.workbuddy/tmp/lora-fixtures');
const OUT = path.resolve('.workbuddy/tmp');
if (!DIR.startsWith(OUT + path.sep)) throw new Error('Fixture directory must stay inside .workbuddy/tmp.');
fs.mkdirSync(DIR, {recursive:true});
const {spawnSync} = require('child_process');
function media(name,args) {
  if(fs.existsSync(path.join(DIR,name)))return;
  const result=spawnSync(process.env.LORA_FFMPEG || 'ffmpeg',['-hide_banner','-loglevel','error',...args,'-y',path.join(DIR,name)],{encoding:'utf8'});
  if(result.error || result.status!==0)throw new Error('Provide ffmpeg through LORA_FFMPEG: '+(result.error?.message || result.stderr));
}
media('motion.mp4',['-f','lavfi','-i','color=c=0xd8663f:s=320x240:d=1','-vf','drawbox=x=60:y=60:w=200:h=120:color=white@0.5:t=fill','-c:v','libx264','-pix_fmt','yuv420p','-movflags','+faststart']);
media('cover.png',['-i',path.join(DIR,'motion.mp4'),'-frames:v','1']);
media('motion.gif',['-i',path.join(DIR,'motion.mp4'),'-vf','fps=5,scale=160:120']);
media('cover.jpg',['-i',path.join(DIR,'cover.png'),'-frames:v','1']);
media('cover.webp',['-i',path.join(DIR,'cover.png'),'-frames:v','1']);
media('motion.webm',['-i',path.join(DIR,'motion.mp4'),'-c:v','libvpx-vp9','-an']);
const checks = [];
const check = (name, value) => { assert.ok(value, name); checks.push(name); };
const modelNames = ['Aurora.safetensors','Motion.safetensors','Loop.safetensors','Blank.safetensors','Delete-me.safetensors'];
for (const [index, name] of modelNames.entries()) {
  fs.writeFileSync(path.join(DIR,name),Buffer.alloc(2048,index+1));
  const stem = name.replace('.safetensors','');
  fs.writeFileSync(path.join(DIR,stem+'.metadata.json'),JSON.stringify({model_name:stem,base_model:index<3?'MiniMax H3':'Other',tags:index<3?['cinematic','soft light']:['test'],notes:'Local test model for preview and generation settings.',civitai:{creator:{username:'Studio Demo'}}}));
}
fs.copyFileSync(path.join(DIR,'cover.png'),path.join(DIR,'Aurora.png'));
fs.copyFileSync(path.join(DIR,'motion.mp4'),path.join(DIR,'Blank.mp4'));
fs.copyFileSync(path.join(DIR,'motion.mp4'),path.join(DIR,'Motion.mp4'));
fs.copyFileSync(path.join(DIR,'cover.png'),path.join(DIR,'Motion.poster.png'));
fs.copyFileSync(path.join(DIR,'motion.gif'),path.join(DIR,'Loop.gif'));
fs.copyFileSync(path.join(DIR,'cover.png'),path.join(DIR,'Loop.poster.png'));
const upstream = http.createServer((req,res)=>{
  res.setHeader('Content-Type','application/json');
  if(req.url==='/models/loras')res.end(JSON.stringify(modelNames.filter(n=>fs.existsSync(path.join(DIR,n)))));
  else if(req.url==='/api/lm/loras/roots')res.end(JSON.stringify({success:true,roots:[DIR]}));
  else {res.statusCode=404;res.end('{}');}
});
const api = (p) => `${BASE}${p}${p.includes('?')?'&':'?'}comfy=${encodeURIComponent(COMFY)}`;
async function post(p,body,extra={}){return fetch(api(p),{method:'POST',headers:{'Content-Type':'application/json',...extra},body:JSON.stringify(body)});}
let browser;
(async()=>{
  await new Promise(r=>upstream.listen(8908,'127.0.0.1',r));
  let response=await fetch(api('/api/lora-library?fresh=1'));assert.equal(response.status,200);let library=await response.json();
  check('Lists only five registered fixture models',library.items.length===5);
  check('Imports local metadata and media types',library.items.some(i=>i.mediaType==='mp4'&&i.author==='Studio Demo')&&library.items.some(i=>i.mediaType==='gif')&&library.items.some(i=>i.mediaType==='png'));
  check('Does not serialize internal file access fields',library.items.every(i=>!('filePath'in i)&&!('modelRoot'in i)));
  await post('/api/lora-library/favorite',{ids:library.items.map(i=>i.id),favorite:false});
  const image=library.items.find(i=>i.name==='Aurora.safetensors'),movie=library.items.find(i=>i.name==='Motion.safetensors'),del=library.items.find(i=>i.name==='Delete-me.safetensors');
  response=await fetch(api(`/api/lora-library/media?id=${movie.id}`),{headers:{Range:'bytes=0-31'}});check('Video range request returns exact 32-byte partial content',response.status===206&&(await response.arrayBuffer()).byteLength===32&&response.headers.get('content-range').startsWith('bytes 0-31/'));
  response=await fetch(api(`/api/lora-library/media?id=${movie.id}`),{headers:{Range:'bytes=999999999-'}});check('Out of bounds ranges return 416',response.status===416);
  response=await fetch(api(`/api/lora-library/media?id=${movie.id}`),{headers:{Range:'bytes=-16'}});check('Suffix ranges stream last bytes',response.status===206&&(await response.arrayBuffer()).byteLength===16);
  response=await fetch(api(`/api/lora-library/download?id=${image.id}`));check('Download returns original model bytes with attachment headers',response.headers.get('content-disposition').includes('attachment')&&(await response.arrayBuffer()).byteLength===2048);
  response=await fetch(api(`/api/lora-library/archive?ids=${image.id},${movie.id}`));const archive=Buffer.from(await response.arrayBuffer());check('Batch download produces a nonempty ZIP with both entries',response.status===200&&archive.subarray(0,2).toString()==='PK'&&archive.includes(Buffer.from('Aurora.safetensors'))&&archive.includes(Buffer.from('Motion.safetensors')));fs.writeFileSync(path.join(OUT,'lora-fixture-download.zip'),archive);
  for(const [filename,type]of [['cover.jpg','image/jpeg'],['cover.webp','image/webp'],['motion.webm','video/webm'],['motion.gif','image/gif']]){
    const ext=path.extname(filename);response=await fetch(api('/api/lora-library/upload?id='+del.id+'&ext='+ext),{method:'POST',headers:{'X-Lora-Upload':'1','Content-Type':type},body:fs.readFileSync(path.join(DIR,filename))});check('Accepts validated '+ext+' preview upload',response.status===200);
  }
  response=await post('/api/lora-library/delete',{ids:[del.id,'0'.repeat(64)],confirm:'TRASH'});check('Batch deletion preflight prevents partial removal on an invalid ID',response.status>=400&&fs.existsSync(path.join(DIR,del.name)));
  response=await fetch(api('/api/lora-library/media?id=../../server.ps1'));check('Rejects unregistered/path traversal identifiers',response.status>=400);
  response=await post('/api/lora-library/edit',{id:image.id,title:'Unexpected'}, {Origin:'http://evil.example'});check('Rejects cross origin metadata changes',response.status>=400);
  response=await post('/api/lora-library/delete',{ids:[del.id]});check('Deletion requires explicit trash confirmation',response.status>=400&&fs.existsSync(path.join(DIR,del.name)));
  response=await fetch(api(`/api/lora-library/upload?id=${image.id}&ext=.png`),{method:'POST',headers:{'X-Lora-Upload':'1','Content-Type':'image/png'},body:Buffer.from('<script>alert(1)</script>')});check('Rejects disguised media content',response.status>=400);
  browser=await chromium.launch();const page=await browser.newPage({viewport:{width:1440,height:1050},acceptDownloads:true});const errors=[];let generated=null,failLibrary=false;
  page.on('pageerror',e=>errors.push(e.message));
  await page.addInitScript(({comfy})=>localStorage.setItem('minimax-h3-workstation-settings-v2',JSON.stringify({comfyUrl:comfy,mode:'t2v',loras:[],loraModeDefaults:false})),{comfy:COMFY});
  await page.route('**/api/**',async route=>{
    const u=new URL(route.request().url());
    if(u.pathname.startsWith('/api/lora-library')){if(failLibrary&&u.pathname==='/api/lora-library')return route.fulfill({status:503,contentType:'application/json',body:JSON.stringify({error:'Simulated connection failure'})});return route.continue();}
    let data={};
    switch(u.pathname){case'/api/health':data={device:'Test fixture'};break;case'/api/ai-config':data={models:[],templates:[]};break;case'/api/capabilities':data={TEspeed:false,LoraManager:true,RtxUpscale:false};break;case'/api/self-check':data={connected:false,error:'Test fixture'};break;case'/api/object-info':data={};break;case'/api/model-list':data=u.searchParams.get('type')==='loras'?modelNames.filter(n=>fs.existsSync(path.join(DIR,n))):['test-model.safetensors'];break;case'/api/check-update':data={configured:false};break;case'/api/generate':generated=route.request().postDataJSON();data={prompt_id:'aaaaaaaa-bbbb-4444-8888-cccccccccccc'};break;case'/api/progress':data={};break;}
    return route.fulfill({status:200,contentType:'application/json',body:JSON.stringify(data)});
  });
  await page.goto(BASE);check('Library defaults collapsed while selected configuration stays visible',!(await page.locator('#loraLibraryPanel').evaluate(p=>p.open))&&await page.locator('.ll-active-heading').isVisible()&&await page.locator('#addLoraButton').isVisible());await page.locator('#loraLibraryPanel > summary').click();await page.locator('.ll-card').first().waitFor();check('Cards rendered in original LoRA section',await page.locator('.ll-card').count()===5&&await page.locator('#loraList').count()===1);
  await page.locator('#loraLibrary').scrollIntoViewIfNeeded();await page.locator('.ll-card[data-id="'+image.id+'"] img').waitFor();await page.waitForFunction(id=>{const img=document.querySelector(`.ll-card[data-id="${id}"] img`);return img?.complete&&img.naturalWidth>0;},image.id);check('Image preview decodes',await page.locator('.ll-card[data-id="'+image.id+'"] img').evaluate(i=>i.complete&&i.naturalWidth>0));
  await page.locator('#llSearch').fill('Studio Demo');check('Search includes author',await page.locator('.ll-card').count()===5);await page.locator('#llSearch').fill('Motion');check('Search narrows cards',await page.locator('.ll-card').count()===1);
  const video=page.locator('.ll-card video');await page.locator('.ll-preview').hover();await page.waitForFunction(()=>{const v=document.querySelector('.ll-card video');return v&&!v.paused&&v.muted;});check('Hover plays video muted',await video.evaluate(v=>v.muted&&!v.paused));await page.locator('#llSearch').hover();await page.waitForFunction(()=>document.querySelector('.ll-card video').paused);check('Leaving preview pauses video',await video.evaluate(v=>v.paused));
  await page.locator('#llSearch').fill('Blank');await page.waitForFunction(()=>document.querySelector('.ll-card video')?.poster.startsWith('data:image/jpeg'));check('Video without a supplied poster gets a first frame cover',await page.locator('.ll-card video').evaluate(v=>v.poster.startsWith('data:image/jpeg')));
  await page.locator('#llSearch').fill('Loop');const gif=page.locator('.ll-card img');await page.locator('.ll-preview').hover();check('GIF with poster switches to animation on hover',(await gif.getAttribute('src')).includes('kind=preview'));await page.locator('#llSearch').hover();check('GIF restores poster when hover ends',(await gif.getAttribute('src')).includes('kind=poster'));
  await page.locator('#llSearch').fill('');await page.locator('#llCategory').selectOption('Other');check('Category filter works',await page.locator('.ll-card').count()===2);await page.locator('#llCategory').selectOption('');check('Tag controls and badges are removed',await page.locator('#llTag,.ll-tags,.ll-tag,#llEditForm [name=tags]').count()===0);await page.locator('#llSearch').fill('cinematic');check('Search ignores removed metadata tags',await page.locator('.ll-card').count()===0);await page.locator('#llSearch').fill('');
  await page.locator('.ll-card[data-id="'+image.id+'"] .ll-star').click();await page.waitForFunction(id=>document.querySelector(`[data-id="${id}"] .ll-star`).getAttribute('aria-pressed')==='true',image.id);await page.locator('#llFavorites').click();check('Favorite filter works',await page.locator('.ll-card').count()===1);await page.locator('#llFavorites').click();
  await page.locator('.ll-card[data-id="'+image.id+'"] .ll-add').click();check('Adding card preserves strength controls',await page.locator('#loraList .lora-row').count()===1);await page.locator('#loraList input[type=number]').fill('0.65');await page.locator('#loraList input[type=number]').blur();await page.locator('#promptInput').fill('Test landscape');await page.locator('#generateButton').click();await page.waitForFunction(()=>document.querySelector('#generateButton').disabled===false);check('Generation request includes chosen LoRA strength',generated&&generated.config.loras.length===1&&generated.config.loras[0].strength===0.65);
  await page.locator('#loraList input[type=checkbox]').uncheck();check('All disabled LoRAs show empty-enabled hint',await page.locator('#loraEmpty').isVisible());await page.locator('#loraList input[type=checkbox]').check();
  await page.locator('.ll-card[data-id="'+image.id+'"] .ll-card-title').click();check('Detail has no download or delete actions',await page.locator('#llDetail').getByRole('button',{name:/下载|删除/}).count()===0);check('Detail dialog opens with full metadata',await page.locator('#llDetail').isVisible()&&await page.locator('#llDetail .ll-path').inputValue()===image.path);await page.context().grantPermissions(['clipboard-read','clipboard-write']);await page.locator('#llDetail').getByRole('button',{name:'复制路径',exact:true}).click();check('Copy path writes the full model path',await page.evaluate(()=>navigator.clipboard.readText())===image.path);await page.locator('#llDetail').screenshot({path:path.join(OUT,'lora-detail.png')});await page.locator('#llDetail').getByRole('button',{name:'编辑',exact:true}).click();await page.locator('#llEditForm [name=title]').fill('Aurora edited');await page.locator('#llEditForm [name=description]').fill('<img src=x onerror=alert(1)> safe plain text');await page.locator('#llEditForm [name=preview]').setInputFiles(path.join(DIR,'cover.png'));await page.locator('#llSave').click();await page.waitForFunction(()=>!document.querySelector('#llEdit').open&&document.querySelector('#llDetailTitle').textContent==='Aurora edited'&&!document.querySelector('#llRefresh').disabled);check('Edit and uploaded preview persist',await page.locator('#llDetailTitle').textContent()==='Aurora edited');check('Description is displayed as text, never HTML',await page.locator('#llDetail .ll-full-description img').count()===0);await page.locator('#llDetail [data-close]').click();
  response=await fetch(api('/api/lora-library?fresh=1'));library=await response.json();check('Uploaded preview updates cache revision',library.items.find(i=>i.id===image.id).revision!==image.revision);
  await page.locator('.ll-card[data-id="'+movie.id+'"] .ll-menu summary').click();check('Card menus have no model download or delete actions',await page.locator('.ll-menu-body').getByRole('button',{name:/下载|删除/}).count()===0);await page.locator('.ll-card[data-id="'+movie.id+'"] .ll-menu summary').click();
  await page.locator('.ll-card[data-id="'+image.id+'"] input[type=checkbox]').check();await page.locator('.ll-card[data-id="'+movie.id+'"] input[type=checkbox]').check();check('Multiselect activates batch toolbar',await page.locator('#llBatch').isVisible()&&await page.locator('#llSelectedCount').textContent()==='已选择 2 项');check('Batch toolbar has no download or delete actions',await page.locator('#llBatch').getByRole('button',{name:/下载|删除/}).count()===0);await page.locator('[data-batch=clear]').click();
  failLibrary=true;await page.locator('#llRefresh').click();await page.waitForFunction(()=>document.querySelector('#llStatus').textContent.includes('刷新失败'));check('Failed refresh retains cards and selected generation settings',await page.locator('.ll-card').count()===5&&await page.locator('#loraList .lora-row').count()===1);failLibrary=false;await page.locator('#llRefresh').click();await page.waitForFunction(()=>!document.querySelector('#llRefresh').disabled);
  const snapshotStyle=await page.addStyleTag({content:'.toast-region,.generate-bar{visibility:hidden!important}'});await page.locator('#loraLibrary').screenshot({path:path.join(OUT,'lora-library-desktop.png')});
  await page.setViewportSize({width:390,height:844});await page.locator('#loraLibrary').screenshot({path:path.join(OUT,'lora-library-mobile.png')});check('Mobile page has no horizontal overflow',await page.evaluate(()=>document.documentElement.scrollWidth<=window.innerWidth));check('Mobile library uses a single column',await page.locator('#llGrid').evaluate(g=>getComputedStyle(g).gridTemplateColumns.split(' ').length===1));
  await snapshotStyle.evaluate(n=>n.remove());check('Mobile has no download or delete controls or delete dialog',await page.locator('#loraLibrary').getByRole('button',{name:/下载|删除/}).count()===0&&await page.locator('#llDelete,#llConfirmDelete').count()===0);check('UI operations leave all model files intact',modelNames.every(n=>fs.existsSync(path.join(DIR,n))));
  check('No JavaScript runtime errors throughout UI operations',errors.length===0);
  fs.writeFileSync(path.join(OUT,'lora-library-test.json'),JSON.stringify({passed:checks.length,checks,errors},null,2));console.log(JSON.stringify({passed:checks.length,checks,errors},null,2));
})().catch(error=>{console.error(error.stack);console.error(JSON.stringify({passed:checks.length,checks}));process.exitCode=1;}).finally(async()=>{if(browser)await browser.close();await new Promise(r=>upstream.close(r));});
