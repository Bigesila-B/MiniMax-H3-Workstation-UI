LoRA 模型库集成测试使用临时模型和自己生成的媒体，不提交真实 ComfyUI 生成任务。界面验证包括默认折叠和模型下载、删除入口的移除。

在项目根目录启动独立测试服务（保留原工作站服务）：

```powershell
$env:WORKSTATION_PORT = '8907'
$env:WORKSTATION_LORA_DATA = Join-Path (Get-Location) '.workbuddy\tmp\lora-test-data'
powershell -NoProfile -ExecutionPolicy Bypass -File .\server.ps1
```

另开终端运行：

```powershell
# NODE_PATH 指向包含 playwright 的 node_modules；ffmpeg 已在 PATH 时无需配置 LORA_FFMPEG。
$env:NODE_PATH = '<包含 playwright 的 node_modules 目录>'
$env:LORA_FFMPEG = '<ffmpeg.exe 的绝对路径>'
node tests/lora-library-smoke.cjs
```

测试会在 `127.0.0.1:8908` 建立临时 ComfyUI 列表服务，生成的模型、媒体、截图和报告保存在 `.workbuddy/tmp/`。自定义 `LORA_FIXTURE_DIR` 也必须位于该目录内。不要把测试资料目录设为真实模型目录。

覆盖元数据读取与保存、所有支持媒体格式、视频首帧和悬停播放、GIF 悬停切换、筛选收藏、多选、复制路径、上传、单文件与 ZIP 下载、Range 请求、路径与跨站保护、删除预检查、移动端布局，以及生成请求中的 LoRA 强度。失败时返回非零退出码。结束后关闭独立测试服务。

更新检测使用离线测试，不访问 GitHub 或启动服务：

```powershell
powershell -NoProfile -File tests/update-info-test.ps1
```

覆盖旧版发现新发行版、当前发行版无更新、缺少版本号、没有发行版时回退提交比较，以及缓存结果。
