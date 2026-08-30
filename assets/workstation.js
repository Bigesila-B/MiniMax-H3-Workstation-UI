const WORKFLOW_FILES = {
  t2v: "minimaxH3文生视频基础加速流.json",
  i2v: "minimaxH3图生视频基础加速流.json",
  flf2v: "minimaxH3首尾帧视频基础加速流.json",
  ref2va: "minimaxh3全能参考(图片+视频+音频)+ai提示词生成+加速+Lora.json",
};

const DEFAULT_MODELS = {
  unet: "minimax_h3_fl2va_pruned_int8_convrot.safetensors",
  clip: "qwen3vl_32b_minimax_h3_int8_convrot.safetensors",
  videoVae: "minimax_h3_video_vae_fp16.safetensors",
  audioVae: "minimax_h3_audio_vae_fp32.safetensors",
  lora: "minimax_h3_turbo_v4_step600_ema",
  ref2vaLora: "minimax_h3_ref2v_turbo_4step_v0.1_comfyui_bf16",
  ref2vaUnet: "minimax_h3_ref2va_pruned_int8_convrot.safetensors",
  ref2vaClip: "qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors",
};

const STORAGE_KEYS = {
  settings: "minimax-h3-workstation-settings-v2",
  tasks: "minimax-h3-workstation-tasks-v2",
};

const ASPECT_RATIO_ALIASES = {
  "1:1": "1:1 (Square)",
  "1:1 (Square)": "1:1 (Square)",
  "2:3": "2:3 (Portrait Photo)",
  "2:3 (Portrait)": "2:3 (Portrait Photo)",
  "2:3 (Portrait Photo)": "2:3 (Portrait Photo)",
  "3:2": "3:2 (Photo)",
  "3:2 (Landscape)": "3:2 (Photo)",
  "3:2 (Photo)": "3:2 (Photo)",
  "3:4": "3:4 (Portrait Standard)",
  "3:4 (Portrait Standard)": "3:4 (Portrait Standard)",
  "4:3": "4:3 (Standard)",
  "4:3 (Landscape Standard)": "4:3 (Standard)",
  "4:3 (Standard)": "4:3 (Standard)",
  "9:16": "9:16 (Portrait Widescreen)",
  "9:16 (Portrait)": "9:16 (Portrait Widescreen)",
  "9:16 (Portrait Widescreen)": "9:16 (Portrait Widescreen)",
  "16:9": "16:9 (Widescreen)",
  "16:9 (Landscape)": "16:9 (Widescreen)",
  "16:9 (Widescreen)": "16:9 (Widescreen)",
  "21:9": "21:9 (Ultrawide)",
  "21:9 (Ultrawide)": "21:9 (Ultrawide)",
};

function normalizeAspectRatio(value) {
  return ASPECT_RATIO_ALIASES[String(value || "").trim()] || "3:4 (Portrait Standard)";
}

function findModelName(list, preferredBase) {
  // 在模型/LoRA 列表里找首选名；忽略子文件夹前缀和扩展名差异
  // （文件被移入 "MiniMax H3" 之类的子文件夹后，旧的裸名字仍应能匹配到）。
  const preferred = String(preferredBase || "").trim();
  if (!preferred || !Array.isArray(list) || !list.length) return "";
  if (list.includes(preferred)) return preferred;
  const lowerBase = preferred.toLowerCase();
  const matches = list.filter((name) => {
    const file = String(name).split(/[\\/]/).pop().toLowerCase();
    return file === lowerBase || file.startsWith(lowerBase + ".");
  });
  return matches[0] || "";
}

const state = {
  mode: "t2v",
  firstFrame: null,
  lastFrame: null,
  referenceImages: [],
  referenceVideos: [],
  referenceAudios: [],
  models: { unet: [], clip: [], vae: [], lora: [] },
  storedModels: {},
  modelsScanned: false,
  aiConfig: { models: [], templates: [] },
  loras: [],
  loraModeDefaults: true,
  tasks: [],
  pollers: new Map(),
  clockTimer: null,
  promptUndoSnapshot: null,
};

const $ = (id) => document.getElementById(id);
const elements = {
  connectionPill: $("connectionPill"), connectionText: $("connectionText"), comfyUrl: $("comfyUrl"),
  testConnectionButton: $("testConnectionButton"), scanModelsButton: $("scanModelsButton"), modelScanStatus: $("modelScanStatus"),
  modeControl: $("modeControl"), imageUploadArea: $("imageUploadArea"), firstFrameCard: $("firstFrameCard"), lastFrameCard: $("lastFrameCard"),
  firstFrameInput: $("firstFrameInput"), lastFrameInput: $("lastFrameInput"), firstFramePreview: $("firstFramePreview"), lastFramePreview: $("lastFramePreview"),
  referenceUploadArea: $("referenceUploadArea"), referenceImagesInput: $("referenceImagesInput"), referenceVideosInput: $("referenceVideosInput"), referenceAudiosInput: $("referenceAudiosInput"),
  referenceImagesList: $("referenceImagesList"), referenceVideosList: $("referenceVideosList"), referenceAudiosList: $("referenceAudiosList"),
  removeFirstFrame: $("removeFirstFrame"), removeLastFrame: $("removeLastFrame"), promptInput: $("promptInput"), promptCount: $("promptCount"),
  promptUndoButton: $("promptUndoButton"),
  generateAiPromptButton: $("generateAiPromptButton"), aiModelSelect: $("aiModelSelect"), aiTemplateSelect: $("aiTemplateSelect"), aiReadImages: $("aiReadImages"),
  durationRange: $("durationRange"), durationNumber: $("durationNumber"), durationValue: $("durationValue"), aspectRatio: $("aspectRatio"), megapixels: $("megapixels"),
  unetModel: $("unetModel"), clipModel: $("clipModel"), videoVae: $("videoVae"), audioVae: $("audioVae"), loraList: $("loraList"), loraEmpty: $("loraEmpty"),
  addLoraButton: $("addLoraButton"), steps: $("steps"), seed: $("seed"), samplerName: $("samplerName"), randomSeedButton: $("randomSeedButton"),
  teControl: $("teControl"), tePercent1: $("tePercent1"), tePercent2: $("tePercent2"), generationSummary: $("generationSummary"), generateButton: $("generateButton"),
  taskList: $("taskList"), taskEmpty: $("taskEmpty"), refreshTasksButton: $("refreshTasksButton"), clearTasksButton: $("clearTasksButton"), toastRegion: $("toastRegion"),
};

function normalizeComfyUrl(value = elements.comfyUrl.value) {
  return value.trim().replace(/\/+$/, "");
}

function apiUrl(path, comfyUrl = normalizeComfyUrl()) {
  const separator = path.includes("?") ? "&" : "?";
  return `${path}${separator}comfy=${encodeURIComponent(comfyUrl)}`;
}

async function fetchJson(url, options = {}, timeoutMs = 30000) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const response = await fetch(url, { ...options, signal: controller.signal });
    const text = await response.text();
    let data = null;
    try { data = text ? JSON.parse(text) : {}; } catch { data = { message: text }; }
    if (!response.ok) throw new Error(data?.error || data?.message || `请求失败（HTTP ${response.status}）`);
    return data;
  } finally {
    clearTimeout(timer);
  }
}

function toast(message, type = "") {
  const node = document.createElement("div");
  node.className = `toast ${type}`.trim();
  node.textContent = message;
  elements.toastRegion.appendChild(node);
  setTimeout(() => node.remove(), 4200);
}

function setConnection(stateName, text) {
  elements.connectionPill.dataset.state = stateName;
  elements.connectionText.textContent = text;
}

function clampDuration(value) {
  return Math.max(1, Math.min(15, Number.parseInt(value, 10) || 1));
}

function syncDuration(value) {
  const seconds = clampDuration(value);
  elements.durationRange.value = String(seconds);
  elements.durationNumber.value = String(seconds);
  elements.durationValue.textContent = `${seconds} 秒`;
  updateSummary();
  saveSettings();
}

function updateSummary() {
  const modeLabels = { t2v: "文生视频", i2v: "图生视频", flf2v: "首尾帧视频", ref2va: "全能参考视频" };
  const ratio = elements.aspectRatio.value.split(" ")[0];
  elements.generationSummary.textContent = `${modeLabels[state.mode]} · ${clampDuration(elements.durationNumber.value)} 秒 · ${ratio}`;
}

function updateMode(mode) {
  const previousMode = state.mode;
  state.mode = mode;
  // 仅当用户仍在使用自动默认 LoRA 时，随模式切换普通 Turbo / Ref2V 专用 4-step Turbo。
  // 一旦用户手动新增、删除、启停、改名或改强度，就保留用户配置，不再强制覆盖。
  if (state.loraModeDefaults && previousMode !== mode) {
    syncAutomaticLora();
    renderLoras();
  }
  [...elements.modeControl.querySelectorAll(".segment")].forEach((button) => {
    const active = button.dataset.mode === mode;
    button.classList.toggle("active", active);
    button.setAttribute("aria-selected", String(active));
  });
  elements.imageUploadArea.classList.toggle("hidden", mode === "t2v" || mode === "ref2va");
  elements.lastFrameCard.classList.toggle("hidden", mode !== "flf2v");
  elements.referenceUploadArea?.classList.toggle("hidden", mode !== "ref2va");
  updateSummary();
  saveSettings();
}

async function loadAiPromptConfig() {
  try {
    const config = await fetchJson("/api/ai-config", {}, 15000);
    state.aiConfig = config;
    const stored = JSON.parse(localStorage.getItem(STORAGE_KEYS.settings) || "{}");
    elements.aiModelSelect.replaceChildren();
    elements.aiTemplateSelect.replaceChildren();
    config.models.forEach((item) => appendOption(elements.aiModelSelect, item.id, item.id));
    config.templates.forEach((item) => appendOption(elements.aiTemplateSelect, item.id, item.name));
    const preferredModel = stored.aiModel || config.defaultModel;
    const preferredTemplate = stored.aiTemplate || config.defaultTemplate;
    if (config.models.some((item) => item.id === preferredModel)) elements.aiModelSelect.value = preferredModel;
    if (config.templates.some((item) => item.id === preferredTemplate)) elements.aiTemplateSelect.value = preferredTemplate;
    elements.generateAiPromptButton.disabled = !config.models.length || !config.templates.length;
  } catch (error) {
    elements.aiModelSelect.replaceChildren();
    elements.aiTemplateSelect.replaceChildren();
    appendOption(elements.aiModelSelect, "", "配置读取失败");
    appendOption(elements.aiTemplateSelect, "", "配置读取失败");
    elements.generateAiPromptButton.disabled = true;
    toast(`AI 配置读取失败：${error.message}`, "error");
  }
}

async function fileToAiDataUrl(file) {
  const originalUrl = URL.createObjectURL(file);
  try {
    const image = await new Promise((resolve, reject) => {
      const node = new Image();
      node.onload = () => resolve(node);
      node.onerror = () => reject(new Error(`无法解析图片：${file.name}`));
      node.src = originalUrl;
    });
    const maxSide = 1536;
    const scale = Math.min(1, maxSide / Math.max(image.naturalWidth, image.naturalHeight));
    const width = Math.max(1, Math.round(image.naturalWidth * scale));
    const height = Math.max(1, Math.round(image.naturalHeight * scale));
    const canvas = document.createElement("canvas");
    canvas.width = width;
    canvas.height = height;
    const context = canvas.getContext("2d", { alpha: false });
    context.fillStyle = "#ffffff";
    context.fillRect(0, 0, width, height);
    context.drawImage(image, 0, 0, width, height);
    return canvas.toDataURL("image/jpeg", 0.84);
  } finally {
    URL.revokeObjectURL(originalUrl);
  }
}

async function generateAiPrompt() {
  const question = elements.promptInput.value.trim();
  if (!question) return toast("请先在提示词框输入一个简短创意或要求。", "error");
  if (!elements.aiModelSelect.value || !elements.aiTemplateSelect.value) return toast("AI 模型或模板配置不可用。", "error");
  // 撤回快照取发送前的内容，只在生成成功覆盖后生效；请求失败不会丢失当前输入。
  const preSendText = elements.promptInput.value;
  elements.generateAiPromptButton.disabled = true;
  elements.generateAiPromptButton.textContent = "AI 正在生成…";
  try {
    const images = [];
    if (elements.aiReadImages.checked) {
      if (state.firstFrame) images.push(await fileToAiDataUrl(state.firstFrame));
      if (state.lastFrame) images.push(await fileToAiDataUrl(state.lastFrame));
      if (state.mode === "ref2va") {
        for (const file of state.referenceImages) {
          images.push(await fileToAiDataUrl(file));
        }
      }
    }
    const result = await fetchJson("/api/ai-prompt", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        modelId: elements.aiModelSelect.value,
        templateId: elements.aiTemplateSelect.value,
        question,
        images,
      }),
    }, 180000);
    elements.promptInput.value = result.prompt || "";
    elements.promptCount.textContent = `${elements.promptInput.value.length} / 12000`;
    state.promptUndoSnapshot = preSendText;
    elements.promptUndoButton.classList.remove("hidden");
    const imageSourceLabel = state.mode === "ref2va" && state.referenceImages.length
      ? `，其中全能参考图片 ${state.referenceImages.length} 张`
      : "";
    toast(images.length ? `AI 已结合 ${images.length} 张图片${imageSourceLabel}生成提示词。` : "AI 提示词已生成并填入文本框。", "success");
    saveSettings();
  } catch (error) {
    toast(`AI 提示词生成失败：${error.message}`, "error");
  } finally {
    elements.generateAiPromptButton.disabled = false;
    elements.generateAiPromptButton.textContent = "AI 生成提示词";
  }
}

function undoAiPrompt() {
  if (state.promptUndoSnapshot == null) return;
  elements.promptInput.value = state.promptUndoSnapshot;
  state.promptUndoSnapshot = null;
  elements.promptUndoButton.classList.add("hidden");
  elements.promptCount.textContent = `${elements.promptInput.value.length} / 12000`;
  toast("已撤回到 AI 生成前的提示词内容。", "success");
}

function setImage(slot, file) {
  const isFirst = slot === "first";
  const preview = isFirst ? elements.firstFramePreview : elements.lastFramePreview;
  const card = isFirst ? elements.firstFrameCard : elements.lastFrameCard;
  if (!file) {
    if (isFirst) state.firstFrame = null; else state.lastFrame = null;
    preview.removeAttribute("src");
    card.classList.remove("has-image");
    return;
  }
  if (!file.type.startsWith("image/")) return toast("请选择图片文件。", "error");
  if (isFirst) state.firstFrame = file; else state.lastFrame = file;
  preview.src = URL.createObjectURL(file);
  card.classList.add("has-image");
}

function appendOption(select, value, label = value) {
  const option = document.createElement("option");
  option.value = value;
  option.textContent = label;
  select.appendChild(option);
}

function fillSelect(select, items, preferred) {
  const current = select.value || preferred;
  const unique = [...new Set(items.filter(Boolean))];
  select.replaceChildren();

  if (!unique.length) {
    appendOption(select, "", "未扫描到本地模型");
    select.disabled = true;
    return;
  }

  unique.forEach((name) => appendOption(select, name));
  select.disabled = false;
  // 当前值失效时（例如模型被移进子文件夹），优先按文件名兜底匹配首选模型。
  select.value = unique.includes(current) ? current : (findModelName(unique, preferred) || unique[0]);
}

function getDefaultLora() {
  const preferred = state.mode === "ref2va" ? DEFAULT_MODELS.ref2vaLora : DEFAULT_MODELS.lora;
  return findModelName(state.models.lora, preferred);
}

function syncAutomaticLora() {
  if (!state.loraModeDefaults) return;
  const name = getDefaultLora();
  state.loras = name ? [{ name, strength: 1, active: true }] : [];
}

function recursivelyCollectOptions(value, result = []) {
  if (!value) return result;
  if (Array.isArray(value)) {
    if (value.length && value.every((item) => typeof item === "string")) result.push(...value);
    else value.forEach((item) => recursivelyCollectOptions(item, result));
  } else if (typeof value === "object") {
    Object.values(value).forEach((item) => recursivelyCollectOptions(item, result));
  }
  return result;
}

function findNodeOptions(objectInfo, classNames, inputNames) {
  const result = [];
  for (const className of classNames) {
    const node = objectInfo[className];
    if (!node?.input) continue;
    for (const inputName of inputNames) {
      recursivelyCollectOptions(node.input.required?.[inputName], result);
      recursivelyCollectOptions(node.input.optional?.[inputName], result);
    }
  }
  return [...new Set(result.filter((item) => typeof item === "string" && item.trim()))];
}

async function testConnection(showSuccess = true) {
  const comfyUrl = normalizeComfyUrl();
  if (!/^https?:\/\//i.test(comfyUrl)) throw new Error("ComfyUI 地址必须以 http:// 或 https:// 开头。");
  setConnection("loading", "正在连接 ComfyUI…");
  elements.testConnectionButton.disabled = true;
  try {
    const data = await fetchJson(apiUrl("/api/health", comfyUrl), {}, 15000);
    setConnection("connected", data.device || "ComfyUI 已连接");
    if (showSuccess) toast("ComfyUI 连接成功。", "success");
    saveSettings();
    return true;
  } catch (error) {
    setConnection("error", "连接失败");
    if (showSuccess) toast(error.message, "error");
    return false;
  } finally {
    elements.testConnectionButton.disabled = false;
  }
}

async function scanModels() {
  elements.scanModelsButton.disabled = true;
  elements.modelScanStatus.textContent = "正在扫描…";
  try {
    const objectInfo = await fetchJson(apiUrl("/api/object-info"), {}, 60000);
    const readModelFolder = async (type) => {
      try {
        const result = await fetchJson(apiUrl(`/api/model-list?type=${encodeURIComponent(type)}`), {}, 60000);
        return Array.isArray(result) ? result : Array.isArray(result?.files) ? result.files : [];
      } catch { return []; }
    };
    const [unetFiles, clipFiles, vaeFiles, loraFiles] = await Promise.all([
      readModelFolder("diffusion_models"), readModelFolder("text_encoders"), readModelFolder("vae"), readModelFolder("loras"),
    ]);
    state.models.unet = [...new Set(unetFiles.filter(Boolean))];
    state.models.clip = [...new Set(clipFiles.filter(Boolean))];
    state.models.vae = [...new Set(vaeFiles.filter(Boolean))];
    state.models.lora = [...new Set(loraFiles.filter(Boolean))];
    state.modelsScanned = true;

    fillSelect(elements.unetModel, state.models.unet, state.storedModels.unet || DEFAULT_MODELS.unet);
    fillSelect(elements.clipModel, state.models.clip, state.storedModels.clip || DEFAULT_MODELS.clip);
    fillSelect(elements.videoVae, state.models.vae, state.storedModels.videoVae || DEFAULT_MODELS.videoVae);
    fillSelect(elements.audioVae, state.models.vae, state.storedModels.audioVae || DEFAULT_MODELS.audioVae);
    // 扫描后把旧保存的 LoRA 名归一化成当前库里的名字（文件可能被移入了子文件夹）。
    state.loras = state.loraModeDefaults
      ? []
      : state.loras
          .map((lora) => ({ ...lora, name: findModelName(state.models.lora, lora.name) || lora.name }))
          .filter((lora) => state.models.lora.includes(lora.name));
    syncAutomaticLora();
    renderLoras();

    const total = state.models.unet.length + state.models.clip.length + state.models.vae.length + state.models.lora.length;
    elements.modelScanStatus.textContent = total ? `已发现 ${total} 个候选` : "未扫描到可用模型";
    toast(total ? "本地 ComfyUI 模型扫描完成。" : "未扫描到可用模型，已阻止提交生成任务。", total ? "success" : "error");
    saveSettings();
  } catch (error) {
    elements.modelScanStatus.textContent = "扫描失败";
    toast(`模型扫描失败：${error.message}`, "error");
  } finally {
    elements.scanModelsButton.disabled = false;
  }
}

function renderLoras() {
  elements.loraList.replaceChildren();
  elements.loraEmpty.classList.toggle("hidden", state.loras.length > 0);
  state.loras.forEach((lora, index) => {
    const row = document.createElement("div");
    row.className = "lora-row";

    const active = document.createElement("input");
    active.type = "checkbox";
    active.checked = lora.active !== false;
    active.title = "启用此 LoRA";
    active.addEventListener("change", () => { state.loraModeDefaults = false; state.loras[index].active = active.checked; saveSettings(); });

    const select = document.createElement("select");
    state.models.lora.forEach((name) => appendOption(select, name));
    select.value = state.models.lora.includes(lora.name) ? lora.name : state.models.lora[0] || "";
    select.disabled = !state.models.lora.length;
    select.addEventListener("change", () => {
      state.loraModeDefaults = false;
      state.loras[index].name = select.value;
      renderLoras();
      saveSettings();
    });

    const makeStrength = (className, label, key) => {
      const wrapper = document.createElement("label");
      wrapper.className = `lora-strength ${className}`;
      const caption = document.createElement("span");
      caption.textContent = label;
      const controls = document.createElement("div");
      controls.className = "lora-strength-controls";
      const slider = document.createElement("input");
      slider.type = "range";
      slider.min = "-4";
      slider.max = "4";
      slider.step = "0.05";
      slider.value = String(lora[key] ?? 1);
      const input = document.createElement("input");
      input.type = "number";
      input.min = "-4";
      input.max = "4";
      input.step = "0.05";
      input.value = slider.value;
      const updateStrength = (value) => {
        const strength = Math.max(-4, Math.min(4, Number(value) || 0));
        state.loraModeDefaults = false;
        state.loras[index][key] = strength;
        slider.value = String(strength);
        input.value = String(strength);
        saveSettings();
      };
      slider.addEventListener("input", () => updateStrength(slider.value));
      input.addEventListener("change", () => updateStrength(input.value));
      controls.append(slider, input);
      wrapper.append(caption, controls);
      return wrapper;
    };

    const remove = document.createElement("button");
    remove.type = "button";
    remove.className = "remove-lora";
    remove.textContent = "×";
    remove.title = "移除 LoRA";
    remove.addEventListener("click", () => { state.loraModeDefaults = false; state.loras.splice(index, 1); renderLoras(); saveSettings(); });

    row.append(active, select, makeStrength("model-strength", "模型强度", "strength"), remove);
    elements.loraList.appendChild(row);
  });
}

async function uploadImage(file) {
  const form = new FormData();
  form.append("image", file, file.name);
  form.append("type", "input");
  form.append("overwrite", "true");  const result = await fetchJson(apiUrl("/api/upload"), { method: "POST", body: form }, 120000);
  return result.name || result.filename;
}

async function uploadReferenceFile(file) {
  // 工作站服务沿用当前项目已有的图片上传代理；参考素材仍写入 ComfyUI input 目录。
  const form = new FormData();
  form.append("image", file, file.name);
  form.append("type", "input");
  form.append("overwrite", "true");
  const result = await fetchJson(apiUrl("/api/upload"), { method: "POST", body: form }, 120000);
  return result.name || result.filename;
}

function loadImageDimensions(file) {
  return new Promise((resolve, reject) => {
    const node = new Image();
    const objectUrl = URL.createObjectURL(file);
    node.onload = () => {
      URL.revokeObjectURL(objectUrl);
      resolve({ width: node.naturalWidth, height: node.naturalHeight });
    };
    node.onerror = () => {
      URL.revokeObjectURL(objectUrl);
      reject(new Error(`无法解析图片“${file.name}”。`));
    };
    node.src = objectUrl;
  });
}

async function validateReferenceFiles(requireVisual = true) {
  const images = state.referenceImages;
  const videos = state.referenceVideos;
  const audios = state.referenceAudios;
  const total = images.length + videos.length + audios.length;
  // 全能参考按官方端口能力保留 9 张图片、3 段视频和 3 段音频；全部素材合计最多 12 个。
  if (images.length > 9) throw new Error("全能参考模式最多上传 9 张图片。");
  if (videos.length > 3) throw new Error("全能参考模式最多上传 3 段视频。");
  if (audios.length > 3) throw new Error("全能参考模式最多上传 3 段音频。");
  if (total > 12) throw new Error("图片、视频和音频参考素材合计不能超过 12 个。");
  if (requireVisual && !images.length && !videos.length) throw new Error("音频不能单独提交，请至少上传一张图片或一段视频。");

  for (const file of images) {
    if (!file.type.startsWith("image/")) throw new Error(`“${file.name}”不是图片文件。`);
    if (file.size > 30 * 1024 * 1024) throw new Error(`图片“${file.name}”超过 30MB。`);
    const { width, height } = await loadImageDimensions(file);
    const ratio = width / height;
    if (width < 256 || width > 5760 || height < 256 || height > 5760) throw new Error(`图片“${file.name}”的宽高必须在 256~5760 像素范围内。`);
    if (ratio < 0.4 || ratio > 2.5) throw new Error(`图片“${file.name}”的宽高比必须在 5:2 到 2:5 范围内。`);
  }

  for (const file of videos) {
    if (!file.type.startsWith("video/")) throw new Error(`“${file.name}”不是视频文件。`);
    if (file.size > 50 * 1024 * 1024) throw new Error(`视频“${file.name}”超过 50MB。`);
  }

  for (const file of audios) {
    if (!file.type.startsWith("audio/")) throw new Error(`“${file.name}”不是音频文件。`);
    if (file.size > 15 * 1024 * 1024) throw new Error(`音频“${file.name}”超过 15MB。`);
  }
}

function renderReferenceFiles() {
  const render = (container, files, label, type) => {
    if (!container) return;
    container.querySelectorAll("[data-preview-url]").forEach((node) => {
      URL.revokeObjectURL(node.dataset.previewUrl);
    });
    container.replaceChildren();
    files.forEach((file, index) => {
      const item = document.createElement("div");
      item.className = "reference-file-item";
      item.title = `${label}：${file.name}`;

      const preview = document.createElement("div");
      preview.className = `reference-preview reference-preview-${type}`;
      const previewUrl = URL.createObjectURL(file);
      let media;
      if (type === "images") {
        media = document.createElement("img");
        media.alt = `${label}预览：${file.name}`;
      } else if (type === "videos") {
        media = document.createElement("video");
        media.muted = true;
        media.playsInline = true;
        media.preload = "metadata";
      } else {
        media = document.createElement("audio");
        media.controls = true;
        media.preload = "metadata";
      }
      media.src = previewUrl;
      media.dataset.previewUrl = previewUrl;
      preview.appendChild(media);

      const info = document.createElement("div");
      info.className = "reference-file-info";
      const name = document.createElement("strong");
      name.textContent = file.name;
      const size = document.createElement("small");
      size.textContent = formatFileSize(file.size);
      info.append(name, size);

      const remove = document.createElement("button");
      remove.type = "button";
      remove.className = "reference-remove-button";
      remove.textContent = "移除";
      remove.title = `移除${label}：${file.name}`;
      remove.addEventListener("click", () => {
        state[type === "images" ? "referenceImages" : type === "videos" ? "referenceVideos" : "referenceAudios"].splice(index, 1);
        renderReferenceFiles();
      });

      item.append(preview, info, remove);
      container.appendChild(item);
    });
  };
  render(elements.referenceImagesList, state.referenceImages, "图片", "images");
  render(elements.referenceVideosList, state.referenceVideos, "视频", "videos");
  render(elements.referenceAudiosList, state.referenceAudios, "音频", "audios");
}

function formatFileSize(bytes) {
  const value = Number(bytes) || 0;
  if (value < 1024 * 1024) return `${Math.max(1, Math.round(value / 1024))} KB`;
  return `${(value / (1024 * 1024)).toFixed(1)} MB`;
}

async function setReferenceFiles(type, files) {
  const accepted = Array.from(files || []);
  const target = type === "images" ? "referenceImages" : type === "videos" ? "referenceVideos" : "referenceAudios";
  const input = type === "images" ? elements.referenceImagesInput : type === "videos" ? elements.referenceVideosInput : elements.referenceAudiosInput;
  const previous = [...state[target]];

  // 同类型素材采用追加方式，保留之前已经添加的文件，方便逐步补充和调整参考列表。
  state[target] = [...previous, ...accepted];
  try {
    await validateReferenceFiles(false);
  } catch (error) {
    state[target] = previous;
    renderReferenceFiles();
    if (input) input.value = "";
    return toast(error.message, "error");
  }

  // 清空原生文件选择器，确保下次选择同一个文件时仍能触发 change 事件。
  if (input) input.value = "";
  renderReferenceFiles();
}

function randomSeed() {
  // 生成 ComfyUI / PowerShell Int64 可稳定接收的非负种子，避免旧版 64 位无符号值溢出。
  const values = new Uint32Array(1);
  crypto.getRandomValues(values);
  return values[0] % 2147483647;
}

function normalizeSeed(value) {
  const seedValue = Number(value);
  if (!Number.isSafeInteger(seedValue) || seedValue < 0 || seedValue > 2147483647) return randomSeed();
  return seedValue;
}

function buildGenerationConfig() {
  const duration = clampDuration(elements.durationNumber.value);
  const seedValue = Number(elements.seed.value);
  return {
    workflowFile: WORKFLOW_FILES[state.mode],
    mode: state.mode,
    prompt: elements.promptInput.value.trim(),
    duration,
    aspectRatio: normalizeAspectRatio(elements.aspectRatio.value),
    megapixels: Number(elements.megapixels.value),
    unet: elements.unetModel.value,
    clip: elements.clipModel.value,
    videoVae: elements.videoVae.value,
    audioVae: elements.audioVae.value,
    loras: state.loras.filter((item) => item.active !== false && item.name),
    steps: Math.max(1, Number(elements.steps.value) || 8),
    seed: seedValue < 0 || !Number.isFinite(seedValue) ? randomSeed() : normalizeSeed(seedValue),
    samplerName: elements.samplerName.value.trim() || "res_multistep",
    teControl: Number(elements.teControl.value),
    tePercent1: Number(elements.tePercent1.value),
    tePercent2: Number(elements.tePercent2.value),
  };
}

async function generate() {
  if (!state.modelsScanned) {
    try {
      await scanModels();
    } catch {}
  }
  const config = buildGenerationConfig();
  const requiredModels = [
    ["UNET", config.unet],
    ["CLIP", config.clip],
    ["视频 VAE", config.videoVae],
    ["音频 VAE", config.audioVae],
  ];
  const missingModels = requiredModels.filter(([, name]) => !name).map(([label]) => label);
  if (missingModels.length) return toast(`请先扫描并选择可用模型：${missingModels.join("、")}。`, "error");
  if (!config.prompt) return toast("请先填写视频提示词。", "error");
  if (state.mode !== "t2v" && state.mode !== "ref2va" && !state.firstFrame) return toast("当前模式需要上传首帧图片。", "error");
  if (state.mode === "flf2v" && !state.lastFrame) return toast("首尾帧模式还需要上传尾帧图片。", "error");
  if (state.mode === "ref2va") {
    try {
      await validateReferenceFiles();
    } catch (error) {
      return toast(error.message, "error");
    }
  }

  elements.generateButton.disabled = true;
  elements.generateButton.textContent = "正在提交…";
  try {
    if (!(await testConnection(false))) throw new Error("无法连接 ComfyUI，请先检查地址和服务状态。");
    if (state.firstFrame) config.firstFrame = await uploadImage(state.firstFrame);
    if (state.lastFrame) config.lastFrame = await uploadImage(state.lastFrame);
    if (state.mode === "ref2va") {
      config.referenceImages = [];
      config.referenceVideos = [];
      config.referenceAudios = [];
      for (const file of state.referenceImages) config.referenceImages.push(await uploadImage(file));
      for (const file of state.referenceVideos) config.referenceVideos.push(await uploadReferenceFile(file));
      for (const file of state.referenceAudios) config.referenceAudios.push(await uploadReferenceFile(file));
    }

    const comfyUrl = normalizeComfyUrl();
    const result = await fetchJson("/api/generate", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ comfyUrl, config }),
    }, 120000);

    const createdAt = Date.now();
    const task = {
      id: result.prompt_id,
      number: result.number ?? null,
      comfyUrl,
      mode: state.mode,
      prompt: config.prompt,
      duration: config.duration,
      createdAt,
      startedAt: createdAt,
      finishedAt: null,
      status: "queued",
      progress: 0,
      message: result.number != null ? `已进入队列，序号 ${result.number}` : "已提交到 ComfyUI 队列",
      outputs: [],
      failures: 0,
    };
    state.tasks.unshift(task);
    persistTasks();
    renderTasks();
    startPolling(task.id, true);
    toast("任务已提交。页面或网络短暂中断不会取消 ComfyUI 生成。", "success");
  } catch (error) {
    toast(error.message, "error");
  } finally {
    elements.generateButton.disabled = false;
    elements.generateButton.textContent = "开始生成视频";
  }
}

function collectOutputFiles(historyItem) {
  const files = [];
  const outputs = historyItem?.outputs || {};
  for (const nodeOutput of Object.values(outputs)) {
    if (!nodeOutput || typeof nodeOutput !== "object") continue;
    for (const key of ["videos", "gifs", "images", "audio", "files"]) {
      const list = nodeOutput[key];
      if (!Array.isArray(list)) continue;
      for (const file of list) {
        if (file?.filename) files.push({
          filename: file.filename,
          subfolder: file.subfolder || "",
          type: file.type || "output",
          mediaType: key,
        });
      }
    }
  }
  return files;
}

function historyStatus(historyItem) {
  const status = historyItem?.status || {};
  const messages = Array.isArray(status.messages) ? status.messages : [];
  const progressMessage = messages.find((entry) => Array.isArray(entry) && /progress/i.test(String(entry[0])));
  const progressValue = progressMessage?.[1]?.value ?? progressMessage?.[1]?.progress;
  const progress = Number.isFinite(Number(progressValue)) ? Math.max(0, Math.min(100, Number(progressValue) <= 1 ? Number(progressValue) * 100 : Number(progressValue))) : null;
  const executionError = messages.find((entry) => Array.isArray(entry) && entry[0] === "execution_error");
  if (status.status_str === "error" || executionError) {
    const detail = executionError?.[1]?.exception_message || executionError?.[1]?.node_type || "ComfyUI 明确返回执行错误";
    return { terminal: true, status: "failed", progress: 0, message: detail };
  }
  const outputs = collectOutputFiles(historyItem);
  if (outputs.length > 0) return { terminal: true, status: "success", progress: 100, message: `生成完成，共找到 ${outputs.length} 个输出文件`, outputs };
  if (status.completed || status.status_str === "success") {
    return {
      terminal: true,
      status: "success",
      progress: 100,
      message: outputs.length
        ? `生成完成，共找到 ${outputs.length} 个输出文件`
        : "ComfyUI 已完成，但历史记录中暂未发现输出文件",
      outputs,
    };
  }
  return { terminal: false, status: "running", progress: progress ?? null, message: "ComfyUI 正在生成，工作站会持续查询" };
}

async function queryTask(taskId, manual = false) {
  const task = state.tasks.find((item) => item.id === taskId);
  if (!task || task.status === "success" || task.status === "failed") return;
  try {
    const data = await fetchJson(apiUrl(`/api/history/${encodeURIComponent(task.id)}`, task.comfyUrl), {}, 45000);
    const historyItem = data[task.id] || data.prompt || null;
    let liveProgress = null;
    if (!historyItem || task.status === "running" || task.status === "queued") {
      try {
        const progressData = await fetchJson(apiUrl("/api/progress", task.comfyUrl), {}, 10000);
        const value = Number(progressData?.value);
        const max = Number(progressData?.max);
        if (Number.isFinite(value) && Number.isFinite(max) && max > 0) {
          liveProgress = Math.max(0, Math.min(100, (value / max) * 100));
        }
      } catch {}
    }
    if (!historyItem) {
      task.status = task.failures > 0 ? "recovering" : "queued";
      task.progress = liveProgress ?? task.progress ?? 2;
      task.message = "任务仍在队列或执行中，尚未写入历史记录";
    } else {
      const result = historyStatus(historyItem);
      task.status = result.status;
      if (result.progress != null) task.progress = result.progress;
      else if (liveProgress != null) task.progress = liveProgress;
      task.message = result.message;
      task.outputs = result.outputs || task.outputs || [];
      task.failures = 0;
      if (result.terminal) {
        task.finishedAt = task.finishedAt || Date.now();
        if (!Number.isFinite(Number(task.elapsedMs))) {
          task.elapsedMs = Math.max(0, task.finishedAt - Number(task.startedAt || task.createdAt || task.finishedAt));
        }
        stopPolling(task.id);
      }
    }
  } catch (error) {
    task.failures = (task.failures || 0) + 1;
    task.status = "recovering";
    task.progress = task.progress || 2;
    task.message = `暂时无法查询 ComfyUI（第 ${task.failures} 次），任务不会被判定失败，将继续恢复：${error.message}`;
    if (manual) toast(task.message, "error");
  }
  persistTasks();
  renderTasks();
}

function startPolling(taskId, immediate = false) {
  stopPolling(taskId);
  const task = state.tasks.find((item) => item.id === taskId);
  if (!task || ["success", "failed"].includes(task.status)) return;
  if (immediate) queryTask(taskId);
  const timer = setInterval(() => queryTask(taskId), 5000);
  state.pollers.set(taskId, timer);
}

function stopPolling(taskId) {
  const timer = state.pollers.get(taskId);
  if (timer) clearInterval(timer);
  state.pollers.delete(taskId);
}

function fileViewUrl(task, output) {
  const params = new URLSearchParams({
    comfy: task.comfyUrl,
    filename: output.filename,
    subfolder: output.subfolder || "",
    type: output.type || "output",
  });
  return `/api/view?${params.toString()}`;
}

function outputIdentity(output) {
  return [output.type || "output", output.subfolder || "", output.filename || ""].join("/");
}

function ensureTaskVideo(card, task, output) {
  const source = fileViewUrl(task, output);
  const identity = outputIdentity(output);
  let video = card.querySelector("video[data-output-id]");
  if (!video) {
    video = document.createElement("video");
    video.controls = true;
    video.preload = "metadata";
    video.playsInline = true;
    video.dataset.outputId = identity;
    video.src = source;
    card.prepend(video);
    return;
  }
  // 只有输出文件真的变化时才替换 src，普通轮询不会重置播放位置。
  if (video.dataset.outputId !== identity) {
    video.dataset.outputId = identity;
    video.src = source;
  }
}

function buildTaskActions(content, task) {
  let actions = content.querySelector(".task-actions");
  if (!task.outputs?.length && ["success", "failed"].includes(task.status)) {
    actions?.remove();
    return;
  }
  if (!actions) {
    actions = document.createElement("div");
    actions.className = "task-actions";
    content.appendChild(actions);
  }
  actions.replaceChildren();
  task.outputs?.forEach((output, index) => {
    const link = document.createElement("a");
    link.href = fileViewUrl(task, output);
    link.target = "_blank";
    link.rel = "noopener";
    link.download = output.filename;
    link.textContent = task.outputs.length > 1 ? `打开输出 ${index + 1}` : "打开 / 下载视频";
    actions.appendChild(link);
  });
  if (!["success", "failed"].includes(task.status)) {
    const retry = document.createElement("button");
    retry.type = "button";
    retry.textContent = "立即查询";
    retry.addEventListener("click", () => queryTask(task.id, true));
    actions.appendChild(retry);
  }
}

function formatElapsed(task) {
  const start = Number(task.startedAt || task.createdAt || Date.now());
  const elapsedMs = Number.isFinite(Number(task.elapsedMs)) ? Number(task.elapsedMs) : null;
  const end = elapsedMs == null ? (task.finishedAt || Date.now()) : start + Math.max(0, elapsedMs);
  const seconds = Math.max(0, Math.floor((end - start) / 1000));
  const minutes = Math.floor(seconds / 60);
  return minutes ? `${minutes} 分 ${String(seconds % 60).padStart(2, "0")} 秒` : `${seconds} 秒`;
}

function updateTaskElapsedDisplays() {
  elements.taskList.querySelectorAll(".task-card[data-task-id]").forEach((card) => {
      const task = state.tasks.find((item) => String(item.id) === card.dataset.taskId);
    const elapsed = card.querySelector(".task-elapsed");
    if (task && elapsed && !["success", "failed"].includes(task.status)) elapsed.textContent = `耗时 ${formatElapsed(task)}`;
  });
}

function updateTaskCard(card, task) {
  card.dataset.taskId = task.id;
  const videoOutput = task.outputs?.find((output) => output.mediaType === "videos" || /\.(mp4|webm|mov|mkv)$/i.test(output.filename));
  if (videoOutput) ensureTaskVideo(card, task, videoOutput);
  else card.querySelector("video[data-output-id]")?.remove();

  const terminal = ["success", "failed"].includes(task.status);
  let progress = card.querySelector(".progress-track");
  if (!progress) {
    progress = document.createElement("div");
    progress.className = "progress-track";
    progress.innerHTML = "<span></span>";
    const content = card.querySelector(".task-content");
    card.insertBefore(progress, content || null);
  }
  const progressFill = progress.querySelector("span");
  const progressValue = terminal ? (task.status === "success" ? 100 : 0) : task.progress;
  progress.classList.toggle("indeterminate", progressValue == null);
  progressFill.style.width = progressValue == null ? "42%" : `${Math.max(0, Math.min(100, progressValue))}%`;

  const labels = { queued: "等待中", running: "生成中", recovering: "状态恢复中", success: "已完成", failed: "生成失败" };
  const content = card.querySelector(".task-content");
  const taskModeLabels = { t2v: "文生", i2v: "图生", flf2v: "首尾帧", ref2va: "全能参考" };
  content.querySelector(".task-title-line strong").textContent = `${taskModeLabels[task.mode] || "视频"} · ${task.duration} 秒`;
  content.querySelector(".task-time").textContent = new Date(task.createdAt).toLocaleString("zh-CN", { month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit" });
  content.querySelector(".task-elapsed").textContent = `耗时 ${formatElapsed(task)}`;
  const status = content.querySelector(".task-status");
  status.dataset.status = task.status;
  status.textContent = labels[task.status] || task.status;
  content.querySelector(".task-message").textContent = task.message || task.prompt;
  buildTaskActions(content, task);
}

function createTaskCard(task) {
  const card = document.createElement("article");
  card.className = "task-card";
  card.innerHTML = `
    <div class="task-content">
      <div class="task-title-line"><strong></strong><span class="task-time"></span></div>
      <div class="task-meta"><span class="task-status"></span><span class="task-elapsed"></span></div>
      <p class="task-message"></p>
    </div>`;
  updateTaskCard(card, task);
  return card;
}

function renderTasks() {
  elements.taskEmpty.classList.toggle("hidden", state.tasks.length > 0);
  // 兼容旧记录：已处于终结状态但没有固化耗时的任务只补算一次。
  let taskStorageChanged = false;
  state.tasks.forEach((task) => {
    if (["success", "failed"].includes(task.status) && !Number.isFinite(Number(task.elapsedMs))) {
      const start = Number(task.startedAt || task.createdAt || task.finishedAt || Date.now());
      const end = Number(task.finishedAt || start);
      task.elapsedMs = Math.max(0, end - start);
      task.finishedAt = task.finishedAt || end;
      taskStorageChanged = true;
    }
  });
  if (taskStorageChanged) persistTasks();
  const expectedIds = new Set(state.tasks.map((task) => String(task.id)));
  elements.taskList.querySelectorAll(".task-card[data-task-id]").forEach((card) => {
    if (!expectedIds.has(card.dataset.taskId)) card.remove();
  });
  state.tasks.forEach((task, index) => {
    const taskId = String(task.id);
    let card = [...elements.taskList.children].find((item) => item.dataset.taskId === taskId);
    if (!card) card = createTaskCard(task);
    else updateTaskCard(card, task);
    const currentAtIndex = elements.taskList.children[index];
    if (currentAtIndex !== card) elements.taskList.insertBefore(card, currentAtIndex || null);
  });
  updateTaskElapsedDisplays();
}

function saveSettings() {
  const data = {
    comfyUrl: elements.comfyUrl.value,
    mode: state.mode,
    aiModel: elements.aiModelSelect.value,
    aiTemplate: elements.aiTemplateSelect.value,
    aiReadImages: elements.aiReadImages.checked,
    duration: clampDuration(elements.durationNumber.value),
    aspectRatio: normalizeAspectRatio(elements.aspectRatio.value),
    megapixels: elements.megapixels.value,
    unet: elements.unetModel.value,
    clip: elements.clipModel.value,
    videoVae: elements.videoVae.value,
    audioVae: elements.audioVae.value,
    loras: state.loras,
    loraModeDefaults: state.loraModeDefaults,
    steps: elements.steps.value,
    samplerName: elements.samplerName.value,
    teControl: elements.teControl.value,
    tePercent1: elements.tePercent1.value,
    tePercent2: elements.tePercent2.value,
  };
  localStorage.setItem(STORAGE_KEYS.settings, JSON.stringify(data));
}

function persistTasks() {
  localStorage.setItem(STORAGE_KEYS.tasks, JSON.stringify(state.tasks.slice(0, 30)));
}

function startElapsedClock() {
  if (state.clockTimer) clearInterval(state.clockTimer);
  state.clockTimer = setInterval(updateTaskElapsedDisplays, 1000);
}

function clearCurrentTasks() {
  if (!state.tasks.length) return toast("当前没有可清空的任务记录。");
  const activeCount = state.tasks.filter((task) => !["success", "failed"].includes(task.status)).length;
  const warning = activeCount
    ? `其中有 ${activeCount} 个任务仍在查询。清空只会移除本浏览器记录并停止查询，不会取消 ComfyUI 中正在生成的任务。确定继续吗？`
    : "确定清空当前浏览器中的全部生成记录吗？这不会删除 ComfyUI 输出文件。";
  if (!window.confirm(warning)) return;
  [...state.pollers.keys()].forEach(stopPolling);
  state.tasks = [];
  persistTasks();
  renderTasks();
  toast("当前任务记录已清空。", "success");
}

function loadStoredState() {
  let settings = {};
  try { settings = JSON.parse(localStorage.getItem(STORAGE_KEYS.settings) || "{}"); } catch {}
  elements.comfyUrl.value = settings.comfyUrl || "http://127.0.0.1:8188";
  elements.aiReadImages.checked = settings.aiReadImages !== false;
  elements.aspectRatio.value = normalizeAspectRatio(settings.aspectRatio);
  elements.megapixels.value = settings.megapixels || "0.7";
  elements.steps.value = settings.steps || "8";
  elements.samplerName.value = settings.samplerName || "res_multistep";
  elements.teControl.value = settings.teControl || "0.12";
  elements.tePercent1.value = settings.tePercent1 || "0.1";
  elements.tePercent2.value = settings.tePercent2 || "0.9";
  state.loras = Array.isArray(settings.loras) && settings.loras.length
    ? settings.loras.map((lora) => ({
        name: lora.name,
        strength: Number(lora.strength ?? 1),
        active: lora.active !== false,
      }))
    : state.loras;
  // 旧版缓存没有该标记时，只把“单个官方默认 LoRA”识别为自动配置；
  // 多 LoRA 或自定义名称继续按用户配置保留，避免升级后被模式切换覆盖。
  const cachedLoras = Array.isArray(settings.loras) ? settings.loras : [];
  const looksLikeAutomaticDefault = cachedLoras.length === 0 || (
    cachedLoras.length === 1 &&
    [DEFAULT_MODELS.lora, DEFAULT_MODELS.ref2vaLora].includes(cachedLoras[0]?.name) &&
    Number(cachedLoras[0]?.strength ?? 1) === 1 &&
    cachedLoras[0]?.active !== false
  );
  state.loraModeDefaults = typeof settings.loraModeDefaults === "boolean"
    ? settings.loraModeDefaults
    : looksLikeAutomaticDefault;

  state.storedModels = {
    unet: settings.unet || "",
    clip: settings.clip || "",
    videoVae: settings.videoVae || "",
    audioVae: settings.audioVae || "",
  };
  fillSelect(elements.unetModel, [], "");
  fillSelect(elements.clipModel, [], "");
  fillSelect(elements.videoVae, [], "");
  fillSelect(elements.audioVae, [], "");
  syncDuration(settings.duration || 5);
  updateMode(settings.mode || "t2v");
  renderLoras();

  try {
    const tasks = JSON.parse(localStorage.getItem(STORAGE_KEYS.tasks) || "[]");
      state.tasks = Array.isArray(tasks) ? tasks.map((task) => {
      if (task.finishedAt && !Number.isFinite(Number(task.elapsedMs))) {
        task.elapsedMs = Math.max(0, task.finishedAt - Number(task.startedAt || task.createdAt || task.finishedAt));
      }
      return task;
    }) : [];
  } catch { state.tasks = []; }
  renderTasks();
  state.tasks.filter((task) => !["success", "failed"].includes(task.status)).forEach((task) => startPolling(task.id, true));
}

function setupDropZone(element, onFiles) {
  if (!element) return;
  element.addEventListener("dragover", (event) => {
    event.preventDefault();
    event.dataTransfer.dropEffect = "copy";
    element.classList.add("drag-over");
  });
  element.addEventListener("dragleave", (event) => {
    if (!element.contains(event.relatedTarget)) element.classList.remove("drag-over");
  });
  element.addEventListener("drop", (event) => {
    event.preventDefault();
    event.stopPropagation();
    element.classList.remove("drag-over");
    const files = Array.from(event.dataTransfer?.files || []);
    if (files.length) onFiles(files);
  });
}

function routeDroppedFiles(files) {
  // 按当前模式把拖入的文件自动归类：全能参考按图片/视频/音频分桶，图生/首尾帧取图片。
  if (state.mode === "ref2va") {
    const images = files.filter((file) => file.type.startsWith("image/"));
    const videos = files.filter((file) => file.type.startsWith("video/"));
    const audios = files.filter((file) => file.type.startsWith("audio/"));
    const skipped = files.length - images.length - videos.length - audios.length;
    if (images.length) setReferenceFiles("images", images);
    if (videos.length) setReferenceFiles("videos", videos);
    if (audios.length) setReferenceFiles("audios", audios);
    if (skipped) toast(`已跳过 ${skipped} 个无法识别的文件。`, "error");
    return;
  }
  if (state.mode === "i2v" || state.mode === "flf2v") {
    const images = files.filter((file) => file.type.startsWith("image/"));
    if (!images.length) return toast("当前模式只需要图片素材，视频/音频请在全能参考模式中使用。", "error");
    setImage("first", images[0]);
    if (state.mode === "flf2v") {
      if (images[1]) setImage("last", images[1]);
      if (images.length > 2) toast("只取前两张图片作为首帧和尾帧。");
    } else if (images.length > 1) {
      toast("图生视频模式只使用首帧，多余图片已忽略。");
    }
    return;
  }
  toast("文生视频模式不使用素材文件；图生视频/首尾帧可拖入图片，全能参考可拖入图片、视频、音频。", "error");
}

function bindEvents() {
  elements.testConnectionButton.addEventListener("click", () => testConnection());
  elements.scanModelsButton.addEventListener("click", scanModels);
  elements.modeControl.addEventListener("click", (event) => {
    const button = event.target.closest("[data-mode]");
    if (button) updateMode(button.dataset.mode);
  });
  elements.firstFrameInput.addEventListener("change", () => setImage("first", elements.firstFrameInput.files[0]));
  elements.lastFrameInput.addEventListener("change", () => setImage("last", elements.lastFrameInput.files[0]));
  elements.removeFirstFrame.addEventListener("click", (event) => { event.preventDefault(); event.stopPropagation(); elements.firstFrameInput.value = ""; setImage("first", null); });
  elements.removeLastFrame.addEventListener("click", (event) => { event.preventDefault(); event.stopPropagation(); elements.lastFrameInput.value = ""; setImage("last", null); });
  elements.promptInput.addEventListener("input", () => { elements.promptCount.textContent = `${elements.promptInput.value.length} / 12000`; });
  elements.promptUndoButton.addEventListener("click", (event) => {
    // 按钮在 label 内部，阻止默认行为避免触发提示词框聚焦。
    event.preventDefault();
    event.stopPropagation();
    undoAiPrompt();
  });
  elements.generateAiPromptButton.addEventListener("click", generateAiPrompt);
  elements.aiModelSelect.addEventListener("change", saveSettings);
  elements.aiTemplateSelect.addEventListener("change", saveSettings);
  elements.aiReadImages.addEventListener("change", saveSettings);
  elements.durationRange.addEventListener("input", () => syncDuration(elements.durationRange.value));
  elements.durationNumber.addEventListener("change", () => syncDuration(elements.durationNumber.value));
  elements.aspectRatio.addEventListener("change", () => { updateSummary(); saveSettings(); });
  elements.megapixels.addEventListener("change", saveSettings);
  [elements.unetModel, elements.clipModel, elements.videoVae, elements.audioVae, elements.steps, elements.samplerName, elements.teControl, elements.tePercent1, elements.tePercent2, elements.comfyUrl].forEach((element) => element.addEventListener("change", saveSettings));
  elements.addLoraButton.addEventListener("click", () => {
    if (!state.models.lora.length) return toast("请先扫描到至少一个本地 LoRA。", "error");
    state.loraModeDefaults = false;
    state.loras.push({ name: state.models.lora[0], strength: 1, active: true });
    renderLoras();
    saveSettings();
  });
  elements.randomSeedButton.addEventListener("click", () => { elements.seed.value = String(randomSeed()); });
  elements.referenceImagesInput?.addEventListener("change", () => setReferenceFiles("images", elements.referenceImagesInput.files));
  elements.referenceVideosInput?.addEventListener("change", () => setReferenceFiles("videos", elements.referenceVideosInput.files));
  elements.referenceAudiosInput?.addEventListener("change", () => setReferenceFiles("audios", elements.referenceAudiosInput.files));
  // 拖拽上传：素材区/首尾帧卡片可直接拖入，页面任意位置拖入也会按类型自动归类。
  setupDropZone(elements.firstFrameCard, (files) => {
    const image = files.find((file) => file.type.startsWith("image/"));
    if (!image) return toast("请拖入图片文件（PNG/JPG/WebP）。", "error");
    if (files.length > 1) toast("一次只取第一张图片作为首帧。");
    setImage("first", image);
  });
  setupDropZone(elements.lastFrameCard, (files) => {
    const image = files.find((file) => file.type.startsWith("image/"));
    if (!image) return toast("请拖入图片文件（PNG/JPG/WebP）。", "error");
    if (files.length > 1) toast("一次只取第一张图片作为尾帧。");
    setImage("last", image);
  });
  setupDropZone(elements.referenceUploadArea, routeDroppedFiles);
  window.addEventListener("dragover", (event) => event.preventDefault());
  window.addEventListener("drop", (event) => {
    event.preventDefault();
    const files = Array.from(event.dataTransfer?.files || []);
    if (files.length) routeDroppedFiles(files);
  });
  elements.generateButton.addEventListener("click", generate);
  elements.refreshTasksButton.addEventListener("click", () => {
    const active = state.tasks.filter((task) => !["success", "failed"].includes(task.status));
    active.forEach((task) => queryTask(task.id, true));
    if (!active.length) toast("没有需要恢复查询的任务。");
  });
  elements.clearTasksButton.addEventListener("click", clearCurrentTasks);
  document.addEventListener("visibilitychange", () => {
    if (!document.hidden) state.tasks.filter((task) => !["success", "failed"].includes(task.status)).forEach((task) => queryTask(task.id));
  });
}

bindEvents();
loadStoredState();
startElapsedClock();
loadAiPromptConfig();
testConnection(false).then((connected) => { if (connected) scanModels(); });
