// The library manages files/metadata; the workstation remains the owner of generation settings.
export function createLoraLibrary(host) {
  const root = document.getElementById('loraLibrary');
  const state = { items: [], selected: new Set(), query: '', category: '', sort: 'name', favorites: false, limit: 24, loading: false, error: '', note: '', request: 0, busy: false, comfy: '' };
  root.innerHTML = `
    <div class="ll-toolbar">
      <div class="ll-search-row"><label class="ll-search"><span aria-hidden="true">⌕</span><input type="search" placeholder="搜索名称、作者或描述" aria-label="搜索 LoRA" id="llSearch"></label><button type="button" class="ll-icon-button" id="llRefresh" title="刷新模型库" aria-label="刷新模型库">↻</button></div>
      <div class="ll-filters"><select id="llCategory" aria-label="基础模型分类"><option value="">全部基础模型</option></select><select id="llSort" aria-label="排序"><option value="name">名称 A–Z</option><option value="updated">最近更新</option><option value="size">文件大小</option><option value="favorite">收藏优先</option></select><button type="button" class="ll-filter-button" id="llFavorites" aria-pressed="false">☆ 收藏</button><button type="button" class="ll-filter-button" id="llSelectAll">多选</button></div>
    </div>
    <div class="ll-batch" id="llBatch" hidden><span id="llSelectedCount"></span><button type="button" data-batch="add">添加到生成</button><button type="button" data-batch="favorite">收藏</button><button type="button" data-batch="unfavorite">取消收藏</button><button type="button" data-batch="clear">取消选择</button></div>
    <div class="ll-status" id="llStatus" role="status" aria-live="polite"></div><p class="ll-note" id="llNote" hidden></p>
    <div class="ll-grid" id="llGrid"></div><button type="button" class="ll-more" id="llMore" hidden>加载更多</button>
    <dialog class="ll-dialog ll-detail" id="llDetail" aria-labelledby="llDetailTitle"><div class="ll-dialog-top"><span class="ll-eyebrow">LORA / 模型详情</span><button type="button" class="ll-icon-button" data-close aria-label="关闭详情">×</button></div><div id="llDetailBody"></div></dialog>
    <dialog class="ll-dialog ll-edit" id="llEdit" aria-labelledby="llEditTitle"><form id="llEditForm"><div class="ll-dialog-top"><h3 id="llEditTitle">编辑 LoRA 资料</h3><button type="button" class="ll-icon-button" data-close aria-label="关闭编辑">×</button></div>
      <div class="ll-edit-grid"><label>显示名称<input name="title" required maxlength="200"></label><label>作者<input name="author" maxlength="200" placeholder="未填写"></label><label>基础模型<input name="baseModel" maxlength="200" placeholder="例如 MiniMax H3"></label><label class="ll-full">描述<textarea name="description" rows="5" maxlength="10000" placeholder="记录模型风格、推荐强度和使用方式"></textarea></label></div>
      <div class="ll-upload-grid"><label>预览文件<input name="preview" type="file" accept=".jpg,.jpeg,.png,.webp,.gif,.mp4,.webm"><small>图片、GIF 或视频，最大 100 MB</small></label><label>视频 / GIF 封面<input name="poster" type="file" accept=".jpg,.jpeg,.png,.webp"><small>JPG / PNG / WebP，最大 100 MB</small></label></div>
      <p class="ll-note">只修改显示资料，模型文件名和已有元数据保持不变。</p><p id="llEditError" class="ll-error" role="alert"></p><div class="ll-dialog-actions"><button type="button" class="button secondary" data-close>取消</button><button type="submit" class="button primary" id="llSave">保存资料</button></div></form></dialog>`;
  const el = (id) => root.querySelector('#' + id);
  const grid = el('llGrid');
  let detailId = '', editingId = '', focusBeforeDialog = null;
  const dialogs = [...root.querySelectorAll('dialog')];
  const make = (tag, className, text) => { const n = document.createElement(tag); if (className) n.className = className; if (text != null) n.textContent = text; return n; };
  const button = (label, action, className = 'll-action-button') => { const b = make('button', className, label); b.type = 'button'; b.addEventListener('click', action); return b; };
  const get = (id) => state.items.find((i) => i.id === id);
  const url = (path) => host.apiUrl(path);
  const mediaUrl = (item, kind = 'preview') => url(`/api/lora-library/media?id=${encodeURIComponent(item.id)}&kind=${kind}&v=${encodeURIComponent(item.revision || item.updatedAt || '')}`);
  const bytes = (size) => { if (size == null) return '大小未知'; if (size < 1024) return `${size} B`; const index = Math.min(3, Math.floor(Math.log(size) / Math.log(1024))); return `${(size / 1024 ** index).toFixed(1)} ${['B','KB','MB','GB'][index]}`; };
  const date = (value) => value && Number.isFinite(Date.parse(value)) ? new Date(value).toLocaleDateString('zh-CN') : '更新时间未知';
  const isAdded = (item) => host.getLoras().some((l) => l.name === item.name);
  const coverCache = new Map(), coverQueue = [];
  let coverJobs = 0;
  function queueCover(video) {
    const source = video.dataset.coverSource;
    if (!source || video.dataset.coverQueued) return;
    video.dataset.coverQueued = '1';
    if (coverCache.has(source)) { video.poster = coverCache.get(source); video.parentElement.querySelector('.ll-placeholder').hidden = true; return; }
    coverQueue.push({ video, source }); pumpCovers();
  }
  function pumpCovers() {
    while (coverJobs < 2 && coverQueue.length) {
      const {video, source} = coverQueue.shift(); if (!video.isConnected) continue;
      coverJobs++;
      const probe = document.createElement('video'); probe.muted = true; probe.playsInline = true; probe.preload = 'auto';
      let done = false;
      const finish = () => { if (done) return; done = true; clearTimeout(timeout); probe.pause(); probe.removeAttribute('src'); probe.load(); coverJobs--; pumpCovers(); };
      const timeout = setTimeout(finish, 8000);
      probe.addEventListener('loadedmetadata', () => { probe.currentTime = Math.min(0.05, Number.isFinite(probe.duration) ? probe.duration / 2 : 0.05); });
      probe.addEventListener('seeked', () => {
        try {
          const canvas = document.createElement('canvas'); canvas.width = 320; canvas.height = Math.max(1, Math.round(320 * probe.videoHeight / probe.videoWidth));
          canvas.getContext('2d').drawImage(probe, 0, 0, canvas.width, canvas.height);
          const cover = canvas.toDataURL('image/jpeg', 0.8); coverCache.set(source, cover);
          if (coverCache.size > 100) coverCache.delete(coverCache.keys().next().value);
          if (video.isConnected) { video.poster = cover; video.parentElement.querySelector('.ll-placeholder').hidden = true; }
        } catch {} finally { finish(); }
      }, { once: true });
      probe.addEventListener('error', finish, { once: true }); probe.src = source;
    }
  }
  function stopMedia(container) { container.querySelectorAll('video').forEach((v) => { v.pause(); v.removeAttribute('src'); v.load(); }); }
  function stopGrid() { stopMedia(grid); }
  const panel = document.getElementById('loraLibraryPanel');
  if (panel) {
    const storageKey = 'workstation.loraLibrary.expanded';
    try { panel.open = localStorage.getItem(storageKey) === '1'; } catch {}
    const updateDisclosure = () => {
      document.getElementById('loraLibraryToggle').textContent = panel.open ? '收起模型库' : '展开模型库';
      if (!panel.open) {
        stopGrid();
        grid.querySelectorAll('.ll-menu[open]').forEach((menu) => { menu.open = false; });
      }
    };
    updateDisclosure();
    panel.addEventListener('toggle', () => {
      updateDisclosure();
      try { localStorage.setItem(storageKey, panel.open ? '1' : '0'); } catch {}
    });
  }
  function open(dialog) { focusBeforeDialog = document.activeElement; dialog.showModal(); dialog.querySelector('button, input')?.focus(); }
  function close(dialog) { if (state.busy) return; stopMedia(dialog); dialog.close(); focusBeforeDialog?.focus(); }
  dialogs.forEach((dialog) => {
    dialog.querySelectorAll('[data-close]').forEach((b) => b.addEventListener('click', () => close(dialog)));
    dialog.addEventListener('cancel', (event) => { if (state.busy) event.preventDefault(); });
    dialog.addEventListener('close', () => stopMedia(dialog));
    dialog.addEventListener('click', (event) => { if (event.target === dialog) { const r = dialog.getBoundingClientRect(); if (event.clientX < r.left || event.clientX > r.right || event.clientY < r.top || event.clientY > r.bottom) close(dialog); } });
  });
  function placeholder() {
    const p = make('div', 'll-placeholder');
    p.innerHTML = '<svg viewBox="0 0 64 64" fill="none" aria-hidden="true"><rect x="12" y="12" width="40" height="40" rx="10" stroke="currentColor" stroke-width="2"/><path d="M19 42l10-12 8 8 5-6 5 10" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/><circle cx="40" cy="24" r="3" fill="currentColor"/></svg><span>暂无预览</span>';
    return p;
  }
  function preview(item, large = false) {
    const box = make('div', `ll-preview${large ? ' ll-preview-large' : ''}`);
    const fallback = placeholder(); box.append(fallback);
    if (!item.hasPreview) return box;
    const videoType = ['mp4', 'webm'].includes(item.mediaType);
    const gif = item.mediaType === 'gif';
    const fail = () => { box.querySelectorAll('img,video,.ll-media-badge').forEach((n) => n.remove()); fallback.hidden = false; fallback.querySelector('span').textContent = '预览加载失败'; };
    if (videoType) {
      const video = make('video'); video.muted = true; video.loop = !large; video.playsInline = true; video.preload = large ? 'metadata' : 'none'; video.controls = large;
      video.setAttribute('aria-label', `${item.title} 视频预览`);
      if (item.hasPoster) { video.poster = mediaUrl(item, 'poster'); fallback.hidden = true; }
      else { fallback.querySelector('span').textContent = '视频预览'; if (!large) video.dataset.coverSource = mediaUrl(item); }
      video.addEventListener('loadeddata', () => { fallback.hidden = true; }); video.addEventListener('error', fail, { once: true });
      box.append(video);
      if (large) video.src = mediaUrl(item);
      else {
        let hovering = false;
        box.addEventListener('mouseenter', () => { if (!matchMedia('(hover: hover)').matches || document.hidden) return; hovering = true; if (!video.getAttribute('src')) video.src = mediaUrl(item); video.play().then(() => { if (!hovering) video.pause(); }).catch(() => {}); });
        box.addEventListener('mouseleave', () => { hovering = false; video.pause(); if (video.readyState) video.currentTime = 0; if (video.poster) { video.removeAttribute('src'); video.load(); } });
      }
    } else {
      const img = make('img'); img.alt = `${item.title} 预览`; img.loading = 'lazy'; img.decoding = 'async';
      img.src = gif && !large && item.hasPoster ? mediaUrl(item, 'poster') : mediaUrl(item);
      img.addEventListener('load', () => { fallback.hidden = true; }); img.addEventListener('error', fail, { once: true }); box.append(img);
      if (gif && !large && item.hasPoster) { box.addEventListener('mouseenter', () => { img.src = mediaUrl(item); }); box.addEventListener('mouseleave', () => { img.src = mediaUrl(item, 'poster'); }); }
    }
    box.append(make('span', 'll-media-badge', videoType ? '▶ VIDEO' : gif ? 'GIF' : item.mediaType.toUpperCase()));
    return box;
  }
  function filtered() {
    const q = state.query.trim().toLocaleLowerCase();
    return state.items.filter((i) => (!q || [i.title,i.name,i.author,i.description].join(' ').toLocaleLowerCase().includes(q)) && (!state.category || (i.baseModel || '未标注') === state.category) && (!state.favorites || i.favorite)).sort((a,b) => {
      if (state.sort === 'updated') return (Date.parse(b.updatedAt) || 0) - (Date.parse(a.updatedAt) || 0) || a.title.localeCompare(b.title, 'zh-CN');
      if (state.sort === 'size') return (b.size || 0) - (a.size || 0) || a.title.localeCompare(b.title, 'zh-CN');
      if (state.sort === 'favorite' && a.favorite !== b.favorite) return Number(b.favorite) - Number(a.favorite);
      return a.title.localeCompare(b.title, 'zh-CN', { numeric: true });
    });
  }
  function populateFilters() {
    for (const [id, values, label, key] of [['llCategory',[...new Set(state.items.map((i) => i.baseModel || '未标注'))],'全部基础模型','category']]) {
      const select = el(id); select.replaceChildren(new Option(label, ''));
      values.sort((a,b) => a.localeCompare(b, 'zh-CN')).forEach((v) => select.add(new Option(v,v)));
      if (values.includes(state[key])) select.value = state[key]; else state[key] = '';
    }
  }
  function renderBatch() {
    el('llBatch').hidden = !state.selected.size;
    el('llSelectedCount').textContent = `已选择 ${state.selected.size} 项`;
    root.querySelectorAll('[data-batch]').forEach((b) => { b.disabled = state.busy; });
  }
  function card(item) {
    const c = make('article', `ll-card${isAdded(item) ? ' is-added' : ''}${state.selected.has(item.id) ? ' is-selected' : ''}`); c.dataset.id = item.id;
    const media = preview(item); const opener = button('', () => showDetail(item.id), 'll-preview-open'); opener.setAttribute('aria-label', `查看 ${item.title} 详情`); media.append(opener);
    const selectLabel = make('label', 'll-select'); const checkbox = make('input'); checkbox.type = 'checkbox'; checkbox.checked = state.selected.has(item.id); checkbox.setAttribute('aria-label', `选择 ${item.title}`);
    checkbox.addEventListener('change', () => { if (checkbox.checked) state.selected.add(item.id); else state.selected.delete(item.id); c.classList.toggle('is-selected', checkbox.checked); renderBatch(); }); selectLabel.append(checkbox); media.append(selectLabel);
    const star = button(item.favorite ? '★' : '☆', () => favorite([item.id], !item.favorite), 'll-star'); star.classList.toggle('is-favorite', item.favorite); star.setAttribute('aria-label', `${item.favorite ? '取消收藏' : '收藏'} ${item.title}`); star.setAttribute('aria-pressed', String(item.favorite)); media.append(star);
    const info = make('div', 'll-card-info'); const title = button(item.title, () => showDetail(item.id), 'll-card-title'); title.title = item.name;
    const byline = make('div', 'll-byline'); byline.append(make('span', '', item.author || '作者未填写'),make('span','ll-model-badge',item.baseModel || '基础模型未标注'));
    const desc = make('p','ll-description',item.description || '暂无描述，可在编辑中补充使用方式。');
    const facts = make('div','ll-facts'); facts.append(make('span','',bytes(item.size)),make('time','',date(item.updatedAt))); facts.lastChild.title = '模型文件更新时间';
    const actions = make('div','ll-card-actions'); const add = button(isAdded(item) ? '✓ 已添加' : '+ 添加到生成', () => { host.add(item.name); updateSelection(); },'ll-add'); add.disabled=isAdded(item);
    const menu = make('details','ll-menu'); const summary = make('summary','','···'); summary.setAttribute('aria-label', `${item.title} 操作`); const menuBody = make('div','ll-menu-body');
    for (const [label,action] of [['查看详情',()=>showDetail(item.id)],['编辑资料',()=>showEdit(item.id)],['复制路径',()=>copyPath(item)]]) {
      const b=button(label,()=>{ menu.open=false; action(); }); menuBody.append(b);
    }
    menu.addEventListener('toggle', () => { if (!menu.open) return; menu.classList.remove('ll-menu-up'); if (menuBody.getBoundingClientRect().bottom > window.innerHeight - 90) menu.classList.add('ll-menu-up'); });
    menu.append(summary,menuBody); actions.append(add,menu); info.append(title,byline,desc,facts,actions); c.append(media,info); return c;
  }
  function render() {
    stopGrid(); grid.replaceChildren();
    const items = filtered();
    el('llStatus').textContent = state.loading ? '正在读取模型库…' : state.error ? `刷新失败：${state.error}。已保留原有模型与生成配置。` : `${state.items.length} 个模型 · 当前显示 ${Math.min(state.limit,items.length)} / ${items.length} 项`;
    el('llStatus').classList.toggle('ll-error', !!state.error);
    el('llRefresh').disabled=state.loading;
    el('llNote').textContent=state.note; el('llNote').hidden=!state.note;
    if (state.loading && !state.items.length) { for (let n=0;n<4;n++) grid.append(make('div','ll-skeleton')); }
    else if (!items.length) {
      const empty=make('div','ll-empty'); empty.append(make('span','',state.items.length ? '没有匹配的模型' : state.error ? '暂时无法读取模型库' : '模型库还是空的'),make('p','',state.items.length ? '试试其他关键词，或清除筛选条件。' : '将 LoRA 放入 ComfyUI 的 models/loras 目录后刷新。'));
      if (state.items.length) empty.append(button('清除筛选',()=>{ state.query='';state.category='';state.favorites=false;el('llSearch').value='';el('llCategory').value='';el('llFavorites').setAttribute('aria-pressed','false');render(); })); grid.append(empty);
    } else items.slice(0,state.limit).forEach((i)=>grid.append(card(i)));
    el('llMore').hidden=state.loading || items.length<=state.limit; renderBatch();
  }
  async function refresh() {
    const request=++state.request, comfy=host.getComfy();
    if (state.comfy && state.comfy !== comfy) { state.items=[]; state.selected.clear(); dialogs.filter((d)=>d.open).forEach(close); }
    state.comfy=comfy;state.loading=true;state.error='';render();
    try {
      const result=await host.fetchJson(url('/api/lora-library?fresh=1'),{},45000);
      if (request!==state.request || comfy!==host.getComfy()) return;
      if (!Array.isArray(result.items)) throw new Error('模型库接口尚未就绪，请重启工作站服务后刷新页面。');
      state.items=result.items;state.note=result.note || '';state.selected=new Set([...state.selected].filter((id)=>get(id)));host.syncNames(state.items.map((i)=>i.name));populateFilters();
      if (detailId && el('llDetail').open) { if (get(detailId)) buildDetail(get(detailId)); else close(el('llDetail')); }
    } catch (error) { if (request===state.request) { state.error=error.message; } }
    finally { if (request===state.request) { state.loading=false;render(); } }
  }
  async function post(path, body) { return host.fetchJson(url(path),{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(body)},45000); }
  async function favorite(ids,value) {
    if (state.busy) return; state.busy=true;renderBatch();
    try { await post('/api/lora-library/favorite',{ids,favorite:value}); state.items.forEach((i)=>{ if(ids.includes(i.id))i.favorite=value; }); if(detailId && el('llDetail').open)buildDetail(get(detailId));render(); }
    catch(error){host.toast(error.message,'error');}
    finally{state.busy=false;renderBatch();}
  }
  async function copyPath(item) {
    try { if (navigator.clipboard && window.isSecureContext) await navigator.clipboard.writeText(item.path); else { const input=make('textarea');input.value=item.path;input.className='ll-copy-buffer';root.append(input);input.select();const ok=document.execCommand('copy');input.remove();if(!ok)throw new Error('copy'); } host.toast('模型路径已复制。','success'); }
    catch { const detail=el('llDetail'); if(!detail.open)showDetail(item.id); const input=el('llDetailBody').querySelector('.ll-path');input?.focus();input?.select();host.toast('自动复制不可用，路径已选中，可手动复制。'); }
  }
  function buildDetail(item) {
    if(!item)return;const body=el('llDetailBody');stopMedia(body);body.replaceChildren();
    const content=make('div','ll-detail-content');const info=make('div','ll-detail-info');const title=make('h3','',item.title);title.id='llDetailTitle';
    const meta=make('dl','ll-metadata');for(const [label,value]of [['作者',item.author||'未填写'],['基础模型',item.baseModel||'未标注'],['文件大小',bytes(item.size)],['更新时间',date(item.updatedAt)],['文件名',item.name]])meta.append(make('dt','',label),make('dd','',value));
    const description=make('p','ll-full-description',item.description||'暂无描述');const pathLabel=make('label','ll-path-label','文件路径');const path=make('textarea','ll-path');path.value=item.path;path.readOnly=true;path.rows=2;pathLabel.append(path);
    info.append(title,meta,description,pathLabel);content.append(preview(item,true),info);
    const actions=make('div','ll-dialog-actions');const add=button(isAdded(item)?'✓ 已添加到生成':'+ 添加到生成',()=>{host.add(item.name);updateSelection();buildDetail(item);},'button primary');add.disabled=isAdded(item);
    actions.append(add,button(item.favorite?'★ 已收藏':'☆ 收藏',()=>favorite([item.id],!item.favorite),'button secondary'),button('编辑',()=>showEdit(item.id),'button secondary'),button('复制路径',()=>copyPath(item),'button secondary'));
    body.append(content,actions);
  }
  function showDetail(id){detailId=id;buildDetail(get(id));open(el('llDetail'));}
  function showEdit(id){
    const item=get(id);if(!item)return;editingId=id;const form=el('llEditForm');form.reset();for(const key of ['title','author','baseModel','description'])form.elements.namedItem(key).value=item[key]||'';el('llEditError').textContent='';open(el('llEdit'));
  }
  el('llEditForm').addEventListener('submit',async(event)=>{
    event.preventDefault();if(state.busy)return;state.busy=true;el('llSave').disabled=true;el('llEditError').textContent='';
    const form=event.currentTarget;const data={id:editingId};for(const key of ['title','author','baseModel','description'])data[key]=form.elements.namedItem(key).value;
    let metadataSaved=false;
    try{
      const uploads=[];for(const kind of ['preview','poster']){const file=form.elements.namedItem(kind).files[0];if(!file)continue;if(file.size>100*1024*1024)throw new Error('预览文件不能超过 100 MB。');uploads.push({kind,file});}
      await post('/api/lora-library/edit',data);metadataSaved=true;
      for(const {kind,file}of uploads){const ext='.'+file.name.split('.').pop().toLowerCase();await host.fetchJson(url(`/api/lora-library/upload?id=${editingId}&kind=${kind}&ext=${encodeURIComponent(ext)}`),{method:'POST',headers:{'Content-Type':file.type||'application/octet-stream','X-Lora-Upload':'1'},body:file},120000);}
      state.busy=false;close(el('llEdit'));await refresh();host.toast('LoRA 资料已保存。','success');
    }catch(error){el('llEditError').textContent=(metadataSaved?'文字资料已保存，预览上传未完成：':'保存失败：')+error.message;}
    finally{state.busy=false;el('llSave').disabled=false;renderBatch();}
  });
  function updateSelection(){grid.querySelectorAll('.ll-card').forEach((c)=>{const item=get(c.dataset.id);if(!item)return;const added=isAdded(item);c.classList.toggle('is-added',added);const add=c.querySelector('.ll-add');add.textContent=added?'✓ 已添加':'+ 添加到生成';add.disabled=added;});const active=host.getLoras().filter((l)=>l.active!==false).length;document.getElementById('loraLibraryCount').textContent=`${state.items.length} 个模型 · ${active} 个已启用`;}
  el('llSearch').addEventListener('input',(e)=>{state.query=e.target.value;state.limit=24;render();});
  for(const [id,key]of [['llCategory','category'],['llSort','sort']])el(id).addEventListener('change',(e)=>{state[key]=e.target.value;state.limit=24;render();});
  el('llFavorites').addEventListener('click',()=>{state.favorites=!state.favorites;el('llFavorites').setAttribute('aria-pressed',String(state.favorites));render();});
  el('llSelectAll').addEventListener('click',()=>{const ids=filtered().slice(0,state.limit).map((i)=>i.id);const all=ids.length&&ids.every((id)=>state.selected.has(id));ids.forEach((id)=>{if(all)state.selected.delete(id);else state.selected.add(id);});render();});
  root.querySelectorAll('[data-batch]').forEach((b)=>b.addEventListener('click',()=>{const ids=[...state.selected];switch(b.dataset.batch){case'add':ids.map(get).filter(Boolean).forEach((i)=>host.add(i.name));updateSelection();break;case'favorite':favorite(ids,true);break;case'unfavorite':favorite(ids,false);break;case'clear':state.selected.clear();render();break;}}));
  el('llRefresh').addEventListener('click',refresh);el('llMore').addEventListener('click',()=>{state.limit+=24;render();});
  document.addEventListener('visibilitychange',()=>{if(document.hidden){root.querySelectorAll('video').forEach((v)=>v.pause());}});
  const observer=new IntersectionObserver((entries)=>entries.forEach((entry)=>{entry.target.querySelectorAll('video').forEach((v)=>{if(!entry.isIntersecting)v.pause();else queueCover(v);});}));
  const gridObserver=new MutationObserver(()=>{observer.disconnect();grid.querySelectorAll('.ll-preview').forEach((n)=>observer.observe(n));updateSelection();});gridObserver.observe(grid,{childList:true});
  document.addEventListener('click',(event)=>{root.querySelectorAll('.ll-menu[open]').forEach((m)=>{if(!m.contains(event.target))m.open=false;});});
  render();return {refresh,updateSelection};
}
