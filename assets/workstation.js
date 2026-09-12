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

const UPDATE_STORAGE_KEY = "minimax-h3-workstation-update-v1";
const UPDATE_AUTO_CHECK_INTERVAL_MS = 6 * 60 * 60 * 1000; // 自动检查最小间隔 6 小时，避免频繁请求 GitHub

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
  updateInfo: null,
  updateBusy: false,
};

// 任务列表内存上限：超出后从最旧的非活跃任务开始丢弃。
// 与 persistTasks 的 slice(0, 30) 不同——那个只管写入 localStorage 的内容，
// 内存里的 state.tasks 若不限制，长时间开着页面不断提交会一直增长（每个任务还带 outputs 数组）。
const MAX_TASKS_IN_MEMORY = 60;

// 单个任务的轮询时长上限：超过后停止轮询并提示用户手动刷新。
// 场景：ComfyUI 重启导致 history 记录丢失，任务会永远停在「恢复中」；
// 或用户在别处取消了任务，工作站这边拿不到终态。没有这个上限会无限轮询下去。
const MAX_POLL_DURATION_MS = 6 * 60 * 60 * 1000; // 6 小时
// 连续查询失败达到该次数时，停止轮询并明确告知用户（而不是无限重试）。
const MAX_QUERY_FAILURES = 60;

const $ = (id) => document.getElementById(id);
const elements = {
  connectionPill: $("connectionPill"), connectionText: $("connectionText"), comfyUrl: $("comfyUrl"), connectionHint: $("connectionHint"),
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
  addLoraButton: $("addLoraButton"), steps: $("steps"), seed: $("seed"), samplerName: $("samplerName"),
  samplerNameOptions: $("samplerNameOptions"), randomSeedButton: $("randomSeedButton"),
  teControl: $("teControl"), tePercent1: $("tePercent1"), tePercent2: $("tePercent2"), cleanVram: $("cleanVram"), freeVramButton: $("freeVramButton"),
  rtxUpscale: $("rtxUpscale"), rtxUpscaleScale: $("rtxUpscaleScale"), capabilityNote: $("capabilityNote"), generationSummary: $("generationSummary"), generateButton: $("generateButton"),
  taskList: $("taskList"), taskEmpty: $("taskEmpty"), refreshTasksButton: $("refreshTasksButton"), clearTasksButton: $("clearTasksButton"), toastRegion: $("toastRegion"),
  checkUpdateButton: $("checkUpdateButton"), updateBanner: $("updateBanner"), updateTitle: $("updateTitle"), updateDetail: $("updateDetail"),
  applyUpdateButton: $("applyUpdateButton"), updateCommitLink: $("updateCommitLink"), dismissUpdateButton: $("dismissUpdateButton"),
  // 以下两项在 HTML 中缺少 id，这里登记后在启动时补齐，避免文案与样式悄悄失效。
  freeVramHint: $("freeVramHint"), aiPromptHint: $("aiPromptHint"),
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

// 基础分辨率（百万像素）：允许留空或输入非法字符时回退默认值 0.4。
// 之前这里直接 Number() 转换，空串会变成 0 —— 0 是合法数字但毫无意义，
// 而 ResolutionSelector 的 megapixels 有取值下界，最终表现为提交后 ComfyUI 报参数错误。
const DEFAULT_MEGAPIXELS = 0.4;
function clampMegapixels(value) {
  const parsed = Number.parseFloat(value);
  if (!Number.isFinite(parsed) || parsed <= 0) return DEFAULT_MEGAPIXELS;
  return Math.max(0.1, Math.min(4, parsed));
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
    // 选项已就绪，之后 saveSettings 直接读下拉即可，不再需要暂存值兜底。
    pendingAiSelection = { model: "", template: "" };
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

function fillDatalist(datalist, items) {
  // 把可选项填进 <datalist>，配合 <input list="..."> 使用。
  // 与 fillSelect 的区别：不替换输入框的值、不禁用输入框——用户仍然可以手动输入
  // 列表以外的值（例如自定义节点提供的采样器），只是会失去下拉提示。
  if (!datalist) return 0;
  const unique = [...new Set((items || []).filter((item) => typeof item === "string" && item.trim()))];
  datalist.replaceChildren();
  unique.forEach((item) => {
    const option = document.createElement("option");
    option.value = item;
    datalist.appendChild(option);
  });
  return unique.length;
}

// 采样器候选：从 ComfyUI 的 /object_info 里读 KSampler 系节点的 sampler_name 选项。
// 这些节点任取其一即可拿到完整列表（ComfyUI 全局只有一套采样器注册表）。
// 拿不到时返回空数组，输入框保持可手动输入，不阻断使用。
const SAMPLER_NODE_CLASSES = ["KSampler", "KSamplerAdvanced", "KSamplerSelect", "SamplerCustom"];
function collectSamplerNames(objectInfo) {
  if (!objectInfo || typeof objectInfo !== "object") return [];
  return findNodeOptions(objectInfo, SAMPLER_NODE_CLASSES, ["sampler_name"]);
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
    setConnectionHint("");
    // 顺带探测可选节点是否存在：缺 RTX / LoRA 管理器之类的节点时提前禁用或提示，
    // 而不是等用户提交后才从错误里知道（服务端同样会自动降级，双保险）。
    // 手动点「测试连接」时强制重新探测，方便刚装完节点包后立刻生效。
    await loadCapabilities(comfyUrl, showSuccess);
    if (showSuccess) toast("ComfyUI 连接成功。", "success");
    saveSettings();
    return true;
  } catch (error) {
    setConnection("error", "连接失败");
    if (showSuccess) toast(error.message, "error");
    // 地址被安全白名单拦下时，在地址框下方常驻显示原因，避免用户只看到一条会消失的提示。
    setConnectionHint(
      String(error.message || "").includes("WORKSTATION_ALLOW_COMFY_HOSTS")
        ? "该地址不在允许范围内。工作站默认只连接本机与局域网内的 ComfyUI；如需连接其它主机（如公网地址），请先设置环境变量 WORKSTATION_ALLOW_COMFY_HOSTS 并重启服务。"
        : ""
    );
    return false;
  } finally {
    elements.testConnectionButton.disabled = false;
  }
}

// 在 ComfyUI 地址下方常驻显示一行说明；传空串即隐藏。
function setConnectionHint(message) {
  const hint = elements.connectionHint;
  if (!hint) return;
  if (message) {
    hint.textContent = message;
    hint.classList.remove("hidden");
  } else {
    hint.textContent = "";
    hint.classList.add("hidden");
  }
}

// 缺少可选节点时要在提示里说的项目：
// [服务端能力字段, 服务端降级提示里出现的节点名, 简短标签, 完整说明]
const CAPABILITY_ITEMS = [
  ["RtxUpscale", "RTXVideoSuperResolution", "RTX 放大", "RTX 视频放大（需 NVIDIA RTX Video 节点包）：不可用，开关已禁用，提交时会自动跳过"],
  ["TEspeed", "TE-SpeedMiniMaxH3", "TE-Speed 加速", "TE-SpeedMiniMaxH3：未检测到，提交时会跳过加速（生成变慢，结果正常）"],
  ["LoraManager", "Lora-Manager", "LoRA", "ComfyUI-Lora-Manager：未检测到，提交时会跳过 LoRA"],
  ["VhsLoadVideo", "VideoHelperSuite", "视频参考素材", "VideoHelperSuite（VHS_LoadVideo）：未检测到，全能参考无法使用视频参考素材"],
  ["SaveVideo", "内置 SaveVideo", "视频保存节点", "内置 SaveVideo：未检测到，所有模式都无法保存视频，请更新 ComfyUI"],
  ["MiniMaxH3ImageToVideo", "MiniMaxH3ImageToVideo", "文生/图生/首尾帧", "MiniMaxH3ImageToVideo：未检测到，文生 / 图生 / 首尾帧模式不可用，请更新 ComfyUI"],
  ["MiniMaxH3ReferenceToVideo", "MiniMaxH3ReferenceToVideo", "全能参考", "MiniMaxH3ReferenceToVideo：未检测到，全能参考模式不可用，请更新 ComfyUI"],
  ["ResolutionSelector", "ResolutionSelector", "画面比例", "ResolutionSelector：未检测到，请更新 ComfyUI"],
  ["ComfyMathExpression", "ComfyMathExpression", "帧数换算", "ComfyMathExpression：未检测到，请更新 ComfyUI"],
  ["CreateVideo", "CreateVideo", "视频合成", "CreateVideo：未检测到，请更新 ComfyUI"],
];

// loadCapabilities 带并发去重的实现放在文件末尾（见「能力探测并发去重」注释）。

function applyCapabilities(caps) {
  if (!caps) return;
  const missing = CAPABILITY_ITEMS.filter(([key]) => caps[key] === false).map(([, , , text]) => text);

  // RTX 放大依赖节点包，缺节点时直接禁用并取消勾选：避免用户以为开了但实际被跳过。
  const rtxAvailable = caps.RtxUpscale !== false;
  elements.rtxUpscale.disabled = !rtxAvailable;
  elements.rtxUpscaleScale.disabled = !rtxAvailable;
  if (!rtxAvailable && elements.rtxUpscale.checked) {
    elements.rtxUpscale.checked = false;
    saveSettings();
  }

  const note = elements.capabilityNote;
  if (!note) return;
  if (!missing.length) {
    note.replaceChildren();
    note.classList.add("hidden");
    return;
  }
  const title = document.createElement("strong");
  title.textContent = "当前 ComfyUI 缺少以下节点，已自动降级（不影响出片）：";
  const list = document.createElement("ul");
  missing.forEach((text) => {
    const item = document.createElement("li");
    item.textContent = text;
    list.appendChild(item);
  });
  note.replaceChildren(title, list);
  note.classList.remove("hidden");
}

// 服务端在构建工作流时若跳过了可选节点，会在提交结果里带上 warnings。
// 这里只弹一条简短汇总，逐条原因已经常驻显示在「高级参数」的兼容性提示里。
function reportBuildWarnings(warnings) {
  if (!Array.isArray(warnings) || !warnings.length) return;
  const labels = [];
  CAPABILITY_ITEMS.forEach(([, marker, label]) => {
    if (warnings.some((text) => String(text).includes(marker)) && !labels.includes(label)) labels.push(label);
  });
  toast(
    labels.length
      ? `本次已自动跳过：${labels.join("、")}。原因见「高级参数」里的兼容性提示。`
      : "本次生成已自动跳过部分可选功能，原因见「高级参数」里的兼容性提示。"
  );
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
    // 顺手把本机 ComfyUI 的真实采样器列表填进 datalist（复用同一次 object-info 响应，不额外发请求）。
    // 这样用户从下拉里选就不会填出不存在的采样器名，从而避免提交后被 ComfyUI 校验拒绝。
    // 注意：只是「候选项」，输入框仍允许手动输入其它值。
    const samplerNames = collectSamplerNames(objectInfo);
    if (fillDatalist(elements.samplerNameOptions, samplerNames) > 0) {
      // 若当前保存的采样器在新列表里不存在，给出提示但不强改（用户可能有意使用自定义值）。
      const current = elements.samplerName.value.trim();
      if (current && !samplerNames.includes(current)) {
        elements.samplerName.title = `当前填写的「${current}」不在本机采样器列表中，提交可能失败。可从下拉列表中选择。`;
      } else {
        elements.samplerName.removeAttribute("title");
      }
    }
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
    megapixels: clampMegapixels(elements.megapixels.value),
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
    cleanVram: elements.cleanVram.checked,
    rtxUpscale: elements.rtxUpscale.checked,
    rtxUpscaleScale: Math.max(1, Math.min(4, Math.round(Number(elements.rtxUpscaleScale.value) || 2))),
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

    // 服务端在缺少可选节点时会自动降级并附带 warnings，这里给用户一个简短提示（不影响本次出片）。
    reportBuildWarnings(result.warnings);

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

let vramCleanInFlight = false;

async function cleanVramAfterTask(comfyUrl) {
  // 任务进入终态后自动清理显存（「自动清理显存」开关开启时）。
  // 传 soft=1 给服务端：队列里还有任务在跑或排队时静默跳过，等最后一个任务结束再清——
  // 这样既做到"生成完就释放显存"，又不会清掉排队中下一个任务刚加载的模型。
  if (!elements.cleanVram.checked || vramCleanInFlight) return;
  vramCleanInFlight = true;
  try {
    await fetchJson(apiUrl("/api/free?soft=1", comfyUrl || normalizeComfyUrl()), { method: "POST" }, 60000);
  } catch {
    // 清理属于优化动作，失败静默处理，不影响任务结果展示。
  } finally {
    vramCleanInFlight = false;
  }
}

async function freeVram() {
  // 手动清理显存：交给服务端调用 ComfyUI 官方 /free（unload_models + free_memory）。
  // 服务端会先确认队列空闲，队列里还有任务时直接拒绝，避免打断正在执行或排队的生成。
  const button = elements.freeVramButton;
  const originalText = button.textContent;
  button.disabled = true;
  button.textContent = "清理中…";
  try {
    const comfyUrl = normalizeComfyUrl();
    if (!/^https?:\/\//i.test(comfyUrl)) throw new Error("ComfyUI 地址必须以 http:// 或 https:// 开头。");
    const result = await fetchJson(apiUrl("/api/free", comfyUrl), { method: "POST" }, 60000);
    toast(result.message || "显存已清理。", "success");
  } catch (error) {
    toast(error.message, "error");
  } finally {
    button.disabled = false;
    button.textContent = originalText;
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
        // 任务结束后清理显存：服务端会先确认 ComfyUI 队列空闲，队列里还有任务时静默跳过。
        cleanVramAfterTask(task.comfyUrl);
      }
    }
  } catch (error) {
    task.failures = (task.failures || 0) + 1;
    task.status = "recovering";
    task.progress = task.progress || 2;
    task.message = `暂时无法查询 ComfyUI（第 ${task.failures} 次），任务不会被判定失败，将继续恢复：${error.message}`;
    if (manual) toast(task.message, "error");
  }
  // 兜底：超过时长上限或连续失败次数上限时停止轮询，避免永久卡在「恢复中」。
  const stopReason = pollingStopReason(task);
  if (stopReason) {
    const wasPolling = state.pollers.has(task.id);
    stopPolling(task.id);
    task.status = "failed";
    task.progress = task.progress || 0;
    task.message = stopReason;
    // 只在自动轮询时提示一次，避免手动刷新后反复弹同一个提示。
    if (wasPolling && !manual) toast(stopReason, "error");
  }
  persistTasks();
  renderTasks();
}

function startPolling(taskId, immediate = false) {
  stopPolling(taskId);
  const task = state.tasks.find((item) => item.id === taskId);
  if (!task || ["success", "failed"].includes(task.status)) return;
  // 记录本次轮询的起点（只在首次进入轮询时记，后续 resume 不会重置），
  // 用于 MAX_POLL_DURATION_MS 的时长兜底。
  if (!task.pollingSince) task.pollingSince = Date.now();
  if (immediate) queryTask(taskId);
  const timer = setInterval(() => queryTask(taskId), 5000);
  state.pollers.set(taskId, timer);
}

function stopPolling(taskId) {
  const timer = state.pollers.get(taskId);
  if (timer) clearInterval(timer);
  state.pollers.delete(taskId);
}

// 判断某个仍在轮询的任务是否已经超过兜底阈值。
// 返回 null 表示继续轮询；返回一段文字表示应当停止，文字用作提示。
function pollingStopReason(task) {
  if (task.pollingSince && Date.now() - task.pollingSince > MAX_POLL_DURATION_MS) {
    return `已连续查询超过 ${Math.round(MAX_POLL_DURATION_MS / 3600000)} 小时仍未取得结果，工作站已停止自动查询。任务可能已在 ComfyUI 中结束或被取消，可点「刷新」手动再查一次。`;
  }
  if ((task.failures || 0) >= MAX_QUERY_FAILURES) {
    return `已连续 ${task.failures} 次无法查询 ComfyUI，工作站已停止自动查询。请确认 ComfyUI 仍在运行且地址正确，然后点「刷新」重试。`;
  }
  return null;
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

// AI 模型 / 模板下拉在 /api/ai-config 返回前只有 HTML 里的占位项（value 为空串）。
// 这段期间若调用 saveSettings（loadStoredState 内部的 syncDuration / updateMode 会触发），
// 已保存的选择会被写成空串，导致每次刷新都回到配置文件里的默认模型。这里暂存原值作为回退，
// 配置加载成功后由 loadAiPromptConfig 清空。
let pendingAiSelection = { model: "", template: "" };

function saveSettings() {
  const data = {
    comfyUrl: elements.comfyUrl.value,
    mode: state.mode,
    aiModel: elements.aiModelSelect.value || pendingAiSelection.model,
    aiTemplate: elements.aiTemplateSelect.value || pendingAiSelection.template,
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
    cleanVram: elements.cleanVram.checked,
    rtxUpscale: elements.rtxUpscale.checked,
    rtxUpscaleScale: elements.rtxUpscaleScale.value,
  };
  localStorage.setItem(STORAGE_KEYS.settings, JSON.stringify(data));
}

function persistTasks() {
  // 先给内存中的任务列表做上限收口：超出 MAX_TASKS_IN_MEMORY 时，从最旧的一端
  // 丢弃「已结束」的任务（success/failed），活跃任务永不丢弃。
  // 只在确实超限时才裁剪，避免每次渲染都创建新数组。
  if (state.tasks.length > MAX_TASKS_IN_MEMORY) {
    const isActive = (task) => !["success", "failed"].includes(task.status);
    let overflow = state.tasks.length - MAX_TASKS_IN_MEMORY;
    // 从尾部（最旧）往前找可丢弃的已结束任务
    for (let i = state.tasks.length - 1; i >= 0 && overflow > 0; i--) {
      if (!isActive(state.tasks[i])) {
        state.tasks.splice(i, 1);
        overflow--;
      }
    }
    // 若已结束任务不够丢（极端情况：大量任务同时在跑），则不再强裁，保证活跃任务不被误删。
    if (overflow > 0) {
      state.tasks = state.tasks.slice(0, MAX_TASKS_IN_MEMORY);
    }
  }
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

function readUpdateStorage() {
  try { return JSON.parse(localStorage.getItem(UPDATE_STORAGE_KEY) || "{}"); } catch { return {}; }
}

function writeUpdateStorage(patch) {
  localStorage.setItem(UPDATE_STORAGE_KEY, JSON.stringify({ ...readUpdateStorage(), ...patch }));
}

function hideUpdateBanner() {
  elements.updateBanner.classList.add("hidden");
  elements.updateBanner.dataset.state = "idle";
}

function formatUpdateDate(value) {
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return "";
  return date.toLocaleDateString("zh-CN", { month: "numeric", day: "numeric" });
}

function renderUpdateBanner(force = false) {
  const info = state.updateInfo;
  if (!info || !info.hasUpdate) return;
  // 自动检查时尊重用户对同一版本的“稍后”；手动点击“检查更新”则强制显示。
  if (!force && !state.updateBusy && readUpdateStorage().dismissedVersion === info.latestVersion) return;
  const currentPart = info.unversioned ? "本地未记录版本" : `当前 ${info.currentShort}`;
  const message = info.commitMessage ? ` · ${info.commitMessage}` : "";
  elements.updateTitle.textContent = `发现新版本：${info.latestShort}（${formatUpdateDate(info.latestDate)}）`;
  elements.updateDetail.textContent = `${currentPart} · 仓库 ${info.repo}（${info.branch} 分支）${message}`;
  elements.updateCommitLink.href = info.commitUrl;
  elements.updateBanner.classList.remove("hidden");
}

async function checkUpdate(manual = false) {
  if (!manual && Date.now() - Number(readUpdateStorage().lastCheckAt || 0) < UPDATE_AUTO_CHECK_INTERVAL_MS) return;
  if (manual) {
    elements.checkUpdateButton.disabled = true;
    elements.checkUpdateButton.textContent = "检查中…";
  }
  try {
    const info = await fetchJson(`/api/check-update${manual ? "?fresh=1" : ""}`, {}, 20000);
    writeUpdateStorage({ lastCheckAt: Date.now() });
    if (info.error) {
      if (manual) toast(`检查更新失败：${info.error}`, "error");
      return;
    }
    if (!info.configured) {
      if (manual) toast(info.reason, "error");
      return;
    }
    state.updateInfo = info;
    if (info.hasUpdate) {
      renderUpdateBanner(manual);
    } else {
      hideUpdateBanner();
      if (manual) {
        toast(info.unversioned
          ? `已连接 GitHub；仓库最新提交为 ${info.latestShort}，但本地未记录版本号。可在更新配置.json 中把「当前版本」改为最新提交。`
          : `已是最新版本（${info.latestShort}）。`, "success");
      }
    }
  } catch (error) {
    // 自动检查保持安静，失败不打扰；手动检查才提示。
    if (manual) toast(`检查更新失败：${error.message}`, "error");
  } finally {
    if (manual) {
      elements.checkUpdateButton.disabled = false;
      elements.checkUpdateButton.textContent = "检查更新";
    }
  }
}

async function waitForServerRestart() {
  // 服务已按请求退出，一旦 /api/check-update 能再次应答，说明新版服务已启动，刷新页面。
  const startedAt = Date.now();
  while (Date.now() - startedAt < 180000) {
    await new Promise((resolve) => setTimeout(resolve, 2500));
    try {
      await fetchJson("/api/check-update", {}, 6000);
      location.reload();
      return;
    } catch {}
  }
  toast("等待服务重启超时：请重新运行「启动工作站.bat」，再刷新页面。", "error");
}

async function applyUpdate() {
  if (state.updateBusy) return;
  const info = state.updateInfo;
  if (!info || !info.hasUpdate) return;
  const confirmed = window.confirm(
    `将下载并应用 GitHub 上的最新版本（${info.latestShort}），工作站服务会自动重启，页面随后自动刷新。\n` +
    "正在生成的任务保存在 ComfyUI 端，不受影响；更新会覆盖页面和工作流文件，本地的手工改动（AI提示词配置.json、更新配置.json 除外）会被替换。\n\n确定继续吗？"
  );
  if (!confirmed) return;
  state.updateBusy = true;
  elements.applyUpdateButton.disabled = true;
  elements.updateBanner.dataset.state = "updating";
  elements.updateTitle.textContent = "正在下载更新包…";
  elements.updateDetail.textContent = "下载完成后工作站服务会自动重启，请勿关闭服务窗口。";
  try {
    const result = await fetchJson("/api/apply-update", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: "{}",
    }, 330000);
    toast(result.message || "更新包下载完成，等待服务重启…", "success");
    elements.updateTitle.textContent = "正在等待工作站服务重启…";
    elements.updateDetail.textContent = "服务重启后页面会自动刷新；如长时间未刷新，请重新运行「启动工作站.bat」。";
    await waitForServerRestart();
  } catch (error) {
    state.updateBusy = false;
    elements.applyUpdateButton.disabled = false;
    elements.updateBanner.dataset.state = "idle";
    elements.updateTitle.textContent = `发现新版本：${info.latestShort}（${formatUpdateDate(info.latestDate)}）`;
    elements.updateDetail.textContent = `更新失败：${error.message}，可点击「一键更新」重试。`;
    toast(`更新失败：${error.message}`, "error");
  }
}

function dismissUpdate() {
  const info = state.updateInfo;
  if (info?.latestVersion) writeUpdateStorage({ dismissedVersion: info.latestVersion });
  hideUpdateBanner();
  toast("已忽略这个版本；待仓库出现更新的提交时会再次提醒。");
}

function loadStoredState() {
  let settings = {};
  try { settings = JSON.parse(localStorage.getItem(STORAGE_KEYS.settings) || "{}"); } catch {}
  // 两个 AI 下拉要等 /api/ai-config 返回后才有真实选项，而本函数内部的 syncDuration() / updateMode()
  // 会调用 saveSettings()——那时下拉里只有占位项（value 为空串），会把已保存的模型/模板选择覆盖掉。
  // 先把原值暂存在这里，供 saveSettings 在选项未就绪时回退使用。
  pendingAiSelection = { model: settings.aiModel || "", template: settings.aiTemplate || "" };
  elements.comfyUrl.value = settings.comfyUrl || "http://127.0.0.1:8188";
  elements.aiReadImages.checked = settings.aiReadImages !== false;
  elements.aspectRatio.value = normalizeAspectRatio(settings.aspectRatio);
  elements.megapixels.value = settings.megapixels || "0.7";
  elements.steps.value = settings.steps || "8";
  elements.samplerName.value = settings.samplerName || "res_multistep";
  elements.teControl.value = settings.teControl || "0.12";
  elements.tePercent1.value = settings.tePercent1 || "0.1";
  elements.tePercent2.value = settings.tePercent2 || "0.9";
  elements.cleanVram.checked = settings.cleanVram !== false;
  elements.rtxUpscale.checked = settings.rtxUpscale === true;
  elements.rtxUpscaleScale.value = ["1", "2", "3", "4"].includes(String(settings.rtxUpscaleScale)) ? String(settings.rtxUpscaleScale) : "2";
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
      // 恢复时重置轮询起点与连续失败计数：
      // 页面重新打开相当于开启新一轮跟踪，不应继承上次会话的计时，否则会立刻触发超时兜底。
      if (!["success", "failed"].includes(task.status)) {
        task.pollingSince = Date.now();
        task.failures = 0;
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
  [elements.unetModel, elements.clipModel, elements.videoVae, elements.audioVae, elements.steps, elements.samplerName, elements.teControl, elements.tePercent1, elements.tePercent2, elements.cleanVram, elements.rtxUpscale, elements.rtxUpscaleScale, elements.comfyUrl].forEach((element) => element.addEventListener("change", saveSettings));
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
  elements.freeVramButton.addEventListener("click", freeVram);
  elements.checkUpdateButton.addEventListener("click", () => checkUpdate(true));
  elements.applyUpdateButton.addEventListener("click", applyUpdate);
  elements.dismissUpdateButton.addEventListener("click", dismissUpdate);
  document.addEventListener("visibilitychange", () => {
    if (!document.hidden) state.tasks.filter((task) => !["success", "failed"].includes(task.status)).forEach((task) => queryTask(task.id));
  });
}

// 【能力探测并发去重】loadCapabilities 有三个触发点（页面加载时的 testConnection、用户点
// 「测试连接」、以及未来的模式切换），它们可能在同一时刻各发一次 /api/capabilities；
// 每次请求都会让服务端重新拉一遍 ComfyUI 的 /object_info（几百 KB 且解析开销大）。
// 这里把"进行中"的请求按 ComfyUI 地址共享，同一地址同一时刻最多一个真实请求。
// 注意：force（用户手动点测试连接）需要立即生效，因此强制请求不参与复用，
// 但会用最新结果覆盖缓存，避免随后的非强制请求拿到更旧的数据。
const capabilityRequests = new Map();
let lastCapabilityAt = 0;
const CAPABILITY_MIN_INTERVAL_MS = 3000;

async function loadCapabilities(comfyUrl, force = false) {
  const key = comfyUrl || "";
  // 非强制请求在极短时间内重复触发（例如页面加载时 testConnection 与模式同步同时执行）时直接复用。
  if (!force && Date.now() - lastCapabilityAt < CAPABILITY_MIN_INTERVAL_MS) return null;
  if (capabilityRequests.has(key)) return capabilityRequests.get(key);
  const request = (async () => {
    try {
      const suffix = force ? "?fresh=1" : "";
      const caps = await fetchJson(apiUrl("/api/capabilities" + suffix, comfyUrl), {}, 30000);
      lastCapabilityAt = Date.now();
      applyCapabilities(caps);
      return caps;
    } catch {
      // 探测失败（例如旧版服务端没有该接口）不影响正常使用：服务端提交时仍会自行降级。
      return null;
    } finally {
      capabilityRequests.delete(key);
    }
  })();
  capabilityRequests.set(key, request);
  return request;
}

bindEvents();
loadStoredState();
startElapsedClock();
loadAiPromptConfig();
testConnection(false).then((connected) => { if (connected) scanModels(); });
// 页面打开后延迟自动检查更新（6 小时节流），之后每 30 分钟补一次自动检查。
setTimeout(() => checkUpdate(false), 2500);
setInterval(() => checkUpdate(false), 30 * 60 * 1000);
