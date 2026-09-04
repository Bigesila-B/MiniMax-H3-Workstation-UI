$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
if (-not $root) { $root = Split-Path -Parent $MyInvocation.MyCommand.Path }
$port = if ($env:WORKSTATION_PORT) { [int]$env:WORKSTATION_PORT } else { 8000 }
Add-Type -AssemblyName System.Net.Http
Add-Type -AssemblyName System.Drawing

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

function Get-RequestArray {
    # 请求体缺少字段或值为 null 时统一返回空数组，避免 @($null) 产生单个 null 元素。
    # 注意末尾的逗号运算符：函数输出管道会把单元素数组拆包成裸字符串，导致后续
    # $images[0] 取到第一个字符而不是第一张图（实测单张参考图+视频时必现），必须保住数组结构。
    param($Data, [string]$Name)
    $property = $Data.PSObject.Properties[$Name]
    if (-not $property -or $null -eq $property.Value) { return ,@() }
    return ,@($property.Value | Where-Object { $_ })
}

function Repair-AiImageDataUrl {
    # Chromium 画布（视频抽帧、参考图缩放）导出的 JPEG 带有 ICC 配置段等编码特征，
    # base64 本身合法，但实测 agnes、部分中转站的图片解码器会报 "Non-base64 digit found"。
    # 这里统一用 GDI+ 解码后重编码为标准 JPEG 抹平编码器差异（GDI+ 输出实测被各服务接受），
    # 顺带前置校验 base64：坏数据直接报出具体是第几张，而不是等模型服务返回模糊错误。
    param([string]$DataUrl, [string]$Label)
    $marker = ';base64,'
    $index = $DataUrl.IndexOf($marker)
    if ($index -lt 0) { return $DataUrl }
    $base64 = $DataUrl.Substring($index + $marker.Length)
    if ([string]::IsNullOrWhiteSpace($base64)) { return $DataUrl }
    try {
        $bytes = [Convert]::FromBase64String($base64)
    } catch {
        throw "${Label}不是有效的 base64 数据（长度 $($base64.Length)），请刷新页面后重试。"
    }
    $inputStream = $null
    $bitmap = $null
    $outputStream = $null
    try {
        $inputStream = New-Object System.IO.MemoryStream(,$bytes)
        $bitmap = [System.Drawing.Image]::FromStream($inputStream)
        $codec = [System.Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() |
            Where-Object { $_.MimeType -eq 'image/jpeg' } | Select-Object -First 1
        if (-not $codec) { return $DataUrl }
        $encoderParams = New-Object System.Drawing.Imaging.EncoderParameters(1)
        $encoderParams.Param[0] = New-Object System.Drawing.Imaging.EncoderParameter([System.Drawing.Imaging.Encoder]::Quality, [long]88)
        # 透明像素垫白底，避免直接编 JPEG 时透明区变黑。
        $width = [Math]::Max(1, $bitmap.Width)
        $height = [Math]::Max(1, $bitmap.Height)
        $flattened = New-Object System.Drawing.Bitmap($width, $height)
        $graphics = [System.Drawing.Graphics]::FromImage($flattened)
        $graphics.Clear([System.Drawing.Color]::White)
        $graphics.DrawImage($bitmap, 0, 0, $width, $height)
        $graphics.Dispose()
        $outputStream = New-Object System.IO.MemoryStream
        $flattened.Save($outputStream, $codec, $encoderParams)
        $flattened.Dispose()
        return 'data:image/jpeg;base64,' + [Convert]::ToBase64String($outputStream.ToArray())
    } catch {
        # 解码或重编码失败时保留原数据，由模型服务返回原始错误。
        return $DataUrl
    } finally {
        if ($bitmap) { $bitmap.Dispose() }
        if ($inputStream) { $inputStream.Dispose() }
        if ($outputStream) { $outputStream.Dispose() }
    }
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

    $images = Get-RequestArray $RequestData 'images'
    $supportsImages = [bool]$model.supports_images
    if (-not $supportsImages) { $images = @() }
    foreach ($image in $images) {
        $imageUrl = [string]$image
        if ($imageUrl -notmatch '^data:image/(png|jpeg|webp);base64,') { throw '图片数据格式不受支持。' }
        if ($imageUrl.Length -gt 12000000) { throw '单张图片数据过大，请压缩后重试。' }
    }
    # 规范化浏览器产出的图片编码（canvas JPEG 带 ICC 等特征会被部分服务拒绝），详见函数说明。
    if ($images.Count -gt 0) {
        $images = @(for ($i = 0; $i -lt $images.Count; $i++) { Repair-AiImageDataUrl $images[$i] "第 $($i + 1) 张图片" })
    }

    $retryCount = if ($null -ne $model.retry_count) { [Math]::Max(0, [Math]::Min(5, [int]$model.retry_count)) } else { 2 }
    $allowTextFallback = $images.Count -gt 0 -and [bool]$model.fallback_to_text_on_image_error
    $attemptModes = @($true)
    if ($allowTextFallback) { $attemptModes += $false }
    $lastError = '未知错误'

    foreach ($useImages in $attemptModes) {
        $activeImages = if ($useImages) { $images } else { @() }
        for ($retry = 0; $retry -le $retryCount; $retry++) {
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
                if (-not $retryable -or $retry -ge $retryCount) { break }
            } catch {
                $lastError = $_.Exception.Message
                if ($retry -ge $retryCount) { break }
            } finally {
                try { $message.Dispose() } catch {}
            }

            Start-Sleep -Milliseconds ([Math]::Min(3000, 500 * [Math]::Pow(2, $retry)))
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
        # 部分工作流 JSON 会烘焙 lora_name 输入，LoRA 文件被移入子文件夹/重命名后会失效；
        # 仅当节点本来就有该输入时才同步成当前选中的名字，避免给节点塞多余输入。
        if ($loraNode.inputs.PSObject.Properties['lora_name']) {
            Set-InputValue $Workflow $NodeId 'lora_name' $loraValues[0].name
        }
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

function Resolve-ComfyModelType {
    param([string]$ModelType)
    switch ($ModelType) {
        'unet' { return 'diffusion_models' }
        'clip' { return 'text_encoders' }
        default { return $ModelType }
    }
}

function Get-ComfyModelNames {
    param([string]$ComfyUrl, [string]$ModelType)
    $comfyModelType = Resolve-ComfyModelType $ModelType
    $remote = Invoke-Comfy 'GET' "$ComfyUrl/models/$comfyModelType"
    if (-not $remote.Success) { throw "无法读取 ComfyUI 的 $ModelType 模型列表（HTTP $($remote.StatusCode)）。" }
    $data = [Text.Encoding]::UTF8.GetString($remote.Bytes) | ConvertFrom-Json
    if ($data -is [System.Array]) { return @($data | ForEach-Object { [string]$_ }) }
    if ($data.files -is [System.Array]) { return @($data.files | ForEach-Object { [string]$_ }) }
    return @()
}

function Assert-SelectedModelsExist {
    param($Config, [string]$ComfyUrl)
    $required = @(
        [pscustomobject]@{ Label = 'UNET'; Type = 'unet'; Name = [string]$Config.unet },
        [pscustomobject]@{ Label = 'CLIP'; Type = 'clip'; Name = [string]$Config.clip },
        [pscustomobject]@{ Label = '视频 VAE'; Type = 'vae'; Name = [string]$Config.videoVae },
        [pscustomobject]@{ Label = '音频 VAE'; Type = 'vae'; Name = [string]$Config.audioVae }
    )
    $availableByType = @{}
    foreach ($item in $required) {
        if ([string]::IsNullOrWhiteSpace($item.Name)) { throw "未选择 $($item.Label) 模型，请重新扫描后选择。" }
        if (-not $availableByType.ContainsKey($item.Type)) {
            $availableByType[$item.Type] = Get-ComfyModelNames $ComfyUrl $item.Type
        }
        if ($availableByType[$item.Type] -notcontains $item.Name) {
            throw "本地 ComfyUI 未找到已选 $($item.Label) 模型：$($item.Name)。请重新扫描并选择存在的模型。"
        }
    }

    $loraNames = @($Config.loras | Where-Object { $_ -and $_.name } | ForEach-Object { [string]$_.name })
    if ($loraNames.Count -gt 0) {
        $availableLoras = Get-ComfyModelNames $ComfyUrl 'loras'
        foreach ($name in $loraNames) {
            if ($availableLoras -notcontains $name) {
                throw "本地 ComfyUI 未找到已选 LoRA：$name。请重新扫描并移除无效 LoRA。"
            }
        }
    }
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
    if ($loraText.Count -eq 0) {
        # 未启用 LoRA 时模型链已绕过该节点，但 ComfyUI 仍会校验节点里烘焙的默认 LoRA 名，
        # 文件被移入子文件夹/重命名后会直接 400，这里整个移除。
        Remove-WorkflowNode $Workflow $loraNodeId
    }

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
    if ($loraCount -eq 0) {
        # 未启用 LoRA 时移除节点，避免其烘焙的默认 LoRA 名失效导致 ComfyUI 校验 400。
        Remove-WorkflowNode $workflow '105:129'
    }

    # 始终移除工作流内置的 easy cleanGpuUsed（105:130）：执行中途清理会破坏 comfy-aimdo
    # 动态显存加载的页缓存状态，导致下一次生成报 hostbuf_file_reader_read failed。
    # 「生成后自动清理显存」改由网页在任务结束后调用 /api/free-vram 等效清理（见下方端点）。
    Remove-WorkflowNode $workflow '105:130'
    return $workflow
}

function Get-IpOctets {
    param([string]$Ip)
    $parts = $Ip.Split('.')
    if ($parts.Count -ne 4) { return $null }
    $octets = @()
    foreach ($part in $parts) {
        $value = 0
        if (-not [int]::TryParse($part, [ref]$value) -or $value -lt 0 -or $value -gt 255) { return $null }
        $octets += $value
    }
    return $octets
}

function Get-IpCategory {
    # 区分真实局域网地址与虚拟网卡地址：Radmin/Hamachi(25/26 段)、Tailscale 等 CGNAT(100.64/10)、
    # Clash 等代理 TUN fake-ip(198.18/15)。虚拟地址即使绑定成功，手机/其它设备通常也无法访问。
    param([string]$Ip)
    $octets = Get-IpOctets $Ip
    if (-not $octets) { return 'invalid' }
    if ($octets[0] -eq 127) { return 'loopback' }
    if ($octets[0] -eq 169 -and $octets[1] -eq 254) { return 'linklocal' }
    if ($octets[0] -eq 10) { return 'lan' }
    if ($octets[0] -eq 192 -and $octets[1] -eq 168) { return 'lan' }
    if ($octets[0] -eq 172 -and $octets[1] -ge 16 -and $octets[1] -le 31) { return 'lan' }
    if ($octets[0] -eq 198 -and $octets[1] -ge 18 -and $octets[1] -le 19) { return 'virtual' }
    if ($octets[0] -eq 100 -and $octets[1] -ge 64 -and $octets[1] -le 127) { return 'virtual' }
    if ($octets[0] -eq 26 -or $octets[0] -eq 25) { return 'virtual' }
    return 'other'
}

# ---------- GitHub 更新检测与一键更新 ----------
# 仓库采用“main 分支最新提交”作为版本基准（本项目未使用 Releases）：
# 更新配置.json 的「当前版本」记录本地对应的提交 SHA，与远端最新提交比对。
$script:UpdateCheckCache = $null
$script:UpdateRestartPending = $false

# 更新专用 HttpClient：禁用自动重定向，每个跳转目标都要重新过一遍域名白名单。
$updateHandler = New-Object System.Net.Http.HttpClientHandler
$updateHandler.AllowAutoRedirect = $false
$script:UpdateHttpClient = New-Object System.Net.Http.HttpClient($updateHandler)
$script:UpdateHttpClient.Timeout = [TimeSpan]::FromMinutes(6)

$updateRedirectStatuses = @(
    [System.Net.HttpStatusCode]::MovedPermanently, [System.Net.HttpStatusCode]::Found,
    [System.Net.HttpStatusCode]::SeeOther, [System.Net.HttpStatusCode]::TemporaryRedirect,
    [System.Net.HttpStatusCode]::PermanentRedirect
)

function Test-UpdateUrlAllowed {
    # 更新请求只允许访问 GitHub 官方域名（白名单比黑名单更严格：localhost、内网、
    # 保留地址乃至任意其它站点都被直接拒绝）。每个重定向目标都会重新过一遍白名单。
    param([string]$Url)
    $uri = $null
    if (-not [Uri]::TryCreate($Url, [UriKind]::Absolute, [ref]$uri)) { throw "更新服务返回了无法解析的地址：$Url" }
    if ($uri.Scheme -ine 'https') { throw '更新功能仅允许 https 地址。' }
    $targetHost = $uri.DnsSafeHost.ToLowerInvariant()
    $allowedHosts = @('api.github.com', 'github.com', 'codeload.github.com', 'objects.githubusercontent.com', 'release-assets.githubusercontent.com')
    if ($allowedHosts -notcontains $targetHost -and -not $targetHost.EndsWith('.githubusercontent.com')) {
        throw "更新功能拒绝了非 GitHub 地址：$targetHost"
    }
    return $uri
}

function Invoke-UpdateRequest {
    # 禁用自动重定向，改为逐跳手动跟随并重新校验 host，防止被重定向到非 GitHub 地址。
    param([string]$Url, [string]$Accept = $null, [int]$TimeoutMs = 20000)
    $current = $Url
    for ($hop = 0; $hop -le 5; $hop++) {
        $uri = Test-UpdateUrlAllowed $current
        $message = New-Object System.Net.Http.HttpRequestMessage([System.Net.Http.HttpMethod]::Get, $uri)
        $message.Headers.TryAddWithoutValidation('User-Agent', 'MiniMaxH3-Workstation-Updater') | Out-Null
        if ($Accept) { $message.Headers.TryAddWithoutValidation('Accept', $Accept) | Out-Null }
        $cts = New-Object System.Threading.CancellationTokenSource
        $cts.CancelAfter($TimeoutMs)
        try {
            $response = $script:UpdateHttpClient.SendAsync($message, $cts.Token).GetAwaiter().GetResult()
        } catch {
            if ($_ -is [System.Threading.Tasks.TaskCanceledException] -or $_.Exception -is [System.Threading.Tasks.TaskCanceledException]) {
                throw '连接 GitHub 超时，请检查网络后重试。'
            }
            $detail = $_.Exception.Message
            if ($_.Exception.InnerException) { $detail = $_.Exception.InnerException.Message }
            throw "无法连接 GitHub：$detail"
        } finally {
            $message.Dispose()
            $cts.Dispose()
        }
        if ($updateRedirectStatuses -contains $response.StatusCode) {
            $location = $response.Headers.Location
            $response.Dispose()
            if (-not $location) { throw 'GitHub 返回了缺少跳转地址的重定向响应。' }
            $current = if ($location.IsAbsoluteUri) { $location.AbsoluteUri } else { ([System.Uri]::new($uri, $location)).AbsoluteUri }
            continue
        }
        return $response
    }
    throw 'GitHub 重定向次数过多，已中止更新请求。'
}

function Get-UpdateConfigData {
    $configPath = Join-Path $root '更新配置.json'
    if (-not (Test-Path $configPath -PathType Leaf)) { return $null }
    try { return Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return $null }
}

function Get-UpdateInfo {
    param([bool]$Fresh = $false)
    if (-not $Fresh -and $script:UpdateCheckCache -and ((Get-Date) - $script:UpdateCheckCache.At).TotalMinutes -lt 30) {
        return $script:UpdateCheckCache.Data
    }
    $config = Get-UpdateConfigData
    if (-not $config -or [string]::IsNullOrWhiteSpace([string]$config.'GitHub仓库')) {
        return @{ configured = $false; reason = '尚未配置更新源：请在更新配置.json 的「GitHub仓库」里填写 用户名/仓库名。' }
    }
    $repo = ([string]$config.'GitHub仓库').Trim()
    if ($repo -match '^https?://github\.com/([^/\s]+)/([^/\s]+?)(\.git)?/?$') { $repo = "$($Matches[1])/$($Matches[2])" }
    if ($repo -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') {
        return @{ configured = $false; reason = '「GitHub仓库」格式不正确，应为 用户名/仓库名。' }
    }
    $branch = if ([string]$config.'分支') { [string]$config.'分支' } else { 'main' }
    if ($branch -notmatch '^[A-Za-z0-9._\-/]+$') { return @{ configured = $false; reason = '「分支」名称不合法。' } }

    try {
        $response = Invoke-UpdateRequest "https://api.github.com/repos/$repo/commits/$([Uri]::EscapeDataString($branch))" 'application/vnd.github+json' 20000
        $text = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        $succeeded = $response.IsSuccessStatusCode
        $response.Dispose()
        if (-not $succeeded) {
            if ([int]$response.StatusCode -eq 404) { throw "GitHub 上找不到仓库 $repo（分支 $branch）。" }
            throw "GitHub API 返回 HTTP $([int]$response.StatusCode)。"
        }
        $data = $text | ConvertFrom-Json
        $latestSha = [string]$data.sha
        if (-not $latestSha) {
            if ($data.message) { throw "GitHub API：$($data.message)" }
            throw 'GitHub 未返回最新提交信息。'
        }
        $current = [string]$config.'当前版本'
        $commitDate = [string]$data.commit.committer.date
        if (-not $commitDate) { $commitDate = [string]$data.commit.author.date }
        $commitMessage = ([string]$data.commit.message -split "`r?`n")[0].Trim()
        $result = @{
            configured = $true
            channel = 'commit'
            repo = $repo
            branch = $branch
            currentVersion = $current
            currentShort = if ($current.Length -ge 7) { $current.Substring(0, 7) } else { $current }
            latestVersion = $latestSha
            latestShort = $latestSha.Substring(0, [Math]::Min(7, $latestSha.Length))
            latestDate = $commitDate
            commitMessage = $commitMessage
            commitUrl = "https://github.com/$repo/commit/$latestSha"
            unversioned = [string]::IsNullOrWhiteSpace($current)
            hasUpdate = ($current -and $latestSha -ine $current)
        }
        # 结果缓存 30 分钟，避免每次刷新页面都请求 GitHub（匿名额度 60 次/小时）。
        $script:UpdateCheckCache = @{ At = Get-Date; Data = $result }
        return $result
    } catch {
        # 检查失败不缓存：网络恢复后下一次检查应立即重试。
        return @{ configured = $true; error = $_.Exception.Message }
    }
}

function Invoke-ApplyUpdate {
    # 下载 main 分支 zipball → 解压到临时目录 → 写入独立更新助手脚本（参数走 JSON，
    # 规避中文路径的命令行转义问题）→ 响应页面 → 退出服务，由助手完成文件替换并重启。
    $info = Get-UpdateInfo -Fresh $true
    if ($info.error) { throw $info.error }
    if (-not $info.configured) { throw $info.reason }
    if (-not $info.hasUpdate) { throw '当前已经是最新版本，无需更新。' }

    $tempRoot = [System.IO.Path]::GetTempPath()
    $stamp = 'MiniMaxH3-update-' + [DateTime]::Now.ToString('yyyyMMdd-HHmmss')
    $workDir = Join-Path $tempRoot $stamp
    $zipPath = Join-Path $workDir 'update.zip'
    $extractRoot = Join-Path $workDir 'payload'
    New-Item -ItemType Directory -Path $workDir -Force | Out-Null

    Write-Host "  正在下载更新包（$($info.latestShort)）..." -ForegroundColor Cyan
    $response = Invoke-UpdateRequest "https://api.github.com/repos/$($info.repo)/zipball/$($info.latestVersion)" $null 300000
    if (-not $response.IsSuccessStatusCode) {
        throw "下载更新包失败（HTTP $([int]$response.StatusCode)）。"
    }
    $contentStream = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
    $fileStream = [System.IO.File]::Create($zipPath)
    try { $contentStream.CopyTo($fileStream) } finally {
        $fileStream.Dispose(); $contentStream.Dispose(); $response.Dispose()
    }
    if ((Get-Item -LiteralPath $zipPath).Length -lt 10240) { throw '下载的更新包不完整，已中止更新。' }

    Expand-Archive -LiteralPath $zipPath -DestinationPath $extractRoot -Force
    # zipball 解压后所有内容都在“仓库名-提交”单层根目录里，先定位真实内容目录。
    $children = @(Get-ChildItem -LiteralPath $extractRoot -Force)
    $contentDir = if ($children.Count -eq 1 -and $children[0].PSIsContainer) { $children[0].FullName } else { $extractRoot }

    $config = Get-UpdateConfigData
    $preserve = @(@($config.'更新时保留的文件') | Where-Object { $_ } | ForEach-Object { ([string]$_) })
    $job = @{
        serverPid = $PID
        targetDir = $root
        extractDir = $contentDir
        newVersion = [string]$info.latestVersion
        preserve = $preserve
    } | ConvertTo-Json -Depth 5
    [System.IO.File]::WriteAllText((Join-Path $workDir 'update-job.json'), $job, (New-Object System.Text.UTF8Encoding($false)))

    $helperPath = Join-Path $workDir 'update-helper.ps1'
    $helper = @'
$ErrorActionPreference = 'Stop'
$workDir = $PSScriptRoot
try {
    $job = Get-Content -LiteralPath (Join-Path $workDir 'update-job.json') -Raw -Encoding UTF8 | ConvertFrom-Json

    # 等待工作站服务退出（最多 45 秒；超时则强制结束，避免文件被占用导致替换失败）。
    try {
        Wait-Process -Id ([int]$job.serverPid) -Timeout 45 -ErrorAction Stop
    } catch {
        $stillRunning = Get-Process -Id ([int]$job.serverPid) -ErrorAction SilentlyContinue
        if ($stillRunning) { try { Stop-Process -Id $stillRunning.Id -Force } catch {} }
    }
    Start-Sleep -Milliseconds 1200

    # 覆盖复制新版文件：只增改、不删除本地多出的文件；保留清单中的文件本地已存在时跳过。
    $source = [string]$job.extractDir
    $target = [string]$job.targetDir
    $preserve = @(@($job.preserve) | ForEach-Object { ([string]$_).TrimStart('\', '/') })
    $copied = 0
    $preserved = @()
    foreach ($file in @(Get-ChildItem -LiteralPath $source -Recurse -File -Force)) {
        $relative = $file.FullName.Substring($source.Length).TrimStart('\', '/')
        if (-not $relative) { continue }
        if ($preserve -contains ($relative -replace '/', '\') -and (Test-Path -LiteralPath (Join-Path $target $relative))) {
            $preserved += $relative
            continue
        }
        $destination = Join-Path $target $relative
        $parent = Split-Path -Parent $destination
        if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
        Copy-Item -LiteralPath $file.FullName -Destination $destination -Force
        $copied++
    }

    # 把新版本号写回 更新配置.json，这样重启后的检查才会显示“已是最新版本”。
    $configPath = Join-Path $target '更新配置.json'
    if (Test-Path -LiteralPath $configPath) {
        try {
            $config = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $property = $config.PSObject.Properties['当前版本']
            if ($property) { $property.Value = [string]$job.newVersion }
            else { $config | Add-Member -NotePropertyName '当前版本' -NotePropertyValue ([string]$job.newVersion) }
            $configJson = $config | ConvertTo-Json -Depth 20
            [System.IO.File]::WriteAllText($configPath, $configJson, (New-Object System.Text.UTF8Encoding($false)))
        } catch {}
    }

    # 重新启动工作站服务（新开一个可见的控制台窗口，与手动启动等效）。
    Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $target 'server.ps1')) -WorkingDirectory $target

    # 延迟清理本次更新的全部临时文件后退出。
    Start-Sleep -Seconds 6
    Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue
} catch {
    # 更新失败：把错误留存在临时目录便于排查，并尽力把工作站服务拉起来。
    try {
        [System.IO.File]::WriteAllText((Join-Path $workDir 'update-error.txt'), ([string]$_), (New-Object System.Text.UTF8Encoding($true)))
    } catch {}
    try {
        Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path ([string]$job.targetDir) 'server.ps1')) -WorkingDirectory ([string]$job.targetDir)
    } catch {}
}
'@
    [System.IO.File]::WriteAllText($helperPath, $helper, (New-Object System.Text.UTF8Encoding($true)))
    Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', $helperPath) -WindowStyle Hidden

    $script:UpdateRestartPending = $true
    Write-Host "  更新包已就绪，服务即将退出，由更新助手替换文件后自动重启。" -ForegroundColor Yellow
    Send-Json $ctx @{ ok = $true; message = "更新包下载完成，服务将自动重启并升级到 $($info.latestShort)，页面随后会自动刷新。" }
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
# 更新自动重启时旧服务刚释放端口可能有瞬时残留，这里最多重试 3 次再判定失败。
for ($bindAttempt = 1; $bindAttempt -le 3 -and -not $listener; $bindAttempt++) {
    if ($bindAttempt -gt 1) { Start-Sleep -Seconds 2 }
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
}

if (-not $listener) {
    Write-Host "启动失败：8000 端口被占用或无权限，请关闭占用程序后重试。" -ForegroundColor Red
    Read-Host "按回车退出"
    exit 1
}

Write-Host "================================================" -ForegroundColor Cyan
Write-Host "  MiniMax H3 视频工作站 · 服务运行中" -ForegroundColor Cyan
$updateVersion = $null
try { $updateVersion = [string](Get-UpdateConfigData).'当前版本' } catch {}
if ([string]::IsNullOrWhiteSpace($updateVersion)) { $updateVersion = '未知（更新配置.json 缺失或损坏）' }
$versionShort = if ($updateVersion.Length -ge 7) { $updateVersion.Substring(0, 7) } else { $updateVersion }
Write-Host "  当前版本: $versionShort" -ForegroundColor DarkGray
Write-Host "================================================" -ForegroundColor Cyan

# 让控制台里的地址可以直接点击打开浏览器：启用 VT 序列并输出 OSC 8 超链接。
# 老式终端不支持时超链接序列会被忽略或自动降级为普通文本，不会出现乱码。
$vtEnabled = $false
try {
    $consoleApi = Add-Type -MemberDefinition @'
[DllImport("kernel32.dll", SetLastError = true)]
public static extern IntPtr GetStdHandle(int nStdHandle);
[DllImport("kernel32.dll", SetLastError = true)]
public static extern bool GetConsoleMode(IntPtr hConsoleHandle, out int lpMode);
[DllImport("kernel32.dll", SetLastError = true)]
public static extern bool SetConsoleMode(IntPtr hConsoleHandle, int dwMode);
'@ -Name 'WorkstationConsoleApi' -Namespace 'MiniMaxH3' -PassThru
    $stdOutput = $consoleApi::GetStdHandle(-11)
    $consoleMode = 0
    if ($consoleApi::GetConsoleMode($stdOutput, [ref]$consoleMode)) {
        $vtEnabled = $consoleApi::SetConsoleMode($stdOutput, $consoleMode -bor 0x0004)
    }
} catch { $vtEnabled = $false }

function Write-ConsoleLink {
    param([string]$Label, [string]$Url, [string]$Note, [string]$Hotkey = '')
    $suffix = if ($Note) { "  $Note" } else { '' }
    $keyPart = if ($Hotkey) { "[$Hotkey] " } else { '' }
    if ($vtEnabled) {
        $esc = [char]27
        $link = "$esc]8;;${Url}$esc\${Url}$esc]8;;$esc\"
        Write-Host "$Label $keyPart$link$suffix" -ForegroundColor Green
    } else {
        Write-Host "$Label $keyPart$Url$suffix" -ForegroundColor Green
    }
}

# 收集地址并显示；数字编号供后台键盘监听使用。
$linkTargets = @()
Write-ConsoleLink '本机访问:' "http://127.0.0.1:$port/" '' '1'
$linkTargets += [pscustomobject]@{ Key = '1'; Url = "http://127.0.0.1:$port/" }
if ($isLan) {
    # 默认路由所在网卡通常是唯一真实接入局域网的物理网卡，其地址排第一并标注推荐。
    $defaultRouteIp = $null
    try {
        $defaultRoute = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction Stop |
            Sort-Object RouteMetric, InterfaceMetric | Select-Object -First 1
        if ($defaultRoute) {
            $defaultRouteIp = Get-NetIPAddress -AddressFamily IPv4 -InterfaceIndex $defaultRoute.InterfaceIndex -ErrorAction SilentlyContinue |
                Where-Object { $_.IPAddress -notlike '169.*' } |
                Select-Object -First 1 -ExpandProperty IPAddress
        }
    } catch { $defaultRouteIp = $null }

    $lanIps = @()
    try {
        $lanIps = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop |
            Where-Object { (Get-IpCategory ([string]$_.IPAddress)) -eq 'lan' } |
            Select-Object -ExpandProperty IPAddress)
    } catch {}

    $orderedLanIps = @()
    if ($defaultRouteIp -and $lanIps -contains $defaultRouteIp) { $orderedLanIps += $defaultRouteIp }
    foreach ($ip in $lanIps) { if ($orderedLanIps -notcontains $ip) { $orderedLanIps += $ip } }
    $lanKey = 2
    foreach ($ip in $orderedLanIps) {
        $note = if ($orderedLanIps.Count -gt 1 -and $ip -eq $orderedLanIps[0]) { '（推荐，本机所在网络）' } else { '（手机/其它电脑可用）' }
        Write-ConsoleLink '局域网访问:' "http://${ip}:$port/" $note "$lanKey"
        $linkTargets += [pscustomobject]@{ Key = "$lanKey"; Url = "http://${ip}:$port/" }
        $lanKey++
    }
    if ($orderedLanIps.Count -eq 0) {
        Write-Host "  未发现可直连的局域网地址；请让手机与本机连接同一 Wi-Fi/路由器网络。" -ForegroundColor Yellow
    }
} else {
    Write-Host "  提示: 当前仅本机可访问。若需局域网访问，请右键以管理员身份运行启动脚本。" -ForegroundColor Yellow
}
if ($linkTargets.Count -gt 1) {
    Write-Host "  提示: 按键盘数字键 1~$($linkTargets.Count) 可直接在浏览器打开对应地址。" -ForegroundColor DarkGray
} else {
    Write-Host "  提示: 按键盘数字键 1 可直接在浏览器打开地址。" -ForegroundColor DarkGray
}

# 经典控制台不支持可点击链接，改用后台线程监听键盘：按数字键即用默认浏览器打开地址，
# 不干扰主 HTTP 循环；无控制台输入（如被重定向）时 ReadKey 会抛错并静默退出。
try {
    $keyListenerScript = {
        param([object[]]$Targets)
        try {
            while ($true) {
                $keyInfo = [Console]::ReadKey($true)
                foreach ($target in $Targets) {
                    if ($target.Key -eq [string]$keyInfo.KeyChar) {
                        Start-Process -FilePath $target.Url
                        break
                    }
                }
            }
        } catch {}
    }
    $keyRunspace = [runspacefactory]::CreateRunspace()
    $keyRunspace.Open()
    $keyPipeline = [powershell]::Create()
    $keyPipeline.Runspace = $keyRunspace
    $keyPipeline.AddScript($keyListenerScript).AddArgument($linkTargets) | Out-Null
    $keyPipeline.BeginInvoke() | Out-Null
} catch {}
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

# 让控制台窗口始终有固定标题，更新助手重启服务后标题保持一致，方便用户按说明关闭服务。
try { $Host.UI.RawUI.WindowTitle = 'MiniMax H3 工作站服务' } catch {}

while ($listener.IsListening -and -not $script:UpdateRestartPending) {
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
        elseif ($path -eq '/api/free-vram' -and $method -eq 'POST') {
            # 任务边界外的显存清理：转发 ComfyUI 官方 /free 接口（unload_models + free_memory），
            # 与在 ComfyUI 界面里手动清理显存完全等效。不再使用工作流内的清理节点，规避
            # comfy-aimdo 动态显存加载在执行中途被清理后，下一次生成 hostbuf 读取失败的问题。
            $comfy = Get-ComfyUrl $ctx.Request
            $payload = '{"unload_models": true, "free_memory": true}'
            try {
                $remote = Invoke-Comfy 'POST' "$comfy/free" ([Text.Encoding]::UTF8.GetBytes($payload)) 'application/json'
            } catch {
                $reason = if ($_.Exception.InnerException) { $_.Exception.InnerException.Message } else { $_.Exception.Message }
                $reason = ([string]$reason).TrimEnd('。', '.')
                throw "无法连接 ComfyUI：$reason。请确认 ComfyUI 正在运行。"
            }
            if (-not $remote.Success) {
                throw "ComfyUI 清理接口返回 HTTP $($remote.StatusCode)；请确认 ComfyUI 为较新版本（提供 /free 接口）。"
            }
            Send-Json $ctx @{ ok = $true }
        }
        elseif ($path -eq '/api/check-update' -and $method -eq 'GET') {
            $fresh = ([string]$ctx.Request.QueryString['fresh'] -eq '1')
            $info = Get-UpdateInfo -Fresh $fresh
            Send-Json $ctx $info
        }
        elseif ($path -eq '/api/apply-update' -and $method -eq 'POST') {
            # 仅接受 application/json 请求：跨站表单无法携带该 Content-Type，阻止其它网站诱导本机执行更新。
            if ($ctx.Request.ContentType -notmatch 'application/json') { throw '请通过页面内的一键更新按钮执行更新。' }
            Invoke-ApplyUpdate
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
            Assert-SelectedModelsExist $bodyObject.config $comfy
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
                if ($workflow.PSObject.Properties['167']) {
                    $debug.loraText = (Get-Node $workflow '167').inputs.text
                    $debug.loraValues = (Get-Node $workflow '167').inputs.loras
                } else {
                    $debug.loraText = '(未启用 LoRA，节点已移除)'
                }
                $debug.containsAiChatPrompt = $nodeIds -contains '165'
            } else {
                $debug.containsAiChatPrompt = $nodeIds -contains '105:123'
                $debug.containsOfficialTemplate = $nodeIds -contains '105:124'
                $debug.containsActionTemplate = $nodeIds -contains '105:132'
                $debug.finalPrompt = (Get-Node $workflow '105:104').inputs.prompt
                $debug.aspectRatio = (Get-Node $workflow '115').inputs.aspect_ratio
                $debug.speedModel = (Get-Node $workflow '105:122').inputs.model
                if ($workflow.PSObject.Properties['105:129']) {
                    $debug.loraText = (Get-Node $workflow '105:129').inputs.text
                    $debug.loraValues = (Get-Node $workflow '105:129').inputs.loras
                    $debug.containsLoraMetadata = $null -ne (Get-Node $workflow '105:129').inputs.PSObject.Properties['loras']
                } else {
                    $debug.loraText = '(未启用 LoRA，节点已移除)'
                }
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
            # HTML 不缓存：更新替换文件后浏览器刷新必须拿到新页面（JS/CSS 由 ?v= 参数控制缓存）。
            if ($ext -eq '.html') { $ctx.Response.Headers['Cache-Control'] = 'no-store' }
            Send-Bytes $ctx ([System.IO.File]::ReadAllBytes($file)) $type 200
        }
    } catch {
        try { Send-Error $ctx $_.Exception.Message 500 } catch {}
    } finally {
        try { $ctx.Response.Close() } catch {}
    }
}

try { $listener.Stop() } catch {}
if ($script:UpdateRestartPending) {
    Write-Host ""
    Write-Host "  工作站服务已退出，更新助手正在替换文件并重启服务，请稍候……" -ForegroundColor Cyan
    Write-Host "  如长时间没有新窗口弹出，请重新运行「启动工作站.bat」。" -ForegroundColor DarkGray
}
