$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
if (-not $root) { $root = Split-Path -Parent $MyInvocation.MyCommand.Path }
$port = if ($env:WORKSTATION_PORT) { [int]$env:WORKSTATION_PORT } else { 8000 }
Add-Type -AssemblyName System.Net.Http

# 复用同一个 HTTP 客户端，避免每次轮询都创建新连接。
$handler = New-Object System.Net.Http.HttpClientHandler
$handler.AllowAutoRedirect = $true
$http = New-Object System.Net.Http.HttpClient($handler)
$http.Timeout = [TimeSpan]::FromMinutes(3)

function Send-Bytes {
    param($Context, [byte[]]$Bytes, [string]$ContentType, [int]$StatusCode = 200)
    $Context.Response.StatusCode = $StatusCode
    if ($ContentType) { $Context.Response.ContentType = $ContentType }
    $Context.Response.ContentLength64 = $Bytes.Length
    $Context.Response.OutputStream.Write($Bytes, 0, $Bytes.Length)
}

function Send-Json {
    param($Context, $Data, [int]$StatusCode = 200)
    $json = if ($Data -is [string]) { $Data } else { $Data | ConvertTo-Json -Depth 100 -Compress }
    Send-Bytes $Context ([Text.Encoding]::UTF8.GetBytes($json)) 'application/json; charset=utf-8' $StatusCode
}

function Send-Error {
    param($Context, [string]$Message, [int]$StatusCode = 500)
    Send-Json $Context @{ error = $Message } $StatusCode
}

function Read-RequestBytes {
    param($Request)
    $memory = New-Object System.IO.MemoryStream
    $Request.InputStream.CopyTo($memory)
    return $memory.ToArray()
}

function Get-ComfyUrl {
    param($Request, $BodyObject = $null)
    $value = $Request.QueryString['comfy']
    if (-not $value -and $BodyObject -and $BodyObject.comfyUrl) { $value = [string]$BodyObject.comfyUrl }
    if (-not $value) { $value = 'http://127.0.0.1:8188' }
    $value = $value.Trim().TrimEnd('/')
    if ($value -notmatch '^https?://') { throw 'ComfyUI 地址必须以 http:// 或 https:// 开头。' }
    return $value
}

function Get-AiPromptConfig {
    $configPath = Join-Path $root 'AI提示词配置.json'
    if (-not (Test-Path $configPath -PathType Leaf)) { throw '找不到 AI提示词配置.json。' }
    return Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
}

function Get-ChatCompletionsUrl {
    param([string]$BaseUrl)
    $value = $BaseUrl.Trim().TrimEnd('/')
    if ($value -notmatch '^https?://') { throw 'AI 模型 URL 必须以 http:// 或 https:// 开头。' }
    if ($value -match '/chat/completions$') { return $value }
    return "$value/chat/completions"
}

function Invoke-AiPrompt {
    param($RequestData)
    $config = Get-AiPromptConfig
    $model = @($config.'模型') | Where-Object { [string]$_.id -eq [string]$RequestData.modelId } | Select-Object -First 1
    if (-not $model) { throw '配置文件中不存在所选 AI 模型 ID。' }
    $template = @($config.'提示词模板') | Where-Object { [string]$_.id -eq [string]$RequestData.templateId } | Select-Object -First 1
    if (-not $template) { throw '配置文件中不存在所选提示词模板。' }
    if (-not $model.api_key -or [string]$model.api_key -match '^请在这里') { throw '请先在 AI提示词配置.json 中填写所选模型的 API Key。' }

    $question = [string]$RequestData.question
    if ([string]::IsNullOrWhiteSpace($question)) { throw '请输入用于生成提示词的创意或要求。' }
    $images = @($RequestData.images)
    if (-not [bool]$model.supports_images) { $images = @() }
    foreach ($image in $images) {
        $imageUrl = [string]$image
        if ($imageUrl -notmatch '^data:image/(png|jpeg|webp);base64,') { throw '图片数据格式不受支持。' }
        if ($imageUrl.Length -gt 12000000) { throw '单张图片数据过大，请压缩后重试。' }
    }

    $retryCount = if ($null -ne $model.retry_count) { [Math]::Max(0, [Math]::Min(5, [int]$model.retry_count)) } else { 2 }
    $allowTextFallback = $images.Count -gt 0 -and [bool]$model.fallback_to_text_on_image_error
    $attemptModes = @($true)
    if ($allowTextFallback) { $attemptModes += $false }
    $lastError = '未知错误'

    foreach ($useImages in $attemptModes) {
        $activeImages = if ($useImages) { $images } else { @() }
        for ($attempt = 0; $attempt -le $retryCount; $attempt++) {
            $userContent = if ($activeImages.Count -gt 0) {
                $parts = @([pscustomobject]@{ type = 'text'; text = $question })
                foreach ($image in $activeImages) {
                    $parts += [pscustomobject]@{ type = 'image_url'; image_url = [pscustomobject]@{ url = [string]$image } }
                }
                $parts
            } else { $question }

            $payloadObject = [ordered]@{
                model = [string]$model.id
                messages = @(
                    [ordered]@{ role = 'system'; content = [string]$template.system_prompt },
                    [ordered]@{ role = 'user'; content = $userContent }
                )
                temperature = if ($null -ne $model.temperature) { [double]$model.temperature } else { 0.7 }
                max_tokens = if ($model.max_tokens) { [int]$model.max_tokens } else { 8192 }
                stream = $false
            }
            $payload = $payloadObject | ConvertTo-Json -Depth 20 -Compress
            $url = Get-ChatCompletionsUrl ([string]$model.url)
            $message = New-Object System.Net.Http.HttpRequestMessage([System.Net.Http.HttpMethod]::Post, $url)
            $message.Headers.TryAddWithoutValidation('Authorization', "Bearer $([string]$model.api_key)") | Out-Null
            $message.Headers.TryAddWithoutValidation('Accept', 'application/json') | Out-Null
            $message.Content = New-Object System.Net.Http.StringContent($payload, [Text.Encoding]::UTF8, 'application/json')

            try {
                $response = $http.SendAsync($message).GetAwaiter().GetResult()
                $text = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
                if ($response.IsSuccessStatusCode) {
                    $result = $text | ConvertFrom-Json
                    $content = [string]$result.choices[0].message.content
                    if ([string]::IsNullOrWhiteSpace($content)) { throw 'AI 服务未返回提示词内容。' }
                    return $content.Trim()
                }

                $statusCode = [int]$response.StatusCode
                $detail = ''
                try {
                    $errorData = $text | ConvertFrom-Json
                    if ($errorData.error.message) { $detail = [string]$errorData.error.message }
                    elseif ($errorData.detail) { $detail = [string]$errorData.detail }
                    elseif ($errorData.message) { $detail = [string]$errorData.message }
                } catch {
                    if ($text -and $text.Length -le 600) { $detail = $text.Trim() }
                }
                $lastError = "AI 服务返回 HTTP $statusCode"
                if ($detail) { $lastError += "：$detail" }
                $retryable = $statusCode -in @(408, 429, 500, 502, 503, 504)
                if (-not $retryable -or $attempt -ge $retryCount) { break }
            } catch {
                $lastError = $_.Exception.Message
                if ($attempt -ge $retryCount) { break }
            } finally {
                try { $message.Dispose() } catch {}
            }

            Start-Sleep -Milliseconds ([Math]::Min(3000, 500 * [Math]::Pow(2, $attempt)))
        }
    }

    if ($allowTextFallback) {
        throw "$lastError。视觉请求和自动纯文字降级均失败；这属于 AI 提示词服务故障，不会影响直接填写提示词后生成视频。"
    }
    throw "$lastError。AI 提示词服务当前不可用；可直接在提示词框填写内容并生成视频。"
}

function Invoke-Comfy {
    param(
        [string]$Method,
        [string]$Url,
        [byte[]]$Body = $null,
        [string]$ContentType = $null
    )
    $request = New-Object System.Net.Http.HttpRequestMessage([System.Net.Http.HttpMethod]::new($Method), $Url)
    if ($null -ne $Body) {
        $content = New-Object System.Net.Http.ByteArrayContent(,$Body)
        if ($ContentType) { $content.Headers.TryAddWithoutValidation('Content-Type', $ContentType) | Out-Null }
        $request.Content = $content
    }
    $response = $http.SendAsync($request).GetAwaiter().GetResult()
    $bytes = $response.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
    $responseType = if ($response.Content.Headers.ContentType) { $response.Content.Headers.ContentType.ToString() } else { 'application/octet-stream' }
    return @{ StatusCode = [int]$response.StatusCode; Bytes = $bytes; ContentType = $responseType; Success = $response.IsSuccessStatusCode }
}

function Get-Node {
    param($Workflow, [string]$Id)
    $property = $Workflow.PSObject.Properties[$Id]
    if (-not $property) { throw "工作流缺少节点 $Id" }
    return $property.Value
}

function Set-InputValue {
    param($Workflow, [string]$NodeId, [string]$InputName, $Value)
    $node = Get-Node $Workflow $NodeId
    if (-not $node.inputs) { $node | Add-Member -NotePropertyName inputs -NotePropertyValue ([pscustomobject]@{}) }
    $inputProperty = $node.inputs.PSObject.Properties[$InputName]
    if ($inputProperty) { $inputProperty.Value = $Value } else { $node.inputs | Add-Member -NotePropertyName $InputName -NotePropertyValue $Value }
}

function Set-LoraManagerInputs {
    param($Workflow, [string]$NodeId, $Loras)
    $loraNode = Get-Node $Workflow $NodeId
    $loraText = @()
    $loraValues = @()
    foreach ($lora in @($Loras)) {
        if (-not $lora.name) { continue }
        $strength = [double]$lora.strength
        $name = [string]$lora.name
        $loraText += ('<lora:{0}:{1:0.00}>' -f $name, $strength)
        # 当前 LoraManager 的 API 执行代码不会读取 text，而是读取动态 loras.__value__ 输入。
        # 仅写 text 会让节点正常运行但实际不加载任何 LoRA。
        $loraValues += [pscustomobject]@{
            name = $name
            strength = $strength
            clipStrength = $strength
            active = $true
            expanded = $false
            selected = $true
            locked = $false
        }
    }
    Set-InputValue $Workflow $NodeId 'text' ($loraText -join ' ')
    if ($loraValues.Count -gt 0) {
        Set-InputValue $Workflow $NodeId 'loras' ([pscustomobject]@{ __value__ = @($loraValues) })
    } elseif ($loraNode.inputs.PSObject.Properties['loras']) {
        $loraNode.inputs.PSObject.Properties.Remove('loras')
    }
    return $loraText
}

function Remove-WorkflowNode {
    param($Workflow, [string]$NodeId)
    if ($Workflow.PSObject.Properties[$NodeId]) {
        $Workflow.PSObject.Properties.Remove($NodeId)
    }
}

function Normalize-AspectRatio {
    param([string]$Value)
    $aliases = @{
        '1:1' = '1:1 (Square)'
        '1:1 (Square)' = '1:1 (Square)'
        '2:3' = '2:3 (Portrait Photo)'
        '2:3 (Portrait)' = '2:3 (Portrait Photo)'
        '2:3 (Portrait Photo)' = '2:3 (Portrait Photo)'
        '3:2' = '3:2 (Photo)'
        '3:2 (Landscape)' = '3:2 (Photo)'
        '3:2 (Photo)' = '3:2 (Photo)'
        '3:4' = '3:4 (Portrait Standard)'
        '3:4 (Portrait Standard)' = '3:4 (Portrait Standard)'
        '4:3' = '4:3 (Standard)'
        '4:3 (Landscape Standard)' = '4:3 (Standard)'
        '4:3 (Standard)' = '4:3 (Standard)'
        '9:16' = '9:16 (Portrait Widescreen)'
        '9:16 (Portrait)' = '9:16 (Portrait Widescreen)'
        '9:16 (Portrait Widescreen)' = '9:16 (Portrait Widescreen)'
        '16:9' = '16:9 (Widescreen)'
        '16:9 (Landscape)' = '16:9 (Widescreen)'
        '16:9 (Widescreen)' = '16:9 (Widescreen)'
        '21:9' = '21:9 (Ultrawide)'
        '21:9 (Ultrawide)' = '21:9 (Ultrawide)'
    }
    $normalizedInput = if ($null -eq $Value) { '' } else { $Value.Trim() }
    if (-not $aliases.ContainsKey($normalizedInput)) {
        throw "不支持的画面比例：$normalizedInput"
    }
    return $aliases[$normalizedInput]
}

function Get-SafeSeed {
    param($Value)
    # ComfyUI 工作流节点这里最终按 Int64 接收种子；前端旧版可能生成超过 Int64 上限的 64 位无符号数。
    # 对缺失、负数、过大或无法解析的值回退到安全的非负种子，避免整次任务提交失败。
    $fallback = [int64]([DateTime]::UtcNow.Ticks % 2147483647)
    try {
        if ($null -eq $Value) { return $fallback }
        $decimal = [decimal]$Value
        $maxInt64 = [decimal][long]::MaxValue
        if ($decimal -lt 0 -or $decimal -gt $maxInt64) { return $fallback }
        return [int64]$decimal
    } catch {
        return $fallback
    }
}

function Convert-UiWorkflowToApi {
    param($UiWorkflow)
    $linkMap = @{}
    foreach ($link in @($UiWorkflow.links)) {
        if ($link.Count -ge 5) {
            $linkMap[[string]$link[0]] = @{ node = [string]$link[1]; slot = [int]$link[2] }
        }
    }
    $api = [ordered]@{}
    foreach ($node in @($UiWorkflow.nodes)) {
        $inputs = [ordered]@{}
        $widgetIndex = 0
        foreach ($input in @($node.inputs)) {
            $hasWidget = $null -ne $input.widget
            $widgetValue = if ($hasWidget -and $null -ne $node.widgets_values -and $widgetIndex -lt @($node.widgets_values).Count) { @($node.widgets_values)[$widgetIndex] } else { $null }
            if ($hasWidget) { $widgetIndex++ }
            # 这些字段只用于 ComfyUI 画布上传控件，不是 API 工作流输入。
            $isUiOnly = [string]$input.name -in @('upload', 'audioUI')
            if ($isUiOnly) { continue }
            if ($null -ne $input.link) {
                $link = $linkMap[[string]$input.link]
                if ($link) { $inputs[[string]$input.name] = @($link.node, $link.slot) }
            } elseif ($hasWidget) {
                $inputs[[string]$input.name] = $widgetValue
            }
        }
        $api[[string]$node.id] = [pscustomobject]@{
            inputs = [pscustomobject]$inputs
            class_type = [string]$node.type
            _meta = [pscustomobject]@{ title = if ($node.title) { [string]$node.title } else { [string]$node.type } }
        }
    }
    return ($api | ConvertTo-Json -Depth 100 -Compress | ConvertFrom-Json)
}

function Add-WorkflowNode {
    param($Workflow, [string]$NodeId, [string]$ClassType, $Inputs)
    $node = [pscustomobject]@{ inputs = [pscustomobject]$Inputs; class_type = $ClassType; _meta = [pscustomobject]@{ title = $ClassType } }
    $Workflow | Add-Member -NotePropertyName $NodeId -NotePropertyValue $node
    return $node
}

function Remove-InputValue {
    param($Workflow, [string]$NodeId, [string]$InputName)
    $node = Get-Node $Workflow $NodeId
    if ($node.inputs.PSObject.Properties[$InputName]) { $node.inputs.PSObject.Properties.Remove($InputName) }
}

function Get-ReferenceFrameLength {
    param([double]$Duration)
    $seconds = [Math]::Max(1, [Math]::Min(15, $Duration))
    $frames = 5 + [Math]::Round(($seconds * 24 - 5) / 17) * 17
    return [int][Math]::Max(5, $frames)
}

function Get-ReferenceResolution {
    param([string]$AspectRatio, [double]$Megapixels)
    $ratioMap = @{
        '1:1 (Square)' = 1.0
        '2:3 (Portrait Photo)' = (2.0 / 3.0)
        '3:2 (Photo)' = (3.0 / 2.0)
        '3:4 (Portrait Standard)' = (3.0 / 4.0)
        '4:3 (Standard)' = (4.0 / 3.0)
        '9:16 (Portrait Widescreen)' = (9.0 / 16.0)
        '16:9 (Widescreen)' = (16.0 / 9.0)
        '21:9 (Ultrawide)' = (21.0 / 9.0)
    }
    $ratio = if ($ratioMap.ContainsKey($AspectRatio)) { [double]$ratioMap[$AspectRatio] } else { 1.0 }
    $area = [Math]::Max(0.1, [Math]::Min(2.0, $Megapixels)) * 1000000
    $height = [Math]::Max(32, [int]([Math]::Sqrt($area / $ratio) / 32) * 32)
    $width = [Math]::Max(32, [int]([Math]::Sqrt($area * $ratio) / 32) * 32)
    return [pscustomobject]@{ width = $width; height = $height }
}

function Get-ReferenceVideoLoader {
    param([string]$ComfyUrl)
    try {
        $remote = Invoke-Comfy 'GET' "$ComfyUrl/object_info"
        if ($remote.Success) {
            # 不只依赖 ConvertFrom-Json 后的 PSObject 属性索引：部分 PowerShell/ComfyUI
            # 组合在超大 object_info 响应下会出现属性索引误判，但原始 JSON 中节点确实存在。
            $jsonText = [Text.Encoding]::UTF8.GetString($remote.Bytes)
            if ($jsonText -match '"VHS_LoadVideo"\s*:') { return 'VHS_LoadVideo' }
            $info = $jsonText | ConvertFrom-Json
            $loadVideo = $info.PSObject.Properties['LoadVideo']
            if ($loadVideo -and @($loadVideo.Value.output) -contains 'IMAGE') { return 'LoadVideo' }
        }
    } catch {}
    throw '当前 ComfyUI 未提供可将视频转换为 IMAGE 帧序列的 VHS_LoadVideo 节点，暂时不能提交视频参考。请安装 VideoHelperSuite 后重试。'
}

function Build-ReferenceWorkflow {
    param($Config, $Workflow, [string]$ComfyUrl)
    # 新版全能参考工作流是 API 格式，节点 ID 与旧版不同；这里集中做参数注入，UI 不需要变化。
    $referenceNode = '136'
    $unetNode = '127'
    $clipNode = '128'
    $videoVaeNode = '119'
    $audioVaeNode = '120'
    $noiseNode = '129'
    $durationNode = '132'
    $resolutionNode = '171'
    $samplerNode = '123'
    $schedulerNode = '124'
    $loraNodeId = '167'
    $speedNode = '168'

    Set-InputValue $Workflow $unetNode 'unet_name' ([string]$Config.unet)
    Set-InputValue $Workflow $clipNode 'clip_name' ([string]$Config.clip)
    Set-InputValue $Workflow $videoVaeNode 'vae_name' ([string]$Config.videoVae)
    Set-InputValue $Workflow $audioVaeNode 'vae_name' ([string]$Config.audioVae)
    Set-InputValue $Workflow $durationNode 'value' ([double]$Config.duration)
    Set-InputValue $Workflow $noiseNode 'noise_seed' (Get-SafeSeed $Config.seed)

    # Ref2VA 使用独立的 BasicScheduler / KSamplerSelect 节点，不能复用普通模式的 105:* 节点。
    # 之前 UI 虽然提交了 steps、samplerName 和 TE-Speed 参数，但这里没有注入，导致实际始终按
    # JSON 默认的 4 步运行，也是 UI 速度异常快、改步数无明显效果的直接原因。
    Set-InputValue $Workflow $schedulerNode 'steps' ([int]$Config.steps)
    Set-InputValue $Workflow $samplerNode 'sampler_name' ([string]$Config.samplerName)
    Set-InputValue $Workflow $speedNode 'processing_control_value' ([double]$Config.teControl)
    Set-InputValue $Workflow $speedNode 'processing_percent_1' ([double]$Config.tePercent1)
    Set-InputValue $Workflow $speedNode 'processing_percent_2' ([double]$Config.tePercent2)

    $aspectRatio = Normalize-AspectRatio ([string]$Config.aspectRatio)
    Set-InputValue $Workflow $resolutionNode 'aspect_ratio' $aspectRatio
    Set-InputValue $Workflow $resolutionNode 'megapixels' ([double]$Config.megapixels)

    Set-InputValue $Workflow $referenceNode 'prompt' ([string]$Config.prompt)
    Set-InputValue $Workflow $referenceNode 'length' @('131', 1)
    Set-InputValue $Workflow $referenceNode 'width' @($resolutionNode, 0)
    Set-InputValue $Workflow $referenceNode 'height' @($resolutionNode, 1)

    $loraText = Set-LoraManagerInputs $Workflow $loraNodeId $Config.loras
    $modelLink = if ($loraText.Count -gt 0) { @($loraNodeId, 0) } else { @($unetNode, 0) }
    Set-InputValue $Workflow $speedNode 'model' $modelLink

    $imageNames = @($Config.referenceImages)
    $videoNames = @($Config.referenceVideos)
    $audioNames = @($Config.referenceAudios)
    # 按全能参考官方规格保留最多 9 张图片、3 段视频、3 段音频，全部素材合计最多 12 个。
    if ($imageNames.Count -gt 9 -or $videoNames.Count -gt 3 -or $audioNames.Count -gt 3) { throw '全能参考模式最多接入 9 张图片、3 段视频和 3 段音频。' }
    if (($imageNames.Count + $videoNames.Count + $audioNames.Count) -gt 12) { throw '图片、视频和音频参考素材合计不能超过 12 个。' }
    if ($imageNames.Count -eq 0 -and $videoNames.Count -eq 0) { throw '音频不能单独提交，请至少上传图片或视频参考。' }

    $nextId = 1000
    foreach ($property in $Workflow.PSObject.Properties) {
        try { $nextId = [Math]::Max($nextId, [int]$property.Name + 1) } catch {}
    }
    for ($i = 0; $i -lt 9; $i++) {
        $inputName = "ref_images.ref_image_$i"
        if ($i -lt $imageNames.Count) {
            $nodeId = if ($i -eq 0) { '137' } elseif ($i -eq 1) { '169' } else { [string]$nextId++ }
            if (-not $Workflow.PSObject.Properties[$nodeId]) { Add-WorkflowNode $Workflow $nodeId 'LoadImage' ([ordered]@{ image = [string]$imageNames[$i] }) | Out-Null }
            else { Set-InputValue $Workflow $nodeId 'image' ([string]$imageNames[$i]) }
            Set-InputValue $Workflow $referenceNode $inputName @($nodeId, 0)
        } else { Remove-InputValue $Workflow $referenceNode $inputName }
    }

    $videoLoader = $null
    if ($videoNames.Count -gt 0) { $videoLoader = Get-ReferenceVideoLoader $ComfyUrl }
    for ($i = 0; $i -lt 3; $i++) {
        $videoInputName = "ref_videos.ref_video_$i"
        $videoAudioInputName = "ref_video_audios.ref_video_audio_$i"
        if ($i -lt $videoNames.Count) {
            $videoNodeId = if ($i -eq 0) { '141' } else { [string]$nextId++ }
            $videoName = [string]$videoNames[$i]
            if (-not $Workflow.PSObject.Properties[$videoNodeId]) {
                if ($videoLoader -eq 'VHS_LoadVideo') {
                    Add-WorkflowNode $Workflow $videoNodeId $videoLoader ([ordered]@{ video = $videoName; force_rate = 24; custom_width = 0; custom_height = 0; frame_load_cap = @('144', 0); skip_first_frames = 0; select_every_nth = 1; format = 'AnimateDiff' }) | Out-Null
                } else { Add-WorkflowNode $Workflow $videoNodeId $videoLoader ([ordered]@{ file = $videoName }) | Out-Null }
            } elseif ($videoLoader -eq 'VHS_LoadVideo') {
                Set-InputValue $Workflow $videoNodeId 'video' $videoName
            } else {
                Set-InputValue $Workflow $videoNodeId 'file' $videoName
            }
            Set-InputValue $Workflow $referenceNode $videoInputName @($videoNodeId, 0)
            Set-InputValue $Workflow $referenceNode $videoAudioInputName @($videoNodeId, 2)
        } else {
            Remove-InputValue $Workflow $referenceNode $videoInputName
            Remove-InputValue $Workflow $referenceNode $videoAudioInputName
        }
    }

    # 独立音频接入新版节点的 ref_audios.* 端口，不与视频原声端口混用。
    for ($i = 0; $i -lt 3; $i++) {
        if ($i -lt $audioNames.Count) {
            $audioNodeId = if ($i -eq 0) { '170' } else { [string]$nextId++ }
            if (-not $Workflow.PSObject.Properties[$audioNodeId]) { Add-WorkflowNode $Workflow $audioNodeId 'LoadAudio' ([ordered]@{ audio = [string]$audioNames[$i] }) | Out-Null }
            else { Set-InputValue $Workflow $audioNodeId 'audio' ([string]$audioNames[$i]) }
            Set-InputValue $Workflow $referenceNode "ref_audios.ref_audio_$i" @($audioNodeId, 0)
        } else {
            Remove-InputValue $Workflow $referenceNode "ref_audios.ref_audio_$i"
        }
    }


    # 提示词已由网页独立生成并直接写入节点 136；移除工作流残留的 AI 节点与模板，
    # 防止无关 API Key、自定义节点校验或旧结果影响最终提交。
    Remove-WorkflowNode $Workflow '164'
    Remove-WorkflowNode $Workflow '165'
    Remove-WorkflowNode $Workflow '166'

    return $Workflow
}

function Build-Workflow {
    param($Config, [string]$ComfyUrl)
    $allowedFiles = @(
        'minimaxH3文生视频基础加速流.json',
        'minimaxH3图生视频基础加速流.json',
        'minimaxH3首尾帧视频基础加速流.json',
        '图片+音频参考加速ai提示词工作流.json',
        'minimaxh3全能参考(图片+视频+音频)+ai提示词生成+加速+Lora.json'
    )
    $workflowFile = [string]$Config.workflowFile
    if ($allowedFiles -notcontains $workflowFile) { throw '不允许使用指定的工作流文件。' }
    $workflowPath = Join-Path $root $workflowFile
    if (-not (Test-Path $workflowPath -PathType Leaf)) { throw "找不到工作流：$workflowFile" }
    $workflow = Get-Content -LiteralPath $workflowPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ([string]$Config.mode -eq 'ref2va') {
        # 新版文件本身已经是 API 工作流；保留旧版 UI 工作流的转换兼容。
        if ($workflow.PSObject.Properties['nodes']) { $workflow = Convert-UiWorkflowToApi $workflow }
        return Build-ReferenceWorkflow $Config $workflow $comfyUrl
    }

    $duration = [Math]::Max(1, [Math]::Min(15, [int]$Config.duration))
    Set-InputValue $workflow '105:111' 'value' $duration
    # MiniMax H3 接受 5 + 17n 帧。按 24fps 将秒数映射到最接近的合法帧数，而不是旧版一律向上取整。
    Set-InputValue $workflow '105:107' 'expression' 'max(5, 5 + round((a * 24 - 5) / 17) * 17)'
    # ResolutionSelector 的 COMBO 值必须逐字匹配。这里同时兼容旧版网页保存在 localStorage 中的名称。
    $aspectRatio = Normalize-AspectRatio ([string]$Config.aspectRatio)
    Set-InputValue $workflow '115' 'aspect_ratio' $aspectRatio
    Set-InputValue $workflow '115' 'megapixels' ([double]$Config.megapixels)
    Set-InputValue $workflow '105:6' 'unet_name' ([string]$Config.unet)
    Set-InputValue $workflow '105:13' 'clip_name' ([string]$Config.clip)
    Set-InputValue $workflow '105:11' 'vae_name' ([string]$Config.videoVae)
    Set-InputValue $workflow '105:24' 'vae_name' ([string]$Config.audioVae)
    Set-InputValue $workflow '105:9' 'steps' ([int]$Config.steps)
    Set-InputValue $workflow '105:15' 'noise_seed' (Get-SafeSeed $Config.seed)
    Set-InputValue $workflow '105:17' 'sampler_name' ([string]$Config.samplerName)
    Set-InputValue $workflow '105:122' 'processing_control_value' ([double]$Config.teControl)
    Set-InputValue $workflow '105:122' 'processing_percent_1' ([double]$Config.tePercent1)
    Set-InputValue $workflow '105:122' 'processing_percent_2' ([double]$Config.tePercent2)

    if ($Config.firstFrame -and $workflow.PSObject.Properties['114']) {
        Set-InputValue $workflow '114' 'image' ([string]$Config.firstFrame)
    }
    if ($Config.lastFrame -and $workflow.PSObject.Properties['134']) {
        Set-InputValue $workflow '134' 'image' ([string]$Config.lastFrame)
    }

    # AI 提示词在提交视频前由独立接口生成并回填文本框，因此工作流始终接收最终文本。
    Set-InputValue $workflow '105:104' 'prompt' ([string]$Config.prompt)
    # ComfyUI 会校验并可能执行工作流中未连到最终输出的自定义节点。彻底移除 AI 节点，
    # 防止旧 JSON 里的 Agnes API 故障、无效 Key 或节点验证错误阻断视频生成。
    Remove-WorkflowNode $workflow '105:123'
    Remove-WorkflowNode $workflow '105:124'
    Remove-WorkflowNode $workflow '105:132'

    $loraText = Set-LoraManagerInputs $workflow '105:129' $Config.loras
    $loraCount = $loraText.Count

    # 无 LoRA 时绕过 LoraManager；有 LoRA 时保留本地 JSON 的 UNET -> LoRA -> TE-Speed 加速链。
    $speedModel = if ($loraCount -gt 0) { @('105:129', 0) } else { @('105:6', 0) }
    Set-InputValue $workflow '105:122' 'model' $speedModel
    return $workflow
}

$listener = $null
$isLan = $false
$lanAddresses = @()
try {
    $lanAddresses = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop |
        Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.*' } |
        Select-Object -ExpandProperty IPAddress)
} catch {}

# HTTP.sys 对 + 通配符需要 URL ACL；失败时改为逐个绑定本机 IPv4，避免手机请求被拦截为 Invalid Hostname。
try {
    $l = New-Object System.Net.HttpListener
    foreach ($address in $lanAddresses) { $l.Prefixes.Add("http://${address}:$port/") }
    $l.Prefixes.Add("http://127.0.0.1:$port/")
    $l.Prefixes.Add("http://localhost:$port/")
    $l.Start()
    $listener = $l
    $isLan = $lanAddresses.Count -gt 0
} catch {
    try { $l.Stop() } catch {}
    try {
        $l2 = New-Object System.Net.HttpListener
        $l2.Prefixes.Add("http://127.0.0.1:$port/")
        $l2.Prefixes.Add("http://localhost:$port/")
        $l2.Start()
        $listener = $l2
    } catch {
        try { $l2.Stop() } catch {}
    }
}

if (-not $listener) {
    Write-Host "启动失败：8000 端口被占用或无权限，请关闭占用程序后重试。" -ForegroundColor Red
    Read-Host "按回车退出"
    exit 1
}

Write-Host "================================================" -ForegroundColor Cyan
Write-Host "  MiniMax H3 视频工作站 · 服务运行中" -ForegroundColor Cyan
Write-Host "================================================" -ForegroundColor Cyan
Write-Host "  本机访问:  http://127.0.0.1:$port/"
if ($isLan) {
    try {
        Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.*' } |
            ForEach-Object { Write-Host "  局域网访问: http://$($_.IPAddress):$port/  (手机/其它电脑可用)" -ForegroundColor Green }
    } catch {}
} else {
    Write-Host "  提示: 当前仅本机可访问。若需局域网访问，请右键以管理员身份运行启动脚本。" -ForegroundColor Yellow
}
Write-Host ""
Write-Host "  ComfyUI 请求由本服务代理，手机端无需直接访问 8188 端口。" -ForegroundColor DarkGray
Write-Host "  关闭本窗口即停止服务。" -ForegroundColor DarkGray
Write-Host "================================================" -ForegroundColor Cyan

$mime = @{
    '.html'='text/html; charset=utf-8'; '.js'='text/javascript; charset=utf-8'; '.css'='text/css; charset=utf-8'
    '.json'='application/json; charset=utf-8'; '.svg'='image/svg+xml'; '.png'='image/png'; '.jpg'='image/jpeg'
    '.jpeg'='image/jpeg'; '.webp'='image/webp'; '.gif'='image/gif'; '.ico'='image/x-icon'
    '.mp4'='video/mp4'; '.webm'='video/webm'; '.woff2'='font/woff2'; '.woff'='font/woff'
    '.txt'='text/plain; charset=utf-8'; '.map'='application/json; charset=utf-8'
}

while ($listener.IsListening) {
    $ctx = $listener.GetContext()
    try {
        $path = $ctx.Request.Url.AbsolutePath
        $method = $ctx.Request.HttpMethod.ToUpperInvariant()

        if ($path -eq '/api/ai-config' -and $method -eq 'GET') {
            $config = Get-AiPromptConfig
            $models = @($config.'模型') | ForEach-Object { [pscustomobject]@{ id = [string]$_.id; supportsImages = [bool]$_.supports_images } }
            $templates = @($config.'提示词模板') | ForEach-Object {
                $templateName = if ($_.name) { [string]$_.name } else { [string]$_.id }
                [pscustomobject]@{ id = [string]$_.id; name = $templateName }
            }
            Send-Json $ctx @{ models = $models; templates = $templates; defaultModel = [string]$config.'默认模型'; defaultTemplate = [string]$config.'默认模板' }
        }
        elseif ($path -eq '/api/ai-prompt' -and $method -eq 'POST') {
            $bodyBytes = Read-RequestBytes $ctx.Request
            if ($bodyBytes.Length -gt 50000000) { throw 'AI 提示词请求过大，请减少或压缩图片。' }
            $bodyObject = [Text.Encoding]::UTF8.GetString($bodyBytes) | ConvertFrom-Json
            $prompt = Invoke-AiPrompt $bodyObject
            Send-Json $ctx @{ prompt = $prompt }
        }
        elseif ($path -eq '/api/health' -and $method -eq 'GET') {
            $comfy = Get-ComfyUrl $ctx.Request
            $remote = Invoke-Comfy 'GET' "$comfy/system_stats"
            if (-not $remote.Success) { throw "ComfyUI 返回 HTTP $($remote.StatusCode)" }
            $stats = [Text.Encoding]::UTF8.GetString($remote.Bytes) | ConvertFrom-Json
            $deviceName = $stats.devices[0].name
            Send-Json $ctx @{ ok = $true; device = if ($deviceName) { $deviceName } else { 'ComfyUI 已连接' } }
        }
        elseif ($path -eq '/api/object-info' -and $method -eq 'GET') {
            $comfy = Get-ComfyUrl $ctx.Request
            $remote = Invoke-Comfy 'GET' "$comfy/object_info"
            Send-Bytes $ctx $remote.Bytes $remote.ContentType $remote.StatusCode
        }
        elseif ($path -eq '/api/progress' -and $method -eq 'GET') {
            $comfy = Get-ComfyUrl $ctx.Request
            $remote = Invoke-Comfy 'GET' "$comfy/progress"
            Send-Bytes $ctx $remote.Bytes $remote.ContentType $remote.StatusCode
        }
        elseif ($path -eq '/api/model-list' -and $method -eq 'GET') {
            $comfy = Get-ComfyUrl $ctx.Request
            $modelType = $ctx.Request.QueryString['type']
            if ($modelType -notmatch '^[a-zA-Z0-9_-]+$') { throw '模型类型不合法。' }
            $remote = Invoke-Comfy 'GET' "$comfy/models/$modelType"
            Send-Bytes $ctx $remote.Bytes $remote.ContentType $remote.StatusCode
        }
        elseif ($path -eq '/api/upload' -and $method -eq 'POST') {
            $comfy = Get-ComfyUrl $ctx.Request
            $body = Read-RequestBytes $ctx.Request
            $remote = Invoke-Comfy 'POST' "$comfy/upload/image" $body $ctx.Request.ContentType
            Send-Bytes $ctx $remote.Bytes $remote.ContentType $remote.StatusCode
        }
        elseif ($path -eq '/api/generate' -and $method -eq 'POST') {
            $bodyBytes = Read-RequestBytes $ctx.Request
            $bodyText = [Text.Encoding]::UTF8.GetString($bodyBytes)
            $bodyObject = $bodyText | ConvertFrom-Json
            $comfy = Get-ComfyUrl $ctx.Request $bodyObject
            $workflow = Build-Workflow $bodyObject.config $comfy
            $payload = @{ prompt = $workflow; client_id = [guid]::NewGuid().ToString('N') } | ConvertTo-Json -Depth 100 -Compress
            $remote = Invoke-Comfy 'POST' "$comfy/prompt" ([Text.Encoding]::UTF8.GetBytes($payload)) 'application/json; charset=utf-8'
            if (-not $remote.Success) {
                $detail = [Text.Encoding]::UTF8.GetString($remote.Bytes)
                throw "ComfyUI 拒绝工作流（HTTP $($remote.StatusCode)）：$detail"
            }
            Send-Bytes $ctx $remote.Bytes $remote.ContentType $remote.StatusCode
        }
        elseif ($path -eq '/api/debug-workflow' -and $method -eq 'POST') {
            $bodyBytes = Read-RequestBytes $ctx.Request
            $bodyObject = [Text.Encoding]::UTF8.GetString($bodyBytes) | ConvertFrom-Json
            $comfy = Get-ComfyUrl $ctx.Request $bodyObject
            $workflow = Build-Workflow $bodyObject.config $comfy
            $nodeIds = @($workflow.PSObject.Properties.Name)
            $debug = [ordered]@{ nodeCount = $nodeIds.Count }
            if ([string]$bodyObject.config.mode -eq 'ref2va') {
                $reference = Get-Node $workflow '136'
                $scheduler = Get-Node $workflow '124'
                $sampler = Get-Node $workflow '123'
                $speed = Get-Node $workflow '168'
                $debug.ref2va = $true
                $debug.prompt = $reference.inputs.prompt
                $debug.width = $reference.inputs.width
                $debug.height = $reference.inputs.height
                $debug.length = $reference.inputs.length
                $debug.referenceInputs = @($reference.inputs.PSObject.Properties.Name | Where-Object { $_ -like 'ref_*' })
                $debug.unet = (Get-Node $workflow '127').inputs.unet_name
                $debug.clip = (Get-Node $workflow '128').inputs.clip_name
                $debug.steps = $scheduler.inputs.steps
                $debug.scheduler = $scheduler.inputs.scheduler
                $debug.samplerName = $sampler.inputs.sampler_name
                $debug.teControl = $speed.inputs.processing_control_value
                $debug.tePercent1 = $speed.inputs.processing_percent_1
                $debug.tePercent2 = $speed.inputs.processing_percent_2
                $debug.speedModel = $speed.inputs.model
                $debug.loraText = (Get-Node $workflow '167').inputs.text
                $debug.loraValues = (Get-Node $workflow '167').inputs.loras
                $debug.containsAiChatPrompt = $nodeIds -contains '165'
            } else {
                $debug.containsAiChatPrompt = $nodeIds -contains '105:123'
                $debug.containsOfficialTemplate = $nodeIds -contains '105:124'
                $debug.containsActionTemplate = $nodeIds -contains '105:132'
                $debug.finalPrompt = (Get-Node $workflow '105:104').inputs.prompt
                $debug.aspectRatio = (Get-Node $workflow '115').inputs.aspect_ratio
                $debug.speedModel = (Get-Node $workflow '105:122').inputs.model
                $debug.loraText = (Get-Node $workflow '105:129').inputs.text
                $debug.loraValues = (Get-Node $workflow '105:129').inputs.loras
                $debug.containsLoraMetadata = $null -ne (Get-Node $workflow '105:129').inputs.PSObject.Properties['loras']
            }
            Send-Json $ctx $debug
        }
        elseif ($path -match '^/api/history/([^/]+)$' -and $method -eq 'GET') {
            $comfy = Get-ComfyUrl $ctx.Request
            $promptId = [Uri]::EscapeDataString($Matches[1])
            $remote = Invoke-Comfy 'GET' "$comfy/history/$promptId"
            Send-Bytes $ctx $remote.Bytes $remote.ContentType $remote.StatusCode
        }
        elseif ($path -eq '/api/view' -and $method -eq 'GET') {
            $comfy = Get-ComfyUrl $ctx.Request
            $filename = [Uri]::EscapeDataString([string]$ctx.Request.QueryString['filename'])
            $subfolder = [Uri]::EscapeDataString([string]$ctx.Request.QueryString['subfolder'])
            $fileType = [Uri]::EscapeDataString([string]$ctx.Request.QueryString['type'])
            $remote = Invoke-Comfy 'GET' "$comfy/view?filename=$filename&subfolder=$subfolder&type=$fileType"
            Send-Bytes $ctx $remote.Bytes $remote.ContentType $remote.StatusCode
        }
        elseif ($path.StartsWith('/api/')) {
            Send-Error $ctx '未找到 API。' 404
        }
        else {
            $rel = $path.TrimStart('/')
            $file = if ($rel) { [System.IO.Path]::GetFullPath((Join-Path $root ($rel.Replace('/', '\')))) } else { Join-Path $root 'index.html' }
            $rootFull = [System.IO.Path]::GetFullPath($root)
            if (-not $file.StartsWith($rootFull) -or -not (Test-Path $file -PathType Leaf)) {
                $file = Join-Path $root 'index.html'
            }
            $ext = [System.IO.Path]::GetExtension($file).ToLower()
            $type = if ($mime.ContainsKey($ext)) { $mime[$ext] } else { 'application/octet-stream' }
            Send-Bytes $ctx ([System.IO.File]::ReadAllBytes($file)) $type 200
        }
    } catch {
        try { Send-Error $ctx $_.Exception.Message 500 } catch {}
    } finally {
        try { $ctx.Response.Close() } catch {}
    }
}
