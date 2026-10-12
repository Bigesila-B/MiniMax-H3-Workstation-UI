import { createLoraLibrary } from "./lora-library.js?v=20261012-7";

const WORKFLOW_FILES = {
  t2v: "minimaxH3文生视频基础加速流.json",
  i2v: "minimaxH3图生视频基础加速流.json",
  flf2v: "minimaxH3首尾帧视频基础加速流.json",
  ref2va: "minimaxh3全能参考(图片+视频+音频)+ai提示词生成+加速+Lora.json",
  director: "minimaxH3长视频导演台加速流.json",
};

// 长视频导演台的参考图必须落在 ComfyUI input 目录下的这个子文件夹里：
// timeline_data 的 images[].file 记的就是这个相对路径，服务端照写。
const DIRECTOR_IMAGE_FOLDER = "minimax_h3_timeline_director";
// 分段数量上限（含第 1 段）。
const MAX_DIRECTOR_SEGMENTS = 12;
// 分段的自增 id 序号（仅用于 DOM 上标 data-segment-id，不参与提交）
let directorSegmentSeq = 0;

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
  // 长视频导演台追加的分镜（第 2 段起）。第 1 段始终复用上方的「视频提示词」与「视频时长」。
  directorSegments: [],
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

// 任务的「终结状态」：到达后不再自动查询，也不再显示「停止任务」按钮。
//  - success / failed 是 ComfyUI 给出的结果；
//  - cancelled 既是本地判定的「用户点了停止任务」，也是识别到 ComfyUI 侧中断（execution_interrupted）
//    后的结论；它和 failed 分开，是为了不把「用户主动停掉」显示成「生成失败」。
const TERMINAL_TASK_STATUSES = ["success", "failed", "cancelled"];
function isTaskTerminal(task) {
  return TERMINAL_TASK_STATUSES.includes(task?.status);
}

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
  samplerNameOptions: $("samplerNameOptions"), samplerNamePicker: $("samplerNamePicker"), samplerNameHint: $("samplerNameHint"), randomSeedButton: $("randomSeedButton"),
  teControl: $("teControl"), tePercent1: $("tePercent1"), tePercent2: $("tePercent2"), cleanVram: $("cleanVram"), freeVramButton: $("freeVramButton"),
  teMode: $("teMode"), teModeHint: $("teModeHint"),
  // 长视频导演台
  directorPanel: $("directorPanel"), directorSummary: $("directorSummary"), segmentList: $("segmentList"),
  addSegmentButton: $("addSegmentButton"), segmentTotalHint: $("segmentTotalHint"),
  directorSecondPass: $("directorSecondPass"), directorSecondPassModel: $("directorSecondPassModel"),
  directorSecondPassSteps: $("directorSecondPassSteps"),
  timingPanel: $("timingPanel"), durationField: $("durationField"),
  promptFieldLabel: $("promptFieldLabel"), promptDirectorHint: $("promptDirectorHint"),
  rtxUpscale: $("rtxUpscale"), rtxUpscaleScale: $("rtxUpscaleScale"), capabilityNote: $("capabilityNote"), generationSummary: $("generationSummary"), generateButton: $("generateButton"),
  taskList: $("taskList"), taskEmpty: $("taskEmpty"), refreshTasksButton: $("refreshTasksButton"), clearTasksButton: $("clearTasksButton"), toastRegion: $("toastRegion"),
  checkUpdateButton: $("checkUpdateButton"), updateBanner: $("updateBanner"), updateTitle: $("updateTitle"), updateDetail: $("updateDetail"),
  applyUpdateButton: $("applyUpdateButton"), updateCommitLink: $("updateCommitLink"), dismissUpdateButton: $("dismissUpdateButton"),
  freeVramHint: $("freeVramHint"), aiPromptHint: $("aiPromptHint"),
  // 环境自检面板（取代原先写死的「工作流状态」四条 ✓）
  selfCheckRefresh: $("selfCheckRefresh"), selfCheckSummary: $("selfCheckSummary"),
  selfCheckModes: $("selfCheckModes"), selfCheckPackages: $("selfCheckPackages"),
  // 性能监控面板（折叠式，展开期间轮询 /api/system-stats）
  perfPanel: $("perfPanel"), perfGrid: $("perfGrid"), perfSummaryNote: $("perfSummaryNote"),
};

const loraLibrary = createLoraLibrary({
  apiUrl, fetchJson, toast,
  getComfy: () => normalizeComfyUrl(),
  getLoras: () => state.loras,
  syncNames: (names) => {
    state.models.lora = names;
    if (state.loraModeDefaults) syncAutomaticLora();
    else state.loras = state.loras.map((item) => ({ ...item, name: findModelName(names, item.name) || item.name }));
    renderLoras(); saveSettings();
  },
  add: (name) => {
    if (state.loras.some((item) => item.name === name)) return;
    state.loraModeDefaults = false;
    state.loras.push({ name, strength: 1, active: true });
    renderLoras(); saveSettings();
  },
  remove: (names) => {
    state.loraModeDefaults = false;
    state.loras = state.loras.filter((item) => !names.includes(item.name));
    state.models.lora = state.models.lora.filter((name) => !names.includes(name));
    renderLoras(); saveSettings();
  },
});

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

// 导演台单段时长 -> 帧数。与服务端 Get-H3FrameCount 是同一套公式：
// 秒数先按 24fps 折算帧数，再取到 H3 合法的 5+17n 上。
function h3SegmentFrames(seconds) {
  return Math.max(5, 5 + Math.round((clampDuration(seconds) * 24 - 5) / 17) * 17);
}

// 单段实际成片秒数。
function h3SegmentSeconds(seconds) {
  return h3SegmentFrames(seconds) / 24;
}

// 相邻分镜的默认重叠帧数：与节点包 js/segment_windows.mjs 里 createWindows 的
// overlap 默认值（字面量 39）保持一致。
const DIRECTOR_SEAM_OVERLAP = 39;

// 复刻节点的 nearestOverlap：候选集 = [0, 1] 加上所有 5+17n，筛掉超过上限的，
// 取最接近 39 的那个。段很短、上限不足 39 时，重叠会退到 22 / 5 / 1 / 0。
function nearestSeamOverlap(maximum, target = DIRECTOR_SEAM_OVERLAP) {
  const choices = [0, 1];
  for (let i = 0; i < Math.max(0, Math.floor((maximum - 5) / 17) + 1); i++) choices.push(5 + 17 * i);
  return choices
    .filter((n) => n <= maximum)
    .reduce((best, n) => (Math.abs(n - target) < Math.abs(best - target) ? n : best), 0);
}

// 分镜布局：逐段算出 startFrame / endFrame。**必须与服务端 Build-DirectorWorkflow
// 的帧范围算法保持一致**——两边都按「相邻段重叠 39 帧（首段从 0 起）」排布，
// 否则界面上的「共约 X 秒」会和实际成片时长对不上。
function directorSegmentsLayout() {
  const layout = [];
  state.directorSegments.forEach((segment, index) => {
    const frames = h3SegmentFrames(segment.duration);
    if (index === 0) {
      layout.push({ frames, start: 0, end: frames });
      return;
    }
    const previous = layout[index - 1];
    const maximum = Math.min(frames, previous.frames) - 1;
    const overlap = maximum >= 0 ? nearestSeamOverlap(maximum) : 0;
    const start = previous.end - overlap;
    layout.push({ frames, start, end: start + frames });
  });
  return layout;
}

// 分段总数：导演台至少保留一段。列表里就是全部段——第 1 段也在其中，
// 不再是"复用上方提示词框"的特殊段（这样才能给每一段单独选参考素材）。
function directorSegmentCount() {
  return state.directorSegments.length;
}

function directorTotalSeconds() {
  // 总长取「最后一段的结束帧 ÷ 24」，而不是各段秒数直接相加 ——
  // 相邻段重叠 39 帧，直接相加会把重叠部分重复计算。
  const layout = directorSegmentsLayout();
  if (!layout.length) return 0;
  return Math.round((layout[layout.length - 1].end / 24) * 100) / 100;
}

// 「全局提示词 / 分段提示词」的互斥关系，语义照抄素材规划台：
//   * 每一段提示词都留空 -> 全局提示词生效，并复用到每一段；
//   * 只要有任何一段填了 -> 全局提示词不生效，且要求每一段都补齐。
// 返回 "global" | "segment" | "incomplete"。
function directorPromptMode() {
  const segments = state.directorSegments;
  if (!segments.length) return "global";
  const filled = segments.filter((item) => String(item.prompt || "").trim()).length;
  if (filled === 0) return "global";
  if (filled === segments.length) return "segment";
  return "incomplete";
}

// 把互斥关系实时显示在提示词框下方（文案改写自素材规划台的 globalPromptHint / globalPromptInactive）。
function updateDirectorPromptHint() {
  const hint = elements.promptDirectorHint;
  if (!hint) return;
  if (state.mode !== "director") {
    hint.classList.add("hidden");
    return;
  }
  const mode = directorPromptMode();
  hint.classList.remove("hidden");
  if (mode === "global") {
    hint.textContent = "全局提示词生效中：所有分段提示词都为空，它会复用到每一段。";
  } else if (mode === "segment") {
    hint.textContent = "各分段都已有自己的提示词，全局提示词不生效。";
  } else {
    hint.textContent = "已有分段提示词，全局提示词不生效；请补全每一段提示词，或把这些分段清空以改用全局提示词。";
  }
  hint.classList.toggle("director-hint-warn", mode === "incomplete");
}

function updateSummary() {
  const modeLabels = { t2v: "文生视频", i2v: "图生视频", flf2v: "首尾帧视频", ref2va: "全能参考视频", director: "长视频导演台" };
  const ratio = elements.aspectRatio.value.split(" ")[0];
  if (state.mode === "director") {
    const total = directorTotalSeconds();
    const count = directorSegmentCount();
    elements.generationSummary.textContent = `${modeLabels.director} · ${count} 段 · 共约 ${total} 秒 · ${ratio}`;
    if (elements.directorSummary) {
      elements.directorSummary.textContent = `${count} 段 · 共约 ${total} 秒`;
    }
    if (elements.segmentTotalHint) {
      elements.segmentTotalHint.textContent = `当前 ${count} 段 · 共约 ${total} 秒`;
    }
    updateDirectorPromptHint();
    return;
  }
  elements.generationSummary.textContent = `${modeLabels[state.mode]} · ${clampDuration(elements.durationNumber.value)} 秒 · ${ratio}`;
}

// ---------------------------------------------------------------- 长视频导演台：分镜
// 第 1 段固定复用上方的「视频提示词」与「视频时长」，这里只维护第 2 段及以后的追加分镜。
// 每段单独生成再交给导演台拼接，所以「长视频」= 各段时长累加；单段（不追加）时行为与普通模式一致。

function createDirectorSegment(prompt = "", duration = 5) {
  directorSegmentSeq += 1;
  return {
    id: `director-seg-${directorSegmentSeq}`,
    prompt: String(prompt || ""),
    duration: clampDuration(duration),
    // 该段引用的参考素材（按文件名记录）。null = 引用全部（之后新增的素材自动包含），
    // 数组 = 只引用列出的这些；空数组表示这一段不引用任何同类素材。
    imageNames: null,
    audioNames: null,
  };
}

// 每段的参考素材勾选器：候选来自上方「参考素材」区已上传的文件。
// 与服务端约定用「文件名」关联——服务端登记素材时也记 name，最后映射成 timeline_data 里的 id。
function segmentMaterialPicker(kind, segment) {
  const isImage = kind === "image";
  const pool = isImage ? state.referenceImages : state.referenceAudios;
  const key = isImage ? "imageNames" : "audioNames";
  const field = document.createElement("div");
  field.className = "field segment-materials";
  const title = document.createElement("span");
  title.textContent = isImage ? "本段参考图片" : "本段参考音频";
  field.appendChild(title);

  if (!pool.length) {
    const empty = document.createElement("small");
    empty.textContent = isImage
      ? "先在上方「参考素材」里添加图片，再回到这里勾选本段要用的。"
      : "先在上方「参考素材」里添加音频，再回到这里勾选本段要用的。";
    field.appendChild(empty);
    return field;
  }

  const list = document.createElement("div");
  list.className = "segment-material-options";
  const chosen = Array.isArray(segment[key]) ? segment[key] : null;

  pool.forEach((file) => {
    const item = document.createElement("label");
    item.className = "segment-material-option";
    item.title = file.name;
    const box = document.createElement("input");
    box.type = "checkbox";
    box.value = file.name;
    box.checked = chosen === null || chosen.includes(file.name);

    // 预览小图：图片直接读本地文件生成 object URL；音频没有画面，用音符占位。
    // object URL 记在 data 上，renderDirectorSegments 重建前统一 revoke（否则每次重建都漏一个）。
    const thumb = document.createElement("span");
    thumb.className = "segment-material-thumb";
    if (isImage) {
      const preview = document.createElement("img");
      const objectUrl = URL.createObjectURL(file);
      preview.src = objectUrl;
      preview.alt = "";
      thumb.dataset.previewUrl = objectUrl;
      thumb.appendChild(preview);
    } else {
      thumb.classList.add("is-audio");
      thumb.textContent = "♪";
    }
    box.addEventListener("change", () => {
      const boxes = Array.from(list.querySelectorAll("input"));
      const checked = boxes.filter((node) => node.checked).map((node) => node.value);
      // 三种状态要分清楚，和服务端一一对应（素材规划台本身允许一段不引用任何素材）：
      //   全勾   -> null   ：未指定，引用全部，且以后新增的素材自动包含
      //   部分勾 -> 具体名单
      //   全不勾 -> 空数组 ：显式声明"这一段不引用任何同类素材"
      segment[key] = checked.length === pool.length ? null : checked;
      saveSettings();
    });
    const text = document.createElement("span");
    text.className = "segment-material-name";
    text.textContent = file.name;
    item.append(box, thumb, text);
    list.appendChild(item);
  });

  field.appendChild(list);
  const hint = document.createElement("small");
  hint.textContent = "全选 = 引用所有素材（含以后新增的）；全不选 = 这一段不引用任何素材。";
  field.appendChild(hint);
  return field;
}

function directorSegmentCard(segment, index) {
  const row = document.createElement("div");
  row.className = "segment-row";
  row.dataset.segmentId = segment.id;

  const head = document.createElement("div");
  head.className = "segment-row-head";
  const label = document.createElement("span");
  label.className = "segment-index";
  label.textContent = `第 ${index + 1} 段`;
  const remove = document.createElement("button");
  remove.type = "button";
  remove.className = "remove-segment";
  remove.textContent = "移除";
  remove.addEventListener("click", () => {
    state.directorSegments = state.directorSegments.filter((item) => item.id !== segment.id);
    // 至少保留一段，否则提交时没有任何分段可展开。
    if (!state.directorSegments.length) state.directorSegments.push(createDirectorSegment());
    renderDirectorSegments();
    saveSettings();
  });
  head.append(label, remove);

  const body = document.createElement("div");
  body.className = "segment-row-body";

  const promptField = document.createElement("label");
  promptField.className = "field";
  const promptLabel = document.createElement("span");
  promptLabel.textContent = "本段提示词";
  const promptInput = document.createElement("textarea");
  promptInput.rows = 4;
  promptInput.maxLength = 12000;
  promptInput.placeholder = "留空则整条时间线共用上方的「全局提示词」。";
  promptInput.value = segment.prompt;
  promptInput.addEventListener("input", () => {
    segment.prompt = promptInput.value;
    updateDirectorPromptHint();
    saveSettings();
  });
  promptField.append(promptLabel, promptInput);

  const durationField = document.createElement("label");
  durationField.className = "field";
  const durationLabel = document.createElement("span");
  durationLabel.textContent = "时长（秒）";
  const durationInput = document.createElement("input");
  durationInput.type = "number";
  durationInput.min = "1";
  durationInput.max = "15";
  durationInput.step = "1";
  durationInput.inputMode = "numeric";
  durationInput.value = String(segment.duration);
  durationInput.addEventListener("input", () => {
    segment.duration = clampDuration(durationInput.value);
    updateSummary();
    saveSettings();
  });
  durationField.append(durationLabel, durationInput);

  body.append(promptField, durationField, segmentMaterialPicker("image", segment), segmentMaterialPicker("audio", segment));
  row.append(head, body);
  return row;
}

function renderDirectorSegments() {
  if (!elements.segmentList) return;
  // 至少保留一段：分段列表为空时导演台没有任何可展开的内容。
  if (!state.directorSegments.length) state.directorSegments.push(createDirectorSegment());
  // 先回收上一轮为素材预览创建的 blob URL —— 分段卡会随素材增删/模式切换频繁重建，
  // 不回收的话每重建一次就漏一批（图片缩略图每张一个）。
  elements.segmentList.querySelectorAll("[data-preview-url]").forEach((node) => {
    URL.revokeObjectURL(node.dataset.previewUrl);
  });
  elements.segmentList.replaceChildren();
  state.directorSegments.forEach((segment, index) => {
    elements.segmentList.appendChild(directorSegmentCard(segment, index));
  });
  updateSummary();
}

function addDirectorSegment() {
  if (state.directorSegments.length >= MAX_DIRECTOR_SEGMENTS) {
    return toast(`最多 ${MAX_DIRECTOR_SEGMENTS} 段。`, "error");
  }
  state.directorSegments.push(createDirectorSegment());
  renderDirectorSegments();
  saveSettings();
  const lastCard = elements.segmentList?.lastElementChild;
  if (lastCard) lastCard.querySelector("textarea")?.focus();
}

elements.addSegmentButton?.addEventListener("click", addDirectorSegment);

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
  elements.imageUploadArea.classList.toggle("hidden", mode === "t2v" || mode === "ref2va" || mode === "director");
  elements.lastFrameCard.classList.toggle("hidden", mode !== "flf2v");
  // 导演台与全能参考共用「参考素材」区；导演台当前只取其中的图片（见下方提示）。
  elements.referenceUploadArea?.classList.toggle("hidden", mode !== "ref2va" && mode !== "director");
  // 导演台与全能参考一样支持图片 / 视频 / 音频三类参考素材，参考区不区分显示。
  const directorMode = mode === "director";
  elements.directorPanel?.classList.toggle("hidden", !directorMode);
  // 导演台的时长全部由各分段决定，顶部的「视频时长」不再适用；
  // 主提示词框在导演台里的语义是「全局提示词」（与分段提示词互斥，见 updateDirectorPromptHint）。
  elements.durationField?.classList.toggle("hidden", directorMode);
  elements.timingPanel?.classList.toggle("director-mode", directorMode);
  if (elements.promptFieldLabel) {
    elements.promptFieldLabel.textContent = directorMode ? "全局提示词" : "提示词或简短创意";
  }
  elements.promptInput.placeholder = directorMode
    ? "整条时间线的整体描述。所有分段提示词都留空时，它会复用到每一段。"
    : "可以输入简单想法，再点击 AI 生成提示词；也可以直接填写最终视频提示词。";
  renderDirectorSegments();
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

// 本机采样器候选的最近一次结果：输入框被手动编辑时要重新判断「这个名字本机到底有没有」，
// 不能为此再去重扫一遍 ComfyUI。
let samplerNameCache = [];

// 输入框里填的采样器不在本机列表时给出提示。
// 只提示、不强行改值——用户可能有意使用自定义节点提供的采样器，替用户改掉更糟。
function markSamplerValidity(names) {
  const input = elements.samplerName;
  if (!input) return;
  const list = Array.isArray(names) ? names : [];
  const current = input.value.trim();
  if (list.length && current && !list.includes(current)) {
    input.title = `当前填写的「${current}」不在本机采样器列表中，提交可能失败。可从右侧下拉里选择。`;
  } else {
    input.removeAttribute("title");
  }
}

// 下拉是「选择动作」而不是状态显示：选完立刻回到占位项。
// 为什么不复读输入框的值：左边本来就是同一个值的输入框，右边再显示一遍会看起来像两个重复控件，
// 而且下拉的宽度会把输入框挤窄。保持「选择…」既省空间，也让「点了会弹出列表」这件事一目了然。
// 附带好处：连续选同一个采样器两次也能各触发一次 change（value 每次都从占位项变过去）。
function resetSamplerPicker() {
  const picker = elements.samplerNamePicker;
  if (picker) picker.value = "";
}

// 把本机 ComfyUI 的真实采样器列表填进右侧下拉。
// 为什么不能只靠 <datalist>：它在不少浏览器里不点那个极小的箭头就不弹列表，用户根本发现不了；
// 显式的 <select> 一眼就知道「这里能选」。datalist 仍然保留，手打时有自动补全。
// 列表为空（还没扫描过模型 / ComfyUI 没起来）时禁用下拉，避免点开一个空菜单。
function applySamplerPicker(names) {
  const picker = elements.samplerNamePicker;
  if (!picker) return;
  samplerNameCache = [...new Set((names || []).filter((item) => typeof item === "string" && item.trim()))];

  picker.replaceChildren();
  const placeholder = document.createElement("option");
  placeholder.value = "";
  placeholder.textContent = samplerNameCache.length ? "选择…" : "（先扫描模型）";
  picker.appendChild(placeholder);
  samplerNameCache.forEach((name) => {
    const option = document.createElement("option");
    option.value = name;
    option.textContent = name;
    picker.appendChild(option);
  });
  picker.disabled = samplerNameCache.length === 0;
  if (elements.samplerNameHint) {
    elements.samplerNameHint.textContent = samplerNameCache.length
      ? `下拉里是本机 ComfyUI 现有的 ${samplerNameCache.length} 个采样器；也可以在左边直接输入其它名称。`
      : "下拉列表取自本机 ComfyUI（点「扫描模型」后填充）。也可以直接在左边输入其它采样器名。";
  }
  resetSamplerPicker();
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
    // 顺带刷新环境自检面板：它复用服务端刚探测好的能力缓存，不额外打 ComfyUI。
    // loadSelfCheck 内部已自行兜底，失败不会冒泡到这里、不影响连接结果。
    loadSelfCheck(comfyUrl, showSuccess);
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

// TE-Speed 加速模式的显示名。值本身照读节点声明，这里只把已知的值翻成人话；
// 节点若声明了这里没有登记的模式，直接显示原始值——绝不因为前端没登记就丢掉一个选项。
const TESPEED_MODE_LABELS = {
  "standard": "standard（长采样加速）",
  "4-step LoRA": "4-step LoRA（4 步蒸馏）",
  "8-step LoRA": "8-step LoRA（8 步蒸馏）",
};
// 记录 HTML 里的原始说明文案：节点不支持 mode 时会被替换成解释性文案，恢复时要还原。
const TESPEED_MODE_HINT_DEFAULT = elements.teModeHint ? elements.teModeHint.innerHTML : "";

// 用节点当前声明的 mode 候选重建下拉。
// 为什么不写死在 HTML 里：mode 是 TE-Speed 3.5 才引入的，以后还可能加新模式（比如 16 步），
// 写死的话上游每改一次都要跟着改前端。这里完全跟随 /api/capabilities 回传的 TEspeedModes。
// 候选为空有两种情况——节点版本太旧（没有 mode 输入）或压根没装 TE-Speed——都禁用下拉，
// 避免用户以为切换生效了，实际却被节点静默忽略。
function applyTespeedModes(modes) {
  const select = elements.teMode;
  if (!select) return;
  const list = Array.isArray(modes) ? modes.filter((item) => typeof item === "string" && item) : [];
  const current = select.value || "standard";
  const hint = elements.teModeHint;

  if (!list.length) {
    select.disabled = true;
    select.replaceChildren();
    const option = document.createElement("option");
    // 保留原值：服务端仍会收到它，并在节点确实不支持时给出明确提示，而不是静默丢弃用户的选择。
    option.value = current;
    option.textContent = "（当前节点版本不支持选择）";
    select.appendChild(option);
    if (hint) {
      hint.textContent = "当前 TE-Speed 节点没有 mode 输入（3.5 以前的版本），加速策略由节点按采样步数自行切换。安装 TE-Speed 3.5 及以上版本并重启 ComfyUI 后本项会自动启用。";
      hint.dataset.unsupported = "1";
    }
    return;
  }

  select.disabled = false;
  select.replaceChildren();
  list.forEach((value) => {
    const option = document.createElement("option");
    option.value = value;
    option.textContent = TESPEED_MODE_LABELS[value] || value;
    select.appendChild(option);
  });
  // 存过的值在当前节点上不存在时回退到第一项（节点把最保守的选项排在第一位）。
  select.value = list.includes(current) ? current : list[0];
  if (hint && hint.dataset.unsupported === "1") {
    hint.innerHTML = TESPEED_MODE_HINT_DEFAULT;
    delete hint.dataset.unsupported;
  }
}

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

  // TE-Speed 加速模式：候选列表与可用性完全由节点声明决定（见 applyTespeedModes）。
  applyTespeedModes(caps.TEspeedModes);

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

// ---------------------------------------------------------------- 环境自检面板

// 模式状态 -> 中文标签。服务端给的是 ok / degraded / unavailable 三种。
// 措辞刻意避开「会降级」这类读起来像「不能用」的说法 —— 降级仍然照常出片。
const SELF_CHECK_STATE_TEXT = { ok: "正常", degraded: "有降级", unavailable: "不可用" };

// 把某模式的缺失节点拼成一段说明，用作悬停提示。
function selfCheckMissingText(mode) {
  const describe = (entry) => `${entry.node}（${entry.impact}）`;
  const lines = [];
  if (mode.requiredMissing?.length) lines.push(`必需缺失：${mode.requiredMissing.map(describe).join("；")}`);
  if (mode.optionalMissing?.length) lines.push(`可选缺失：${mode.optionalMissing.map(describe).join("；")}`);
  return lines.join("\n");
}

// 一键安装一个节点包：转发给 ComfyUI-Manager。请求体只带**包名** ——
// 仓库地址由服务端从登记表反查，前端无法指定任意 URL（这是有意的安全设计）。
async function installPackage(pkg, button) {
  const original = button.textContent;
  button.disabled = true;
  button.textContent = "安装中…";
  try {
    // 超时给到 10 分钟：Manager 需要克隆仓库并可能装 pip 依赖。
    const result = await fetchJson(apiUrl("/api/install-package"), {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ package: pkg.package }),
    }, 600000);
    toast(`${result.message || `已提交 ${pkg.package} 的安装。`}装好后点「重新检测」。`, "success");
  } catch (error) {
    // 安装失败是常见路径而不是异常：Manager 没开 allow_git_url_install、
    // ComfyUI 不是以 loopback 启动、版本过旧都会走到这里。服务端已经把原因
    // 翻译成人话并附带手动安装指引，直接原样显示即可。
    toast(error.message || "一键安装失败，请改用「复制安装命令」手动安装。", "error");
  } finally {
    button.disabled = false;
    button.textContent = original;
  }
}

// 一个「待安装节点包」卡片：包名 + 缺失节点 + 安装操作。
function selfCheckPackageCard(pkg, manager) {
  const box = document.createElement("div");
  box.className = `self-check-package${pkg.isCore ? " is-core" : ""}`;

  const name = document.createElement("strong");
  name.className = "self-check-package-name";
  // 内置节点不是「装包」能解决的，必须说清是升级 ComfyUI。
  name.textContent = pkg.isCore ? "ComfyUI 内置节点缺失" : String(pkg.package || "未登记来源");

  const nodes = document.createElement("p");
  nodes.className = "self-check-package-nodes";
  nodes.textContent = `缺失：${(pkg.nodes || []).join("、")}`;
  box.append(name, nodes);

  if (pkg.isCore) {
    const hint = document.createElement("p");
    hint.className = "self-check-hint";
    hint.textContent = "这些节点由较新版本 ComfyUI 内置，请更新 ComfyUI 后重启。";
    box.appendChild(hint);
    return box;
  }

  const actions = document.createElement("div");
  actions.className = "self-check-package-actions";

  if (pkg.url) {
    const command = `git clone ${pkg.url}`;
    // 检测到 ComfyUI-Manager 才显示「一键安装」；没装就保持「复制安装命令」。
    // 两个按钮都保留：一键安装会因 Manager 的配置（allow_git_url_install /
    // security_level / ComfyUI 非 loopback 启动）失败，这时手动命令是兜底路径。
    if (manager?.available) {
      const install = document.createElement("button");
      install.type = "button";
      install.className = "button primary";
      install.textContent = "一键安装";
      install.addEventListener("click", () => installPackage(pkg, install));
      actions.appendChild(install);
    }
    const copy = document.createElement("button");
    copy.type = "button";
    copy.className = "button ghost";
    copy.textContent = "复制安装命令";
    copy.addEventListener("click", async () => {
      try {
        // 剪贴板 API 只在安全上下文可用（localhost / HTTPS）。用局域网 IP 访问工作站时
        // 会拿不到 writeText，这时退化成把命令显示出来让用户手抄，而不是静默什么都不做。
        await navigator.clipboard.writeText(command);
        toast("安装命令已复制。请在 ComfyUI 的 custom_nodes 目录下执行，装完重启 ComfyUI。", "success");
      } catch {
        toast(`请手动执行：${command}（在 ComfyUI 的 custom_nodes 目录下），装完重启 ComfyUI。`, "error");
      }
    });
    const open = document.createElement("button");
    open.type = "button";
    open.className = "button ghost";
    open.textContent = "打开仓库";
    open.addEventListener("click", () => window.open(pkg.url, "_blank", "noopener"));
    actions.append(copy, open);
  } else {
    const hint = document.createElement("p");
    hint.className = "self-check-hint";
    hint.textContent = `未登记仓库地址，请在 ComfyUI-Manager 中搜索「${pkg.package}」安装。`;
    box.appendChild(hint);
  }

  if (actions.childElementCount) box.appendChild(actions);
  return box;
}

function renderSelfCheck(report) {
  const summary = elements.selfCheckSummary;
  const modeList = elements.selfCheckModes;
  const packageBox = elements.selfCheckPackages;
  if (!summary || !modeList || !packageBox) return;

  if (!report) {
    summary.textContent = "自检数据暂不可用（不影响生成）。";
    modeList.replaceChildren();
    packageBox.replaceChildren();
    return;
  }

  // 「连不上 ComfyUI」与「缺节点」必须分开说 —— 都报红的话用户会以为节点装崩了。
  if (report.connected === false) {
    summary.replaceChildren();
    const bad = document.createElement("strong");
    bad.className = "is-bad";
    bad.textContent = "未连接到 ComfyUI";
    const detail = document.createElement("span");
    detail.textContent = `　${report.error || "请确认 ComfyUI 已启动，然后点「重新检测」。"}`;
    summary.append(bad, detail);
    modeList.replaceChildren();
    packageBox.replaceChildren();
    return;
  }

  const stats = report.summary || {};
  summary.replaceChildren();
  const badge = (cls, text) => {
    const el = document.createElement("span");
    el.className = cls;
    el.textContent = text;
    return el;
  };
  summary.append(document.createTextNode(`${stats.modes || 0} 个模式：`));
  summary.append(badge("is-ok", `${stats.available || 0} 正常`));
  if (stats.degraded) summary.append(document.createTextNode(" · "), badge("is-soft", `${stats.degraded} 有降级`));
  if (stats.unavailable) summary.append(document.createTextNode(" · "), badge("is-bad", `${stats.unavailable} 不可用`));

  modeList.replaceChildren();
  (report.modes || []).forEach((mode) => {
    const item = document.createElement("li");
    item.className = `self-check-mode is-${mode.status}`;
    const name = document.createElement("span");
    name.className = "self-check-mode-name";
    name.textContent = mode.label;
    const state = document.createElement("span");
    state.className = "self-check-mode-state";
    state.textContent = SELF_CHECK_STATE_TEXT[mode.status] || mode.status;
    const detail = selfCheckMissingText(mode);
    if (detail) item.title = detail;
    item.append(name, state);
    modeList.appendChild(item);
  });

  packageBox.replaceChildren();
  // 先讲清「降级 ≠ 不能用」：否则只缺一个 RTX 放大就会让五个模式全变黄，
  // 用户会以为环境装坏了。这也点明了本面板是只读诊断、不拦生成。
  if (stats.degraded || stats.unavailable) {
    const note = document.createElement("p");
    note.className = "self-check-hint";
    note.textContent = stats.unavailable
      ? "缺「必需」节点会让对应模式不可用；缺「可选」节点只会降级，仍会正常出片。"
      : "缺「可选」节点只会降级，仍会正常出片。";
    packageBox.appendChild(note);
  }
  const packages = report.packages || [];
  const unknown = report.unknownNodes || [];
  if (!packages.length) {
    const ok = document.createElement("p");
    ok.className = "self-check-hint";
    ok.textContent = "五个模式所需节点齐全，无需安装。";
    packageBox.appendChild(ok);
  } else {
    const head = document.createElement("p");
    head.className = "self-check-hint";
    head.textContent = "需要安装的节点包：";
    packageBox.appendChild(head);
    const manager = report.manager || { available: false };
    packages.forEach((pkg) => packageBox.appendChild(selfCheckPackageCard(pkg, manager)));
  }
  if (unknown.length) {
    const hint = document.createElement("p");
    hint.className = "self-check-hint";
    hint.textContent = `另有未登记来源的缺失节点：${unknown.join("、")}（请在 ComfyUI-Manager 中按节点名搜索）。`;
    packageBox.appendChild(hint);
  }
}

// 拉取并渲染自检结果。失败只让面板显示中性提示，绝不影响生成流程 ——
// 与 loadCapabilities 的容错策略一致：旧版服务端没有这个接口时应当静默降级。
async function loadSelfCheck(comfyUrl, force = false) {
  if (!elements.selfCheckSummary) return null;
  try {
    const suffix = force ? "?fresh=1" : "";
    const report = await fetchJson(apiUrl("/api/self-check" + suffix, comfyUrl), {}, 30000);
    renderSelfCheck(report);
    return report;
  } catch {
    renderSelfCheck(null);
    return null;
  }
}

// ---------------------------------------------------------------------------
// 性能监控面板：只读展示服务端所在机器的 CPU / 内存 / 显卡占用与显卡温度。
// 数据来自 GET /api/system-stats —— 服务端那份快照由**后台常驻采集线程**每约 500ms
// 刷新一次（CPU/内存走常驻性能计数器、显卡走常驻 nvidia-smi 流，一轮约 1 毫秒），
// 接口只读内存快照，所以这里可以按秒级轮询而不给服务端增加负担。
// 【为什么固定 1 秒、不做档位】1 秒已经是"实时感"的上限：采集线程本身约 500ms 一轮，
// 再快也只是把同一份快照多读几遍。少一个下拉，少一处状态，少一类"改了档位没生效"的疑问。
// 【为什么仍然只在面板展开时轮询】服务端不疼了，但没必要在没人看的时候白白发请求、
// 白白重绘：面板默认折叠，展开才轮询；页面切到后台（visibilitychange）同样暂停。
// 【为什么渲染必须"就地更新"】1 秒一刷如果每次都 replaceChildren()，进度条元素每秒
// 被重建一次，CSS 的 width 过渡永远来不及触发（新元素直接以目标宽度出生），
// 看上去就是数字在跳、条子在闪。所以按稳定的 key 复用已有的行元素。
// ---------------------------------------------------------------------------
const PERF_POLL_INTERVAL_MS = 1000;
const perfState = { timer: null, busy: false, failureCount: 0 };

function perfStatus(text) {
  if (elements.perfSummaryNote) elements.perfSummaryNote.textContent = text;
}

function perfBarClass(percent) {
  if (percent == null) return "";
  if (percent >= 90) return " is-bad";
  if (percent >= 75) return " is-warn";
  return "";
}

function perfPercentText(percent) {
  return percent == null ? "—" : `${Math.round(percent)}%`;
}

// 进度条只在"这一行需要进度条"时存在；数值没变就不动 DOM（避免无谓重排）。
function perfFillBar(row, percent) {
  let bar = row.querySelector(".perf-bar");
  if (percent == null) {
    if (bar) bar.remove();
    return;
  }
  if (!bar) {
    bar = document.createElement("div");
    bar.className = "perf-bar";
    const created = document.createElement("div");
    created.className = "perf-bar-fill";
    bar.appendChild(created);
    row.appendChild(bar);
  }
  const fill = bar.firstElementChild;
  const nextClass = `perf-bar-fill${perfBarClass(percent)}`.trim();
  if (fill.className !== nextClass) fill.className = nextClass;
  const nextWidth = `${Math.max(0, Math.min(100, percent))}%`;
  if (fill.style.width !== nextWidth) fill.style.width = nextWidth;
}

// 按 key 取回（必要时新建）一行指标。key 是这一行在面板里的稳定身份：
// 只要 key 不变，元素就一直被复用，进度条的 width 过渡才有机会真正播放。
// 【注意】新建后必须先挂进 grid：perfReconcile 只重排"已经在树上的元素"，
// 没挂上去的行会被它当作不存在，结果是分组标题都在、数据一行都不显示。
function perfEnsureRow(grid, key) {
  let row = grid.querySelector(`[data-perf-key="${key}"]`);
  if (row) return row;
  row = document.createElement("div");
  row.className = "perf-row";
  row.dataset.perfKey = key;
  const top = document.createElement("div");
  top.className = "perf-row-top";
  const label = document.createElement("span");
  label.className = "perf-row-label";
  const value = document.createElement("span");
  value.className = "perf-row-value";
  top.append(label, value);
  row.appendChild(top);
  grid.appendChild(row);
  return row;
}

// 一行指标 = 「标签 + 数值」+（可选）副标题 +（可选）进度条。全部就地更新。
function perfFillRow(row, label, valueText, detail = "", percent = null) {
  row.querySelector(".perf-row-label").textContent = label;
  row.querySelector(".perf-row-value").textContent = valueText;
  let sub = row.querySelector(".perf-row-detail");
  if (detail) {
    if (!sub) {
      sub = document.createElement("span");
      sub.className = "perf-row-detail";
      row.appendChild(sub);
    }
    if (sub.textContent !== detail) sub.textContent = detail;
  } else if (sub) {
    sub.remove();
  }
  perfFillBar(row, percent);
}

function perfEnsureSectionTitle(grid, key, text) {
  let el = grid.querySelector(`[data-perf-key="${key}"]`);
  if (!el) {
    el = document.createElement("span");
    el.className = "perf-section-title";
    el.dataset.perfKey = key;
    grid.appendChild(el);
  }
  if (el.textContent !== text) el.textContent = text;
  return el;
}

// 按 order 把已有元素重排成目标顺序，并删掉这一轮不再需要的元素。
// 只移动/删除，不重建 —— 重建会让进度条动画和输入焦点一并丢失。
function perfReconcile(grid, order) {
  const present = new Map();
  for (const child of Array.from(grid.children)) {
    if (child.dataset.perfKey) present.set(child.dataset.perfKey, child);
  }
  const keep = new Set(order);
  let cursor = grid.firstElementChild;
  for (const key of order) {
    const el = present.get(key);
    if (!el) continue;
    if (el === cursor) {
      cursor = cursor.nextElementSibling;
      continue;
    }
    grid.insertBefore(el, cursor);
  }
  for (const [key, el] of present) {
    if (!keep.has(key)) el.remove();
  }
}

function renderPerfStats(stats) {
  const grid = elements.perfGrid;
  if (!grid || !stats) return;
  const order = [];

  const errors = Array.isArray(stats.errors) ? stats.errors.filter(Boolean) : [];
  if (errors.length) {
    const key = "note";
    let note = grid.querySelector(`[data-perf-key="${key}"]`);
    if (!note) {
      note = document.createElement("p");
      note.className = "perf-note is-error";
      note.dataset.perfKey = key;
      grid.appendChild(note);
    }
    note.textContent = errors.join("　");
    order.push(key);
  }

  // ---- CPU ----
  const cpu = stats.cpu || {};
  if (cpu.name || cpu.loadPercent != null) {
    perfEnsureSectionTitle(grid, "title:cpu", "处理器");
    order.push("title:cpu");
    const details = [];
    if (cpu.name) details.push(cpu.name);
    if (cpu.logicalCores) details.push(`${cpu.logicalCores} 线程`);
    perfFillRow(perfEnsureRow(grid, "row:cpu"), "CPU 占用", perfPercentText(cpu.loadPercent), details.join(" · "), cpu.loadPercent);
    order.push("row:cpu");
  }

  // ---- 内存 ----
  const memory = stats.memory || {};
  if (memory.totalGb != null) {
    perfEnsureSectionTitle(grid, "title:memory", "内存");
    order.push("title:memory");
    const label = memory.usedGb != null ? `${memory.usedGb} / ${memory.totalGb} GB` : `${memory.totalGb} GB`;
    perfFillRow(perfEnsureRow(grid, "row:memory"), "内存占用", `${perfPercentText(memory.usedPercent)} · ${label}`, "", memory.usedPercent);
    order.push("row:memory");
  }

  // ---- 显卡 ----
  const gpus = Array.isArray(stats.gpus) ? stats.gpus : [];
  if (gpus.length) {
    perfEnsureSectionTitle(grid, "title:gpu", "显卡");
    order.push("title:gpu");
    gpus.forEach((gpu, index) => {
      if (gpu.utilizationPercent == null && gpu.memoryTotalMb == null) {
        // 没有 nvidia-smi 时的 WMI 兜底：只有型号，没有占用/温度可报。
        const key = `row:gpu:${index}:name`;
        perfFillRow(perfEnsureRow(grid, key), gpu.name || "显卡", "占用 / 温度不可用", "未检测到 NVIDIA 驱动（nvidia-smi）。", null);
        order.push(key);
        return;
      }
      const tempParts = [];
      if (gpu.temperatureC != null) tempParts.push(`${gpu.temperatureC}℃`);
      if (gpu.powerW != null) tempParts.push(`${gpu.powerW}W`);
      const utilKey = `row:gpu:${index}:util`;
      perfFillRow(
        perfEnsureRow(grid, utilKey),
        "GPU 占用",
        [perfPercentText(gpu.utilizationPercent)].concat(tempParts).join(" · "),
        gpu.name || "",
        gpu.utilizationPercent
      );
      order.push(utilKey);
      if (gpu.memoryTotalMb) {
        const usedMb = gpu.memoryUsedMb || 0;
        const vramPercent = (usedMb / gpu.memoryTotalMb) * 100;
        const vramKey = `row:gpu:${index}:vram`;
        perfFillRow(
          perfEnsureRow(grid, vramKey),
          "显存",
          `${perfPercentText(vramPercent)} · ${(usedMb / 1024).toFixed(1)} / ${(gpu.memoryTotalMb / 1024).toFixed(1)} GB`,
          "",
          vramPercent
        );
        order.push(vramKey);
      }
    });
  }

  perfReconcile(grid, order);
}

async function pollPerfStats() {
  if (perfState.busy || !elements.perfPanel?.open) return;
  perfState.busy = true;
  try {
    // 10 秒：接口读的是服务端内存快照，正常情况下几毫秒就返回；
    // 只有服务端采集线程异常、退回按需采集时才可能慢到接近 1 秒。
    const stats = await fetchJson(apiUrl("/api/system-stats"), {}, 10000);
    perfState.failureCount = 0;
    renderPerfStats(stats);
    // 服务端采集线程没在工作时如实说明，而不是让人以为面板坏了 ——
    // 这时数据仍是现场采的，只是刷新会明显变慢。
    const degraded = stats.collector && stats.collector.fresh === false;
    perfStatus(degraded ? "自动刷新中 · 服务端采集降级（按需采集）" : "自动刷新中");
  } catch {
    // 失败不清空最后一次成功的数据，只在摘要处提示；连续失败也静默重试。
    perfState.failureCount += 1;
    if (perfState.failureCount === 1) perfStatus("刷新失败，将自动重试…");
  } finally {
    perfState.busy = false;
  }
}

function startPerfPolling() {
  if (perfState.timer) return;
  if (!elements.perfPanel?.open) return;
  perfStatus("自动刷新中");
  pollPerfStats();
  perfState.timer = setInterval(pollPerfStats, PERF_POLL_INTERVAL_MS);
}

function stopPerfPolling(reason = "collapsed") {
  if (perfState.timer) {
    clearInterval(perfState.timer);
    perfState.timer = null;
  }
  if (elements.perfPanel) {
    perfStatus(reason === "hidden" ? "已暂停（页面在后台，切回自动恢复）" : "已暂停（展开后自动恢复）");
  }
}

// 服务端在构建工作流时若跳过了可选节点，会在提交结果里带上 warnings。
// 分两类处理：
//   1) 能力降级类（「未检测到 XXX 节点」）——汇总成一条。逐条原因已常驻在「高级参数」的
//      兼容性提示里，弹一条就够，不然会刷屏；
//   2) 其它提示（例如「已自动补齐必需输入」「选定的加速模式被旧版节点忽略」）——这些
//      没有常驻展示位置，必须原样弹出来，否则用户根本不会知道发生过什么。
//
// 【为什么按前缀而不是整段子串匹配】原先用 `text.includes(marker)` 找 CAPABILITY_ITEMS 的节点名，
// 但自动补齐的告警里会拼进**节点类名**（例如「…自动补齐必需输入：CreateVideo.fps=24」），
// 而 marker 里恰好也有一堆类名（CreateVideo / SaveVideo / ResolutionSelector…）→ 会把
// 「补齐了输入」误报成「本次已自动跳过：视频合成」，语义完全错，还会把排查方向带偏。
// 服务端的降级告警都固定以「未检测到」开头（见 server.ps1 的 Add-BuildWarning 调用点），
// 用它做闸门既准确又不用和文案细节耦合。
const CAPABILITY_WARNING_PREFIX = "未检测到";
function reportBuildWarnings(warnings) {
  if (!Array.isArray(warnings) || !warnings.length) return;
  const labels = [];
  const details = [];
  warnings.forEach((raw) => {
    const text = String(raw);
    if (!text.startsWith(CAPABILITY_WARNING_PREFIX)) {
      details.push(text);
      return;
    }
    const matched = CAPABILITY_ITEMS
      .filter(([, marker]) => text.includes(marker))
      .map(([, , label]) => label);
    if (!matched.length) {
      // 以「未检测到」开头但前端没登记该节点：仍然原样弹出，不能因为没登记就把它吞掉。
      details.push(text);
      return;
    }
    matched.forEach((label) => { if (!labels.includes(label)) labels.push(label); });
  });
  if (labels.length) {
    toast(`本次已自动跳过：${labels.join("、")}。原因见「高级参数」里的兼容性提示。`);
  }
  details.forEach((text) => toast(text));
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
      } catch (error) { if (type === "loras") throw error; return []; }
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
    fillDatalist(elements.samplerNameOptions, samplerNames);
    // 下拉与 datalist 一起填；若当前保存的采样器不在新列表里，只提示不强改
    // （用户可能有意使用自定义节点提供的采样器）。
    applySamplerPicker(samplerNames);
    markSamplerValidity(samplerNames);
    // 扫描后把旧保存的 LoRA 名归一化成当前库里的名字（文件可能被移入了子文件夹）。
    state.loras = state.loraModeDefaults
      ? []
      : state.loras
          .map((lora) => ({ ...lora, name: findModelName(state.models.lora, lora.name) || lora.name }))
          .filter((lora) => state.models.lora.includes(lora.name));
    syncAutomaticLora();
    renderLoras();
    await loraLibrary.refresh();

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
  elements.loraEmpty.classList.toggle("hidden", state.loras.some((item) => item.active !== false && item.name));
  loraLibrary.updateSelection();
  state.loras.forEach((lora, index) => {
    const row = document.createElement("div");
    row.className = "lora-row";

    const active = document.createElement("input");
    active.type = "checkbox";
    active.checked = lora.active !== false;
    active.title = "启用此 LoRA";
    active.addEventListener("change", () => { state.loraModeDefaults = false; state.loras[index].active = active.checked; elements.loraEmpty.classList.toggle("hidden", state.loras.some((item) => item.active !== false && item.name)); loraLibrary.updateSelection(); saveSettings(); });

    const select = document.createElement("select");
    state.models.lora.forEach((name) => appendOption(select, name));
    if (lora.name && !state.models.lora.includes(lora.name)) appendOption(select, lora.name, `未找到：${lora.name}`);
    select.value = lora.name || state.models.lora[0] || "";
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

// 读取媒体时长（视频 / 音频）。浏览器读不出 metadata 时返回 0，服务端照常登记这条素材。
function loadMediaDuration(file) {
  return new Promise((resolve) => {
    const isVideo = file.type.startsWith("video/");
    const node = document.createElement(isVideo ? "video" : "audio");
    const objectUrl = URL.createObjectURL(file);
    let settled = false;
    const finish = (value) => {
      if (settled) return;
      settled = true;
      URL.revokeObjectURL(objectUrl);
      resolve(value);
    };
    node.preload = "metadata";
    node.onloadedmetadata = () => finish(Number.isFinite(node.duration) ? Math.round(node.duration * 1000) / 1000 : 0);
    node.onerror = () => finish(0);
    // 兜底：部分编码浏览器读不出 metadata，别让上传流程卡在这里。
    setTimeout(() => finish(0), 2500);
    node.src = objectUrl;
  });
}

// 长视频导演台的参考素材要落进 input 下的子目录（timeline_data 里记的就是这个相对路径），
// 并按类型回传时间线需要的附加字段：图片给宽高，视频 / 音频给时长。
async function uploadDirectorAsset(file, subfolder) {
  const form = new FormData();
  form.append("image", file, file.name);
  form.append("type", "input");
  form.append("overwrite", "true");
  form.append("subfolder", subfolder);
  const result = await fetchJson(apiUrl("/api/upload"), { method: "POST", body: form }, 300000);
  const name = result.name || result.filename;
  const folder = result.subfolder != null && result.subfolder !== "" ? result.subfolder : subfolder;
  const payload = { file: `${folder}/${name}` };
  if (file.type.startsWith("image/")) {
    try {
      const dimensions = await loadImageDimensions(file);
      payload.width = dimensions.width;
      payload.height = dimensions.height;
    } catch {
      // 浏览器读不出尺寸（特殊编码）时留空，服务端照样登记这条参考素材。
    }
  } else {
    const seconds = await loadMediaDuration(file);
    if (seconds > 0) {
      payload.duration = seconds;
    } else {
      // 绝不传 0：节点侧会把 duration<=0 的参考视频整条丢弃（静默、无报错）。
      // 服务端会兜底成 5 秒，但截取范围会偏短，所以这里明确告诉用户换文件。
      toast(`没能读出「${file.name}」的时长，已按 5 秒计入参考（可能只截取开头一段）。换成标准编码的 MP4 可以避免。`, "error");
    }
  }
  return payload;
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
  if (images.length > 9) throw new Error("参考图片最多 9 张，请先移除多余的图片。");
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
        // 素材池变了：导演台分段里的素材勾选器要跟着重建，被删掉的文件不再出现在候选里。
        renderDirectorSegments();
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
  // 新增素材后重建导演台分段卡，让「本段参考图片 / 音频」的候选项立即出现。
  renderDirectorSegments();
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
    // 加速模式：节点没有 mode 输入时下拉被禁用并保留原值，服务端会按节点实际能力判断是否采纳。
    teMode: elements.teMode ? elements.teMode.value : "",
    cleanVram: elements.cleanVram.checked,
    rtxUpscale: elements.rtxUpscale.checked,
    rtxUpscaleScale: Math.max(1, Math.min(4, Math.round(Number(elements.rtxUpscaleScale.value) || 2))),
    // ---- 长视频导演台专用（只有 director 模式会被服务端读取）----
    // 主提示词框在导演台里是「全局提示词」：所有分段提示词都为空时由服务端复用到每一段。
    // 分段整份带过去（含提示词为空的），由服务端的同一套互斥规则决定用哪一套。
    directorGlobalPrompt: state.mode === "director" ? elements.promptInput.value.trim() : "",
    directorSegments: state.directorSegments.map((item) => ({
      prompt: String(item.prompt || "").trim(),
      duration: clampDuration(item.duration),
      imageNames: Array.isArray(item.imageNames) ? item.imageNames : null,
      audioNames: Array.isArray(item.audioNames) ? item.audioNames : null,
    })),
    directorSecondPass: elements.directorSecondPass ? elements.directorSecondPass.checked : true,
    directorSecondPassModel: elements.directorSecondPassModel ? elements.directorSecondPassModel.value.trim() : "",
    directorSecondPassSteps: elements.directorSecondPassSteps
      ? Math.max(1, Math.min(10, Number(elements.directorSecondPassSteps.value) || 2))
      : 2,
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
  const needsFirstFrame = !["t2v", "ref2va", "director"].includes(state.mode);
  if (needsFirstFrame && !state.firstFrame) return toast("当前模式需要上传首帧图片。", "error");
  if (state.mode === "flf2v" && !state.lastFrame) return toast("首尾帧模式还需要上传尾帧图片。", "error");
  if (state.mode === "ref2va" || state.mode === "director") {
    try {
      await validateReferenceFiles();
    } catch (error) {
      return toast(error.message, "error");
    }
  }
  if (state.mode === "director") {
    // 参考素材至少要有一种画面来源（图片或视频）——这一条已由上面的 validateReferenceFiles 保证。
    // 提示词按「全局 / 分段」的互斥规则校验，与素材规划台的语义一致。
    const promptMode = directorPromptMode();
    if (promptMode === "global" && !elements.promptInput.value.trim()) {
      return toast("请填写「全局提示词」，或给每一段分别填写提示词。", "error");
    }
    if (promptMode === "incomplete") {
      const emptyIndex = state.directorSegments.findIndex((item) => !String(item.prompt || "").trim());
      return toast(`第 ${emptyIndex + 1} 段还没填提示词：要么把每段都补全，要么把所有分段的提示词清空、改用全局提示词。`, "error");
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
    if (state.mode === "director") {
      // 三类参考素材都落进同一个子目录，服务端按类型分别组装成
      // timeline_data 的 images[] / videoClips[] / audios[]。
      config.directorImages = [];
      config.directorVideos = [];
      config.directorAudios = [];
      for (const file of state.referenceImages) {
        config.directorImages.push(await uploadDirectorAsset(file, DIRECTOR_IMAGE_FOLDER));
      }
      for (const file of state.referenceVideos) {
        config.directorVideos.push(await uploadDirectorAsset(file, DIRECTOR_IMAGE_FOLDER));
      }
      for (const file of state.referenceAudios) {
        config.directorAudios.push(await uploadDirectorAsset(file, DIRECTOR_IMAGE_FOLDER));
      }
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
  // 中断与报错必须分开判：ComfyUI 在 /interrupt 后往历史里写的是 execution_interrupted
  // （而不是 execution_error），但它同样会把 status_str 记成 error。若先按 error 判，用户自己
  // 停掉的任务会在别的标签页里被显示成「生成失败」。所以中断优先。
  const interrupted = messages.find((entry) => Array.isArray(entry) && entry[0] === "execution_interrupted");
  if (interrupted) {
    return { terminal: true, status: "cancelled", progress: 0, message: "任务已在 ComfyUI 中被中断（已停止）。" };
  }
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
  if (!task || isTaskTerminal(task)) return;
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
    // 标记「这次失败是兜底停下来的」，而不是 ComfyUI 真的报了错。
    // 有它任务卡片才会保留一个「重新查询」入口 —— 否则任务会被钉死在失败态，
    // 而提示里还写着「可以再查一次」，用户却找不到任何能点的按钮。
    task.pollingStopped = true;
    // 只在自动轮询时提示一次，避免手动刷新后反复弹同一个提示。
    if (wasPolling && !manual) toast(stopReason, "error");
  }
  persistTasks();
  renderTasks();
}

// 恢复一个被兜底停止的任务：重置计时与失败计数，重新开始轮询。
// 这是一次全新的跟踪，所以 pollingSince 必须重设 —— 否则刚恢复就会撞上同一个超时阈值，
// 用户点一下、界面闪一下又变回停止，等于按钮没用。
function resumeStoppedTask(taskId) {
  const task = state.tasks.find((item) => item.id === taskId);
  if (!task || !task.pollingStopped) return;
  task.pollingStopped = false;
  task.failures = 0;
  task.pollingSince = Date.now();
  task.status = "recovering";
  task.message = "已恢复自动查询，正在向 ComfyUI 确认任务状态…";
  persistTasks();
  renderTasks();
  startPolling(task.id, true);
  toast("已恢复查询。", "success");
}

// 停止任务：把用户在任务中心点的那一个任务从 ComfyUI 侧真正停掉。
// 排队中的会从队列移除，正在执行的会被中断；两者都不影响同队列里的其它任务。
async function cancelTask(taskId, button = null) {
  const task = state.tasks.find((item) => item.id === taskId);
  if (!task || isTaskTerminal(task)) return;
  // 停止会丢弃已经算出来的部分，属于不可撤销操作，先确认一次（与「清空任务」的处理保持一致）。
  const confirmed = window.confirm(
    "停止这个任务？\n\n" +
    "排队中的任务会从 ComfyUI 队列里移除；已经开始生成的任务会立即中断，本次生成作废。\n" +
    "该操作只影响这一个任务，不会打断其它任务。"
  );
  if (!confirmed) return;

  const originalText = button ? button.textContent : "";
  if (button) {
    button.disabled = true;
    button.textContent = "停止中…";
  }
  try {
    const result = await fetchJson(apiUrl("/api/cancel", task.comfyUrl), {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ promptId: task.id }),
    }, 30000);

    if (!result.stopped) {
      // 任务已经不在 ComfyUI 队列里（可能刚好跑完，或 ComfyUI 重启过）。
      // 这里**不伪造「已停止」**：只提示，并主动同步一次真实状态，避免界面与 ComfyUI 说法不一致。
      toast(result.message || "该任务已不在 ComfyUI 队列中。", "error");
      queryTask(task.id, true);
      return;
    }

    stopPolling(task.id);
    task.status = "cancelled";
    task.finishedAt = Date.now();
    task.elapsedMs = Math.max(0, task.finishedAt - Number(task.startedAt || task.createdAt || task.finishedAt));
    task.message = result.message || "任务已停止。";
    persistTasks();
    renderTasks();
    toast(task.message, "success");
    // 队列可能因为这次停止而空出来，顺手走一遍「任务边界」显存清理（队列非空时服务端会自动跳过）。
    cleanVramAfterTask(task.comfyUrl);
  } catch (error) {
    toast(error.message, "error");
  } finally {
    // 成功停止时卡片已经重绘、这个按钮已被换掉，isConnected 为 false，无需恢复。
    if (button && button.isConnected) {
      button.disabled = false;
      button.textContent = originalText;
    }
  }
}

function startPolling(taskId, immediate = false) {
  stopPolling(taskId);
  const task = state.tasks.find((item) => item.id === taskId);
  if (!task || isTaskTerminal(task)) return;
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
// 提示里点名的按钮必须是**任务卡片上**那个「恢复查询」：顶部的「重新查询」只处理仍在
// 查询中的任务，对已经停下来的任务它什么也不做（还会提示"没有需要恢复查询的任务"）。
function pollingStopReason(task) {
  if (task.pollingSince && Date.now() - task.pollingSince > MAX_POLL_DURATION_MS) {
    return `已连续查询超过 ${Math.round(MAX_POLL_DURATION_MS / 3600000)} 小时仍未取得结果，工作站已停止自动查询。任务可能已在 ComfyUI 中结束或被取消，可点这张卡片上的「恢复查询」再试一次。`;
  }
  if ((task.failures || 0) >= MAX_QUERY_FAILURES) {
    return `已连续 ${task.failures} 次无法查询 ComfyUI，工作站已停止自动查询。请确认 ComfyUI 仍在运行且地址正确，然后点这张卡片上的「恢复查询」重试。`;
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
  const terminal = isTaskTerminal(task);
  // 被兜底停止自动查询的任务即使没有输出，也要保留一个「恢复查询」入口，
  // 否则它会永远钉在失败态、界面上一个按钮都没有。
  const needsResume = terminal && Boolean(task.pollingStopped);
  if (!task.outputs?.length && terminal && !needsResume) {
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
  if (!terminal) {
    // 卡片上只留「停止任务」一个按钮。
    // 【为什么不做「立即查询」】自动轮询本来就只有 5 秒一次，而性能监控面板那种秒级场景
    // 才需要手动催一下；任务卡片上多一个"点了基本看不出变化"的按钮只会让人犹豫点哪个。
    // 真要立刻催一次，标题栏的「重新查询」会对所有未结束任务一起催，够用了。
    const stop = document.createElement("button");
    stop.type = "button";
    stop.className = "task-stop-button";
    stop.textContent = "停止任务";
    stop.addEventListener("click", () => cancelTask(task.id, stop));
    actions.appendChild(stop);
  } else if (needsResume) {
    const resume = document.createElement("button");
    resume.type = "button";
    // 叫「恢复查询」而不是「重新查询」：标题栏那个「重新查询」只对**未结束**的任务催一次，
    // 这个按钮是重置超时计时与失败计数、把自动轮询整个重新拉起来 —— 同名会让人以为是一回事。
    resume.textContent = "恢复查询";
    resume.addEventListener("click", () => resumeStoppedTask(task.id));
    actions.appendChild(resume);
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
    if (task && elapsed && !isTaskTerminal(task)) elapsed.textContent = `耗时 ${formatElapsed(task)}`;
  });
}

function updateTaskCard(card, task) {
  card.dataset.taskId = task.id;
  const videoOutput = task.outputs?.find((output) => output.mediaType === "videos" || /\.(mp4|webm|mov|mkv)$/i.test(output.filename));
  if (videoOutput) ensureTaskVideo(card, task, videoOutput);
  else card.querySelector("video[data-output-id]")?.remove();

  const terminal = isTaskTerminal(task);
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

  const labels = { queued: "等待中", running: "生成中", recovering: "状态恢复中", success: "已完成", failed: "生成失败", cancelled: "已停止" };
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
    if (isTaskTerminal(task) && !Number.isFinite(Number(task.elapsedMs))) {
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
    teMode: elements.teMode ? elements.teMode.value : "",
    directorSegments: state.directorSegments,
    directorSecondPass: elements.directorSecondPass ? elements.directorSecondPass.checked : true,
    directorSecondPassModel: elements.directorSecondPassModel ? elements.directorSecondPassModel.value : "",
    directorSecondPassSteps: elements.directorSecondPassSteps ? elements.directorSecondPassSteps.value : "2",
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
    const isActive = (task) => !isTaskTerminal(task);
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
  const activeCount = state.tasks.filter((task) => !isTaskTerminal(task)).length;
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
  // 存过的模式先写回下拉（此处 HTML 里已有兜底选项）；等 /api/capabilities 回来后会按
  // 节点真实声明的候选重建，届时若该值已不存在会自动回退到第一项。
  if (elements.teMode && settings.teMode) elements.teMode.value = settings.teMode;
  elements.cleanVram.checked = settings.cleanVram !== false;
  elements.rtxUpscale.checked = settings.rtxUpscale === true;
  elements.rtxUpscaleScale.value = ["1", "2", "3", "4"].includes(String(settings.rtxUpscaleScale)) ? String(settings.rtxUpscaleScale) : "2";
  // 长视频导演台：恢复追加的分镜与二采超分设置（分镜卡片由 updateMode → renderDirectorSegments 渲染）
  state.directorSegments = Array.isArray(settings.directorSegments)
    ? settings.directorSegments
        .filter((item) => item && typeof item.prompt === "string")
        .slice(0, MAX_DIRECTOR_SEGMENTS)
        .map((item) => {
          const segment = createDirectorSegment(item.prompt, item.duration);
          segment.imageNames = Array.isArray(item.imageNames) ? item.imageNames : null;
          segment.audioNames = Array.isArray(item.audioNames) ? item.audioNames : null;
          return segment;
        })
    : [];
  if (elements.directorSecondPass) elements.directorSecondPass.checked = settings.directorSecondPass !== false;
  if (elements.directorSecondPassModel) {
    elements.directorSecondPassModel.value = settings.directorSecondPassModel || "minimax_h3_latent_upscaler_3d_bf16.safetensors";
  }
  if (elements.directorSecondPassSteps) {
    elements.directorSecondPassSteps.value = settings.directorSecondPassSteps || "2";
  }
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
      if (!isTaskTerminal(task)) {
        task.pollingSince = Date.now();
        task.failures = 0;
      }
      return task;
    }) : [];
  } catch { state.tasks = []; }
  renderTasks();
  state.tasks.filter((task) => !isTaskTerminal(task)).forEach((task) => startPolling(task.id, true));
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
  // 按当前模式把拖入的文件自动归类：全能参考按图片/视频/音频分桶，图生/首尾帧取图片，
  // 长视频导演台按图片分桶（当前只把图片写进 timeline_data）。
  if (state.mode === "ref2va" || state.mode === "director") {
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
  toast("文生视频模式不使用素材文件；图生视频/首尾帧可拖入图片，全能参考可拖入图片、视频、音频，长视频导演台可拖入图片。", "error");
}

function bindEvents() {
  elements.testConnectionButton.addEventListener("click", () => testConnection());
  // 「重新检测」= 强制重新探测（fresh=1），供用户刚装完节点包时立刻看到变化。
  if (elements.selfCheckRefresh) {
    elements.selfCheckRefresh.addEventListener("click", async () => {
      elements.selfCheckRefresh.disabled = true;
      try {
        await loadSelfCheck(normalizeComfyUrl(), true);
      } finally {
        elements.selfCheckRefresh.disabled = false;
      }
    });
  }
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
  [elements.unetModel, elements.clipModel, elements.videoVae, elements.audioVae, elements.steps, elements.samplerName, elements.teControl, elements.teMode, elements.tePercent1, elements.tePercent2, elements.cleanVram, elements.rtxUpscale, elements.rtxUpscaleScale, elements.comfyUrl].forEach((element) => element && element.addEventListener("change", saveSettings));
  // 采样器：右边下拉是「从本机列表里挑」的动作入口，左边输入框负责自由填写。
  elements.samplerNamePicker?.addEventListener("change", () => {
    const value = elements.samplerNamePicker.value;
    if (!value) return;
    elements.samplerName.value = value;
    resetSamplerPicker();
    markSamplerValidity(samplerNameCache);
    updateSummary();
    saveSettings();
  });
  // 手打采样器名时即时判断这个名字本机到底有没有，并给出提示。
  elements.samplerName.addEventListener("input", () => {
    markSamplerValidity(samplerNameCache);
  });
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
    const active = state.tasks.filter((task) => !isTaskTerminal(task));
    active.forEach((task) => queryTask(task.id, true));
    if (!active.length) toast("没有需要恢复查询的任务。");
  });
  elements.clearTasksButton.addEventListener("click", clearCurrentTasks);
  elements.freeVramButton.addEventListener("click", freeVram);
  elements.checkUpdateButton.addEventListener("click", () => checkUpdate(true));
  elements.applyUpdateButton.addEventListener("click", applyUpdate);
  elements.dismissUpdateButton.addEventListener("click", dismissUpdate);
  document.addEventListener("visibilitychange", () => {
    if (!document.hidden) state.tasks.filter((task) => !isTaskTerminal(task)).forEach((task) => queryTask(task.id));
    // 性能监控：页面切到后台即停止轮询，切回且面板展开时恢复。
    if (document.hidden) stopPerfPolling("hidden"); else startPerfPolling();
  });
  // 性能监控面板：展开才开始轮询，收起立即停止（没人看的时候没必要刷）。
  if (elements.perfPanel) {
    elements.perfPanel.addEventListener("toggle", () => {
      if (elements.perfPanel.open) startPerfPolling(); else stopPerfPolling("collapsed");
    });
  }
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
