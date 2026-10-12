$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
if (-not $root) { $root = Split-Path -Parent $MyInvocation.MyCommand.Path }
$port = 8000
if ($env:WORKSTATION_PORT) {
    # 非法端口直接 [int] 转换会在脚本最外层抛错退出，这里改为提示后回退默认值。
    $parsedPort = 0
    if ([int]::TryParse($env:WORKSTATION_PORT, [ref]$parsedPort) -and $parsedPort -ge 1 -and $parsedPort -le 65535) {
        $port = $parsedPort
    } else {
        Write-Host "  [提示] 环境变量 WORKSTATION_PORT=$($env:WORKSTATION_PORT) 不是合法端口，已回退到 8000。" -ForegroundColor DarkYellow
    }
}
Add-Type -AssemblyName System.Net.Http
Add-Type -AssemblyName System.Drawing

# MiniMax H3 的 length 必须落在 5 + 17n 上（节点 length 的 min=5、step=17）。
# 这是"秒数 -> 帧数"的唯一换算公式，基础三模式（节点 105:107）与全能参考（节点 131/141）
# 共用它，避免同一个秒数在两种模式下算出不同的时长（此前两条链路各用一套公式，实测最多差 17 帧）。
$script:FrameExpression = 'max(5, 5 + round((a * 24 - 5) / 17) * 17)'

# ComfyUI 地址白名单（防 SSRF）：默认只允许本机与私有网段，需要连接其它主机时显式放开，例如
#   set WORKSTATION_ALLOW_COMFY_HOSTS=comfy.example.com,10.0.0.9
$script:AllowedComfyHosts = @()
if ($env:WORKSTATION_ALLOW_COMFY_HOSTS) {
    $script:AllowedComfyHosts = @($env:WORKSTATION_ALLOW_COMFY_HOSTS.Split(',') |
        ForEach-Object { $_.Trim().ToLowerInvariant() } | Where-Object { $_ })
}

# ComfyUI 节点能力缓存（键为 ComfyUI 地址），避免每次生成都重新拉一遍 /object_info。
$script:CapabilityCache = @{}

# RTX 超分「真实可用性」探测缓存（键为 ComfyUI 地址）。
# 与 CapabilityCache 分开：前者回答"节点在不在"，这里回答"节点跑不跑得起来"。
$script:RtxVfxCache = @{}

# 单节点定义缓存（键为 "ComfyUI地址|节点名"），存 /object_info/<节点名> 返回的 input.required 等定义。
# 用途见 Complete-RequiredInputs：提交前按 ComfyUI 当前实际节点定义补齐缺失的必需输入，
# 这样上游节点包升级后新增必需字段（例如 TE-Speed 3.5 新增 mode）也不会让整单生成失败。
$script:NodeSchemaCache = @{}

# 节点定义缓存的存活时间。
# 【为什么成功和失败要用两套 TTL】探测失败（ComfyUI 刚重启、正在扫模型、网络抖动）如果也按
# 10 分钟缓存 $null，整个兼容层就会在最需要它的时候静默失效：用户看到的是 ComfyUI 的
# required_input_missing，根本想不到是工作站这边的缓存，而唯一的手动刷新入口是网页上的「测试连接」，
# 谁也不会为一个"节点明明装好了"的问题去点它。30 秒足以避免「节点确实不存在」时每次提交都重试，
# 又不会把一次抖动放大成 10 分钟。
$script:NodeSchemaTtlMinutes = 10
$script:NodeSchemaNegativeTtlSeconds = 30

# 本次构建产生的降级提示（例如缺少 RTX 节点而跳过放大）。每次构建前清空，构建后随响应回给网页。
$script:BuildWarnings = @()

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

function Test-ComfyHostAllowed {
    # 防 SSRF：服务端会带着用户传入的 comfy 地址去发请求，若不限制就等于一台内网请求跳板。
    # 默认只放行本机 / 私有网段 / 单标签局域网主机名；其它地址必须由
    # WORKSTATION_ALLOW_COMFY_HOSTS 显式放开。
    param([string]$HostName)
    $hostName = ([string]$HostName).ToLowerInvariant()
    if (-not $hostName) { return $false }
    if ($script:AllowedComfyHosts -contains $hostName) { return $true }
    if ($hostName -eq 'localhost' -or $hostName -eq '::1' -or $hostName -eq '0.0.0.0') { return $true }
    if ($hostName.EndsWith('.localhost') -or $hostName.EndsWith('.local')) { return $true }
    # 单标签主机名（如 comfy-box）视为局域网名称
    if ($hostName -notmatch '[.:]' -and $hostName -notmatch '^\d+$') { return $true }
    # IPv6：ULA(fc00::/7) 与链路本地(fe80::/10)
    if ($hostName -match '^(fc|fd)[0-9a-f]{2}:') { return $true }
    if ($hostName -match '^fe[89ab][0-9a-f]:') { return $true }
    $category = Get-IpCategory $hostName
    return @('loopback', 'lan', 'linklocal', 'virtual') -contains $category
}

function Assert-SameOrigin {
    # 防御跨站写请求：浏览器发起的跨站请求一定会带 Origin，且与服务自身地址不一致。
    # 只在"带了 Origin 且主机名不匹配"时拒绝，因此 curl / 脚本（不带 Origin）不受影响，
    # 与 ComfyUI 自身的 origin_only_middleware 策略保持一致。
    param($Request)
    $origin = [string]$Request.Headers['Origin']
    if ([string]::IsNullOrWhiteSpace($origin)) { return }
    $hostHeader = [string]$Request.Headers['Host']
    if ([string]::IsNullOrWhiteSpace($hostHeader)) { return }
    $originUri = $null
    if (-not [Uri]::TryCreate($origin, [UriKind]::Absolute, [ref]$originUri)) { throw '请求来源无法解析，已拒绝。' }
    $originHost = $originUri.Host.ToLowerInvariant()
    $requestHost = ($hostHeader -split ':')[0].Trim('[', ']').ToLowerInvariant()
    if ($originHost -ine $requestHost) { throw '拒绝来自其它站点的请求。' }
}

function Assert-RequestSize {
    # 请求体上限必须在"读取之前"判断：Read-RequestBytes 会把整个 body 读进内存，
    # 读完再检查等于没防住（内存已经被吃掉了）。分块传输时 ContentLength64 为 -1，
    # 此时退回读取后的长度检查。
    param($Request, [long]$MaxBytes, [string]$Message)
    if ($Request.ContentLength64 -gt $MaxBytes) { throw $Message }
}

function Get-ComfyUrl {
    param($Request, $BodyObject = $null)
    $value = $Request.QueryString['comfy']
    if (-not $value -and $BodyObject -and $BodyObject.comfyUrl) { $value = [string]$BodyObject.comfyUrl }
    if (-not $value) { $value = 'http://127.0.0.1:8188' }
    $value = $value.Trim().TrimEnd('/')
    if ($value -notmatch '^https?://') { throw 'ComfyUI 地址必须以 http:// 或 https:// 开头。' }
    $comfyUri = $null
    if (-not [Uri]::TryCreate($value, [UriKind]::Absolute, [ref]$comfyUri)) { throw 'ComfyUI 地址无法解析。' }
    if (-not (Test-ComfyHostAllowed $comfyUri.DnsSafeHost)) {
        throw "出于安全考虑，工作站只允许连接本机与局域网内的 ComfyUI（当前为 $($comfyUri.DnsSafeHost)）。如需连接其它主机，请设置环境变量 WORKSTATION_ALLOW_COMFY_HOSTS 显式放开。"
    }
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
        [string]$ContentType = $null,
        [hashtable]$Headers = $null
    )
    $request = New-Object System.Net.Http.HttpRequestMessage([System.Net.Http.HttpMethod]::new($Method), $Url)
    # 允许调用方追加请求头；目前只有 /api/view 需要把浏览器的 Range 头透传给 ComfyUI。
    if ($Headers) {
        foreach ($name in $Headers.Keys) { $request.Headers.TryAddWithoutValidation($name, [string]$Headers[$name]) | Out-Null }
    }
    if ($null -ne $Body) {
        $content = New-Object System.Net.Http.ByteArrayContent(,$Body)
        if ($ContentType) { $content.Headers.TryAddWithoutValidation('Content-Type', $ContentType) | Out-Null }
        $request.Content = $content
    }
    $response = $http.SendAsync($request).GetAwaiter().GetResult()
    $bytes = $response.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
    $responseType = if ($response.Content.Headers.ContentType) { $response.Content.Headers.ContentType.ToString() } else { 'application/octet-stream' }
    # 收集上游响应头，供 /api/view 透传分段下载所需的 Content-Range / Accept-Ranges。
    $responseHeaders = @{}
    foreach ($header in $response.Headers) { $responseHeaders[$header.Key] = ($header.Value -join ', ') }
    foreach ($header in $response.Content.Headers) { $responseHeaders[$header.Key] = ($header.Value -join ', ') }
    return @{
        StatusCode = [int]$response.StatusCode
        Bytes = $bytes
        ContentType = $responseType
        Success = $response.IsSuccessStatusCode
        Headers = $responseHeaders
    }
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

# 移除「没有任何其他节点连线引用它」的孤立节点（含按指定方向级联）。
# 背景：全能参考工作流 JSON 里预置了 137/169(图片)、141(视频)、170(音频) 等加载节点，
# 用户没上传对应素材时，服务端只把聚合节点 136 上的 ref_* 端口摘掉，预置节点本身仍留在
# 提交内容里（值是空字符串）。ComfyUI 的可达性校验只从 output_node 反向递归，这些孤立节点
# 既不参与校验也不执行，功能上无害；但它们会白白占用请求体积，且在旧版工作流里曾把
# 用户本地的素材文件名原样带到请求体中。这里在摘掉端口后顺带清理掉，避免无用负载与信息暴露。
#
# 【安全约束】只允许在 $Allowed 白名单内删除，白名单之外的节点一律保留。
# 这是硬性护栏：视频链里 156(ImageResizeKJv2) 同时引用 171(ResolutionSelector)，
# 而 171 是聚合节点 136 的 width/height 来源；一旦越界删除 171，整个工作流会构建失败。
# 因此这里不做「智能推断」，只删除调用方显式点名的那几个节点。
function Remove-OrphanLoader {
    param($Workflow, [string[]]$Allowed = @())
    $removed = 0
    # 多轮扫描：删掉一个节点后，原本只被它引用的节点会变成新的孤立节点，需要再来一轮。
    # 最多循环 10 轮，避免异常数据导致死循环。
    for ($round = 0; $round -lt 10; $round++) {
        $changed = $false
        foreach ($nodeId in $Allowed) {
            if (-not $Workflow.PSObject.Properties[$nodeId]) { continue }
            # 仍被别的节点引用则保留（例如同一张参考图被多处复用）。
            $referenced = $false
            foreach ($property in $Workflow.PSObject.Properties) {
                if ($property.Name -eq $nodeId) { continue }
                $inputs = $property.Value.inputs
                if (-not $inputs) { continue }
                foreach ($input in $inputs.PSObject.Properties) {
                    $value = $input.Value
                    # 连线形如 @('137', 0)：第一个元素是上游节点 ID。
                    if ($value -is [System.Array] -and $value.Count -ge 1 -and [string]$value[0] -eq $nodeId) {
                        $referenced = $true
                        break
                    }
                }
                if ($referenced) { break }
            }
            if ($referenced) { continue }
            Remove-WorkflowNode $Workflow $nodeId
            $removed++
            $changed = $true
        }
        if (-not $changed) { break }
    }
    return $removed
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

function Get-SafeMegapixels {
    param($Value)
    # ResolutionSelector 的 megapixels 有取值下界，且它是一条「数值输入」而不是连线，
    # ComfyUI 在提交时会直接校验。网页输入框留空 / 非数字时前端会回退默认值，
    # 但直连 API 的请求不受前端约束，因此服务端再做一次夹紧。
    #
    # 【踩坑记录】不要写成 [Math]::Max(0.1, [Math]::Min(4, $number))：
    # PowerShell 5.1 在函数作用域内解析 [Math]::Min(4, <double变量>) 时会选中 Int32 重载，
    # 把 double 直接截断成整数 —— 0.4 变 0、0.7 变 1（顶层作用域反而正常，所以极易漏测）。
    # 两个参数都显式转 [double] 才会走 Double 重载。详见开发文档「踩坑记录」。
    $fallback = 0.4
    try {
        if ($null -eq $Value) { return $fallback }
        $number = [double]$Value
        if ([double]::IsNaN($number) -or [double]::IsInfinity($number)) { return $fallback }
        if ($number -le 0) { return $fallback }
        return [Math]::Max([double]0.1, [Math]::Min([double]4, $number))
    } catch {
        return $fallback
    }
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
    # 【节点的输入有两条来源，必须都取】
    # ComfyUI 0.4 导出的工作流里，`inputs` 数组**不一定包含 widget**：
    # 纯 widget、没有任何连线的节点（UNETLoader / CLIPLoader / BasicScheduler /
    # KSamplerSelect 等）的 `inputs` 干脆是空数组，它们的参数只存在于 `widgets_values_named`。
    # 只按 `inputs` 枚举的话，这些节点的参数会整个丢失（实测 BasicScheduler 的
    # scheduler="simple" 与 denoise=1 就是这么丢的，补默认值后会悄悄变成 normal）。
    # 所以分两步：① 按 inputs 的 link 建立连线；② 从 widgets_values_named 把
    # 「没有被连线覆盖」的参数逐个补上。两路合起来才等于节点的完整输入。
    # 旧版格式没有 widgets_values_named，退回按 inputs 声明顺序读 widgets_values 的位置法。
    #
    # 另外按名字取还有个附带好处：control_after_generate 这类「有值但没有同名输入」的
    # 前端专用 widget 不会再造成错位（位置法实测会把 "fixed" 塞进布尔输入 continue_audio_latent）。
    $uiOnlyNames = @('upload', 'audioUI', 'preview', 'control_after_generate', '__lm_autocomplete_meta_text')
    foreach ($node in @($UiWorkflow.nodes)) {
        $inputs = [ordered]@{}
        foreach ($input in @($node.inputs)) {
            if ($null -eq $input.link) { continue }
            $link = $linkMap[[string]$input.link]
            if ($link) { $inputs[[string]$input.name] = @($link.node, $link.slot) }
        }
        $named = $node.widgets_values_named
        if ($null -ne $named) {
            foreach ($property in $named.PSObject.Properties) {
                $name = [string]$property.Name
                if ($uiOnlyNames -contains $name) { continue }
                # 已被连线覆盖的输入以连线为准，不再写 widget 值。
                if ($inputs.Contains($name)) { continue }
                $inputs[$name] = $property.Value
            }
        } elseif ($null -ne $node.widgets_values) {
            $widgetIndex = 0
            $values = @($node.widgets_values)
            foreach ($input in @($node.inputs)) {
                if ($null -eq $input.widget) { continue }
                $name = [string]$input.name
                if ($widgetIndex -lt $values.Count -and $uiOnlyNames -notcontains $name -and -not $inputs.Contains($name)) {
                    $inputs[$name] = $values[$widgetIndex]
                }
                $widgetIndex++
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

function ConvertFrom-JsonStringLiteral {
    # 把 JSON 字符串字面量（已去掉两端引号）里的转义序列还原成真实字符。
    # 只处理常见的几类，避免引入完整 JSON 解析器的复杂度：
    #   \" \\ \/ \b \f \n \r \t 以及 \uXXXX（含 UTF-16 代理对）
    # 目的：让文本扫描回退路径与 JavaScriptSerializer 路径返回**完全一致**的节点名集合。
    # 例：ComfyUI 返回 "LoRA Syntax \u2192 Path (LoraManager)"，
    #     解码后应为 "LoRA Syntax → Path (LoraManager)"。
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text) -or $Text.IndexOf('\') -lt 0) { return $Text }
    $sb = New-Object System.Text.StringBuilder
    $i = 0
    $len = $Text.Length
    while ($i -lt $len) {
        $ch = $Text[$i]
        if ($ch -ne '\' -or $i -eq ($len - 1)) {
            [void]$sb.Append($ch)
            $i++
            continue
        }
        $next = $Text[$i + 1]
        switch ($next) {
            '"'  { [void]$sb.Append('"');  $i += 2; continue }
            '\'  { [void]$sb.Append('\');  $i += 2; continue }
            '/'  { [void]$sb.Append('/');  $i += 2; continue }
            'b'  { [void]$sb.Append([char]8);  $i += 2; continue }
            'f'  { [void]$sb.Append([char]12); $i += 2; continue }
            'n'  { [void]$sb.Append([char]10); $i += 2; continue }
            'r'  { [void]$sb.Append([char]13); $i += 2; continue }
            't'  { [void]$sb.Append([char]9);  $i += 2; continue }
            'u'  {
                if ($i + 6 -le $len) {
                    $hex = $Text.Substring($i + 2, 4)
                    $code = 0
                    if ([int]::TryParse($hex, [System.Globalization.NumberStyles]::HexNumber,
                            [System.Globalization.CultureInfo]::InvariantCulture, [ref]$code)) {
                        [void]$sb.Append([char]$code)
                        $i += 6
                        continue
                    }
                }
                # 不是合法 \uXXXX，原样保留
                [void]$sb.Append($next)
                $i += 2
                continue
            }
            default {
                [void]$sb.Append($next)
                $i += 2
                continue
            }
        }
    }
    return $sb.ToString()
}

function Get-ObjectInfoNodeNamesFromText {
    # 【回退实现】逐字符扫描 JSON 文本，收集「顶层节点类名」。
    # 只在 Get-ObjectInfoNodeNames 的首选方案（JavaScriptSerializer）不可用或抛异常时才走到这里，
    # 属于最后一道保险，保证再极端的环境下能力探测也不会因为解析问题而整体失败。
    #
    # 只需要「顶层键」，也就是紧跟在 { 或 , 之后、深度为 1 的键名。
    # 用逐字符扫描统计深度（跳过字符串内部），比正则更准确：正则会把嵌套层里
    # 形如 "output":{ 的键也当成节点名（实测多出 27 个 → 16319 个误匹配）。
    # 5.6MB / 3027 节点实测约 0.8 秒，只在缓存过期时执行一次，可接受。
    param([string]$JsonText)
    $names = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    $depth = 0
    $i = 0
    $length = $JsonText.Length
    while ($i -lt $length) {
        $ch = $JsonText[$i]
        if ($ch -eq '"') {
            # 读一个完整字符串（处理 \" 转义），并记录它在扫描结束时的下标
            $i++
            $start = $i
            while ($i -lt $length) {
                if ($JsonText[$i] -eq '\') { $i += 2; continue }
                if ($JsonText[$i] -eq '"') { break }
                $i++
            }
            $text = $JsonText.Substring($start, [Math]::Max(0, $i - $start))
            # 字符串结束后紧跟 ':' 说明它是键；再看它前面第一个非空白字符是不是 '{' 或 ','
            $after = $i + 1
            while ($after -lt $length -and [char]::IsWhiteSpace($JsonText[$after])) { $after++ }
            if ($after -lt $length -and $JsonText[$after] -eq ':') {
                $before = $start - 2
                while ($before -ge 0 -and [char]::IsWhiteSpace($JsonText[$before])) { $before-- }
                if ($before -ge 0 -and ($JsonText[$before] -eq '{' -or $JsonText[$before] -eq ',')) {
                    # 深度 1 = 顶层
                    if ($depth -eq 1) {
                        # 【必须做转义解码，否则与 JavaScriptSerializer 路径结果不一致】
                        # ComfyUI 会把节点名里的非 ASCII 字符写成 \uXXXX 转义，
                        # 例如 "LoRA Syntax \u2192 Path (LoraManager)"（→ 被转义）。
                        # JS 路径会自动解码成 "LoRA Syntax → Path (LoraManager)"，
                        # 这里若不解码，两条路径返回的节点名集合就会有差异（实测差 1 项）。
                        $names.Add((ConvertFrom-JsonStringLiteral $text)) | Out-Null
                    }
                }
            }
            $i++
            continue
        }
        if ($ch -eq '{' -or $ch -eq '[') { $depth++ }
        elseif ($ch -eq '}' -or $ch -eq ']') { $depth-- }
        $i++
    }
    # 【踩坑记录】必须写 return ,$names（逗号前缀）：
    # 直接 return $names 会让 PowerShell 把 HashSet 展开成 Object[]，
    # 调用方的 .Contains() 就退化成大小写敏感的线性查找。详见 Get-ObjectInfoNodeNames 的说明。
    return ,$names
}

function Get-ObjectInfoNodeNames {
    # 从 /object_info 的原始 JSON 文本中取出「顶层节点类名」集合。
    #
    # 【为什么不用 ConvertFrom-Json】
    # Windows PowerShell 5.1 的 ConvertFrom-Json 会把对象解析成「大小写不敏感」的
    # PSCustomObject/字典，一旦 ComfyUI 里存在仅大小写不同的两个节点名，就直接抛
    # 「转换的字典包含重复的键」并让整个探测失败。本机实测就有一例：
    #   dynamicThresholdingFull 与 DynamicThresholdingFull（3027 个节点、5.6MB 响应）
    # 这类重复只影响解析，不影响节点本身是否可用。
    #
    # 【实现策略：双保险】
    # 首选 JavaScriptSerializer（.NET Framework 内置 System.Web.Extensions，无需装包）：
    #   它的反序列化结果是 Dictionary[string,object]，**【大小写敏感】**，
    #   两个仅大小写不同的键可以共存，因此天然绕开了 ConvertFrom-Json 的坑；
    #   实测 5.6MB / 3027 节点约 190 毫秒，比逐字符扫描快约 4 倍。
    # 回退 逐字符扫描（Get-ObjectInfoNodeNamesFromText）：
    #   万一 JavaScriptSerializer 不可用（被裁剪的 .NET 运行时、极简 Nano Server 等）
    #   或抛异常，自动降级到纯文本扫描，保证功能不中断。
    #
    # 【关键陷阱：MaxJsonLength 默认只有 2MB】
    # JavaScriptSerializer 默认 MaxJsonLength = 2097152（2MB），
    # ComfyUI 装了较多自定义节点后 object_info 很容易超过 2MB（本机 5.6MB），
    # 不改这个值会直接抛「已超出 maxJsonLength」。
    # 必须显式把 MaxJsonLength 设成 [int]::MaxValue。
    param([string]$JsonText)
    if ([string]::IsNullOrWhiteSpace($JsonText)) {
        # 同样用逗号前缀，保证返回的是 HashSet 而不是被展开的数组
        return ,(New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase))
    }

    # —— 首选：JavaScriptSerializer ——
    try {
        # 【踩坑记录】判断类型是否可用不能用 [System.Type]::GetType('System.Web.Script.Serialization.JavaScriptSerializer')：
        # Type.GetType 只在「已加载的程序集」和 mscorlib 里找，System.Web.Extensions 默认没加载，
        # 于是会静默返回 $null，导致首选路径被无声跳过（实测就是这样退化成文本扫描的）。
        # 正确做法是先显式 Add-Type 加载程序集，再创建实例。
        Add-Type -AssemblyName System.Web.Extensions -ErrorAction Stop
        $serializer = New-Object System.Web.Script.Serialization.JavaScriptSerializer
        # 见上方【关键陷阱】：不设这一行，>2MB 的 object_info 会直接失败
        $serializer.MaxJsonLength = [int]::MaxValue
        $dict = $serializer.DeserializeObject($JsonText)
        if ($dict -is [System.Collections.IDictionary]) {
            # JavaScriptSerializer 返回的是 Dictionary[string,object]，键是**【大小写敏感】**的，
            # 所以 dynamicThresholdingFull 与 DynamicThresholdingFull 能同时存在、互不覆盖。
            $names = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
            foreach ($key in $dict.Keys) { $names.Add([string]$key) | Out-Null }
            # 【踩坑记录】必须写 return ,$names（逗号前缀），不能写 return $names！
            # PowerShell 的 return 会把「可枚举对象」自动展开并重新打包：
            #   return $names        → 调用方拿到的是 System.Object[]（数组），
            #                          它的 .Contains() 是大小写敏感的线性查找，
            #                          会漏判 DynamicThresholdingFull 这类仅大小写不同的节点名。
            #   return ,$names       → 原样返回 HashSet，.Contains() 走 OrdinalIgnoreCase 比较器。
            # 实测：不加逗号时 $classes.GetType() 是 System.Object[]，行为与预期不符。
            if ($names.Count -gt 0) { return ,$names }
        }
    } catch {
        # 静默降级：把失败原因记到构建警告里，方便排查，但不阻断能力探测
        Add-BuildWarning "节点列表解析已降级为文本扫描模式（原因：$($_.Exception.Message)）。功能正常，仅首次探测略慢。"
    }

    # —— 回退：纯文本扫描 ——
    # 同样必须用逗号前缀，避免 HashSet 被 PowerShell 展开成 Object[]。
    return ,(Get-ObjectInfoNodeNamesFromText $JsonText)
}

function Add-BuildWarning {
    # 记录本次构建的降级提示，最终由 /api/generate 放进响应里，网页会弹出提示。
    param([string]$Message)
    if ([string]::IsNullOrWhiteSpace($Message)) { return }
    if ($script:BuildWarnings -notcontains $Message) { $script:BuildWarnings += $Message }
}

function Set-CapabilityCache {
    # 把"刚刚实际用过的能力表"写回缓存。
    # 场景：网页提交时 Get-ComfyCapabilities 的 60 秒缓存刚好过期，于是重新探测了一次；
    # 构建结束后若不在 60 秒内补写缓存，下一次提交又会再探测一次（object_info 是大响应）。
    param([string]$ComfyUrl, $Data)
    if (-not $ComfyUrl -or -not $Data) { return }
    $script:CapabilityCache[$ComfyUrl] = [pscustomobject]@{ At = (Get-Date); Data = $Data }
}

function Get-ComfyCapabilities {
    # 读取 ComfyUI 的 /object_info，判断哪些「可选节点」存在。
    # 目的是兼容性：用户没装 RTX / TE-Speed / LoraManager 这类非关键节点时，
    # 工作站应自动降级继续出片，而不是直接报错阻断整个生成。
    # 结果按 ComfyUI 地址缓存 60 秒；用户手动点「测试连接」时用 -Force 立即重新探测
    # （例如刚装完节点包，不想等缓存过期）。
    param([string]$ComfyUrl, [switch]$Force)
    $now = Get-Date
    $cached = $script:CapabilityCache[$ComfyUrl]
    if (-not $Force -and $cached -and ($now - $cached.At).TotalSeconds -lt 60) { return $cached.Data }

    $remote = Invoke-Comfy 'GET' "$ComfyUrl/object_info"
    if (-not $remote.Success) { throw "无法读取 ComfyUI 节点列表（HTTP $($remote.StatusCode)），请确认 ComfyUI 已启动。" }
    $jsonText = [Text.Encoding]::UTF8.GetString($remote.Bytes)
    # 双保险解析（优先 JavaScriptSerializer，失败回退文本扫描）：
    # 见 Get-ObjectInfoNodeNames 的完整说明。绝不要改回 ConvertFrom-Json——
    # 节点名存在仅大小写不同的重复时它会直接抛异常。
    $classes = Get-ObjectInfoNodeNames $jsonText
    # 【防御性收口】显式包成 HashSet[string] 并用 OrdinalIgnoreCase 比较器。
    # 原因：PowerShell 的 return 可能把集合展开成 Object[]，而数组的 .Contains()
    # 是大小写敏感的线性查找，会漏判仅大小写不同的节点名。
    # 这里统一收口，保证后续所有 .Contains() 都是正确的大小写不敏感语义。
    $nodeSet = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($n in @($classes)) { [void]$nodeSet.Add([string]$n) }

    $data = [pscustomobject]@{
        # 可选节点：缺失时按降级继续
        RtxUpscale   = $nodeSet.Contains('RTXVideoSuperResolution')
        LoraManager  = $nodeSet.Contains('Lora Loader (LoraManager)')
        TEspeed      = $nodeSet.Contains('TESpeedMiniMaxH3')
        VhsLoadVideo = $nodeSet.Contains('VHS_LoadVideo')
        # RTX 放大前插「透传式清显存」节点用（ComfyUI-Easy-Use 的 easy cleanGpuUsed）。
        # 缺失时只是没法在放大前腾显存，放大本身照常尝试，不当作错误。
        ClearVramNode = $nodeSet.Contains('easy cleanGpuUsed')
        # 「长视频导演台」专属：TimelineDirector 节点包提供的两个必需节点，
        # 缺失时该模式整体不可用（提示装包，而不是降级出一个跑不通的工作流）。
        MiniMaxH3TimelinePlanner      = $nodeSet.Contains('MiniMaxH3TimelinePlanner')
        MiniMaxH3FiniteSegmentSampler = $nodeSet.Contains('MiniMaxH3FiniteSegmentSampler')
        # 导演台链路里的「可选」节点：缺失时从模型链/SIGMAS 链上摘除并重连，不影响出片。
        H3SigmaRefiner          = $nodeSet.Contains('H3SigmaRefiner')
        SageAttentionKJ         = $nodeSet.Contains('PathchSageAttentionKJ')
        MiniMaxLowVRAMAttention = $nodeSet.Contains('MiniMaxLowVRAMAttention')
        MiniMaxChunkFeedForward = $nodeSet.Contains('MiniMaxChunkFeedForward')
        # 关键节点：缺失时对应模式直接不可用，需要给出明确提示
        SaveVideo                 = $nodeSet.Contains('SaveVideo')
        MiniMaxH3ImageToVideo     = $nodeSet.Contains('MiniMaxH3ImageToVideo')
        MiniMaxH3ReferenceToVideo = $nodeSet.Contains('MiniMaxH3ReferenceToVideo')
        ResolutionSelector        = $nodeSet.Contains('ResolutionSelector')
        ComfyMathExpression       = $nodeSet.Contains('ComfyMathExpression')
        CreateVideo               = $nodeSet.Contains('CreateVideo')
    }
    $script:CapabilityCache[$ComfyUrl] = [pscustomobject]@{ At = $now; Data = $data }
    return $data
}

# ---------------------------------------------------------------------------
# 环境自检（只读）
#
# 目的：把已经探测到的节点可用性，翻译成「哪个模式还能用 / 缺什么 / 要装哪个包」，
# 让用户不必等到点生成、再从报错里倒推。
#
# 三条设计约束：
#   1. **只读诊断，绝不阻断生成**：缺可选节点仍然照旧降级出片，这里只是把事实讲清楚。
#      任何情况下都不能变成「环境不达标就不给点生成」。
#   2. **零新增探测**：完全复用 Get-ComfyCapabilities 的结果（它自带 60 秒缓存）。
#   3. **「连不上 ComfyUI」与「缺节点」必须分开**：否则 ComfyUI 没开时满屏红叉，
#      用户会以为节点装崩了。
#
# 关于「节点 → 节点包」的映射为什么不自动提取：4 个基础模式的工作流是「导出(API)」
# 格式，不带 properties.cnr_id / aux_id；只有导演台那份 UI 格式工作流带，且只覆盖 6 个包。
# 所以这里保留一张人工登记表作为唯一事实来源。Url 只在确信时填写 —— 留空表示
# 「请在 ComfyUI-Manager 里搜索 Package 里的 ID」，宁可不给也不给错地址。
# ---------------------------------------------------------------------------

$script:SelfCheckNodeInfo = @{
    # ---- comfy-core：ComfyUI 内置，缺失只能靠升级 ComfyUI，不是装包能解决的 ----
    'SaveVideo'                 = @{ Node = 'SaveVideo';                 Label = '视频保存节点';     Package = ''; Url = ''; IsCore = $true; Impact = '所有模式都无法保存成片' }
    'CreateVideo'               = @{ Node = 'CreateVideo';               Label = '视频合成';         Package = ''; Url = ''; IsCore = $true; Impact = '所有模式都无法合成为视频' }
    'ResolutionSelector'        = @{ Node = 'ResolutionSelector';        Label = '分辨率选择';       Package = ''; Url = ''; IsCore = $true; Impact = '所有模式都无法确定画面尺寸' }
    'ComfyMathExpression'       = @{ Node = 'ComfyMathExpression';       Label = '帧数换算';         Package = ''; Url = ''; IsCore = $true; Impact = '基础四模式的时长换算不可用' }
    'MiniMaxH3ImageToVideo'     = @{ Node = 'MiniMaxH3ImageToVideo';     Label = 'H3 图生视频';      Package = ''; Url = ''; IsCore = $true; Impact = '文生 / 图生 / 首尾帧三个模式不可用' }
    'MiniMaxH3ReferenceToVideo' = @{ Node = 'MiniMaxH3ReferenceToVideo'; Label = 'H3 全能参考';      Package = ''; Url = ''; IsCore = $true; Impact = '全能参考模式不可用' }

    # ---- 第三方节点包 ----
    'MiniMaxH3TimelinePlanner'      = @{ Node = 'MiniMaxH3TimelinePlanner';      Label = '时间线规划台'; Package = 'ComfyUI-MiniMaxH3-TimelineDirector'; Url = 'https://github.com/Songssx/ComfyUI-MiniMaxH3-TimelineDirector'; IsCore = $false; Impact = '长视频导演台不可用' }
    'MiniMaxH3FiniteSegmentSampler' = @{ Node = 'MiniMaxH3FiniteSegmentSampler'; Label = '分镜采样器';   Package = 'ComfyUI-MiniMaxH3-TimelineDirector'; Url = 'https://github.com/Songssx/ComfyUI-MiniMaxH3-TimelineDirector'; IsCore = $false; Impact = '长视频导演台不可用' }
    'H3SigmaRefiner'                = @{ Node = 'H3SigmaRefiner';                Label = '额外精修步';   Package = 'ComfyUI-YCNodes-MiniMax-H3';         Url = 'https://github.com/yichengup/ComfyUI-YCNodes-MiniMax-H3';        IsCore = $false; Impact = '导演台跳过额外精修步（仍会正常出片）' }
    'SageAttentionKJ'               = @{ Node = 'PathchSageAttentionKJ';          Label = 'SageAttention';Package = 'ComfyUI-KJNodes';                    Url = 'https://github.com/kijai/ComfyUI-KJNodes';                       IsCore = $false; Impact = '导演台跳过 SageAttention（显存占用略高）' }
    'MiniMaxLowVRAMAttention'       = @{ Node = 'MiniMaxLowVRAMAttention';       Label = '低显存注意力'; Package = 'ComfyUI-KJNodes';                    Url = 'https://github.com/kijai/ComfyUI-KJNodes';                       IsCore = $false; Impact = '导演台跳过低显存注意力优化（显存占用略高）' }
    'MiniMaxChunkFeedForward'       = @{ Node = 'MiniMaxChunkFeedForward';       Label = '分块前馈';     Package = 'ComfyUI-KJNodes';                    Url = 'https://github.com/kijai/ComfyUI-KJNodes';                       IsCore = $false; Impact = '导演台跳过分块前馈（显存占用略高）' }
    'TEspeed'                       = @{ Node = 'TESpeedMiniMaxH3';              Label = 'TE-Speed 加速';Package = 'TE-Speed-MiniMaxH3';                 Url = 'https://github.com/tl2012tl/TE-Speed-MiniMaxH3';                 IsCore = $false; Impact = '跳过加速，生成变慢但结果正常' }
    'LoraManager'                   = @{ Node = 'Lora Loader (LoraManager)';     Label = 'LoRA 加载';    Package = 'ComfyUI-Lora-Manager';               Url = '';                                                              IsCore = $false; Impact = '跳过 LoRA，风格/画质微调不生效' }
    'RtxUpscale'                    = @{ Node = 'RTXVideoSuperResolution';       Label = 'RTX 视频放大'; Package = '';                                   Url = '';                                                              IsCore = $false; Impact = 'RTX 放大开关会被禁用并自动跳过' }
    'ClearVramNode'                 = @{ Node = 'easy cleanGpuUsed';             Label = '放大前清显存'; Package = 'ComfyUI-Easy-Use';                   Url = 'https://github.com/yolain/ComfyUI-Easy-Use';                     IsCore = $false; Impact = 'RTX 放大前无法腾显存（放大本身照常尝试）' }
    'VhsLoadVideo'                  = @{ Node = 'VHS_LoadVideo';                 Label = '视频参考素材'; Package = 'VideoHelperSuite';                   Url = 'https://github.com/Kosinkadink/ComfyUI-VideoHelperSuite';        IsCore = $false; Impact = '全能参考无法使用「视频」类型的参考素材' }
}

# 每个模式各自需要哪些节点。Required 缺失 -> 该模式整体不可用；Optional 缺失 -> 只降级。
$script:SelfCheckModes = @(
    @{ Mode = 't2v';     Label = '文生视频'
       Required = @('MiniMaxH3ImageToVideo', 'ResolutionSelector', 'ComfyMathExpression', 'CreateVideo', 'SaveVideo')
       Optional = @('TEspeed', 'LoraManager', 'RtxUpscale', 'ClearVramNode') }
    @{ Mode = 'i2v';     Label = '图生视频'
       Required = @('MiniMaxH3ImageToVideo', 'ResolutionSelector', 'ComfyMathExpression', 'CreateVideo', 'SaveVideo')
       Optional = @('TEspeed', 'LoraManager', 'RtxUpscale', 'ClearVramNode') }
    @{ Mode = 'flf2v';   Label = '首尾帧'
       Required = @('MiniMaxH3ImageToVideo', 'ResolutionSelector', 'ComfyMathExpression', 'CreateVideo', 'SaveVideo')
       Optional = @('TEspeed', 'LoraManager', 'RtxUpscale', 'ClearVramNode') }
    @{ Mode = 'ref2va';  Label = '全能参考'
       Required = @('MiniMaxH3ReferenceToVideo', 'ResolutionSelector', 'ComfyMathExpression', 'CreateVideo', 'SaveVideo')
       Optional = @('VhsLoadVideo', 'TEspeed', 'LoraManager', 'RtxUpscale', 'ClearVramNode') }
    @{ Mode = 'director'; Label = '长视频导演台'
       Required = @('MiniMaxH3TimelinePlanner', 'MiniMaxH3FiniteSegmentSampler', 'ResolutionSelector', 'CreateVideo', 'SaveVideo')
       Optional = @('H3SigmaRefiner', 'SageAttentionKJ', 'MiniMaxLowVRAMAttention', 'MiniMaxChunkFeedForward', 'TEspeed', 'LoraManager', 'RtxUpscale', 'ClearVramNode') }
)

function Get-SelfCheckNodeEntry {
    # 把 capabilities 的字段名翻译成给用户看的一条记录。
    # 登记表里没有的键不丢，退化成「只有类名」——新加探测项时不会因为漏登记而静默消失。
    param([string]$Key)
    $info = $script:SelfCheckNodeInfo[$Key]
    if (-not $info) {
        return [pscustomobject]@{
            key = $Key; node = $Key; label = $Key; package = ''; url = ''; isCore = $false
            impact = '未登记来源，请在 ComfyUI-Manager 中搜索该节点名'
        }
    }
    return [pscustomobject]@{
        key     = $Key
        node    = $info.Node
        label   = $info.Label
        package = $info.Package
        url     = $info.Url
        isCore  = [bool]$info.IsCore
        impact  = $info.Impact
    }
}

function Get-SelfCheckReport {
    # 把 capabilities 组装成「按模式分组的缺失清单 + 待安装包汇总」。
    # 只读：不修改任何状态，也不会因为「有缺失」而影响后续请求。
    param($Capabilities)

    $modeReports = @()
    $missingKeys = @()
    $available = 0
    $degraded = 0
    $unavailable = 0

    foreach ($definition in $script:SelfCheckModes) {
        $requiredMissing = @()
        foreach ($key in $definition.Required) {
            if ($Capabilities.$key -eq $false) { $requiredMissing += $key }
        }
        $optionalMissing = @()
        foreach ($key in $definition.Optional) {
            if ($Capabilities.$key -eq $false) { $optionalMissing += $key }
        }
        if ($requiredMissing.Count -gt 0) { $status = 'unavailable'; $unavailable++ }
        elseif ($optionalMissing.Count -gt 0) { $status = 'degraded'; $degraded++ }
        else { $status = 'ok'; $available++ }

        $modeReports += [pscustomobject]@{
            mode            = $definition.Mode
            label           = $definition.Label
            status          = $status
            requiredMissing = @($requiredMissing | ForEach-Object { Get-SelfCheckNodeEntry $_ })
            optionalMissing = @($optionalMissing | ForEach-Object { Get-SelfCheckNodeEntry $_ })
        }
        $missingKeys += $requiredMissing
        $missingKeys += $optionalMissing
    }

    # 待安装包汇总：按节点包合并（KJNodes 的三个节点会并成一条）。
    $entries = @()
    foreach ($key in ($missingKeys | Select-Object -Unique)) { $entries += Get-SelfCheckNodeEntry $key }

    $packages = @()
    foreach ($group in @($entries | Where-Object { $_.package } | Group-Object { $_.package })) {
        $head = $group.Group[0]
        $packages += [pscustomobject]@{
            package = $head.package
            url     = $head.url
            isCore  = [bool]$head.isCore
            nodes   = @($group.Group | ForEach-Object { $_.node } | Select-Object -Unique)
        }
    }
    # 内置节点单独成条，前端据此提示「升级 ComfyUI」而不是「装包」。
    $coreNodes = @($entries | Where-Object { $_.isCore } | ForEach-Object { $_.node } | Select-Object -Unique)
    if ($coreNodes.Count -gt 0) {
        $packages += [pscustomobject]@{
            package = 'comfy-core'
            url     = ''
            isCore  = $true
            nodes   = $coreNodes
        }
    }

    return [pscustomobject]@{
        connected = $true
        summary   = [pscustomobject]@{
            modes           = $script:SelfCheckModes.Count
            available       = $available
            degraded        = $degraded
            unavailable     = $unavailable
            missingPackages = $packages.Count
        }
        modes    = @($modeReports)
        packages = @($packages)
        # 未登记来源的节点（package 为空且非内置）：单独列出来，让用户知道"还有这些缺，
        # 但本站不知道它属于哪个包"，而不是假装没这回事。
        unknownNodes = @($entries | Where-Object { -not $_.package -and -not $_.isCore } | ForEach-Object { $_.node } | Select-Object -Unique)
    }
}

function Get-ComfyManagerInfo {
    # 探测 ComfyUI-Manager 是否可用 —— 它提供「一键安装自定义节点」的接口。
    #
    # 用 GET /manager/version 做存在性探针：这是 Manager 最轻量的公开路由，返回纯文本版本号。
    # （接口清单取自节点包源码 glob/manager_server.py，非推断。）
    #
    # 探测失败一律返回 available = false 而不是抛错：**没装 Manager 是完全正常的状态**，
    # 前端会据此退化成「复制 git clone 命令」让用户手动装，不该因此报错。
    param([string]$ComfyUrl)
    try {
        $remote = Invoke-Comfy 'GET' "$ComfyUrl/manager/version"
        if (-not $remote.Success) { return [pscustomobject]@{ available = $false; version = '' } }
        $version = ([Text.Encoding]::UTF8.GetString($remote.Bytes)).Trim()
        # 防误判：ComfyUI 对未知路径正常返回 404，但万一有反向代理回了个 HTML 页，
        # 这里按「长度异常 / 含标签」把它挡掉，避免把网页当成版本号。
        if (-not $version -or $version.Length -gt 64 -or $version.Contains('<')) {
            return [pscustomobject]@{ available = $false; version = '' }
        }
        return [pscustomobject]@{ available = $true; version = $version }
    } catch {
        return [pscustomobject]@{ available = $false; version = '' }
    }
}

function Get-InstallablePackage {
    # 从登记表反查某个包名对应的仓库地址。
    # 这是「一键安装」的安全闸门：**仓库地址只来自这张服务端登记表**，
    # 前端请求里只允许出现包名，因此这个接口不可能被诱导去安装登记表之外的仓库。
    # 返回 $null 表示不可安装（包不存在 / 是内置节点 / 未登记地址）。
    param([string]$PackageName)
    if ([string]::IsNullOrWhiteSpace($PackageName)) { return $null }
    $packageName = $PackageName.Trim()
    # 'comfy-core' 不在登记表的 Package 字段里 —— 它是 Get-SelfCheckReport 汇总时
    # 给「内置节点」现起的合成包名（内置条目的 Package 字段是空串）。这里显式认这一个名字，
    # 好让 /api/install-package 能回「请更新 ComfyUI」，而不是含糊的「不在可安装清单里」。
    if ($packageName -eq 'comfy-core') {
        return [pscustomobject]@{ package = $packageName; url = ''; isCore = $true }
    }
    $matched = $false
    $isCore = $false
    $url = ''
    foreach ($info in $script:SelfCheckNodeInfo.Values) {
        if (([string]$info.Package) -ne $packageName) { continue }
        $matched = $true
        if ($info.IsCore) { $isCore = $true; break }
        if ($info.Url) { $url = [string]$info.Url; break }
    }
    if (-not $matched) { return $null }
    if ($isCore) { return [pscustomobject]@{ package = $packageName; url = ''; isCore = $true } }
    if (-not $url) { return [pscustomobject]@{ package = $packageName; url = ''; isCore = $false } }
    return [pscustomobject]@{ package = $packageName; url = $url; isCore = $false }
}

# ---------------------------------------------------------------------------
# 必需输入自动补齐（跨节点包版本的兼容层）
#
# 背景（真实踩坑）：
#   ComfyUI 0.35.x 的 execution.py 里 validate_inputs() 会逐个检查每个 required 输入
#   是否出现在 prompt 中，缺失就写一条 required_input_missing 并整体拒绝请求（HTTP 400）。
#   而本工作站的工作流 JSON 是「发布时的快照」，上游节点包一旦升级并新增了必需输入，
#   快照里就没有这个字段，于是整单生成全部失败。
#   实例：TE-Speed-MiniMaxH3 从 3.2 升到 3.5 时新增了必需输入
#         mode = ["standard", "4-step LoRA", "8-step LoRA"]，
#         模型里没有 mode 就会被 ComfyUI 判为 required_input_missing，三种基础模式与
#         全能参考模式一起挂掉。
#
# 另一侧的关键事实：多余输入是安全的。
#   execution.py 的 get_input_data() 只遍历节点自己声明过的输入（input_category 非空）才
#   会塞进调用参数，未声明的键被静默忽略；validate_inputs() 也只报「缺必需输入」，不报
#   「多了未知输入」。所以按当前定义补出来的字段，对旧版节点同样无害。
#
# 因此这里不做版本判断、不硬编码字段名，而是每次提交前向 ComfyUI 询问
# 「这个节点现在声明了哪些必需输入」，把工作流里缺的按声明默认值补上。
# 上游以后再改字段，这里是自动跟随的，不需要再改工作流 JSON。
# ---------------------------------------------------------------------------

function Get-ComfyNodeSchema {
    # 读取单个节点类型的完整定义：GET /object_info/<节点名>。
    # 结果按「ComfyUI 地址 + 节点名」缓存（成功 10 分钟 / 失败 30 秒，见 $script:NodeSchemaTtl*）。
    # 探测失败（节点不存在、ComfyUI 临时抽风）时返回 $null，由调用方按「不补齐」处理——
    # 兼容层只能帮上忙，绝不能在它自己出问题时阻断生成。
    param([string]$ComfyUrl, [string]$ClassType)
    if (-not $ComfyUrl -or [string]::IsNullOrWhiteSpace($ClassType)) { return $null }

    $key = "$ComfyUrl|$ClassType"
    $cached = $script:NodeSchemaCache[$key]
    if ($cached -and $cached.At) {
        # 失败结果用短 TTL：缓存里躺着一个 $null 时，下一次提交必须很快能重试。
        $ttlSeconds = $script:NodeSchemaTtlMinutes * 60
        if ($cached.PSObject.Properties['Negative'] -and $cached.Negative) {
            $ttlSeconds = $script:NodeSchemaNegativeTtlSeconds
        }
        if (((Get-Date) - $cached.At).TotalSeconds -lt $ttlSeconds) { return $cached.Data }
    }

    $data = $null
    try {
        # 节点名可能带空格和括号（例如 Lora Loader (LoraManager)），必须转义后再拼进路径。
        $encoded = [System.Uri]::EscapeDataString($ClassType)
        $remote = Invoke-Comfy 'GET' "$ComfyUrl/object_info/$encoded"
        if ($remote.Success) {
            $text = [Text.Encoding]::UTF8.GetString($remote.Bytes)
            $parsed = $text | ConvertFrom-Json
            # 返回体形如 { "节点名": { input = { required = ...; optional = ... }, ... } }。
            # 用 PSObject.Properties 取值而不是 $parsed.$ClassType，避免节点名里的特殊字符被当成
            # 属性路径解析。这里只请求了一个节点，不存在「仅大小写不同的重复键」问题。
            $entry = $parsed.PSObject.Properties[$ClassType]
            if ($entry) { $data = $entry.Value }
        }
    } catch {
        # 静默降级：兼容层失败不该影响本次生成，最多是少补一个字段。
        $data = $null
    }
    $script:NodeSchemaCache[$key] = [pscustomobject]@{
        At       = (Get-Date)
        Data     = $data
        Negative = ($null -eq $data)
    }
    return $data
}

function Test-LooksLikeFileList {
    # 判断一组组合框候选是不是「文件列表」（模型/图片/音频/LoRA 的文件名枚举）。
    # 为什么需要：文件列表型 combobox 的第一项就是某个真实文件名，把它当默认值补进工作流
    # **不会报错**（它确实是节点声明的候选之一，ComfyUI 的 combo 校验会放行），
    # 结果就是用户静默地用错了模型/素材——比直接报错更难发现。
    # 判定口径：
    #   1) 候选数 > 20 —— ComfyUI 自己在回传超长候选列表时也是这个口径（execution.py 里
    #      对 len(options) > 20 的列表直接截断描述，认为那是"一大堆扫描出来的路径"）；
    #   2) 候选里出现路径分隔符或常见素材扩展名 —— 枚举型候选（standard/auto/high）不会长这样。
    param($Candidates)
    $list = @($Candidates)
    if ($list.Count -gt 20) { return $true }
    foreach ($item in $list) {
        $text = [string]$item
        if ($text -match '[\\/]') { return $true }
        if ($text -match '\.(safetensors|ckpt|pt|pth|bin|gguf|onnx|sft|pkl|npz|json|txt|png|jpe?g|webp|gif|bmp|tiff?|mp4|mov|mkv|webm|avi|wav|mp3|flac|ogg|m4a|aac)$') { return $true }
    }
    return $false
}

function Test-RangeAllowsZero {
    # 数字类型没有声明默认值时，能不能安全地补 0？
    # ComfyUI 会对 widget 值做区间校验：val < min → value_smaller_than_min、val > max →
    # value_bigger_than_max，两种情况都直接 400。所以"补 0"在 min=1 这类输入上不是兜底，
    # 而是把「缺少必需输入」换成一句更难懂的错误。只有区间包含 0（或没声明区间）时才敢补。
    param($Options, [double]$Value = 0)
    if (-not $Options) { return $true }
    $minProperty = $Options.PSObject.Properties['min']
    if ($minProperty -and $null -ne $minProperty.Value) {
        try { if ($Value -lt [double]$minProperty.Value) { return $false } } catch { }
    }
    $maxProperty = $Options.PSObject.Properties['max']
    if ($maxProperty -and $null -ne $maxProperty.Value) {
        try { if ($Value -gt [double]$maxProperty.Value) { return $false } } catch { }
    }
    return $true
}

function Get-ComfyInputDefinition {
    # 按输入名取定义，required 优先、optional 兜底。
    # 【为什么两个桶都要看】只查 required 会把「节点把它声明成可选」误判成「节点没有这个输入」，
    # 于是对着一个其实支持该参数的节点打出「不支持」的结论并丢弃用户的选择——正是兼容层要消灭的静默。
    # 注意：这里只服务于「探测/读取」；补齐仍然只补 required（见 Complete-RequiredInputs），
    # 不能因为可选输入有默认值就凭空给工作流加端口。
    param($Schema, [string]$InputName)
    if (-not $Schema -or -not $Schema.input -or [string]::IsNullOrWhiteSpace($InputName)) { return $null }
    foreach ($bucketName in @('required', 'optional')) {
        $bucket = $Schema.input.$bucketName
        if (-not $bucket) { continue }
        $property = $bucket.PSObject.Properties[$InputName]
        if ($property) { return $property.Value }
    }
    return $null
}

function Get-InputDefaultValue {
    # 从 /object_info 的单个输入定义里取出可用的默认值。
    # 定义形态：
    #   ["FLOAT", { default = 0.08; min = 0; max = 1; step = 0.005 }]
    #   [["standard", "4-step LoRA"], { default = "standard" }]      ← 组合框
    #   ["MODEL"]                                                     ← 连线类型，无默认值
    # 返回 @{ Found = $true/$false; Value = 值; Guessed = $true/$false }。
    # Guessed 表示「这不是节点声明的默认值，而是工作站按类型/首项取的保守值」——
    # 调用方要把这类单独告警，让用户知道哪一项其实"是猜的"。见 Complete-RequiredInputs。
    # 无法确定默认值时返回 Found = $false（典型是 MODEL/LATENT 这类必须连线的输入）——
    # 那种缺失说明工作流本身有问题，应该让 ComfyUI 正常报错，而不是伪造一个假值。
    param($Definition)
    $result = @{ Found = $false; Value = $null; Guessed = $false }
    if ($null -eq $Definition) { return $result }

    $items = @($Definition)
    if ($items.Count -ge 1) {
        $optionsProperty = $null
        if ($items.Count -ge 2) {
            try { $optionsProperty = $items[1] } catch { $optionsProperty = $null }
        }

        # 1) 优先取显式声明的 default（唯一"节点作者亲口说的"值，可信）。
        if ($optionsProperty) {
            $defaultProperty = $optionsProperty.PSObject.Properties['default']
            if ($defaultProperty) {
                $result.Found = $true
                $result.Value = $defaultProperty.Value
                return $result
            }
        }

        $typeSpec = $items[0]
        # 2) 组合框没有 default：只有当候选像「枚举值」时才敢取第一项。
        if ($null -ne $typeSpec -and -not ($typeSpec -is [string]) -and
            ($typeSpec -is [System.Array] -or $typeSpec -is [System.Collections.IList])) {
            $candidates = @($typeSpec)
            if ($candidates.Count -gt 0 -and -not (Test-LooksLikeFileList $candidates)) {
                $result.Found = $true
                $result.Value = $candidates[0]
                $result.Guessed = $true
            }
            return $result
        }

        # 3) 基本类型没有 default：数字要先确认区间包含 0，否则宁可不补（让 ComfyUI 正常报「缺必需输入」）。
        switch ([string]$typeSpec) {
            'INT' {
                if (Test-RangeAllowsZero $optionsProperty 0) { $result.Found = $true; $result.Value = 0; $result.Guessed = $true }
            }
            'FLOAT' {
                if (Test-RangeAllowsZero $optionsProperty 0.0) { $result.Found = $true; $result.Value = 0.0; $result.Guessed = $true }
            }
            'STRING' { $result.Found = $true; $result.Value = ''; $result.Guessed = $true }
            'BOOLEAN' { $result.Found = $true; $result.Value = $false; $result.Guessed = $true }
            default { }
        }
    }
    return $result
}

function Complete-RequiredInputs {
    # 提交前兜底：对照 ComfyUI 当前实际节点定义，把工作流里缺失的必需输入补成声明默认值。
    # 这是「节点包升级后工作站还能继续用」的关键一步，原因见本节的块注释。
    # 只补必需输入，且只在默认值可确定时补；已存在的输入（含所有连线）一律不动。
    param($Workflow, [string]$ComfyUrl)
    if (-not $Workflow -or -not $ComfyUrl) { return }

    $filled = @()
    $guessed = @()
    foreach ($nodeProperty in @($Workflow.PSObject.Properties)) {
        $node = $nodeProperty.Value
        if (-not $node -or -not $node.class_type) { continue }

        $classType = [string]$node.class_type
        $schema = Get-ComfyNodeSchema $ComfyUrl $classType
        if (-not $schema) { continue }
        $required = $schema.input.required
        if (-not $required) { continue }

        # 工作流里已声明的输入名（连线和普通值都在这里），这些绝不覆盖。
        $present = @()
        if ($node.inputs) { $present = @($node.inputs.PSObject.Properties.Name) }

        foreach ($inputProperty in @($required.PSObject.Properties)) {
            $inputName = $inputProperty.Name
            if ($present -contains $inputName) { continue }

            $default = Get-InputDefaultValue $inputProperty.Value
            if (-not $default.Found) { continue }

            Set-InputValue $Workflow $nodeProperty.Name $inputName $default.Value
            $present += $inputName
            $entry = '{0}.{1}={2}' -f $classType, $inputName, $default.Value
            if ($default.Guessed) { $guessed += $entry } else { $filled += $entry }
        }
    }

    if ($filled.Count -gt 0 -or $guessed.Count -gt 0) {
        $parts = @()
        if ($filled.Count -gt 0) {
            $parts += ("已按 ComfyUI 当前节点定义自动补齐必需输入：{0}（节点包升级新增的字段，无需修改工作流）。" -f ($filled -join '，'))
        }
        if ($guessed.Count -gt 0) {
            # 这些字段节点没有声明默认值，是工作站按类型/首项取的保守值，必须单独点名：
            # 用户看到「自动补齐」就不会去核对，而"猜错"的典型后果是静默用错模型或参数。
            $parts += ("以下输入节点未声明默认值，工作站按其类型取了保守值，请确认是否符合预期：{0}。" -f ($guessed -join '，'))
        }
        Add-BuildWarning ($parts -join ' ')
    }
}

function Get-ComfyChoiceOptionsInfo {
    # 与 Get-ComfyChoiceOptions 同源，但额外带一个「探测是否成功」的状态位：Ok / Options。
    # 【为什么必须要这个状态位】PowerShell 里 `return @()` 和 `return $null` **对调用方是一回事**：
    # 空数组不会产生任何管道输出，赋值后拿到的都是 $null。所以单靠返回值分不清
    # 「探测失败，不知道节点支持什么」和「确认节点没有这个输入」——
    # 而这两种情况的处理刚好相反：前者必须保持安静（免得对着一个其实支持该输入的节点说"接口里没有它"），
    # 后者必须明确告警（否则用户选的参数会被静默丢弃，正是兼容层要消灭的现象）。
    # 想用返回值表达三种结果，就得有个明确的载体。
    param([string]$ComfyUrl, [string]$ClassType, [string]$InputName)
    $result = [pscustomobject]@{ Ok = $false; Options = @() }
    $schema = Get-ComfyNodeSchema $ComfyUrl $ClassType
    if (-not $schema) { return $result }

    $result.Ok = $true
    # 输入的归属不看 required/optional，两个桶都找（原因见 Get-ComfyInputDefinition）。
    $definition = Get-ComfyInputDefinition $schema $InputName
    if ($null -eq $definition) { return $result }
    $items = @($definition)
    if ($items.Count -lt 1) { return $result }
    $typeSpec = $items[0]
    # 组合框的形态是 [ [候选...], { default = ... } ]：第一个元素是数组，而不是 "FLOAT" 这类字符串。
    if ($null -eq $typeSpec -or $typeSpec -is [string]) { return $result }
    if ($typeSpec -is [System.Array] -or $typeSpec -is [System.Collections.IList]) {
        $result.Options = @($typeSpec)
    }
    return $result
}

function Get-ComfyChoiceOptions {
    # 只要候选数组的入口（网页下拉、以及不关心探测状态的调用点用这个）。
    # 需要区分「探测失败」与「确认没有这个输入」时，请用 Get-ComfyChoiceOptionsInfo。
    # 关联数组约定：这里直接逐个输出元素，调用方一律用 @(...) 收口成数组。
    # 不要用 PowerShell 那个 `return ,@(...)` 的「防拆包」写法——它会和调用方的 @() 叠成
    # 「数组套数组」，导致 .Count 恒为 1、-contains 永远不成立（本函数第一版就踩了这个坑，
    # 结果「节点支持 mode」被判成「不认识 mode」，用户选的模式被静默丢弃）。
    param([string]$ComfyUrl, [string]$ClassType, [string]$InputName)
    $info = Get-ComfyChoiceOptionsInfo $ComfyUrl $ClassType $InputName
    return @($info.Options)
}

function Clear-ComfyNodeSchemaCache {
    # 清掉某个 ComfyUI 地址下的节点定义缓存。
    # 场景：用户刚更新了自定义节点包并重启 ComfyUI，点网页上的「测试连接」（fresh=1）期望立即生效；
    # 若不清理，Get-ComfyNodeSchema 的 10 分钟缓存会继续返回旧定义——例如 TE-Speed 刚升到 3.5，
    # 加速模式下拉却还是「不支持选择」，用户会以为新版本没装上。
    param([string]$ComfyUrl)
    if (-not $ComfyUrl) { $script:NodeSchemaCache = @{}; return }
    $prefix = "$ComfyUrl|"
    # 先复制一份键再删，避免边遍历边修改哈希表。
    foreach ($key in @($script:NodeSchemaCache.Keys)) {
        if ($key.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            $script:NodeSchemaCache.Remove($key) | Out-Null
        }
    }
}

function Set-TespeedMode {
    # 把网页上选的 TE-Speed 加速模式写进工作流。
    #
    # 兼容性说明（这就是本函数存在的全部理由）：
    #   mode 是 TE-Speed 3.5 才新增的输入。旧版节点没有这个输入，而 ComfyUI 会静默忽略
    #   未被节点声明的输入，所以「写进去」本身不会让旧版节点报错；但旧版节点是按实际采样
    #   步数自行切换内部策略的，用户选的模式并不会生效。因此这里必须先核对节点是否真的
    #   声明了 mode，不认识就明确提示——不能让用户以为切了模式，实际却被节点悄悄忽略。
    param($Workflow, [string]$NodeId, $Config, [string]$ComfyUrl)
    if (-not $Workflow -or -not $Workflow.PSObject.Properties[$NodeId]) { return }

    $mode = ''
    if ($Config -and $Config.PSObject.Properties['teMode']) { $mode = [string]$Config.teMode }
    # 网页没选模式（旧版网页、或该项被禁用）时什么都不做，
    # 交给提交前的 Complete-RequiredInputs 按节点声明的默认值补齐。
    if ([string]::IsNullOrWhiteSpace($mode)) { return }

    $info = Get-ComfyChoiceOptionsInfo $ComfyUrl 'TESpeedMiniMaxH3' 'mode'
    if (-not $info.Ok) {
        # 探测失败（ComfyUI 正在重启 / 读不到节点定义）：既不能写，也不要下结论。
        # 这里如果按「候选为空」处理，就会对着一个其实支持 mode 的节点打出「节点接口里没有 mode」——
        # 那是一句事实错误的话，还会把用户引向"去装/升级节点"这种无效操作。
        # 本次交给提交前的 Complete-RequiredInputs 兜底（它读同一份缓存，结论一致）。
        return
    }
    $supported = @($info.Options)
    if ($supported.Count -eq 0) {
        # 节点没有 mode 输入：standard 是它的固有行为，无需提示；选了非 standard 才提示。
        if ($mode -ne 'standard') {
            $message = "当前 TE-Speed 节点版本不支持加速模式选择（节点接口里没有 mode），已忽略「{0}」：" -f $mode
            Add-BuildWarning ($message + '该节点会按采样步数自行切换策略。安装 TE-Speed 3.5 及以上版本后本项才会生效。')
        }
        return
    }
    if ($supported -notcontains $mode) {
        Add-BuildWarning ("当前 TE-Speed 节点不认识加速模式「{0}」，本次已忽略；该节点可选：{1}。" -f $mode, ($supported -join ' / '))
        return
    }
    Set-InputValue $Workflow $NodeId 'mode' $mode
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
            # 全部走原始 JSON 文本判断，不再 ConvertFrom-Json：
            # 1) 超大 object_info（本机 5.4MB / 3027 节点）下 PSObject 属性索引会误判；
            # 2) 节点名存在仅大小写不同的重复时 ConvertFrom-Json 会直接抛异常
            #    （见 Get-ObjectInfoNodeNames 说明）。
            $jsonText = [Text.Encoding]::UTF8.GetString($remote.Bytes)
            if ($jsonText -match '"VHS_LoadVideo"\s*:') { return 'VHS_LoadVideo' }
            # ComfyUI 内置的 LoadVideo 节点：确认它确实声明了 IMAGE 输出，
            # 避免只是名字里含 LoadVideo 却拿不到帧序列。
            if ($jsonText -match '"LoadVideo"\s*:\s*\{[^}]*"output"\s*:\s*\[[^\]]*"IMAGE"') { return 'LoadVideo' }
        }
    } catch {}
    throw '当前 ComfyUI 未提供可将视频转换为 IMAGE 帧序列的 VHS_LoadVideo 节点，暂时不能提交视频参考。请安装 VideoHelperSuite 后重试。'
}

function Get-ComfyQueueState {
    # 读取 ComfyUI 队列状态，用于判断现在是否"完全空闲"。
    # 只有「正在执行」和「排队等待」的任务都为 0 时才算空闲，显存清理只在这个时机执行，
    # 保证清理落在"上一个任务已结束、下一个任务还没开始"的安全间隙里，不会打断排队生成。
    param([string]$ComfyUrl)
    $remote = Invoke-Comfy 'GET' "$ComfyUrl/queue"
    if (-not $remote.Success) { throw "无法读取 ComfyUI 队列状态（HTTP $($remote.StatusCode)）" }
    $queue = [Text.Encoding]::UTF8.GetString($remote.Bytes) | ConvertFrom-Json
    $running = @($queue.queue_running).Count
    $pending = @($queue.queue_pending).Count
    return [pscustomobject]@{
        Running = $running
        Pending = $pending
        Idle    = (($running -eq 0) -and ($pending -eq 0))
    }
}

function Clear-ComfyVram {
    # 调用 ComfyUI 官方 /free 接口卸载模型并释放显存，效果等同在 ComfyUI 界面点「清理显存」。
    # 注意：这是"任务边界"清理，调用方必须先确认队列空闲。
    param([string]$ComfyUrl)
    $body = [Text.Encoding]::UTF8.GetBytes('{"unload_models":true,"free_memory":true}')
    $remote = Invoke-Comfy 'POST' "$ComfyUrl/free" $body 'application/json'
    if (-not $remote.Success) { throw "ComfyUI 清理显存失败（HTTP $($remote.StatusCode)）" }
}

function Get-ComfyQueueIds {
    # 读取 ComfyUI 队列中「正在执行」与「排队等待」两组的 prompt_id。
    # 【为什么要分开拿到这两组 id】停止任务必须先知道这个任务处在哪个状态：排队中的可以
    # 直接从队列里删掉，正在执行的只能发中断；而「两组里都没有」说明它已经结束、已被取消
    # 或 ComfyUI 重启过 —— 这种情况绝不能动手，否则会误伤此刻真正在跑的那个任务。
    # 队列条目结构由 ComfyUI 固定为：[序号, prompt_id, prompt, extra_data, outputs_to_execute]。
    param([string]$ComfyUrl)
    $remote = Invoke-Comfy 'GET' "$ComfyUrl/queue"
    if (-not $remote.Success) { throw "无法读取 ComfyUI 队列状态（HTTP $($remote.StatusCode)）" }
    $queue = [Text.Encoding]::UTF8.GetString($remote.Bytes) | ConvertFrom-Json
    # 用显式循环而不是管道展开：JSON 里的队列是「数组的数组」，
    # 空队列或字段缺失时管道写法容易产出 $null 元素，显式循环的判断更直白。
    $running = @()
    $pending = @()
    foreach ($item in @($queue.queue_running)) {
        if ($item -and $item.Count -gt 1) { $running += [string]$item[1] }
    }
    foreach ($item in @($queue.queue_pending)) {
        if ($item -and $item.Count -gt 1) { $pending += [string]$item[1] }
    }
    return [pscustomobject]@{ Running = $running; Pending = $pending }
}

function Stop-ComfyPrompt {
    # 停止 ComfyUI 中的某一个任务（网页任务中心的「停止任务」）。
    # 只操作调用方明确指定的 promptId，无论它排在哪个位置，都不会牵连同队列里的其它任务。
    #
    # 【为什么优先用 /api/jobs/{id}/cancel】ComfyUI 新版（master 0.39 起）提供了状态无关的
    # 单任务取消接口：它内部用 interrupt_if_running() 在队列锁内原子地判断「这个 prompt 还
    # 在不在跑」再发中断，从根上避免了「判断时在跑 → 真正发信号时已经跑完 → 中断落到下一个
    # 任务头上」的串味；对已完成或未知的 id 也是幂等的（回 {"cancelled": false}，而非报错）。
    # 本项目验证过的 0.34.5 不一定有这个路由，所以 404/405 时回退到手工两步走。
    #
    # 【回退路径为什么必须先读队列】不带 prompt_id 的 /interrupt 是**全局**中断（见 ComfyUI
    # server.py 的 post_interrupt）：只要此刻真有任务在跑，一个全局中断就会把它打断。所以
    # 回退路径必须先用 /queue 确认「正在执行的就是这一个」，才允许发中断 —— 此时全局中断
    # 与定向中断等价，不会伤到别的任务。
    param([string]$ComfyUrl, [string]$PromptId)

    $jsonBody = [Text.Encoding]::UTF8.GetBytes((@{ prompt_id = $PromptId } | ConvertTo-Json -Compress))
    $jobUrl = "$ComfyUrl/api/jobs/$([Uri]::EscapeDataString($PromptId))/cancel"
    $cancel = Invoke-Comfy 'POST' $jobUrl $jsonBody 'application/json'

    if ($cancel.StatusCode -eq 404 -or $cancel.StatusCode -eq 405) {
        # 旧版 ComfyUI 没有这个路由，往下走手工回退。
    } elseif ($cancel.Success) {
        $cancelResult = [Text.Encoding]::UTF8.GetString($cancel.Bytes) | ConvertFrom-Json
        if ($cancelResult.cancelled) {
            return [pscustomobject]@{
                Stopped = $true
                Action  = 'cancelled'
                Message = '已在 ComfyUI 中停止该任务。'
            }
        }
        return [pscustomobject]@{
            Stopped = $false
            Action  = 'missing'
            Message = '该任务已不在 ComfyUI 队列中（可能刚好生成完成、已被取消，或 ComfyUI 重启过）。'
        }
    } else {
        throw "ComfyUI 拒绝停止任务（HTTP $($cancel.StatusCode)）。"
    }

    # —— 旧版回退：查队列 → 排队中则删除 → 再确认一次是否已开跑 → 是则中断 ——
    $queueState = Get-ComfyQueueIds $ComfyUrl
    # 【必须靠这个标志记住"删过"】删除成功之后要重读队列确认有没有开跑，而重读的结果里
    # 这个 id **必然**已经不在 pending 里了 —— 如果再拿重读结果判断"是不是排队任务"，
    # 刚删掉的任务会被判成"不在队列中"，向用户回报一个与事实相反的结论。
    $removedFromQueue = $false
    if ($queueState.Pending -contains $PromptId) {
        $deleteBody = [Text.Encoding]::UTF8.GetBytes((@{ delete = @($PromptId) } | ConvertTo-Json -Compress))
        $deleted = Invoke-Comfy 'POST' "$ComfyUrl/queue" $deleteBody 'application/json'
        if (-not $deleted.Success) { throw "ComfyUI 拒绝移除排队任务（HTTP $($deleted.StatusCode)）。" }
        # 「从队列删除」与「刚好被取出去执行」之间存在竞态窗口，删完再确认一次：
        # 如果它已经开跑，删除是空操作，必须补一次中断，否则用户以为停了、实际还在跑。
        $removedFromQueue = $true
        $queueState = Get-ComfyQueueIds $ComfyUrl
    }
    if ($queueState.Running -contains $PromptId) {
        $interrupt = Invoke-Comfy 'POST' "$ComfyUrl/interrupt" $jsonBody 'application/json'
        if (-not $interrupt.Success) { throw "ComfyUI 拒绝中断任务（HTTP $($interrupt.StatusCode)）。" }
        return [pscustomobject]@{
            Stopped = $true
            Action  = 'interrupted'
            Message = '已中断正在执行的任务，本次生成作废。'
        }
    }
    if ($removedFromQueue) {
        return [pscustomobject]@{
            Stopped = $true
            Action  = 'deleted'
            Message = '已从 ComfyUI 队列中移除，该任务不会再开始生成。'
        }
    }
    return [pscustomobject]@{
        Stopped = $false
        Action  = 'missing'
        Message = '该任务已不在 ComfyUI 队列中（可能刚好生成完成、已被取消，或 ComfyUI 重启过）。'
    }
}

function Get-RtxScaleValue {
    # 放大倍数限制为 1-4 的整数（1 倍不改变分辨率、仅走 RTX 画质增强），异常输入回退默认 2 倍。
    param($RawValue)
    $scale = 2
    try { if ($null -ne $RawValue) { $scale = [int][Math]::Round([double]$RawValue) } } catch {}
    return [Math]::Max(1, [Math]::Min(4, $scale))
}

function Test-RtxVfxRuntime {
    # 【为什么需要这个函数】
    # 判断 RTXVideoSuperResolution「节点是否存在」远远不够。这个节点只是 Python 外壳，
    # 真正的超分能力来自 NVIDIA NGX / MAXINE VFX 运行时。当 nvidia-vfx 包自带的
    # nvngx_vsr.dll 与当前显卡驱动不匹配、或模型/feature 文件缺失时，
    # 节点依然会出现在 /object_info 里（所以存在性探测会误判为「可用」），
    # 但一旦真正创建效果实例就抛：
    #   nvvfx.NvVFXError: NvVFX_CreateEffect failed:
    #   The requested feature is not yet implemented (code -2)
    # 结果是整个任务在采样完成后、后处理阶段崩掉 —— 用户白白等了几分钟。
    #
    # 【做法】提交一个极小的一次性探测工作流（64x64 纯色图 -> RTX超分 -> 预览），
    # 用 ComfyUI 自己的 /history 读取执行结果。这比猜 nvidia-vfx 版本号可靠得多：
    # 它直接回答「这台机器上、这个 ComfyUI 进程里，VSR 到底能不能跑」。
    # 探测工作流与用户任务共用同一个 ComfyUI 进程，结论完全等价。
    #
    # 【开销】图极小，实测 1-3 秒；结果按 ComfyUI 地址缓存（见 $script:RtxVfxCache），
    # 用户点「测试连接」时用 -Force 立即重测。
    param([string]$ComfyUrl, [switch]$Force)
    $now = Get-Date
    $cached = $script:RtxVfxCache[$ComfyUrl]
    if (-not $Force -and $cached -and ($now - $cached.At).TotalMinutes -lt 10) { return $cached }

    $verdict = [pscustomobject]@{
        At      = $now
        Ok      = $false
        Reason  = ''
        Detail  = ''
    }
    try {
        $clientId = [guid]::NewGuid().ToString('N')
        # 探测工作流：颜色节点用 EmptyImage 生成纯色图，避免依赖任何外部素材文件。
        $probe = [ordered]@{
            '1' = [ordered]@{ class_type = 'EmptyImage'; inputs = [ordered]@{ width = 64; height = 64; batch_size = 1; color = 0 } }
            '2' = [ordered]@{
                class_type = 'RTXVideoSuperResolution'
                inputs = [ordered]@{
                    images = @('1', 0)
                    resize_type = 'scale by multiplier'
                    'resize_type.scale' = 2.0
                    quality = 'ULTRA'
                }
            }
            '3' = [ordered]@{ class_type = 'PreviewImage'; inputs = [ordered]@{ images = @('2', 0) } }
        }
        $payload = @{ prompt = $probe; client_id = $clientId } | ConvertTo-Json -Depth 100 -Compress
        $submit = Invoke-Comfy 'POST' "$ComfyUrl/prompt" ([Text.Encoding]::UTF8.GetBytes($payload)) 'application/json; charset=utf-8'
        if (-not $submit.Success) {
            $verdict.Reason = 'ProbeRejected'
            $verdict.Detail = "探测工作流被拒绝（HTTP $($submit.StatusCode)）"
            $script:RtxVfxCache[$ComfyUrl] = $verdict
            return $verdict
        }
        $submitObj = [Text.Encoding]::UTF8.GetString($submit.Bytes) | ConvertFrom-Json
        $promptId = [string]$submitObj.prompt_id
        if ([string]::IsNullOrWhiteSpace($promptId)) {
            $verdict.Reason = 'ProbeRejected'
            $verdict.Detail = '探测工作流未返回 prompt_id'
            $script:RtxVfxCache[$ComfyUrl] = $verdict
            return $verdict
        }

        # 轮询执行结果，最多等 30 秒。VSR 初始化失败通常几秒内就返回。
        for ($i = 0; $i -lt 60; $i++) {
            Start-Sleep -Milliseconds 500
            $hist = Invoke-Comfy 'GET' "$ComfyUrl/history/$promptId"
            if (-not $hist.Success) { continue }
            $histText = [Text.Encoding]::UTF8.GetString($hist.Bytes)
            if ([string]::IsNullOrWhiteSpace($histText) -or $histText -eq '{}') { continue }
            # 记录已出现：检查是否报错
            if ($histText -match '"status_str"\s*:\s*"error"') {
                $verdict.Ok = $false
                $verdict.Reason = 'VsrUnavailable'
                # 从异常信息里提取原始报错，便于网页展示真实原因
                $m = [regex]::Match($histText, '"exception_message"\s*:\s*"((?:[^"\\]|\\.)*)"')
                if ($m.Success) { $verdict.Detail = $m.Groups[1].Value -replace '\\n', ' ' -replace '\\"', '"' }
                $script:RtxVfxCache[$ComfyUrl] = $verdict
                return $verdict
            }
            if ($histText -match '"completed"\s*:\s*true' -or $histText -match '"status_str"\s*:\s*"success"') {
                $verdict.Ok = $true
                $verdict.Reason = 'Ok'
                $verdict.Detail = 'RTX 视频超分运行正常'
                $script:RtxVfxCache[$ComfyUrl] = $verdict
                return $verdict
            }
        }
        # 超时：不下"不可用"的结论（可能只是队列忙），标记为未知，调用方按可用处理但给出提示。
        $verdict.Ok = $true
        $verdict.Reason = 'ProbeTimeout'
        $verdict.Detail = '探测超时（ComfyUI 队列可能繁忙），未确认 RTX 超分是否可用'
        $script:RtxVfxCache[$ComfyUrl] = $verdict
        return $verdict
    } catch {
        # 探测本身失败（网络等）不应阻断生成：按"未知"处理，留给实际执行去暴露问题。
        $verdict.Ok = $true
        $verdict.Reason = 'ProbeError'
        $verdict.Detail = "探测异常：$($_.Exception.Message)"
        return $verdict
    }
}

function Add-RtxUpscaleChain {
    # 在输出端接入 RTX 放大链（只做后处理，不碰采样链）：
    #   [可选：清显存] -> GetVideoComponents（拆出图像帧/音频/fps/位深/色彩空间）
    #   -> RTXVideoSuperResolution（只放大图像帧）-> CreateVideo（用原参数与原音频重新合成）。
    # 返回新 CreateVideo 的节点 ID，由调用方把保存节点的 video 输入改接到它。
    #
    # 【为什么要把「清显存」插在放大之前】
    # RTX 放大是整个图的最后一步。执行到它时采样刚结束，MiniMax H3 的权重和中间张量仍然占着
    # 显存（ComfyUI 不会在节点之间自动卸载模型）。而 RTX Video Super Resolution 走 NVIDIA NGX，
    # 需要自己申请一块显存去创建效果实例；显存已经吃紧时这一步很容易失败，
    # 表现就是"采样跑完了、后处理崩掉"，用户白等几分钟。
    # 所以先把模型卸掉、把缓存还回去，再让 VSR 申请显存。
    #
    # 【实现方式】用 ComfyUI-Easy-Use 的 easy cleanGpuUsed 做「透传式清显存」：
    #   anything 进、anything 出（INPUT_TYPES 里 required.anything 是 '*' 类型），
    #   且 OUTPUT_NODE=True。ComfyUI 的 validate_node_input 对 '*' 直接放行
    #   （comfy_execution/validation.py：received_type 或 input_type 为 '*' 即返回 True），
    #   所以它的输出可以直接接进 GetVideoComponents 的 VIDEO 输入，
    #   靠依赖关系强制出「先清显存、再放大」的顺序。
    #   它内部只做 gc.collect() + unload_all_models() + soft_empty_cache()，
    #   以及清 ComfyUI-Easy-Use 自己那张 tagged cache，不会破坏 ComfyUI 的执行缓存，
    #   因此接在图中段是安全的。
    #
    # 【和 v20260912 移除的「末尾清显存」不冲突】那次的移除原因是：清理节点接在整张图末尾，
    # 会在任务刚结束、队列里下一个任务刚要加载模型的瞬间执行，两边抢时序导致下一个任务读页缓存失败。
    # 这里插在图中段，本任务还在跑、队列里的下一个任务还没轮到，不存在这个问题。
    param($Workflow, [string]$SourceNodeId, [double]$Scale, [int]$StartId, [bool]$ClearVramBefore = $false)

    $need = 3
    if ($ClearVramBefore) { $need = 4 }
    $ids = @()
    $candidate = $StartId
    while ($ids.Count -lt $need) {
        $name = [string]$candidate
        if (-not $Workflow.PSObject.Properties[$name]) { $ids += $name }
        $candidate++
    }

    # 逐段往下接：每插入一级就把来源换成上一级的输出，保证执行顺序严格递增。
    $videoSource = @($SourceNodeId, 0)
    $index = 0
    if ($ClearVramBefore) {
        Add-WorkflowNode $Workflow $ids[0] 'easy cleanGpuUsed' ([ordered]@{ anything = $videoSource }) | Out-Null
        $videoSource = @($ids[0], 0)
        $index = 1
    }
    Add-WorkflowNode $Workflow $ids[$index] 'GetVideoComponents' ([ordered]@{ video = $videoSource }) | Out-Null
    Add-WorkflowNode $Workflow $ids[$index + 1] 'RTXVideoSuperResolution' ([ordered]@{
        resize_type = 'scale by multiplier'
        'resize_type.scale' = $Scale
        quality = 'ULTRA'
        images = @($ids[$index], 0)
    }) | Out-Null
    Add-WorkflowNode $Workflow $ids[$index + 2] 'CreateVideo' ([ordered]@{
        fps = @($ids[$index], 2)
        bit_depth = @($ids[$index], 3)
        color_space = @($ids[$index], 4)
        images = @($ids[$index + 1], 0)
        audio = @($ids[$index], 1)
    }) | Out-Null
    return $ids[$index + 2]
}

function Add-RtxUpscaleLink {
    # RTX 放大的统一接入点：基础三模式与全能参考共用，避免两处逻辑各写一遍后漂移。
    # 返回「最终视频连线」(@(节点ID, 输出槽))；未开启放大或节点缺失时原样返回来源连线。
    param($Workflow, [string]$SourceNodeId, [int]$StartId, $Config, $Capabilities)

    $link = @($SourceNodeId, 0)
    if (-not $Config.rtxUpscale) { return $link }

    # RTX 放大是可选的画质增强：没装节点包时跳过放大继续出片，而不是阻断整个生成。
    if (-not $Capabilities.RtxUpscale) {
        Add-BuildWarning '未检测到 RTXVideoSuperResolution 节点（NVIDIA RTX Video 节点包），本次已跳过 RTX 放大，视频按原分辨率输出。安装节点包并重启 ComfyUI 后会自动恢复。'
        return $link
    }

    # 放大前先清显存（见 Add-RtxUpscaleChain 的详细说明）。
    # 清显存节点是 ComfyUI-Easy-Use 提供的可选节点：缺失时不让放大失败，但要明确告诉用户
    # 「这次没能在放大前腾显存」——放大真失败时，这就是最可能的原因。
    $clearBefore = [bool]$Capabilities.ClearVramNode
    if (-not $clearBefore) {
        Add-BuildWarning '未检测到 ComfyUI-Easy-Use（easy cleanGpuUsed），本次无法在 RTX 放大前预先清理显存。若放大失败，请安装该节点包后重试；也可以把放大倍数降到 1-2 倍减少显存压力。'
    }

    $scale = Get-RtxScaleValue $Config.rtxUpscaleScale
    $videoOut = Add-RtxUpscaleChain $Workflow $SourceNodeId $scale $StartId -ClearVramBefore:$clearBefore
    return @($videoOut, 0)
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
    # 时长夹紧到 1-15 秒（与基础三模式的处理一致），否则直连 API 可以传任意值：
    # 因为 length 是一条连线，ComfyUI 的校验期看不到它的数值，超大时长会直接入队。
    # 帧数换算也必须与基础三模式共用同一个公式：此前这里沿用了工作流 JSON 里烘焙的旧公式
    # （向上取整到下一个 5+17n），而基础模式用的是"四舍五入到最近的 5+17n"，
    # 结果同一个秒数在两种模式下最多差 17 帧（0.71 秒），例如 6 秒分别是 158 帧与 141 帧。
    $duration = [Math]::Max(1, [Math]::Min(15, [int]$Config.duration))
    Set-InputValue $Workflow $durationNode 'value' ([double]$duration)
    Set-InputValue $Workflow '131' 'expression' $script:FrameExpression
    # 节点 144 用同一公式算出参考视频要截取多少帧（frame_load_cap），保持两者一致。
    Set-InputValue $Workflow '144' 'value' $script:FrameExpression
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
    Set-InputValue $Workflow $resolutionNode 'megapixels' (Get-SafeMegapixels $Config.megapixels)

    Set-InputValue $Workflow $referenceNode 'prompt' ([string]$Config.prompt)
    Set-InputValue $Workflow $referenceNode 'length' @('131', 1)
    Set-InputValue $Workflow $referenceNode 'width' @($resolutionNode, 0)
    Set-InputValue $Workflow $referenceNode 'height' @($resolutionNode, 1)

    # LoRA / TE-Speed 都是可选自定义节点：缺失时旁路继续生成，不让整单失败。
    $capabilities = Get-ComfyCapabilities $ComfyUrl
    Set-CapabilityCache $ComfyUrl $capabilities
    $loraCount = 0
    if ($capabilities.LoraManager) {
        $loraText = Set-LoraManagerInputs $Workflow $loraNodeId $Config.loras
        $loraCount = $loraText.Count
    } else {
        Add-BuildWarning '未检测到 ComfyUI-Lora-Manager 节点，本次已跳过 LoRA（仍会正常生成，只是少了 LoRA 效果）。安装该节点包并重启 ComfyUI 后会自动恢复。'
    }

    $modelLink = if ($loraCount -gt 0) { @($loraNodeId, 0) } else { @($unetNode, 0) }
    if ($loraCount -eq 0) {
        # 未启用 LoRA 时模型链已绕过该节点，但 ComfyUI 仍会校验节点里烘焙的默认 LoRA 名，
        # 文件被移入子文件夹/重命名后会直接 400，这里整个移除。
        Remove-WorkflowNode $Workflow $loraNodeId
    }
    if ($capabilities.TEspeed) {
        Set-InputValue $Workflow $speedNode 'model' $modelLink
        # 加速模式（standard / 4-step LoRA / 8-step LoRA）只在节点确实被保留时才注入，
        # 否则节点马上会被移除，再提示模式不生效就是误导。节点版本不支持时会给出明确提示。
        Set-TespeedMode $Workflow $speedNode $Config $ComfyUrl
    } else {
        # 没有 TE-Speed 时把模型直接接到采样器的 guider（节点 126），跳过加速而不是报错。
        Add-BuildWarning '未检测到 TE-SpeedMiniMaxH3 加速节点，本次已跳过加速（生成会变慢，结果正常）。安装该节点包并重启 ComfyUI 后会自动恢复。'
        Remove-WorkflowNode $Workflow $speedNode
        Set-InputValue $Workflow '126' 'model' $modelLink
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
        } else {
            Remove-InputValue $Workflow $referenceNode $inputName
            # 预置但未使用的图片节点（169 等）：摘掉端口后若已无人引用，一并移除以避免空负载。
            # Remove-OrphanLoader 返回删除计数，必须丢弃：裸调用会把计数泄漏进本函数的输出流，
            # 导致 Build-Workflow 收到「计数+工作流」数组、prompt 字段序列化成 JSON 数组（ComfyUI 500）。
            if ($i -eq 1) { Remove-OrphanLoader $Workflow @('169') | Out-Null }
        }
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
            # 未使用的视频加载节点（141）及其专属尺寸链：141 载入视频后经 156(缩放) 算尺寸，
            # 再由 154(取尺寸) 供 136 使用。无视频时这条链整条都失去意义，一起清掉可避免把
            # 本地视频文件名带进请求体（旧版工作流里 141.video 曾直接存着用户素材名）。
            # 白名单刻意不含 171(ResolutionSelector)：它是 136 的 width/height 来源，必须保留。
            if ($i -eq 0) { Remove-OrphanLoader $Workflow @('141', '156', '154') | Out-Null }
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
            # 未使用的音频加载节点（170）：同样按需移除。
            if ($i -eq 0) { Remove-OrphanLoader $Workflow @('170') | Out-Null }
        }
    }


    # 提示词已由网页独立生成并直接写入节点 136；移除工作流残留的 AI 节点与模板，
    # 防止无关 API Key、自定义节点校验或旧结果影响最终提交。
    Remove-WorkflowNode $Workflow '164'
    Remove-WorkflowNode $Workflow '165'
    Remove-WorkflowNode $Workflow '166'

    # 显存清理不再放进工作流：工作流末尾的清理节点会在推理刚结束时立刻清显存，而 ComfyUI 会
    # 马上接着执行队列里的下一个任务，导致下一个任务加载模型时读取失败
    # （comfy-aimdo 动态显存加载的页缓存被清掉）。现统一改为"提交任务前、且队列空闲时"
    # 调用 ComfyUI 官方 /free 接口，让清理时机与排队执行彻底解耦。
    # 保存节点(172)固定接在 CreateVideo(130) 上；RTX 放大插在两者之间。
    $saveSource = '130'
    # 统一走 Add-RtxUpscaleLink：未开启 RTX 时原样返回 CreateVideo 的连线。
    $finalVideoLink = Add-RtxUpscaleLink $Workflow $saveSource $nextId $Config $capabilities

    # 输出节点统一用 ComfyUI 官方内置的 SaveVideo（工作流 JSON 里节点 172 已经是 SaveVideo），
    # 全能参考因此不再依赖第三方的 ComfyUI-MetadataCleaner。
    Set-InputValue $Workflow '172' 'video' $finalVideoLink

    return $Workflow
}

function Get-H3FrameCount {
    # 秒数 -> MiniMax H3 合法帧数（必须落在 5 + 17n 上）。
    # 与 $script:FrameExpression 是同一套公式，这里先算成整数，供导演台划分各分镜的帧范围。
    param([double]$Seconds)
    $steps = [Math]::Round(($Seconds * 24 - 5) / 17)
    if ($steps -lt 0) { $steps = 0 }
    return [int](5 + $steps * 17)
}

function Get-H3Overlap {
    # 相邻分镜之间的重叠帧数，复刻节点包 js/segment_windows.mjs 的 nearestOverlap。
    #
    # 候选集 = [0, 1] 再加上所有 5+17n（H3 的合法帧数梯度），筛掉超过上限的，
    # 最后挑出最接近目标值（默认 39）的那个。所以：
    #   * 段足够长时结果就是 39；
    #   * 段很短、上限不足 39 时会退到 22 / 5 / 1 / 0。
    # 比较用严格小于、初值取 0，与官方 reduce 的行为一致（等距时保留先出现的）。
    param([int]$Maximum, [int]$Target = 39)
    $candidates = New-Object System.Collections.Generic.List[int]
    $candidates.Add(0)
    $candidates.Add(1)
    $steps = [Math]::Max(0, [Math]::Floor(($Maximum - 5) / 17) + 1)
    for ($i = 0; $i -lt $steps; $i++) { $candidates.Add(5 + 17 * $i) }
    $best = 0
    foreach ($candidate in $candidates) {
        if ($candidate -gt $Maximum) { continue }
        if ([Math]::Abs($candidate - $Target) -lt [Math]::Abs($best - $Target)) { $best = $candidate }
    }
    return $best
}

function Build-DirectorWorkflow {
    # 「长视频导演台」（ComfyUI-MiniMaxH3-TimelineDirector · Songssx）构建。
    #
    # 它与其余四个模式最大的不同：提示词 / 参考图 / 分镜划分 / 二采超分设置
    # 全部塞在节点 7（MiniMaxH3TimelinePlanner）的 timeline_data 这一条 JSON 字符串里，
    # 而不是挂在普通节点的输入上。所以这里的主要工作是把网页表单重新组装成 timeline_data。
    #
    # 分镜帧范围的约定：每段各自取 5+17n 帧（单段生成必须满足这个约束），
    # 段与段之间按「绝对帧号」累加 —— 第 2 段从第 1 段的 endFrame 接着往下排。
    # 单段时结果与画布上手工导出的工作流完全一致（15 秒 -> 362 帧 -> 15.0833 秒）。
    param($Config, $Workflow, [string]$ComfyUrl, $Capabilities)

    # ---- 分段与提示词 ----
    # 语义照抄素材规划台（它的 globalPromptHint / globalPromptInactive 两条文案）：
    #   * 每一段提示词都为空  -> 「全局提示词」生效，并复用到每一段；
    #   * 只要有任何一段填了 -> 全局提示词不生效，且要求每一段都补齐。
    $globalPrompt = [string]$Config.directorGlobalPrompt
    $segments = @()
    foreach ($item in @($Config.directorSegments)) {
        if (-not $item) { continue }
        $text = if ($item.PSObject.Properties['prompt']) { [string]$item.prompt } else { '' }
        $seconds = 5
        if ($item.PSObject.Properties['duration']) { $seconds = [int]$item.duration }
        # 该段引用哪些素材（按文件名）。这里必须区分两种"空"：
        #   null（字段为 null） = 未指定 -> 引用全部（"全选"时前端存的就是 null）
        #   数组（含空数组）    = 显式指定 -> 空数组表示这一段不引用任何同类素材，
        #                         素材规划台本身是允许的（官方用例里有 images:[] 只挂音频的段）。
        # 注意别用 @() 兜底把两者抹平：PowerShell 5.1 能区分（null 判为 $null，空数组是长度 0 的
        # Object[]），但比较时**必须把 $null 写在左边**，否则 -ne 会退化成「数组过滤」而不是标量比较。
        $imageNamesProperty = $item.PSObject.Properties['imageNames']
        $hasImageFilter = $false
        $imageNames = @()
        if ($imageNamesProperty -and ($null -ne $imageNamesProperty.Value)) {
            $hasImageFilter = $true
            $imageNames = @($imageNamesProperty.Value)
        }
        $audioNamesProperty = $item.PSObject.Properties['audioNames']
        $hasAudioFilter = $false
        $audioNames = @()
        if ($audioNamesProperty -and ($null -ne $audioNamesProperty.Value)) {
            $hasAudioFilter = $true
            $audioNames = @($audioNamesProperty.Value)
        }
        $segments += [pscustomobject]@{
            Prompt         = $text
            Duration       = [Math]::Max(1, [Math]::Min(15, $seconds))
            ImageNames     = $imageNames
            HasImageFilter = $hasImageFilter
            AudioNames     = $audioNames
            HasAudioFilter = $hasAudioFilter
        }
    }
    if ($segments.Count -eq 0) { throw '长视频导演台至少需要 1 个分段。' }

    $useGlobalPrompt = $true
    foreach ($segment in $segments) {
        if (-not [string]::IsNullOrWhiteSpace($segment.Prompt)) { $useGlobalPrompt = $false; break }
    }
    if ($useGlobalPrompt) {
        if ([string]::IsNullOrWhiteSpace($globalPrompt)) { throw '请填写「全局提示词」，或给每一段分别填写提示词。' }
        foreach ($segment in $segments) { $segment.Prompt = $globalPrompt }
    } else {
        for ($index = 0; $index -lt $segments.Count; $index++) {
            if ([string]::IsNullOrWhiteSpace($segments[$index].Prompt)) {
                throw ("第 {0} 段还没填提示词：要么把每段都补全，要么把所有分段的提示词清空、改用全局提示词。" -f ($index + 1))
            }
        }
    }

    # ---- 参考图：网页已上传到 minimax_h3_timeline_director/ 子目录，这里登记成 images[] ----
    $imageObjects = @()
    $imageIds = @()
    $imageIndex = 0
    foreach ($item in @($Config.directorImages)) {
        if (-not $item) { continue }
        $file = if ($item.PSObject.Properties['file']) { [string]$item.file } else { '' }
        $file = $file.Replace('\', '/').TrimStart('/')
        if ([string]::IsNullOrWhiteSpace($file)) { continue }
        $imageIndex++
        $id = 'ref{0}' -f $imageIndex
        $imageIds += $id
        $width = 0
        $height = 0
        if ($item.PSObject.Properties['width']) { $width = [int]$item.width }
        if ($item.PSObject.Properties['height']) { $height = [int]$item.height }
        $imageObjects += [pscustomobject]@{
            id     = $id
            file   = $file
            name   = [System.IO.Path]::GetFileName($file)
            width  = $width
            height = $height
        }
    }

    # ---- 参考视频 / 音频：登记进 videoClips[] 与 audios[]，再由分镜按 id 引用 ----
    # 字段结构取自节点包源码（Songssx/ComfyUI-MiniMaxH3-TimelineDirector）：
    #   * js/minimax_h3_timeline_director.js 导入视频时构造的对象是
    #     {id,file,name,start,duration,trimStart,sourceDuration,hasAudio,referenceMode,peaks,proxy}；
    #   * 同一文件加载音频时会补上 id 与 audioMode（"reference" | "locked"），且只要求存在 file；
    #   * segments[].images / segments[].audios 都是「id 字符串数组」，videoClips 则是全局的。
    $videoObjects = @()
    $videoIds = @()
    $videoIndex = 0
    foreach ($item in @($Config.directorVideos)) {
        if (-not $item) { continue }
        $file = if ($item.PSObject.Properties['file']) { [string]$item.file } else { '' }
        $file = $file.Replace('\', '/').TrimStart('/')
        if ([string]::IsNullOrWhiteSpace($file)) { continue }
        $videoIndex++
        $id = 'clip{0}' -f $videoIndex
        $videoIds += $id
        $seconds = 0.0
        if ($item.PSObject.Properties['duration']) { $seconds = [double]$item.duration }
        # 【必须保证 duration > 0 且 hasAudio 不为 false】
        # 节点侧 minimax_h3_finite_segments.py 对 videoClips 有两道硬过滤：
        #     clip.get("file") and clip.get("hasAudio", True) is not False
        #     and float(clip.get("duration") or 0.0) > 0.0
        # 即：hasAudio=false 的视频、以及时长读不出来（0 或缺失）的视频都会被【静默丢弃】——
        # 界面上传了却完全不参与生成，而且没有任何报错。所以这里宁可兜底也不能留 0。
        # 兜底 5 秒与节点侧 JS 归一化的 num(c.duration, 5) 默认值一致。
        if ($seconds -le 0) { $seconds = 5 }
        $videoObjects += [pscustomobject]@{
            id             = $id
            file           = $file
            name           = [System.IO.Path]::GetFileName($file)
            start          = 0
            duration       = $seconds
            trimStart      = 0
            sourceDuration = $seconds
            # 官方网页的归一化是 c.hasAudio !== false（默认 true），这里必须跟随默认值：
            # 给 false 会让整条参考视频被过滤掉。
            hasAudio       = $true
            referenceMode  = 'guide'
            peaks          = @()
            proxy          = ''
        }
    }

    $audioObjects = @()
    $audioIds = @()
    $audioIndex = 0
    foreach ($item in @($Config.directorAudios)) {
        if (-not $item) { continue }
        $file = if ($item.PSObject.Properties['file']) { [string]$item.file } else { '' }
        $file = $file.Replace('\', '/').TrimStart('/')
        if ([string]::IsNullOrWhiteSpace($file)) { continue }
        $audioIndex++
        $id = 'audio{0}' -f $audioIndex
        $audioIds += $id
        $seconds = 0.0
        if ($item.PSObject.Properties['duration']) { $seconds = [double]$item.duration }
        $audioObjects += [pscustomobject]@{
            id        = $id
            file      = $file
            name      = [System.IO.Path]::GetFileName($file)
            duration  = $seconds
            audioMode = 'reference'
        }
    }

    # ---- 帧范围：与节点包 js/segment_windows.mjs 的 createWindows 保持同一几何 ----
    # 每段各自取 5+17n 帧；**相邻两段默认重叠 39 帧**，首段仍从 0 开始。
    #
    # 为什么是 39：官方 createWindows 里 overlap 的默认值就是这个字面量，并且会用
    # nearestOverlap 把它吸附到 [0, 1, 5, 22, 39, 56, ...] 中「不超过
    # min(本段帧数, 上段帧数) - 1」的最接近值 —— 段很短时重叠会随之变小。
    # 三处佐证（均取自节点包源码，非推断）：
    #   * 官方单测 tests/segment_windows.test.mjs：createWindows([],4,243) 的
    #     startFrame = [0, 204, 408, 612]，步长 204 = 243 - 39；
    #   * 官方示例工作流 example_workflows/…导演台工作流.json 里两段是 {0,192}
    #     与 {153,396}，192 - 153 = 39；
    #   * editWindow() 的注释明确要求 "preserve existing seam overlaps"。
    # 这段重叠是跨段承接用的。早先按「无缝累加」实现（上一段 endFrame 直接当下一段
    # 起点），会让成片比官方长、且段边界缺少承接区间，故改回官方几何。
    $segmentLengths = @()
    foreach ($segment in $segments) { $segmentLengths += (Get-H3FrameCount $segment.Duration) }

    $segmentObjects = @()
    $lastFrame = 0
    for ($index = 0; $index -lt $segments.Count; $index++) {
        $segment = $segments[$index]
        $frames = $segmentLengths[$index]
        if ($index -eq 0) {
            $startFrame = 0
        } else {
            # 重叠上限 = min(本段, 上段) - 1；理论上限为负时按 0 处理（不重叠且不可后移）。
            $overlapLimit = [Math]::Min($frames, $segmentLengths[$index - 1]) - 1
            $overlap = if ($overlapLimit -ge 0) { Get-H3Overlap $overlapLimit } else { 0 }
            $startFrame = $lastFrame - $overlap
        }
        # 本段引用的素材：没指定过（null）就引用全部；指定过（哪怕是空数组）就按名单挑，
        # 空名单即"这一段不引用任何同类素材"。
        $segmentImageIds = @()
        foreach ($image in $imageObjects) {
            if (-not $segment.HasImageFilter) { $segmentImageIds += $image.id; continue }
            if ($segment.ImageNames -contains $image.name) { $segmentImageIds += $image.id }
        }
        $segmentAudioIds = @()
        foreach ($audio in $audioObjects) {
            if (-not $segment.HasAudioFilter) { $segmentAudioIds += $audio.id; continue }
            if ($segment.AudioNames -contains $audio.name) { $segmentAudioIds += $audio.id }
        }
        $segmentObjects += [pscustomobject]@{
            images     = @($segmentImageIds)
            audios     = @($segmentAudioIds)
            prompt     = $segment.Prompt
            startFrame = $startFrame
            endFrame   = $startFrame + $frames
        }
        $lastFrame = $startFrame + $frames
    }
    # 成片总长 = 最后一段的结束帧（段间重叠已经体现为总长的减少）。
    $totalSeconds = [Math]::Round($lastFrame / 24.0, 6)

    # ---- 二采超分（secondPass） ----
    $secondPass = $true
    if ($null -ne $Config.directorSecondPass) { $secondPass = [bool]$Config.directorSecondPass }
    $secondPassModel = [string]$Config.directorSecondPassModel
    if ([string]::IsNullOrWhiteSpace($secondPassModel)) { $secondPassModel = 'minimax_h3_latent_upscaler_3d_bf16.safetensors' }
    $highSteps = 2
    if ($null -ne $Config.directorSecondPassSteps) { $highSteps = [int]$Config.directorSecondPassSteps }
    $highSteps = [Math]::Max(1, [Math]::Min(10, $highSteps))

    $timeline = [ordered]@{
        version             = 9
        fps                 = 24
        globalPrompt        = $globalPrompt
        secondPass          = $secondPass
        secondPassModel     = $secondPassModel
        secondPassHighSteps = $highSteps
        selection           = [ordered]@{ start = 0; duration = $totalSeconds }
        videoAudioEnabled   = $true
        videoClips          = @($videoObjects)
        images              = @($imageObjects)
        audios              = @($audioObjects)
        segmentConfig       = [ordered]@{
            count       = $segmentObjects.Count
            activeIndex = 0
            mode        = 'timeline'
            segments    = @($segmentObjects)
        }
    }
    Set-InputValue $Workflow '7' 'timeline_data' ($timeline | ConvertTo-Json -Depth 20 -Compress)
    Set-InputValue $Workflow '7' 'generation_seconds' $totalSeconds

    # ---- 常规参数 ----
    Set-InputValue $Workflow '18' 'aspect_ratio' (Normalize-AspectRatio ([string]$Config.aspectRatio))
    Set-InputValue $Workflow '18' 'megapixels' (Get-SafeMegapixels $Config.megapixels)
    Set-InputValue $Workflow '1' 'unet_name' ([string]$Config.unet)
    Set-InputValue $Workflow '2' 'clip_name' ([string]$Config.clip)
    Set-InputValue $Workflow '3' 'vae_name' ([string]$Config.videoVae)
    Set-InputValue $Workflow '4' 'vae_name' ([string]$Config.audioVae)
    Set-InputValue $Workflow '5' 'steps' ([int]$Config.steps)
    Set-InputValue $Workflow '6' 'sampler_name' ([string]$Config.samplerName)
    Set-InputValue $Workflow '8' 'seed' (Get-SafeSeed $Config.seed)

    # ---- 模型链逐级降级：1 → 20 → 32 → 33 → 23 → 17 → (5, 8) ----
    # 缺哪个可选节点就把它从链上摘掉，用前一个节点的 MODEL 直接接给下一个，不影响出片。
    $modelChain = @(
        [pscustomobject]@{ Id = '20'; Ok = [bool]$Capabilities.LoraManager;             Label = 'ComfyUI-LoraManager' }
        [pscustomobject]@{ Id = '32'; Ok = [bool]$Capabilities.MiniMaxLowVRAMAttention; Label = 'ComfyUI-KJNodes（MiniMaxLowVRAMAttention）' }
        [pscustomobject]@{ Id = '33'; Ok = [bool]$Capabilities.MiniMaxChunkFeedForward; Label = 'ComfyUI-KJNodes（MiniMaxChunkFeedForward）' }
        [pscustomobject]@{ Id = '23'; Ok = [bool]$Capabilities.TEspeed;                 Label = 'TE-SpeedMiniMaxH3' }
        [pscustomobject]@{ Id = '17'; Ok = [bool]$Capabilities.SageAttentionKJ;         Label = 'ComfyUI-KJNodes（PathchSageAttentionKJ）' }
    )
    $source = @('1', 0)
    $dropped = @()
    foreach ($link in $modelChain) {
        if (-not $link.Ok) {
            $dropped += $link.Label
            Remove-WorkflowNode $Workflow $link.Id
            continue
        }
        Set-InputValue $Workflow $link.Id 'model' $source
        $source = @($link.Id, 0)
    }
    Set-InputValue $Workflow '5' 'model' $source
    Set-InputValue $Workflow '8' 'model' $source

    # CLIP：LoraManager 在链上时用它输出的 CLIP（LoRA 同样作用于文本编码器），摘掉后直连 CLIPLoader。
    if ($Capabilities.LoraManager) { Set-InputValue $Workflow '8' 'clip' @('20', 1) }
    else { Set-InputValue $Workflow '8' 'clip' @('2', 0) }

    if ($dropped.Count -gt 0) {
        Add-BuildWarning ('导演台链路缺少可选节点，本次已跳过：{0}。安装对应节点包并重启 ComfyUI 后自动恢复，结果仍会正常产出。' -f (($dropped | Select-Object -Unique) -join '、'))
    }

    # LoRA 写入（节点缺失时上面已摘除，这里只在存在时写）
    if ($Capabilities.LoraManager) { [void](Set-LoraManagerInputs $Workflow '20' $Config.loras) }

    # TE-Speed 参数与加速模式
    if ($Capabilities.TEspeed) {
        Set-InputValue $Workflow '23' 'processing_control_value' ([double]$Config.teControl)
        Set-InputValue $Workflow '23' 'processing_percent_1' ([double]$Config.tePercent1)
        Set-InputValue $Workflow '23' 'processing_percent_2' ([double]$Config.tePercent2)
        Set-TespeedMode $Workflow '23' $Config $ComfyUrl
    }

    # SIGMAS 链：5 → 30 → 8；缺 H3SigmaRefiner 时把 5 的 SIGMAS 直连 8
    if ($Capabilities.H3SigmaRefiner) {
        Set-InputValue $Workflow '8' 'sigmas' @('30', 0)
    } else {
        Remove-WorkflowNode $Workflow '30'
        Set-InputValue $Workflow '8' 'sigmas' @('5', 0)
        Add-BuildWarning '未检测到 H3SigmaRefiner（ComfyUI-YCNodes-MiniMax-H3），本次已跳过额外精修步（结果仍会正常产出）。'
    }

    # RTX 放大：导演台的输出链是 CreateVideo(9) → SaveVideo(10)，与基础三模式/全能参考同构，
    # 直接复用同一个统一接入点把它插在两者之间；未开启放大（或没装节点包）时原样返回
    # CreateVideo 的连线，走的是和以前完全一样的直连路径。
    $nextId = 1000
    foreach ($property in $Workflow.PSObject.Properties) {
        try { $nextId = [Math]::Max($nextId, [int]$property.Name + 1) } catch {}
    }
    $finalVideoLink = Add-RtxUpscaleLink $Workflow '9' $nextId $Config $Capabilities
    Set-InputValue $Workflow '10' 'video' $finalVideoLink

    return $Workflow
}

function Build-Workflow {
    param($Config, [string]$ComfyUrl)
    # 每次构建都重置降级提示；能力探测结果按地址缓存 60 秒。
    $script:BuildWarnings = @()
    $capabilities = Get-ComfyCapabilities $ComfyUrl
    # 探测结果用回写刷新一次时间戳：避免用户连续提交时每 60 秒就重新拉一遍 /object_info。
    Set-CapabilityCache $ComfyUrl $capabilities
    # 关键节点缺失时给出明确原因（这些由较新版本 ComfyUI 内置，无法自动降级）。
    $missingCore = @()
    $missingDirector = @()
    if ([string]$Config.mode -eq 'director') {
        # 导演台不用内置的 MiniMaxH3ImageToVideo / MiniMaxH3ReferenceToVideo 出片，
        # 而是由 ComfyUI-MiniMaxH3-TimelineDirector（Songssx）的两个节点承担，
        # 所以这两项单独检查、单独提示（缺的是节点包，不是 ComfyUI 版本）。
        if (-not $capabilities.MiniMaxH3TimelinePlanner) { $missingDirector += 'MiniMaxH3TimelinePlanner' }
        if (-not $capabilities.MiniMaxH3FiniteSegmentSampler) { $missingDirector += 'MiniMaxH3FiniteSegmentSampler' }
    } elseif ([string]$Config.mode -eq 'ref2va') {
        if (-not $capabilities.MiniMaxH3ReferenceToVideo) { $missingCore += 'MiniMaxH3ReferenceToVideo' }
    } elseif (-not $capabilities.MiniMaxH3ImageToVideo) {
        $missingCore += 'MiniMaxH3ImageToVideo'
    }
    if (-not $capabilities.ResolutionSelector) { $missingCore += 'ResolutionSelector' }
    # ComfyMathExpression 只被三个基础模式的帧数表达式用到，导演台没有这个节点。
    if ([string]$Config.mode -ne 'director' -and -not $capabilities.ComfyMathExpression) { $missingCore += 'ComfyMathExpression' }
    if (-not $capabilities.CreateVideo) { $missingCore += 'CreateVideo' }
    # 五个工作流的输出节点都是官方内置的 SaveVideo，它是必需节点。
    if (-not $capabilities.SaveVideo) { $missingCore += 'SaveVideo' }
    if ($missingDirector.Count -gt 0) {
        throw "「长视频导演台」需要 ComfyUI-MiniMaxH3-TimelineDirector 节点包，当前缺少：$($missingDirector -join '、')。请安装该节点包（Songssx/ComfyUI-MiniMaxH3-TimelineDirector）并重启 ComfyUI 后重试。"
    }
    if ($missingCore.Count -gt 0) {
        throw "当前 ComfyUI 缺少必需节点：$($missingCore -join '、')。这些节点由较新版本 ComfyUI 内置（comfy_extras），请更新 ComfyUI 后重试（本项目在 0.34.5 上验证）。"
    }
    $allowedFiles = @(
        'minimaxH3文生视频基础加速流.json',
        'minimaxH3图生视频基础加速流.json',
        'minimaxH3首尾帧视频基础加速流.json',
        '图片+音频参考加速ai提示词工作流.json',
        'minimaxh3全能参考(图片+视频+音频)+ai提示词生成+加速+Lora.json',
        'minimaxH3长视频导演台加速流.json'
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
    if ([string]$Config.mode -eq 'director') {
        # 导演台的工作流文件是 ComfyUI 画布导出的 UI 格式（用户在画布上改完直接导出），
        # 提交前先转成 API 格式再注入参数。
        if ($workflow.PSObject.Properties['nodes']) { $workflow = Convert-UiWorkflowToApi $workflow }
        return Build-DirectorWorkflow $Config $workflow $comfyUrl $capabilities
    }

    $duration = [Math]::Max(1, [Math]::Min(15, [int]$Config.duration))
    Set-InputValue $workflow '105:111' 'value' $duration
    # MiniMax H3 接受 5 + 17n 帧。按 24fps 将秒数映射到最接近的合法帧数（公式见 $script:FrameExpression，
    # 全能参考模式共用同一份，避免同一个秒数在两种模式下算出不同时长）。
    Set-InputValue $workflow '105:107' 'expression' $script:FrameExpression
    # ResolutionSelector 的 COMBO 值必须逐字匹配。这里同时兼容旧版网页保存在 localStorage 中的名称。
    $aspectRatio = Normalize-AspectRatio ([string]$Config.aspectRatio)
    Set-InputValue $workflow '115' 'aspect_ratio' $aspectRatio
    Set-InputValue $workflow '115' 'megapixels' (Get-SafeMegapixels $Config.megapixels)
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

    # LoRA 与 TE-Speed 都是「可选」自定义节点：用户没装时不能让整单失败，改为旁路后继续生成。
    $loraCount = 0
    if ($capabilities.LoraManager) {
        $loraText = Set-LoraManagerInputs $workflow '105:129' $Config.loras
        $loraCount = $loraText.Count
    } else {
        Add-BuildWarning '未检测到 ComfyUI-Lora-Manager 节点，本次已跳过 LoRA（仍会正常生成，只是少了 LoRA 效果）。安装该节点包并重启 ComfyUI 后会自动恢复。'
    }

    # 无 LoRA（或没有 LoraManager）时绕过该节点，模型从 UNET 直接往下走。
    $speedModel = if ($loraCount -gt 0) { @('105:129', 0) } else { @('105:6', 0) }
    if ($loraCount -eq 0) {
        # 未启用 LoRA 时移除节点，避免其烘焙的默认 LoRA 名失效导致 ComfyUI 校验 400。
        Remove-WorkflowNode $workflow '105:129'
    }

    if ($capabilities.TEspeed) {
        Set-InputValue $workflow '105:122' 'model' $speedModel
        # 加速模式（standard / 4-step LoRA / 8-step LoRA）：只在节点确实被保留时才注入，
        # 节点版本不支持时会给出明确提示，而不是让用户以为切换生效了。
        Set-TespeedMode $workflow '105:122' $Config $comfyUrl
    } else {
        # 没有 TE-Speed 节点时把模型链直接接到采样器的 guider，跳过加速而不是报错。
        Add-BuildWarning '未检测到 TE-SpeedMiniMaxH3 加速节点，本次已跳过加速（生成会变慢，结果正常）。安装该节点包并重启 ComfyUI 后会自动恢复。'
        Remove-WorkflowNode $workflow '105:122'
        Set-InputValue $workflow '105:16' 'model' $speedModel
    }

    # 普通三模式的工作流 JSON 内置了 easy cleanGpuUsed（105:130，接在 CreateVideo 之后），
    # 这里始终移除它并把保存节点接回 CreateVideo：工作流末尾清显存会在推理刚结束时执行，
    # 与紧接着从队列启动的下一个任务抢时序，导致下一个任务加载模型失败。显存清理统一改由
    # /api/generate 在"提交前且队列空闲"时调用 ComfyUI 官方 /free 接口完成。
    Remove-WorkflowNode $workflow '105:130'
    Set-InputValue $workflow '92' 'video' @('105:91', 0)
    # RTX 放大链从 CreateVideo 接入；统一走 Add-RtxUpscaleLink 处理能力判断与降级提示。
    # 未开启 RTX 时保持上面那条直连，不新增任何节点。
    $saveSource = '105:91'
    if ($Config.rtxUpscale) {
        $nextId = 1000
        foreach ($property in $workflow.PSObject.Properties) {
            try { $nextId = [Math]::Max($nextId, [int]$property.Name + 1) } catch {}
        }
        Set-InputValue $workflow '92' 'video' (Add-RtxUpscaleLink $workflow $saveSource $nextId $Config $capabilities)
    }
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

    $current = [string]$config.'当前版本'

    # ---- 优先按 Release tag 判断（根治「回填锚点」导致的永久误报）----
    # 锚点写在 更新配置.json 里，而“回填锚点”这个动作本身又会产生一个新提交：用 commit SHA
    # 比较的话，发布者的锚点永远比仓库 HEAD 少一个提交，检查更新必然误报（本项目真实踩坑：
    # 本地锚点 5a23acc vs 远端 HEAD bdbdea3，远端那个只是回填版本号的元提交）。
    # 改成比较 Release tag 后：锚点存 tag 名（如 v20260922），发布时打同名 tag，两者相等即
    # 「已是最新」，彻底打破自引用。仓库没有 Release（或查询失败）时退回旧的 commit 模式，
    # 兼容老仓库。zipball 接口对 tag 同样有效，下载逻辑无需改动。
    $releaseInfo = $null
    try {
        $relResponse = Invoke-UpdateRequest "https://api.github.com/repos/$repo/releases/latest" 'application/vnd.github+json' 20000
        if ($relResponse.IsSuccessStatusCode) {
            $relText = $relResponse.Content.ReadAsStringAsync().GetAwaiter().GetResult()
            $relData = $relText | ConvertFrom-Json
            if ([string]$relData.tag_name) {
                $releaseInfo = @{
                    tag       = [string]$relData.tag_name
                    name      = [string]$relData.name
                    url       = [string]$relData.html_url
                    published = [string]$relData.published_at
                }
            }
        }
        $relResponse.Dispose()
    } catch { $releaseInfo = $null }

    if ($releaseInfo) {
        $tag = $releaseInfo.tag
        $result = @{
            configured     = $true
            channel        = 'release'
            repo           = $repo
            branch         = $branch
            currentVersion = $current
            currentShort   = $current
            latestVersion  = $tag
            latestShort    = $tag
            latestDate     = $releaseInfo.published
            commitMessage  = $releaseInfo.name
            commitUrl      = $releaseInfo.url
            unversioned    = [string]::IsNullOrWhiteSpace($current)
            hasUpdate      = ($current -and ($tag -ine $current))
        }
        # 结果缓存 30 分钟，避免每次刷新页面都请求 GitHub（匿名额度 60 次/小时）。
        $script:UpdateCheckCache = @{ At = Get-Date; Data = $result }
        return $result
    }

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

# ---------------------------------------------------------------------------
# 性能监控快照（后台常驻采集）
#
# 供网页「性能监控」面板轮询（GET /api/system-stats），报告本机 CPU / 内存 /
# 显卡占用与显卡温度。三条设计约束：
#   1. **零第三方依赖**：只用 Windows 自带的性能计数器（PDH）与显卡驱动自带的
#      nvidia-smi.exe。CPU 温度/功耗 Windows 没有系统级直读口（需 LibreHardwareMonitor
#      等外部软件），不属于本面板范围。
#   2. **只读诊断，绝不阻断生成**：采集失败的字段置 null 并把原因收进 errors，
#      接口永远回 200 结构化结果（与环境自检同策略）；网页轮询失败也只是
#      停止刷新，不影响任何生成流程。
#   3. **不能拖慢主循环**：HTTP 主循环是单线程的，把采集放进去就会卡住 /api/progress
#      等所有请求。所以采集整体搬到**后台 runspace**，接口只读内存快照。
#
# 【采集成本实测（2026-10-12，本机 i9-13900KF + RTX 4090），选型依据全在这】
#   PerformanceCounter('Processor','% Processor Time','_Total')    0.68 ms/次
#   Win32_PerfFormattedData_PerfOS_Processor                        304 ms/次  ← 弃用
#   PerformanceCounter('Memory','Available Bytes')                  0.25 ms/次
#   nvidia-smi 一次性调用                                            293 ms/次
#   nvidia-smi -lms 500 常驻流（阻塞读下一行）                         0 ms/次
#   结论：CPU/内存改用**常驻 PDH 计数器**、GPU 改用**常驻 nvidia-smi -lms 流**，
#   一轮采集的实际开销约 1 毫秒。若沿用「每轮现场跑 WMI + 每轮新起一个 nvidia-smi」，
#   一轮就是 600 毫秒，常驻采集会持续吃掉可观资源，也就没法做秒级刷新。
#   —— 这两处是「能实时」的关键，改动前请先复测本表。
# ---------------------------------------------------------------------------
# 后台采集线程与 HTTP 线程之间只通过这一个**同步哈希表**交换数据：
#   latest —— 采集线程每次采完把 { json = 快照JSON; at = 写入时刻 } 整体换掉，HTTP 线程只读；
#   smiPid —— 采集线程拉起的常驻 nvidia-smi 进程号，服务退出时用于精确回收该子进程。
# 快照用 JSON 字符串而不是对象，是为了彻底避开跨 runspace 的对象类型问题。
$script:PerfShared = [hashtable]::Synchronized(@{
    latest = $null
    smiPid = 0
})
$script:PerfCollector = $null          # [powershell] 实例（采集线程宿主）
$script:PerfCollectorAsync = $null     # BeginInvoke 返回的句柄
# 快照超过这个年龄就认定采集线程没在工作，接口改走按需采集兜底。
$script:PerfStaleSeconds = 10
# nvidia-smi 的查询参数只在这里写一份，一次性调用与常驻流共用，避免两处走样。
$script:PerfSmiArgs = '--query-gpu=index,name,utilization.gpu,memory.used,memory.total,temperature.gpu,power.draw --format=csv,noheader,nounits'

# nvidia-smi 路径探测缓存：$false 表示"本机没有"，避免每次轮询都去摸文件系统。
# 找不到的结果只缓存 5 分钟 —— 用户装好驱动后无需重启服务就能看到显卡数据。
$script:NvidiaSmiPath = $null
$script:NvidiaSmiProbedAt = [DateTime]::MinValue

function Find-NvidiaSmi {
    param([TimeSpan]$NegativeTtl)
    if ($null -ne $script:NvidiaSmiPath) { return $script:NvidiaSmiPath }
    if ((Get-Date) - $script:NvidiaSmiProbedAt -lt $NegativeTtl) { return $false }
    $script:NvidiaSmiProbedAt = Get-Date
    # 新版驱动把 nvidia-smi 装进 System32；旧版在 Program Files\NVIDIA Corporation\NVSMI。
    $candidates = @(
        (Join-Path $env:SystemRoot 'System32\nvidia-smi.exe'),
        (Join-Path ${env:ProgramFiles} 'NVIDIA Corporation\NVSMI\nvidia-smi.exe')
    )
    foreach ($candidate in $candidates) {
        if (Test-Path $candidate -PathType Leaf) {
            $script:NvidiaSmiPath = $candidate
            return $candidate
        }
    }
    $script:NvidiaSmiPath = $false
    return $false
}

function Invoke-NvidiaSmi {
    # 带超时看门狗地调用 nvidia-smi。ReadToEndAsync 必须在 WaitForExit 之前发起，
    # 否则输出缓冲区写满时子进程会被管道背压卡死，WaitForExit 永远等不到退出。
    param([string]$ExePath, [int]$TimeoutMs = 3000)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $ExePath
    # 固定参数、无任何用户输入，不存在注入面。
    # 参数文本与后台采集线程共用 $script:PerfSmiArgs（在下面作为实参传进采集脚本），
    # 两处一旦走样，就会出现"接口显示的列和采集线程解析的列不一致"这种极难排查的问题。
    $psi.Arguments = $script:PerfSmiArgs
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $process = [System.Diagnostics.Process]::Start($psi)
    try {
        $readTask = $process.StandardOutput.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutMs)) {
            try { $process.Kill() } catch {}
            throw 'nvidia-smi 响应超时（显卡驱动可能正忙）。'
        }
        return $readTask.Result
    } finally {
        $process.Dispose()
    }
}

function Get-GpuSnapshot {
    # 返回 @{ gpus = [...]; error = $null | '...' }，普通 PowerShell 对象数组，调用方负责拼快照。
    $gpus = @()
    $smiPath = Find-NvidiaSmi -NegativeTtl ([TimeSpan]::FromMinutes(5))
    if ($smiPath) {
        try {
            $text = Invoke-NvidiaSmi -ExePath $smiPath
            foreach ($line in ($text -split "`r?`n" | Where-Object { $_.Trim() })) {
                $cols = $line.Split(',') | ForEach-Object { $_.Trim() }
                # CSV 列：index, name, util%, memUsed(MB), memTotal(MB), temp(C), power(W)
                if ($cols.Count -lt 7) { continue }
                $parse = { param($v) $n = 0.0; if ($v -match '^[0-9]+(\.[0-9]+)?$' -and [double]::TryParse($v, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$n)) { [Math]::Round($n, 1) } else { $null } }
                $gpus += [ordered]@{
                    source              = 'nvidia-smi'
                    name                = [string]$cols[1]
                    utilizationPercent  = & $parse $cols[2]
                    memoryUsedMb        = & $parse $cols[3]
                    memoryTotalMb       = & $parse $cols[4]
                    temperatureC        = & $parse $cols[5]
                    powerW              = & $parse $cols[6]
                }
            }
        } catch {
            return @{ gpus = $gpus; error = "NVIDIA 显卡数据读取失败：$($_.Exception.Message)" }
        }
        if ($gpus.Count) { return @{ gpus = $gpus; error = $null } }
    }
    # 没有 nvidia-smi（非 NVIDIA 显卡 / 未装驱动）时的兜底：只报显卡型号，
    # 不冒充占用数据 —— Win32_VideoController 给不出利用率与温度，宁可留空。
    try {
        foreach ($adapter in (Get-CimInstance -ClassName Win32_VideoController -ErrorAction Stop)) {
            if (-not $adapter.Name) { continue }
            $gpus += [ordered]@{
                source              = 'wmi'
                name                = [string]$adapter.Name
                utilizationPercent  = $null
                memoryUsedMb        = $null
                memoryTotalMb       = $null
                temperatureC        = $null
                powerW              = $null
            }
        }
    } catch {
        return @{ gpus = $gpus; error = "显卡信息读取失败：$($_.Exception.Message)" }
    }
    return @{ gpus = $gpus; error = $null }
}

# ---------------------------------------------------------------------------
# 后台采集线程本体
#
# 【为什么长这样】这段脚本在**独立 runspace** 里跑，拿不到本文件的任何函数与变量
# （Find-NvidiaSmi / Invoke-NvidiaSmi / Get-GpuSnapshot 全都用不了），所以 nvidia-smi
# 的路径与参数由调用方以实参传进来，采集逻辑必须自包含。
# 节奏由常驻 nvidia-smi 的输出行驱动（约 500ms 一行，阻塞读即可），
# 没有 nvidia-smi 时退化为定时 sleep —— 两种情况下**一轮的实际开销都是毫秒级**。
# ---------------------------------------------------------------------------
$script:PerfCollectorBody = {
    param($shared, $smiPath, $smiArgs)

    $ErrorActionPreference = 'Continue'
    $intervalMs = 500

    # ---- 静态信息：只读一次（WMI 查询约 0.3~1 秒，不能放进每轮循环）----
    $cpuName = ''
    $logicalCores = [Environment]::ProcessorCount
    $totalKb = 0.0
    $staticErrors = @()
    try {
        $procs = @(Get-CimInstance -ClassName Win32_Processor -ErrorAction Stop)
        if ($procs.Count -gt 0) {
            $cpuName = [string]$procs[0].Name
            $coreSum = ($procs | Measure-Object -Property NumberOfLogicalProcessors -Sum).Sum
            if ($coreSum) { $logicalCores = [int]$coreSum }
        }
    } catch {
        $staticErrors += "CPU 信息读取失败：$($_.Exception.Message)"
    }
    try {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
        $totalKb = [double]$os.TotalVisibleMemorySize
    } catch {
        $staticErrors += "内存总量读取失败：$($_.Exception.Message)"
    }

    # ---- 常驻性能计数器：一次创建，之后每轮只读一个值（0.2~0.7 毫秒）----
    $cpuCounter = $null
    $memCounter = $null
    try {
        $cpuCounter = New-Object System.Diagnostics.PerformanceCounter('Processor', '% Processor Time', '_Total')
        # 计数器首值不可信（没有上一帧可比较），先读一次建立基线再丢弃。
        $null = $cpuCounter.NextValue()
    } catch {
        $staticErrors += "CPU 计数器初始化失败：$($_.Exception.Message)"
        $cpuCounter = $null
    }
    try {
        $memCounter = New-Object System.Diagnostics.PerformanceCounter('Memory', 'Available Bytes')
        $null = $memCounter.NextValue()
    } catch {
        $staticErrors += "内存计数器初始化失败：$($_.Exception.Message)"
        $memCounter = $null
    }

    $parseNumber = {
        param($value)
        $n = 0.0
        if ($value -match '^[0-9]+(\.[0-9]+)?$' -and [double]::TryParse($value, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$n)) {
            return [Math]::Round($n, 1)
        }
        return $null
    }

    # ---- 没有 nvidia-smi 时的显卡兜底：只报型号，也只在启动时查一次 ----
    $lastGpus = @()
    if (-not $smiPath) {
        try {
            foreach ($adapter in (Get-CimInstance -ClassName Win32_VideoController -ErrorAction Stop)) {
                if (-not $adapter.Name) { continue }
                $lastGpus += [ordered]@{
                    source             = 'wmi'
                    name               = [string]$adapter.Name
                    utilizationPercent = $null
                    memoryUsedMb       = $null
                    memoryTotalMb      = $null
                    temperatureC       = $null
                    powerW             = $null
                }
            }
        } catch {
            $staticErrors += "显卡信息读取失败：$($_.Exception.Message)"
        }
    }

    $smiProcess = $null
    $smiFailures = 0
    $streamBroken = -not $smiPath
    $streamNote = '未检测到 NVIDIA 显卡工具（nvidia-smi），显卡只报型号。'
    if ($smiPath) { $streamNote = '' }

    while ($true) {
        $gpuLine = $null

        if ($streamBroken) {
            Start-Sleep -Milliseconds $intervalMs
        } else {
            if ($null -eq $smiProcess) {
                try {
                    $psi = New-Object System.Diagnostics.ProcessStartInfo
                    $psi.FileName = $smiPath
                    $psi.Arguments = "$smiArgs -lms $intervalMs"
                    $psi.UseShellExecute = $false
                    $psi.CreateNoWindow = $true
                    $psi.RedirectStandardOutput = $true
                    $psi.RedirectStandardError = $true
                    $smiProcess = [System.Diagnostics.Process]::Start($psi)
                    # 把进程号记到共享状态里：nvidia-smi 是**子进程**，不会随本服务退出而消失，
                    # Stop-PerfCollector 需要靠这个"精确的号码"在关服务时把它收掉
                    # （绝不按进程名批量杀 —— 那会误伤用户自己执行的 nvidia-smi 查询）。
                    $shared.smiPid = $smiProcess.Id
                } catch {
                    $smiProcess = $null
                    $streamBroken = $true
                    $streamNote = "nvidia-smi 常驻进程启动失败，已退化为定时采集：$($_.Exception.Message)"
                }
            }
            if ($null -ne $smiProcess) {
                try {
                    $readTask = $smiProcess.StandardOutput.ReadLineAsync()
                    # 3 秒看门狗：显卡驱动忙等时 ReadLine 会一直堵着，不能让采集线程无声停摆。
                    if ($readTask.Wait(3000)) { $gpuLine = $readTask.Result }
                } catch {
                    $gpuLine = $null
                }
                if ([string]::IsNullOrWhiteSpace($gpuLine)) {
                    # 进程退出或读取超时：销毁它，下一轮重新拉起；连续三次就彻底放弃流模式。
                    try { $smiProcess.Kill() } catch {}
                    try { $smiProcess.Dispose() } catch {}
                    $smiProcess = $null
                    $shared.smiPid = 0
                    $smiFailures++
                    if ($smiFailures -ge 3) {
                        $streamBroken = $true
                        $streamNote = 'nvidia-smi 流式读取连续失败，已退化为定时采集。'
                    }
                    Start-Sleep -Milliseconds 200
                }
            }
        }

        # ---- 一轮采样 ----
        $errors = @($staticErrors)

        $cpuPercent = $null
        if ($cpuCounter) {
            try { $cpuPercent = [Math]::Round([double]$cpuCounter.NextValue(), 0) }
            catch { $errors += "CPU 占用读取失败：$($_.Exception.Message)"; $cpuCounter = $null }
        }

        $totalGb = $null
        $usedGb = $null
        $usedPercent = $null
        if ($totalKb -gt 0) {
            $totalGb = [Math]::Round($totalKb / 1MB, 1)
            $availableKb = $null
            if ($memCounter) {
                try { $availableKb = [double]$memCounter.NextValue() / 1KB }
                catch { $errors += "内存占用读取失败：$($_.Exception.Message)"; $memCounter = $null }
            }
            if ($null -ne $availableKb) {
                $usedKb = [Math]::Max(0, $totalKb - $availableKb)
                $usedGb = [Math]::Round($usedKb / 1MB, 1)
                $usedPercent = [Math]::Round($usedKb / $totalKb * 100, 1)
            }
        }

        $gpus = @()
        if ($null -ne $gpuLine) {
            # CSV 列：index, name, util%, memUsed(MB), memTotal(MB), temp(C), power(W)
            $cols = @($gpuLine.Split(',') | ForEach-Object { $_.Trim() })
            if ($cols.Count -ge 7) {
                $gpus += [ordered]@{
                    source             = 'nvidia-smi'
                    name               = [string]$cols[1]
                    utilizationPercent = & $parseNumber $cols[2]
                    memoryUsedMb       = & $parseNumber $cols[3]
                    memoryTotalMb      = & $parseNumber $cols[4]
                    temperatureC       = & $parseNumber $cols[5]
                    powerW             = & $parseNumber $cols[6]
                }
            }
        }
        # 本轮没读到显卡数据（例如流刚被重启）时沿用上一次的值，避免面板数字闪烁归零。
        if ($gpus.Count -eq 0) { $gpus = @($lastGpus) } else { $lastGpus = $gpus }

        $mode = 'timer'
        if (-not $streamBroken) { $mode = 'stream' }

        $snapshot = [ordered]@{
            timestamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
            cpu       = [ordered]@{ name = $cpuName; loadPercent = $cpuPercent; logicalCores = $logicalCores }
            memory    = [ordered]@{ totalGb = $totalGb; usedGb = $usedGb; usedPercent = $usedPercent }
            gpus      = @($gpus)
            errors    = @($errors)
            collector = [ordered]@{ mode = $mode; fresh = $true; note = $streamNote }
        }

        # 把「数据 + 时刻 + 状态」作为**一个对象**整体发布：HTTP 线程读到的永远是自洽的一份，
        # 不会出现"新数据配旧时刻"这种半新半旧的中间态（分两次写就会有这个缝）。
        $shared.latest = @{
            json = ($snapshot | ConvertTo-Json -Depth 6 -Compress)
            at   = (Get-Date)
        }
    }
}

function Start-PerfCollector {
    # 启动常驻采集线程。失败不影响服务：Get-SystemPerformanceSnapshot 会退回按需采集。
    if ($script:PerfCollector) { return }
    $smiPath = Find-NvidiaSmi -NegativeTtl ([TimeSpan]::FromMinutes(5))
    if (-not $smiPath) { $smiPath = $null }
    try {
        # 显式建一个**独占 runspace**：不这么做，BeginInvoke 每次调用会自己开临时 runspace，
        # 这个无限循环就会把临时 runspace 永远占住，行为难以预料。
        $runspace = [runspacefactory]::CreateRunspace()
        $runspace.Open()
        $shell = [powershell]::Create()
        $shell.Runspace = $runspace
        $null = $shell.AddScript($script:PerfCollectorBody.ToString())
        $null = $shell.AddArgument($script:PerfShared)
        $null = $shell.AddArgument($smiPath)
        $null = $shell.AddArgument($script:PerfSmiArgs)
        $script:PerfCollector = $shell
        # 无限循环的脚本永远不会"跑完"，BeginInvoke 只是把它丢到后台线程上。
        $script:PerfCollectorAsync = $shell.BeginInvoke()
        Write-Host "  [性能监控] 后台采集线程已启动（CPU/内存走常驻计数器，显卡走 nvidia-smi 常驻流）。" -ForegroundColor DarkCyan
    } catch {
        $script:PerfCollector = $null
        $script:PerfCollectorAsync = $null
        Write-Host "  [提示] 性能监控后台采集线程启动失败，已退化为按需采集：$($_.Exception.Message)" -ForegroundColor DarkYellow
    }
}

function Stop-PerfCollector {
    $shell = $script:PerfCollector
    if ($shell) {
        try { $shell.Stop() } catch {}
        try { if ($shell.Runspace) { $shell.Runspace.Dispose() } } catch {}
        try { $shell.Dispose() } catch {}
    }
    $script:PerfCollector = $null
    $script:PerfCollectorAsync = $null
    # 收掉采集线程拉起的常驻 nvidia-smi。它跑在别的 runspace 里、我们又没法直接拿到它的
    # 进程对象，所以靠采集线程写下的进程号精确地杀 —— 并且核对进程名，
    # 避免号码被系统回收后被我们误杀成别的进程。
    $smiPid = 0
    try { $smiPid = [int]$script:PerfShared.smiPid } catch {}
    if ($smiPid -gt 0) {
        try {
            $child = Get-Process -Id $smiPid -ErrorAction Stop
            if ($child.ProcessName -eq 'nvidia-smi') { $child.Kill() }
        } catch {}
        $script:PerfShared.smiPid = 0
    }
}

function Get-SystemPerformanceOnDemandJson {
    # 兜底路径：现场采集（约 0.6 秒，而且跑在单线程 HTTP 主循环里）。
    # 只有后台采集线程没产出第一份数据、或快照已明显过期时才会走到这里。
    $now = Get-Date
    $errors = @()
    # ---- CPU（占用）----
    $cpu = [ordered]@{ name = ''; loadPercent = $null; logicalCores = $null }
    try {
        $processors = @(Get-CimInstance -ClassName Win32_Processor -ErrorAction Stop)
        if ($processors.Count) {
            $cpu.name = [string]$processors[0].Name
            # LoadPercentage 每颗 CPU 一个值，多路平台取平均。
            $loads = @($processors | ForEach-Object { if ($null -ne $_.LoadPercentage) { [double]$_.LoadPercentage } })
            if ($loads.Count) { $cpu.loadPercent = [Math]::Round(($loads | Measure-Object -Average).Average, 0) }
            $cpu.logicalCores = ($processors | Measure-Object -Property NumberOfLogicalProcessors -Sum).Sum
        }
    } catch {
        $errors += "CPU 信息读取失败：$($_.Exception.Message)"
    }
    # ---- 内存 ----
    $memory = [ordered]@{ totalGb = $null; usedGb = $null; usedPercent = $null }
    try {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
        $totalKb = [double]$os.TotalVisibleMemorySize
        $freeKb = [double]$os.FreePhysicalMemory
        if ($totalKb -gt 0) {
            $memory.totalGb = [Math]::Round($totalKb / 1MB, 1)
            $memory.usedGb = [Math]::Round(($totalKb - $freeKb) / 1MB, 1)
            $memory.usedPercent = [Math]::Round(($totalKb - $freeKb) / $totalKb * 100, 1)
        }
    } catch {
        $errors += "内存信息读取失败：$($_.Exception.Message)"
    }
    # ---- 显卡 ----
    $gpuResult = Get-GpuSnapshot
    if ($gpuResult.error) { $errors += $gpuResult.error }

    $snapshot = [ordered]@{
        timestamp = $now.ToString('yyyy-MM-dd HH:mm:ss')
        cpu       = $cpu
        memory    = $memory
        gpus      = @($gpuResult.gpus)
        errors    = @($errors)
        # fresh=$false 让网页把"采集线程没在工作"如实告诉用户，而不是让人以为面板坏了。
        collector = [ordered]@{ mode = 'ondemand'; fresh = $false; note = '后台采集线程未在运行，本次为按需采集，刷新会明显变慢。' }
    }
    return ($snapshot | ConvertTo-Json -Depth 6 -Compress)
}

function Get-SystemPerformanceSnapshot {
    # HTTP 线程的唯一入口：优先返回后台采集线程发布的那份快照（微秒级）。
    # 只有快照缺失或已明显过期时才现场采集兜底 —— 宁可这一次慢一点，
    # 也不要让面板空着或永远停在旧数据上（与"绝不阻断"同策略）。
    $latest = $script:PerfShared.latest
    if ($latest -and ((Get-Date) - $latest.at).TotalSeconds -lt $script:PerfStaleSeconds) {
        return $latest.json
    }
    return (Get-SystemPerformanceOnDemandJson)
}

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

# 静态托管的扩展名白名单。项目目录里同时放着 AI提示词配置.json（含真实 API Key）、
# server.ps1（服务端源码）、工作流 JSON、启动脚本等，若不限制类型，同网段任何设备只要
# 直接 GET 文件名就能把它们下载走（实测 /server.ps1 与 /AI提示词配置.json 均返回 200）。
# 前端用到的静态资源只有 index.html、favicon.svg 与 assets/ 下的 css/js，所以这里只放开这些类型。
$script:StaticExtensions = @('.html', '.js', '.css', '.svg', '.png', '.jpg', '.jpeg', '.webp', '.gif', '.ico', '.woff', '.woff2')

# 让控制台窗口始终有固定标题，更新助手重启服务后标题保持一致，方便用户按说明关闭服务。
try { $Host.UI.RawUI.WindowTitle = 'MiniMax H3 工作站服务' } catch {}

# 性能监控的后台采集线程：进主循环之前拉起来，此后由它按固定节奏刷新内存快照，
# /api/system-stats 只读快照。即使这一步失败，接口也会退回按需采集，不影响任何功能。
Start-PerfCollector

. (Join-Path $root "lora-library.ps1")

while ($listener.IsListening -and -not $script:UpdateRestartPending) {
    $ctx = $listener.GetContext()
    $script:LoraResponseDetached = $false
    try {
        $path = $ctx.Request.Url.AbsolutePath
        $method = $ctx.Request.HttpMethod.ToUpperInvariant()

        if (Invoke-LoraLibraryRoute $ctx $path $method) { }
        elseif ($path -eq '/api/ai-config' -and $method -eq 'GET') {
            $config = Get-AiPromptConfig
            $models = @($config.'模型') | ForEach-Object { [pscustomobject]@{ id = [string]$_.id; supportsImages = [bool]$_.supports_images } }
            $templates = @($config.'提示词模板') | ForEach-Object {
                $templateName = if ($_.name) { [string]$_.name } else { [string]$_.id }
                [pscustomobject]@{ id = [string]$_.id; name = $templateName }
            }
            Send-Json $ctx @{ models = $models; templates = $templates; defaultModel = [string]$config.'默认模型'; defaultTemplate = [string]$config.'默认模板' }
        }
        elseif ($path -eq '/api/ai-prompt' -and $method -eq 'POST') {
            Assert-SameOrigin $ctx.Request
            # 上限必须在读取之前判断，否则超大 body 先吃掉内存了（分块传输时 ContentLength64 为 -1，
            # 由读取后的长度检查兜底）。
            Assert-RequestSize $ctx.Request 50000000 'AI 提示词请求过大，请减少或压缩图片。'
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
        elseif ($path -eq '/api/free' -and $method -eq 'POST') {
            # 只允许 POST：清理显存是状态变更操作。若同时允许 GET，任何网页只要放一个
            # <img src="http://127.0.0.1:8000/api/free"> 就能跨站把 ComfyUI 的模型卸载掉。
            Assert-SameOrigin $ctx.Request
            # soft=1：「自动清理显存」在任务结束后由网页调用。队列非空（还有任务在跑或排队）时
            # 静默跳过，等最后一个任务结束再清；不会打断任何生成。
            # 不带 soft：用户手动点「立即清理显存」。队列非空时直接拒绝并提示原因，避免手滑打断生成。
            $comfy = Get-ComfyUrl $ctx.Request
            $soft = ([string]$ctx.Request.QueryString['soft'] -eq '1')
            $queueState = Get-ComfyQueueState $comfy
            if (-not $queueState.Idle) {
                $busy = "执行中 $($queueState.Running) 个 / 排队中 $($queueState.Pending) 个"
                if ($soft) {
                    Send-Json $ctx @{ ok = $true; skipped = $true; message = "队列仍有任务（$busy），本次跳过清理。" }
                } else {
                    throw "ComfyUI 队列尚未空闲（$busy），此时清理会中断生成，请等任务完成后再试。"
                }
            } else {
                Clear-ComfyVram $comfy
                Write-Host "  [显存] ComfyUI 队列空闲，已卸载模型并释放显存。" -ForegroundColor DarkCyan
                Send-Json $ctx @{ ok = $true; message = '显存已清理：模型已从显存卸载。' }
            }
        }
        elseif ($path -eq '/api/cancel' -and $method -eq 'POST') {
            # 停止任务：把用户指定的一项已提交任务从 ComfyUI 侧真正停掉（排队中的移除、
            # 正在执行的立即中断）。与 /api/free 同一套闸门 —— 只允许 POST + 同源校验：
            # 若同时接受 GET，任何网页只要放一个 <img src="http://127.0.0.1:8000/api/cancel?promptId=…">
            # 就能跨站把用户正在跑的生成打断。
            Assert-SameOrigin $ctx.Request
            Assert-RequestSize $ctx.Request 65536 '停止任务请求过大。'
            $bodyBytes = Read-RequestBytes $ctx.Request
            if ($bodyBytes.Length -gt 65536) { throw '停止任务请求过大。' }
            $bodyObject = [Text.Encoding]::UTF8.GetString($bodyBytes) | ConvertFrom-Json
            $promptId = [string]$bodyObject.promptId
            # prompt_id 由 ComfyUI 生成为 UUID，只可能是字母数字与连字符。这条校验是硬护栏：
            # 它既挡住空值与超长垃圾，又保证下面拼进上游 URL / 请求体的是纯安全字符。
            if ($promptId -notmatch '^[0-9a-zA-Z_-]{1,64}$') { throw '任务编号不合法，无法停止。' }
            $comfy = Get-ComfyUrl $ctx.Request $bodyObject
            $result = Stop-ComfyPrompt $comfy $promptId
            # stopped=false 不当作错误（任务可能刚好跑完），由网页决定后续如何显示；
            # 这里永远回 200 结构化结果，避免用户点一下停止却弹一个红叉。
            Send-Json $ctx @{ ok = $true; stopped = $result.Stopped; action = $result.Action; message = $result.Message }
        }
        elseif ($path -eq '/api/check-update' -and $method -eq 'GET') {
            $fresh = ([string]$ctx.Request.QueryString['fresh'] -eq '1')
            $info = Get-UpdateInfo -Fresh $fresh
            Send-Json $ctx $info
        }
        elseif ($path -eq '/api/apply-update' -and $method -eq 'POST') {
            # 仅接受 application/json 请求：跨站表单无法携带该 Content-Type，阻止其它网站诱导本机执行更新。
            if ($ctx.Request.ContentType -notmatch 'application/json') { throw '请通过页面内的一键更新按钮执行更新。' }
            Assert-SameOrigin $ctx.Request
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
            Assert-SameOrigin $ctx.Request
            # 单次上传上限 200MB（网页侧的限制是图片 30MB / 视频 50MB / 音频 15MB，
            # 这里只是防止无鉴权的局域网请求用超大 body 把服务内存打满）。
            Assert-RequestSize $ctx.Request 209715200 '上传文件过大（单次不超过 200MB）。'
            $comfy = Get-ComfyUrl $ctx.Request
            $body = Read-RequestBytes $ctx.Request
            if ($body.Length -gt 209715200) { throw '上传文件过大（单次不超过 200MB）。' }
            $remote = Invoke-Comfy 'POST' "$comfy/upload/image" $body $ctx.Request.ContentType
            Send-Bytes $ctx $remote.Bytes $remote.ContentType $remote.StatusCode
        }
        elseif ($path -eq '/api/generate' -and $method -eq 'POST') {
            Assert-SameOrigin $ctx.Request
            # 生成请求只是提示词 + 参数，2MB 足够；上限放在读取之前。
            Assert-RequestSize $ctx.Request 2097152 '生成请求过大。'
            $bodyBytes = Read-RequestBytes $ctx.Request
            if ($bodyBytes.Length -gt 2097152) { throw '生成请求过大。' }
            $bodyText = [Text.Encoding]::UTF8.GetString($bodyBytes)
            $bodyObject = $bodyText | ConvertFrom-Json
            $comfy = Get-ComfyUrl $ctx.Request $bodyObject
            Assert-SelectedModelsExist $bodyObject.config $comfy
            # 「自动清理显存」在任务边界执行：仅当 ComfyUI 队列完全空闲（没有正在执行、也没有
            # 排队等待的任务）时，才先卸载模型释放显存，再提交本次任务。此时清理永远落在
            # "上一个任务已结束、下一个任务还没开始"的安全间隙；队列里还有任务就自动跳过，
            # 避免像工作流内清理节点那样清掉排队中下一个任务刚加载的模型。
            # 清理属于优化动作，失败只提示、不阻断生成。
            $cleanVram = if ($null -eq $bodyObject.config.cleanVram) { $true } else { [bool]$bodyObject.config.cleanVram }
            if ($cleanVram) {
                try {
                    $queueState = Get-ComfyQueueState $comfy
                    if ($queueState.Idle) { Clear-ComfyVram $comfy }
                } catch {
                    Write-Host "  [提示] 提交前清理显存已跳过：$($_.Exception.Message)" -ForegroundColor DarkYellow
                }
            }
            $workflow = Build-Workflow $bodyObject.config $comfy
            # 防御：PowerShell 函数会把管道输出全部收进返回值，任何一处裸调用有返回值的辅助函数
            # 都会把 $workflow 从单个对象污染成数组（v20260912 的全能参考 500 就是这么来的）。
            # 在这里拦下并给出明确原因，而不是把坏 payload 发给 ComfyUI 换回一句难懂的 500。
            if ($workflow -is [System.Array]) { throw '内部错误：工作流构建结果是数组而非对象（函数输出泄漏），已阻止提交，请反馈给作者。' }
            # 提交前兼容层：按 ComfyUI 当前实际节点定义补齐缺失的必需输入。
            # 上游自定义节点包升级后新增必需字段（如 TE-Speed 3.5 的 mode）时，工作流 JSON 快照
            # 里没有该字段，ComfyUI 会判为 required_input_missing 并整体拒绝。这里自动补上，
            # 无需改工作流 JSON；探测失败时静默跳过，不影响正常生成。
            Complete-RequiredInputs $workflow $comfy
            $payload = @{ prompt = $workflow; client_id = [guid]::NewGuid().ToString('N') } | ConvertTo-Json -Depth 100 -Compress
            $remote = Invoke-Comfy 'POST' "$comfy/prompt" ([Text.Encoding]::UTF8.GetBytes($payload)) 'application/json; charset=utf-8'
            if (-not $remote.Success) {
                $detail = [Text.Encoding]::UTF8.GetString($remote.Bytes)
                throw "ComfyUI 拒绝工作流（HTTP $($remote.StatusCode)）：$detail"
            }
            if ($script:BuildWarnings.Count -gt 0) {
                # 把降级提示附在响应里，网页会逐条弹出，让用户清楚本次跳过了哪些可选节点。
                $result = [Text.Encoding]::UTF8.GetString($remote.Bytes) | ConvertFrom-Json
                $result | Add-Member -NotePropertyName warnings -NotePropertyValue @($script:BuildWarnings) -Force
                Send-Json $ctx $result $remote.StatusCode
            } else {
                Send-Bytes $ctx $remote.Bytes $remote.ContentType $remote.StatusCode
            }
        }
        elseif ($path -eq '/api/capabilities' -and $method -eq 'GET') {
            # 供网页判断哪些可选节点存在，从而禁用/提示不可用的开关（如 RTX 放大）。
            # fresh=1 强制重新探测（用户刚装完节点包时用）。
            $comfy = Get-ComfyUrl $ctx.Request
            $force = -not [string]::IsNullOrWhiteSpace([string]$ctx.Request.QueryString['fresh'])
            $capabilities = Get-ComfyCapabilities $comfy -Force:$force
            # 手动「测试连接」时连节点定义缓存一起清掉：用户刚更新过节点包，期望立刻看到新接口
            # （例如 TE-Speed 3.5 新出现的 mode 候选），不能被 10 分钟的缓存挡住。
            if ($force) { Clear-ComfyNodeSchemaCache $comfy }
            # TE-Speed 加速模式的候选列表照读节点声明，不写死在前端：上游节点包新增模式时
            # 网页下拉自动跟着变，不用改前端代码。多花一次 /object_info/<节点名>（自带缓存）。
            # 探测失败与「节点没有 mode」（3.5 以前）在这里同样处理：前端都是禁用该下拉并显示原因，
            # 区分它们对网页没有意义；下一次 /api/capabilities 会重新探测。
            $tespeedModes = @(Get-ComfyChoiceOptions $comfy 'TESpeedMiniMaxH3' 'mode')
            # 【为什么要复制一份】Get-ComfyCapabilities 返回的是 $script:CapabilityCache 里的**同一个对象引用**，
            # 直接 Add-Member / 改属性会把「本次请求的探测结果」写进缓存本体：下一次读缓存时，
            # 里面已经带着上一次算出来的 TEspeedModes，缓存对象的含义变得含混（谁写的、什么时候写的都说不清）。
            # 复制成一个新的有序字典再挂字段，缓存保持纯净。
            $payload = [ordered]@{}
            foreach ($property in $capabilities.PSObject.Properties) {
                $payload[$property.Name] = $property.Value
            }
            $payload['TEspeedModes'] = @($tespeedModes)
            Send-Json $ctx $payload
        }
        elseif ($path -eq '/api/self-check' -and $method -eq 'GET') {
            # 只读环境自检：告诉用户哪个模式还能用、缺什么、要装哪个包。
            # 这里**刻意不抛 5xx** —— ComfyUI 没启动是很常见的状态，必须回一个结构化结果，
            # 让网页能把「连不上 ComfyUI」和「缺节点」分开显示（都报红的话用户会以为装崩了）。
            # fresh=1 强制重新探测，供用户刚装完节点包时点「重新检测」。
            $comfy = $null
            try {
                $comfy = Get-ComfyUrl $ctx.Request
                $force = -not [string]::IsNullOrWhiteSpace([string]$ctx.Request.QueryString['fresh'])
                $capabilities = Get-ComfyCapabilities $comfy -Force:$force
                $report = Get-SelfCheckReport $capabilities
                $report | Add-Member -NotePropertyName comfyUrl -NotePropertyValue $comfy -Force
                # 顺带探测 ComfyUI-Manager：装了它前端才能把「复制安装命令」升级成「一键安装」。
                $report | Add-Member -NotePropertyName manager -NotePropertyValue (Get-ComfyManagerInfo $comfy) -Force
                Send-Json $ctx $report
            } catch {
                Send-Json $ctx ([pscustomobject]@{
                    connected = $false
                    comfyUrl  = [string]$comfy
                    error     = $_.Exception.Message
                })
            }
        }
        elseif ($path -eq '/api/system-stats' -and $method -eq 'GET') {
            # 只读性能快照：本机 CPU / 内存 / 显卡占用与显卡温度，供网页「性能监控」面板轮询。
            # 刻意不抛 5xx（与环境自检同策略）：个别字段读不到就在 errors 里说明，其余照常返回。
            # 数据来自后台常驻采集线程，这里只是读内存快照，因此可以撑住秒级刷新；
            # 快照缺失或过期时函数内部会退回按需采集，接口永远有数据。
            Send-Json $ctx (Get-SystemPerformanceSnapshot)
        }
        elseif ($path -eq '/api/install-package' -and $method -eq 'POST') {
            # 一键安装缺失的节点包：转发给 ComfyUI-Manager 的 POST /customnode/install/git_url
            # （body 为 JSON {"url": ...}，接口清单取自 Manager 源码 glob/manager_server.py）。
            #
            # 【安全】请求体里只接受**包名**，仓库地址由服务端 Get-InstallablePackage 从登记表反查，
            # 所以这个接口不可能被诱导去安装登记表之外的仓库。另与 /api/apply-update 保持一致的
            # 两道闸：要求 application/json（跨站表单发不出该 Content-Type，挡 CSRF）+ 同源校验。
            #
            # 注意：这里刻意不用 return —— 本段位于脚本顶层的主循环里，return 会直接结束整个服务。
            if ($ctx.Request.ContentType -notmatch 'application/json') { throw '请通过页面内的「一键安装」按钮执行安装。' }
            Assert-SameOrigin $ctx.Request
            Assert-RequestSize $ctx.Request 65536 '安装请求过大。'
            $bodyBytes = Read-RequestBytes $ctx.Request
            $bodyObject = [Text.Encoding]::UTF8.GetString($bodyBytes) | ConvertFrom-Json
            $packageName = [string]$bodyObject.package
            if ([string]::IsNullOrWhiteSpace($packageName)) { throw '安装请求缺少 package 字段。' }

            $target = Get-InstallablePackage $packageName
            if (-not $target) { throw "「$packageName」不在可安装清单里（本站只允许安装自检面板列出的节点包）。" }
            if ($target.isCore) { throw '这些是 ComfyUI 内置节点，请更新 ComfyUI，而不是安装节点包。' }
            if (-not $target.url) { throw "未登记「$packageName」的仓库地址，请在 ComfyUI-Manager 中按节点名搜索安装。" }

            $comfy = Get-ComfyUrl $ctx.Request $bodyObject
            if (-not (Get-ComfyManagerInfo $comfy).available) {
                throw '未检测到 ComfyUI-Manager，请先安装它，或改用「复制安装命令」手动安装。'
            }

            $payload = @{ url = [string]$target.url } | ConvertTo-Json -Compress
            $remote = Invoke-Comfy 'POST' "$comfy/customnode/install/git_url" ([Text.Encoding]::UTF8.GetBytes($payload)) 'application/json'
            if ($remote.Success) {
                Send-Json $ctx ([pscustomobject]@{
                    ok      = $true
                    message = "已提交 $packageName 的安装，装好后需要重启 ComfyUI 才会生效。"
                })
            } else {
                # Manager 的 403 带机器可读的 flag_token，直接抛给用户只会看到一个英文标识符，
                # 这里翻译成能照着做的说明。
                $detail = [Text.Encoding]::UTF8.GetString($remote.Bytes)
                $hint = "ComfyUI-Manager 拒绝安装（HTTP $($remote.StatusCode)）：$detail"
                if ($detail -match 'comfyui_outdated') {
                    $hint = 'ComfyUI 版本过旧，ComfyUI-Manager 拒绝执行 Git 安装。请先更新 ComfyUI。'
                } elseif ($detail -match 'allow_git_url_install') {
                    $hint = 'ComfyUI-Manager 没开启 Git URL 安装（配置项 allow_git_url_install），或 ComfyUI 不是以本机（loopback）模式启动。请改用「复制安装命令」手动安装。'
                } elseif ($detail -match 'security_level') {
                    $hint = 'ComfyUI-Manager 的 security_level 设置不允许该安装，请在 Manager 面板调整后重试，或改用「复制安装命令」。'
                }
                throw $hint
            }
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
                # mode 只在 TE-Speed 3.5+ 才有；旧版节点读到的会是 $null，正好用来判断节点版本。
                $debug.teMode = $speed.inputs.mode
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
            # 把浏览器的 Range 头透传给 ComfyUI，并回传 206 / Content-Range / Accept-Ranges：
            # 网页里的 <video> 拖动进度条依赖分段下载，不透传会导致每次都要整段读取且无法 seek。
            $forwardHeaders = @{}
            $rangeHeader = [string]$ctx.Request.Headers['Range']
            if (-not [string]::IsNullOrWhiteSpace($rangeHeader)) { $forwardHeaders['Range'] = $rangeHeader }
            $remote = Invoke-Comfy 'GET' "$comfy/view?filename=$filename&subfolder=$subfolder&type=$fileType" $null $null $forwardHeaders
            foreach ($headerName in @('Content-Range', 'Accept-Ranges', 'Content-Disposition')) {
                if ($remote.Headers -and $remote.Headers.ContainsKey($headerName)) {
                    try { $ctx.Response.Headers[$headerName] = $remote.Headers[$headerName] } catch {}
                }
            }
            Send-Bytes $ctx $remote.Bytes $remote.ContentType $remote.StatusCode
        }
        elseif ($path.StartsWith('/api/')) {
            Send-Error $ctx '未找到 API。' 404
        }
        else {
            $rel = $path.TrimStart('/')
            $file = if ($rel) { [System.IO.Path]::GetFullPath((Join-Path $root ($rel.Replace('/', '\')))) } else { Join-Path $root 'index.html' }
            $rootFull = [System.IO.Path]::GetFullPath($root)
            # 路径必须确实位于项目目录内。原实现用 $file.StartsWith($rootFull) 且区分大小写：
            # 既会把同名前缀的兄弟目录（如「…包-X」）判为合法，也不符合 Windows 路径不区分大小写的语义。
            $rootPrefix = $rootFull.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
            $insideRoot = $file.Equals($rootFull, [System.StringComparison]::OrdinalIgnoreCase) -or
                          $file.StartsWith($rootPrefix, [System.StringComparison]::OrdinalIgnoreCase)
            $ext = [System.IO.Path]::GetExtension($file).ToLower()
            # 同时要求：位于项目目录内 + 扩展名在白名单内 + 文件存在。不满足一律回退到首页，
            # 避免把 server.ps1、AI提示词配置.json、工作流 JSON 等当成静态资源直接发出去。
            if (-not $insideRoot -or
                -not $script:StaticExtensions.Contains($ext) -or
                -not (Test-Path $file -PathType Leaf)) {
                $file = Join-Path $root 'index.html'
                $ext = '.html'
            }
            $type = if ($mime.ContainsKey($ext)) { $mime[$ext] } else { 'text/html; charset=utf-8' }
            # HTML 不缓存：更新替换文件后浏览器刷新必须拿到新页面（JS/CSS 由 ?v= 参数控制缓存）。
            if ($ext -eq '.html') { $ctx.Response.Headers['Cache-Control'] = 'no-store' }
            Send-Bytes $ctx ([System.IO.File]::ReadAllBytes($file)) $type 200
        }
    } catch {
        try { Send-Error $ctx $_.Exception.Message 500 } catch {}
    } finally {
        if (-not $script:LoraResponseDetached) { try { $ctx.Response.Close() } catch {} }
    }
}

# 退出前把后台采集线程连同它的 runspace 一起收掉，避免进程退出时留下残留线程。
Stop-PerfCollector
foreach ($stream in $script:LoraStreams) { try { $stream.job.Stop(); $stream.job.Dispose() } catch {} }

try { $listener.Stop() } catch {}
if ($script:UpdateRestartPending) {
    Write-Host ""
    Write-Host "  工作站服务已退出，更新助手正在替换文件并重启服务，请稍候……" -ForegroundColor Cyan
    Write-Host "  如长时间没有新窗口弹出，请重新运行「启动工作站.bat」。" -ForegroundColor DarkGray
}
