# Local LoRA library. Names come from ComfyUI; clients never supply filesystem paths.
$script:LoraLibraryCache = @{}
$script:LoraRootCache = @{}
$script:LoraDataDirectory = if ($env:WORKSTATION_LORA_DATA) { [IO.Path]::GetFullPath($env:WORKSTATION_LORA_DATA) } else { Join-Path $root '.lora-library' }
$script:LoraModelExtensions = @('.safetensors', '.ckpt', '.pt', '.pth', '.bin')
$script:LoraMediaTypes = @{ '.jpg'='image/jpeg'; '.jpeg'='image/jpeg'; '.png'='image/png'; '.webp'='image/webp'; '.gif'='image/gif'; '.mp4'='video/mp4'; '.webm'='video/webm' }
if (-not ('LoraNonSeekingStream' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.IO;
public sealed class LoraNonSeekingStream : Stream {
    private readonly Stream target;
    private long written;
    public LoraNonSeekingStream(Stream target) { this.target = target; }
    public override bool CanRead { get { return false; } }
    public override bool CanSeek { get { return false; } }
    public override bool CanWrite { get { return true; } }
    public override long Length { get { throw new NotSupportedException(); } }
    public override long Position { get { return written; } set { throw new NotSupportedException(); } }
    public override void Flush() { target.Flush(); }
    public override void Write(byte[] buffer, int offset, int count) { target.Write(buffer, offset, count); written += count; }
    public override int Read(byte[] buffer, int offset, int count) { throw new NotSupportedException(); }
    public override long Seek(long offset, SeekOrigin origin) { throw new NotSupportedException(); }
    public override void SetLength(long value) { throw new NotSupportedException(); }
}
'@
}

function Get-LoraId([string]$Comfy, [string]$Name) {
    $hash = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes("$Comfy|$Name")))).Replace('-', '').ToLowerInvariant() }
    finally { $hash.Dispose() }
}

function Read-LoraStore {
    $file = Join-Path $script:LoraDataDirectory 'library.json'
    if (-not (Test-Path -LiteralPath $file)) { return [pscustomobject]@{} }
    # A corrupt store must be reported, never silently replaced with an empty library.
    return (Get-Content -LiteralPath $file -Raw -Encoding UTF8 | ConvertFrom-Json)
}

function Save-LoraStore($Store) {
    [IO.Directory]::CreateDirectory($script:LoraDataDirectory) | Out-Null
    $file = Join-Path $script:LoraDataDirectory 'library.json'
    $temporary = "$file.tmp"
    [IO.File]::WriteAllText($temporary, ($Store | ConvertTo-Json -Depth 30), (New-Object Text.UTF8Encoding($false)))
    if (Test-Path -LiteralPath $file) { [IO.File]::Replace($temporary, $file, "$file.bak") }
    else { [IO.File]::Move($temporary, $file) }
}

function Get-LoraJson([string]$Url) {
    $cancel = New-Object Threading.CancellationTokenSource
    $cancel.CancelAfter(10000)
    $response = $null
    try {
        $response = $http.GetAsync($Url, $cancel.Token).GetAwaiter().GetResult()
        if (-not $response.IsSuccessStatusCode) { throw "LoRA 列表请求失败（HTTP $([int]$response.StatusCode)）。" }
        return ($response.Content.ReadAsStringAsync().GetAwaiter().GetResult() | ConvertFrom-Json)
    } finally { if ($response) { $response.Dispose() }; $cancel.Dispose() }
}

function Test-LoraContained([string]$Path, [string]$Directory) {
    try {
        $base = [IO.Path]::GetFullPath($Directory).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
        $full = [IO.Path]::GetFullPath($Path)
        if (-not $full.StartsWith($base, [StringComparison]::OrdinalIgnoreCase)) { return $false }
        # Do not traverse junctions or symbolic links, including the configured root itself.
        $cursor = $full
        while ($cursor -and $cursor.Length -ge $base.TrimEnd('\').Length) {
            if (Test-Path -LiteralPath $cursor) {
                if ((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { return $false }
            }
            $cursor = [IO.Path]::GetDirectoryName($cursor)
        }
        return $true
    } catch { return $false }
}

function Get-LoraRoots([string]$Comfy, [bool]$Fresh) {
    if (-not ([Uri]$Comfy).IsLoopback) { return @() }
    if (-not $Fresh -and $script:LoraRootCache[$Comfy] -and ((Get-Date) - $script:LoraRootCache[$Comfy].at).TotalSeconds -lt 60) { return @($script:LoraRootCache[$Comfy].roots) }
    $directories = @()
    if ($env:WORKSTATION_LORA_ROOTS) { $directories += @($env:WORKSTATION_LORA_ROOTS.Split(';')) }
    try {
        # Installed LoraManager supplies the actual roots, including extra_model_paths.
        $result = Get-LoraJson "$Comfy/api/lm/loras/roots"
        if ($result.success) { $directories += @($result.roots) }
    } catch {}
    if ($directories.Count -eq 0) {
        foreach ($process in @(Get-CimInstance Win32_Process -Filter "name = 'python.exe' OR name = 'pythonw.exe'" -ErrorAction SilentlyContinue)) {
            if ($process.CommandLine -match '"([^"\r\n]*[\\/]main\.py)"|([^\s"]*[\\/]main\.py)') {
                $main = if ($Matches[1]) { $Matches[1] } else { $Matches[2] }
                $directories += (Join-Path (Split-Path -Parent $main) 'models\loras')
            }
        }
    }
    $directories = @($directories | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Container) } | ForEach-Object { [IO.Path]::GetFullPath($_) } | Select-Object -Unique)
    $script:LoraRootCache[$Comfy] = @{ at=Get-Date; roots=$directories }
    return $directories
}

function Get-LoraLibrary([string]$Comfy, [bool]$Fresh = $false) {
    if (-not $Fresh -and $script:LoraLibraryCache[$Comfy] -and ((Get-Date) - $script:LoraLibraryCache[$Comfy].at).TotalSeconds -lt 20) { return $script:LoraLibraryCache[$Comfy].data }
    $names = @(Get-LoraJson "$Comfy/models/loras")
    $roots = @(Get-LoraRoots $Comfy $Fresh)
    $store = Read-LoraStore
    $items = @()
    foreach ($name in $names) {
        if ($name -isnot [string] -or [IO.Path]::IsPathRooted($name) -or $name -match '(^|[\\/])\.\.([\\/]|$)') { continue }
        if ($script:LoraModelExtensions -notcontains [IO.Path]::GetExtension($name).ToLowerInvariant()) { continue }
        $id = Get-LoraId $Comfy $name
        $path = $null
        $directory = $null
        foreach ($candidateRoot in $roots) {
            $candidate = Join-Path $candidateRoot $name
            if ((Test-LoraContained $candidate $candidateRoot) -and (Test-Path -LiteralPath $candidate -PathType Leaf)) { $path=$candidate; $directory=$candidateRoot; break }
        }
        $record = $store.PSObject.Properties[$id]
        $custom = if ($record) { $record.Value } else { [pscustomobject]@{} }
        $metadata = [pscustomobject]@{}
        $preview = $null
        $poster = $null
        $size = $null
        $updated = $null
        if ($path) {
            $file = Get-Item -LiteralPath $path
            $size = $file.Length
            $updated = $file.LastWriteTimeUtc.ToString('o')
            $stem = Join-Path $file.DirectoryName $file.BaseName
            foreach ($sidecar in @("$stem.metadata.json", "$path.metadata.json", "$stem.civitai.info")) {
                if ((Test-LoraContained $sidecar $directory) -and (Test-Path -LiteralPath $sidecar)) {
                    try { if ((Get-Item -LiteralPath $sidecar).Length -lt 2097152) { $metadata = Get-Content -LiteralPath $sidecar -Raw -Encoding UTF8 | ConvertFrom-Json; break } } catch {}
                }
            }
            # Local files only; remote preview URLs never become an SSRF or tracking request.
            foreach ($ext in @('.mp4','.webm','.gif','.webp','.png','.jpg','.jpeg')) {
                foreach ($candidate in @("$stem$ext", "$stem.preview$ext")) {
                    if ((Test-LoraContained $candidate $directory) -and (Test-Path -LiteralPath $candidate)) { if (-not $preview) { $preview=$candidate } }
                }
            }
            foreach ($ext in @('.webp','.png','.jpg','.jpeg')) {
                foreach ($candidate in @("$stem.poster$ext", "$stem$ext", "$stem.preview$ext")) {
                    if ((Test-LoraContained $candidate $directory) -and (Test-Path -LiteralPath $candidate)) { if (-not $poster) { $poster=$candidate } }
                }
            }
        }
        foreach ($kind in @('preview','poster')) {
            $stored = [string]$custom.$kind
            if ($stored -and $stored -match '^[a-f0-9]{64}-[a-f0-9]+\.(jpg|jpeg|png|webp|gif|mp4|webm)$') {
                $managed = Join-Path (Join-Path $script:LoraDataDirectory 'media') $stored
                if ((Test-LoraContained $managed $script:LoraDataDirectory) -and (Test-Path -LiteralPath $managed)) { if ($kind -eq 'preview') { $preview=$managed } else { $poster=$managed } }
            }
        }
        $title = if ($custom.PSObject.Properties['title']) { [string]$custom.title } elseif ($metadata.model_name) { [string]$metadata.model_name } else { [IO.Path]::GetFileNameWithoutExtension($name) }
        $author = if ($custom.PSObject.Properties['author']) { [string]$custom.author } elseif ($metadata.civitai.creator.username) { [string]$metadata.civitai.creator.username } elseif ($metadata.creator.username) { [string]$metadata.creator.username } else { '' }
        $baseModel = if ($custom.PSObject.Properties['baseModel']) { [string]$custom.baseModel } elseif ($metadata.base_model) { [string]$metadata.base_model } elseif ($metadata.baseModel) { [string]$metadata.baseModel } else { '' }
        $description = if ($custom.PSObject.Properties['description']) { [string]$custom.description } elseif ($metadata.notes) { [string]$metadata.notes } elseif ($metadata.modelDescription) { [string]$metadata.modelDescription } else { '' }
        $description = [Net.WebUtility]::HtmlDecode(($description -replace '<[^>]*>', ' '))
        $favorite = if ($custom.PSObject.Properties['favorite']) { [bool]$custom.favorite } else { [bool]$metadata.favorite }
        $type = if ($preview) { [IO.Path]::GetExtension($preview).TrimStart('.').ToLowerInvariant() } else { '' }
        $revision = if ($preview) { (Get-Item -LiteralPath $preview).LastWriteTimeUtc.Ticks.ToString() } else { '0' }
        if ($poster) { $revision += '-' + (Get-Item -LiteralPath $poster).LastWriteTimeUtc.Ticks.ToString() }
        $items += [pscustomobject]@{ id=$id; name=$name; title=$title; author=$author; baseModel=$baseModel; description=$description; favorite=$favorite; size=$size; updatedAt=$updated; revision=$revision; path=if ($path) { $path } else { $name }; local=[bool]$path; mediaType=$type; hasPreview=[bool]$preview; hasPoster=[bool]$poster; filePath=$path; previewPath=$preview; posterPath=$poster; modelRoot=$directory }
    }
    $data = [pscustomobject]@{ items=$items; local=($roots.Count -gt 0); note=if ($roots.Count -eq 0) { '未定位本机 LoRA 目录：可浏览和编辑资料；下载与删除需连接本机 ComfyUI，或设置 WORKSTATION_LORA_ROOTS。' } else { '' } }
    $script:LoraLibraryCache[$Comfy] = @{ at=Get-Date; data=$data }
    return $data
}

function Get-LoraEntry([string]$Comfy, [string]$Id) {
    if ($Id -notmatch '^[a-f0-9]{64}$') { throw '模型编号不合法。' }
    $entry = @((Get-LoraLibrary $Comfy).items | Where-Object { $_.id -eq $Id })
    if ($entry.Count -ne 1) { throw '模型已不存在，请刷新模型库。' }
    return $entry[0]
}

function Send-LoraFile($Context, [string]$File, [bool]$Download) {
    $info = Get-Item -LiteralPath $File
    $length = [long]$info.Length
    $start = [long]0
    $end = $length - 1
    $range = [string]$Context.Request.Headers['Range']
    if ($range) {
        if ($range -notmatch '^bytes=(\d*)-(\d*)$' -or (-not $Matches[1] -and -not $Matches[2])) { $Context.Response.StatusCode=416; $Context.Response.Headers['Content-Range']="bytes */$length"; return }
        if (-not $Matches[1]) { $start=[Math]::Max([long]0, $length-[long]$Matches[2]) }
        else { $start=[long]$Matches[1]; if ($Matches[2]) { $end=[Math]::Min($end,[long]$Matches[2]) } }
        if ($start -gt $end -or $start -ge $length) { $Context.Response.StatusCode=416; $Context.Response.Headers['Content-Range']="bytes */$length"; return }
        $Context.Response.StatusCode=206
        $Context.Response.Headers['Content-Range']="bytes $start-$end/$length"
    }
    $Context.Response.Headers['Accept-Ranges']='bytes'
    $Context.Response.Headers['X-Content-Type-Options']='nosniff'
    $Context.Response.Headers['Cache-Control']='private, max-age=60'
    $Context.Response.ContentLength64=[Math]::Max([long]0,$end-$start+1)
    $extension = $info.Extension.ToLowerInvariant()
    $Context.Response.ContentType = if ($Download) { 'application/octet-stream' } else { $script:LoraMediaTypes[$extension] }
    if ($Download) { $Context.Response.Headers['Content-Disposition']="attachment; filename*=UTF-8''$([Uri]::EscapeDataString($info.Name))" }
    # Stream on a separate runspace so model downloads/video playback do not block generation polling.
    $job = [PowerShell]::Create()
    [void]$job.AddScript({ param($ctx,$file,$offset,$count)
        $stream=$null
        try {
            $stream=[IO.File]::Open($file,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
            [void]$stream.Seek($offset,[IO.SeekOrigin]::Begin)
            $buffer=New-Object byte[] 65536
            while ($count -gt 0) {
                $read=$stream.Read($buffer,0,[int][Math]::Min([long]$buffer.Length,$count))
                if ($read -eq 0) { break }
                $ctx.Response.OutputStream.Write($buffer,0,$read)
                $count-=$read
            }
        } catch {} finally { if ($stream) { $stream.Dispose() }; try { $ctx.Response.Close() } catch {} }
    }).AddArgument($Context).AddArgument($File).AddArgument($start).AddArgument($Context.Response.ContentLength64)
    $async=$job.BeginInvoke()
    $script:LoraStreams += [pscustomobject]@{ job=$job; async=$async }
    $script:LoraResponseDetached=$true
}

$script:LoraStreams = @()
function Clear-LoraStreams {
    $pending=@()
    foreach ($stream in $script:LoraStreams) { if ($stream.async.IsCompleted) { try { [void]$stream.job.EndInvoke($stream.async) } catch {}; $stream.job.Dispose() } else { $pending+=$stream } }
    $script:LoraStreams=$pending
}

function Send-LoraArchive($Context, $Entries) {
    Add-Type -AssemblyName System.IO.Compression
    $Context.Response.ContentType='application/zip'
    $Context.Response.Headers['Content-Disposition']='attachment; filename="LoRA-models.zip"'
    $Context.Response.Headers['X-Content-Type-Options']='nosniff'
    $Context.Response.SendChunked=$true
    $job=[PowerShell]::Create()
    [void]$job.AddScript({ param($ctx,$entries)
        $zip=$null
        try {
            $transport=New-Object LoraNonSeekingStream($ctx.Response.OutputStream)
            $zip=New-Object IO.Compression.ZipArchive($transport,[IO.Compression.ZipArchiveMode]::Create,$true)
            foreach ($item in $entries) {
                $entry=$zip.CreateEntry($item.name.Replace('\','/'),[IO.Compression.CompressionLevel]::NoCompression)
                $modelStream=$null; $entryStream=$null
                try { $modelStream=[IO.File]::OpenRead($item.filePath); $entryStream=$entry.Open(); $modelStream.CopyTo($entryStream,65536) }
                finally { if ($entryStream) { $entryStream.Dispose() }; if ($modelStream) { $modelStream.Dispose() } }
            }
        } catch { [Console]::Error.WriteLine("LoRA archive: " + $_.Exception.GetBaseException().ToString()) } finally { if ($zip) { try { $zip.Dispose() } catch {} }; try { $ctx.Response.Close() } catch {} }
    }).AddArgument($Context).AddArgument($Entries)
    $async=$job.BeginInvoke()
    $script:LoraStreams += [pscustomobject]@{ job=$job; async=$async }
    $script:LoraResponseDetached=$true
}

function Invoke-LoraLibraryRoute($Context, [string]$Path, [string]$Method) {
    if (-not $Path.StartsWith('/api/lora-library')) { return $false }
    Clear-LoraStreams
    if ($Method -notin @('GET','POST')) { Send-Error $Context '请求方法不支持。' 405; return $true }
    $body=$null
    if ($Method -eq 'POST') {
        Assert-SameOrigin $Context.Request
        if ($Path -ne '/api/lora-library/upload') {
            if ($Context.Request.ContentType -notmatch '^application/json') { throw '请使用模型库界面执行操作。' }
            Assert-RequestSize $Context.Request 65536 '模型资料过大。'
            $bytes=Read-RequestBytes $Context.Request
            if ($bytes.Length -gt 65536) { throw '模型资料过大。' }
            $body=[Text.Encoding]::UTF8.GetString($bytes) | ConvertFrom-Json
        }
    }
    $comfy=Get-ComfyUrl $Context.Request $body
    if ($Path -eq '/api/lora-library' -and $Method -eq 'GET') {
        $library=Get-LoraLibrary $comfy ($Context.Request.QueryString['fresh'] -eq '1')
        $public=@($library.items | Select-Object id,name,title,author,baseModel,description,favorite,size,updatedAt,revision,path,local,mediaType,hasPreview,hasPoster)
        Send-Json $Context @{ items=$public; local=$library.local; note=$library.note }
        return $true
    }
    if ($Path -eq '/api/lora-library/archive' -and $Method -eq 'GET') {
        $ids=@(([string]$Context.Request.QueryString['ids']).Split(',') | Select-Object -Unique)
        if ($ids.Count -lt 1 -or $ids.Count -gt 100) { throw '每次请选择 1 至 100 个模型。' }
        $entries=@($ids | ForEach-Object { Get-LoraEntry $comfy $_ })
        foreach ($entry in $entries) { if (-not $entry.local -or -not (Test-LoraContained $entry.filePath $entry.modelRoot) -or -not (Test-Path -LiteralPath $entry.filePath)) { throw '只能下载已定位的本机模型。' } }
        if ($script:LoraStreams.Count -ge 6) { Send-Error $Context '下载请求较多，请稍后重试。' 429; return $true }
        Send-LoraArchive $Context $entries
        return $true
    }
    if ($Path -in @('/api/lora-library/media','/api/lora-library/download') -and $Method -eq 'GET') {
        $entry=Get-LoraEntry $comfy $Context.Request.QueryString['id']
        $download=$Path -eq '/api/lora-library/download'
        $file=if ($download) { $entry.filePath } elseif ($Context.Request.QueryString['kind'] -eq 'poster') { $entry.posterPath } else { $entry.previewPath }
        if (-not $file -or -not (Test-Path -LiteralPath $file -PathType Leaf)) { Send-Error $Context '文件不存在或不可在本机访问。' 404; return $true }
        $trusted=if ($download) { Test-LoraContained $file $entry.modelRoot } else { (Test-LoraContained $file $entry.modelRoot) -or (Test-LoraContained $file $script:LoraDataDirectory) }
        if (-not $trusted) { throw '文件不在允许的模型目录中。' }
        if (-not $download -and -not $script:LoraMediaTypes.ContainsKey([IO.Path]::GetExtension($file).ToLowerInvariant())) { throw '预览格式不支持。' }
        if ($script:LoraStreams.Count -ge 6) { Send-Error $Context '下载或预览请求较多，请稍后重试。' 429; return $true }
        Send-LoraFile $Context $file $download
        return $true
    }
    if ($Method -ne 'POST') { Send-Error $Context '接口不存在。' 404; return $true }
    $store=Read-LoraStore
    if ($Path -eq '/api/lora-library/upload') {
        if ($Context.Request.Headers['X-Lora-Upload'] -ne '1') { throw '请使用模型库的上传按钮。' }
        Assert-RequestSize $Context.Request 104857600 '预览文件不能超过 100 MB。'
        $entry=Get-LoraEntry $comfy $Context.Request.QueryString['id']
        $extension=([string]$Context.Request.QueryString['ext']).ToLowerInvariant()
        $kind=if ($Context.Request.QueryString['kind'] -eq 'poster') { 'poster' } else { 'preview' }
        if (-not $script:LoraMediaTypes.ContainsKey($extension) -or ($kind -eq 'poster' -and $extension -notin @('.jpg','.jpeg','.png','.webp'))) { throw '预览格式不支持。' }
        $bytes=Read-RequestBytes $Context.Request
        if ($bytes.Length -lt 12 -or $bytes.Length -gt 104857600) { throw '预览文件为空、损坏或超过 100 MB。' }
        $signature=[BitConverter]::ToString($bytes[0..11])
        $valid=switch ($extension) {
            '.jpg' { $signature.StartsWith('FF-D8-FF') }; '.jpeg' { $signature.StartsWith('FF-D8-FF') }
            '.png' { $signature.StartsWith('89-50-4E-47-0D-0A-1A-0A') }
            '.gif' { $signature.StartsWith('47-49-46-38-37-61') -or $signature.StartsWith('47-49-46-38-39-61') }
            '.webp' { [Text.Encoding]::ASCII.GetString($bytes,0,4) -eq 'RIFF' -and [Text.Encoding]::ASCII.GetString($bytes,8,4) -eq 'WEBP' }
            '.mp4' { [Text.Encoding]::ASCII.GetString($bytes,4,4) -eq 'ftyp' }
            '.webm' { $signature.StartsWith('1A-45-DF-A3') }
        }
        if (-not $valid) { throw '文件内容与所选媒体格式不符。' }
        $folder=Join-Path $script:LoraDataDirectory 'media'
        [IO.Directory]::CreateDirectory($folder) | Out-Null
        $filename="$($entry.id)-$([Guid]::NewGuid().ToString('N'))$extension"
        if (-not (Test-LoraContained (Join-Path $folder $filename) $script:LoraDataDirectory)) { throw '预览保存目录不合法。' }
        [IO.File]::WriteAllBytes((Join-Path $folder $filename),$bytes)
        $record=if ($store.PSObject.Properties[$entry.id]) { $store.PSObject.Properties[$entry.id].Value } else { [pscustomobject]@{} }
        $record | Add-Member -NotePropertyName $kind -NotePropertyValue $filename -Force
        $store | Add-Member -NotePropertyName $entry.id -NotePropertyValue $record -Force
        Save-LoraStore $store
    } elseif ($Path -eq '/api/lora-library/edit') {
        $entry=Get-LoraEntry $comfy ([string]$body.id)
        $record=if ($store.PSObject.Properties[$entry.id]) { $store.PSObject.Properties[$entry.id].Value } else { [pscustomobject]@{} }
        foreach ($field in @('title','author','baseModel','description')) {
            $value=([string]$body.$field).Trim()
            if ($value.Length -gt 10000) { throw '资料文字过长。' }
            $record | Add-Member -NotePropertyName $field -NotePropertyValue $value -Force
        }
        if (-not $record.title) { throw '请填写 LoRA 名称。' }
        $store | Add-Member -NotePropertyName $entry.id -NotePropertyValue $record -Force
        Save-LoraStore $store
    } elseif ($Path -eq '/api/lora-library/favorite') {
        if ($body.favorite -isnot [bool]) { throw '收藏状态必须为 true 或 false。' }
        $ids=@($body.ids)
        if ($ids.Count -lt 1 -or $ids.Count -gt 100) { throw '每次请选择 1 至 100 个模型。' }
        $entries=@($ids | ForEach-Object { Get-LoraEntry $comfy ([string]$_) })
        foreach ($entry in $entries) {
            $record=if ($store.PSObject.Properties[$entry.id]) { $store.PSObject.Properties[$entry.id].Value } else { [pscustomobject]@{} }
            $record | Add-Member -NotePropertyName favorite -NotePropertyValue ([bool]$body.favorite) -Force
            $store | Add-Member -NotePropertyName $entry.id -NotePropertyValue $record -Force
        }
        Save-LoraStore $store
    } elseif ($Path -eq '/api/lora-library/delete') {
        $ids=@($body.ids | Select-Object -Unique)
        if ($body.confirm -ne 'TRASH' -or $ids.Count -lt 1 -or $ids.Count -gt 100) { throw '请先确认要移入回收目录的模型。' }
        # Fresh lookup + preflight every path before moving anything.
        [void](Get-LoraLibrary $comfy $true)
        $entries=@($ids | ForEach-Object { Get-LoraEntry $comfy ([string]$_) })
        foreach ($entry in $entries) {
            if (-not $entry.local -or -not (Test-LoraContained $entry.filePath $entry.modelRoot)) { throw '仅能删除已定位的本机模型文件。' }
        }
        $trash=Join-Path (Join-Path $script:LoraDataDirectory 'trash') ([Guid]::NewGuid().ToString('N'))
        [IO.Directory]::CreateDirectory($trash) | Out-Null
        $manifest=@($entries | Select-Object id,name,filePath)
        [IO.File]::WriteAllText((Join-Path $trash 'manifest.json'),(ConvertTo-Json -InputObject $manifest -Depth 5),(New-Object Text.UTF8Encoding($false)))
        $moved=@()
        try {
            foreach ($entry in $entries) {
                $target=Join-Path $trash ($entry.id+[IO.Path]::GetExtension($entry.filePath))
                if (-not (Test-LoraContained $target $script:LoraDataDirectory)) { throw '回收目录不合法。' }
                Move-Item -LiteralPath $entry.filePath -Destination $target
                $moved+=@{ original=$entry.filePath; target=$target }
            }
        } catch {
            foreach ($move in $moved) { Move-Item -LiteralPath $move.target -Destination $move.original }
            throw
        }
        $script:LoraLibraryCache.Remove($comfy)
        Send-Json $Context @{ ok=$true; deleted=@($entries.name); trash=$trash }
        return $true
    } else { Send-Error $Context '接口不存在。' 404; return $true }
    $script:LoraLibraryCache.Remove($comfy)
    Send-Json $Context @{ ok=$true }
    return $true
}
