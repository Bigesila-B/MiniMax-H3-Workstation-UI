<#
  MiniMax H3 工作站 —— 启动器（真正的启动逻辑都在这里）

  【为什么这些逻辑不放在 .bat 里】
  cmd.exe 在活动代码页为 65001（UTF-8）时解析批处理文件有缺陷：它按「字节偏移」回退读取
  文件，遇到多字节字符（中文）时会从字符中间切断，把一行拆成两半 —— 后半截会被当成命令执行，
  终端里于是冒出一堆
      '……' is not recognized as an internal or external command
  实测原 .bat 里两行长中文注释（REM）就是这么被拆出来的。

  所以约定如下，改动时请遵守：
    * 启动工作站.bat 保持「纯 ASCII」，只负责把本脚本叫起来，里面不写任何中文；
    * 中文与全部逻辑放本文件 —— PowerShell 读 UTF-8(BOM) 脚本没有上述问题。
    * 本文件必须保持 **UTF-8 带 BOM + CRLF** 保存，否则 PowerShell 5.1 会把中文读成乱码。

  用法（一般由 启动工作站.bat 双击调用，也可手动跑）：
    powershell -NoProfile -ExecutionPolicy Bypass -File launch.ps1
  可选参数：
    -Port 8000            服务端口（默认 8000，与 server.ps1 的 WORKSTATION_PORT 一致）
    -NoBrowser            启动后不自动打开浏览器（自测用）
    -NoPause              出错时不等待按键（由 启动工作站.bat 传入：它自己会在退出码非 0 时 pause，
                          两边都等会让用户连按两次回车）
#>
param(
    [int]$Port = 8000,
    [switch]$NoBrowser,
    [switch]$NoPause
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$serverScript = Join-Path $root 'server.ps1'
$serviceTitle = 'MiniMax H3 工作站服务'

function Write-Step([string]$Text) { Write-Host "  $Text" -ForegroundColor Cyan }
function Write-Ok([string]$Text) { Write-Host "  $Text" -ForegroundColor Green }
function Write-Warn([string]$Text) { Write-Host "  $Text" -ForegroundColor Yellow }

function Wait-ExitKey {
    # 出错时停一下让用户看清信息。
    # 由 启动工作站.bat 调用时传了 -NoPause：.bat 在退出码非 0 时自己会 pause，
    # 两边都等的话用户要按两次回车，很容易以为程序卡住了。
    # 手动直接运行本脚本（不经过 .bat）时仍然等待，否则窗口一闪而过什么都来不及看。
    if ($NoPause) { return }
    Read-Host '按回车键退出' | Out-Null
}

function Start-DetachedProcess {
    # 统一的「起一个独立进程」入口。
    #
    # 【为什么不用 Start-Process】
    # Windows PowerShell 5.1 的 Start-Process 在构造子进程环境时，要求环境变量名在
    # 大小写不敏感的前提下唯一；一旦系统里同时存在 Path 与 PATH（或 HTTP_PROXY 与
    # http_proxy）这类仅大小写不同的重复键，它会直接抛
    #     「已添加项。字典中的关键字:"Path"所添加的关键字:"PATH"」
    # 而启动器恰恰是最不该挑环境的地方。改用 .NET 的 Process.Start + UseShellExecute，
    # 不经过那套环境字典，行为等价且没有这个限制。
    #
    # UseShellExecute = $true 有两个必要作用：
    #   1) 子进程会拿到自己的控制台窗口 —— 服务窗口必须是独立可关闭的；
    #   2) FileName 传 URL 时由系统默认浏览器打开。
    param(
        [string]$FileName,
        [string]$Arguments = '',
        [string]$Verb = ''
    )
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $FileName
    if ($Arguments) { $startInfo.Arguments = $Arguments }
    if ($Verb) { $startInfo.Verb = $Verb }
    $startInfo.UseShellExecute = $true
    $startInfo.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Normal
    return [System.Diagnostics.Process]::Start($startInfo)
}

function Test-Administrator {
    # 是否需要管理员：只有绑定「局域网地址」才需要提权（HTTP.sys 的 URL 前缀注册）。
    # 只用本机 127.0.0.1 时普通权限就够，server.ps1 会自动退回该模式。
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-StaleWorkstationProcess {
    # 找出「上一次没关干净」的旧服务进程。
    #
    # 为什么必须清：server.ps1 的代码改动只有进程重启后才生效，而 HttpListener 注册在
    # Windows 内核的 HTTP.sys 上，旧进程只要还活着就会一直霸占端口，新进程绑不上 ——
    # 表现就是「明明重启了、窗口也新开了，但跑的还是旧代码」。
    #
    # 匹配用双条件，避免误杀其它程序：
    #   1) 主窗口标题包含「MiniMax H3 工作站服务」—— server.ps1 会自己把标题设成它；
    #      提权进程的命令行在普通权限下读不到，所以不能只靠命令行匹配。
    #   2) 正在监听目标端口的进程 —— 兜底，万一窗口标题被改过也能找出来。
    param([int]$Port)
    $ids = New-Object 'System.Collections.Generic.HashSet[int]'
    foreach ($process in (Get-Process -ErrorAction SilentlyContinue)) {
        if ($process.MainWindowTitle -like "*$serviceTitle*") { [void]$ids.Add($process.Id) }
    }
    try {
        foreach ($conn in (Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction Stop)) {
            if ($conn.OwningProcess -ne 4 -and $conn.OwningProcess -ne 0) {
                [void]$ids.Add([int]$conn.OwningProcess)
            }
        }
    } catch {
        # 该端口没人监听时 Get-NetTCPConnection 会报错，属正常情况，忽略。
    }
    [void]$ids.Remove($PID)
    return @($ids)
}

function Start-WorkstationService {
    # 单独开一个窗口跑 server.ps1：用户按说明关掉那个窗口就等于停止服务。
    # server.ps1 启动后会自己把窗口标题设成「MiniMax H3 工作站服务」。
    # 端口通过环境变量传递（子进程继承），与 server.ps1 的 WORKSTATION_PORT 约定一致。
    param([string]$ServerScript, [int]$Port)
    $env:WORKSTATION_PORT = "$Port"
    return Start-DetachedProcess -FileName 'powershell.exe' `
        -Arguments "-NoProfile -ExecutionPolicy Bypass -File `"$ServerScript`""
}

function Wait-StationReady {
    # 轮询等待服务真正就绪，最多等 20 秒。
    # 不用固定 sleep：慢机器上会误判「已启动」而实际还没起来。
    # 判定标准是「拿到任何 HTTP 响应」——服务在监听就算起来了；
    # 返回码是不是 200 只反映 ComfyUI 通不通，不该算作启动失败（否则 ComfyUI 没开会误报）。
    param([int]$Port, [int]$TimeoutSeconds = 20)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $url = "http://127.0.0.1:$Port/api/capabilities"
    while ((Get-Date) -lt $deadline) {
        $status = 0
        try {
            $response = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 3 -ErrorAction Stop
            $status = [int]$response.StatusCode
        } catch {
            $response = $_.Exception.Response
            if ($response) { $status = [int]$response.StatusCode }
        }
        if ($status -gt 0) { return $status }
        Start-Sleep -Milliseconds 500
    }
    return 0
}

# ---------------------------------------------------------------- 主流程

try { $Host.UI.RawUI.WindowTitle = 'MiniMax H3 工作站启动器' } catch { }

Write-Host ''
Write-Host '  ============================================' -ForegroundColor DarkCyan
Write-Host '   MiniMax H3 视频工作站' -ForegroundColor White
Write-Host '  ============================================' -ForegroundColor DarkCyan
Write-Host ''

if (-not (Test-Path -LiteralPath $serverScript)) {
    Write-Warn "[错误] 找不到 server.ps1：$serverScript"
    Write-Host '       请确认整个文件夹都是完整解压出来的。' -ForegroundColor DarkGray
    Wait-ExitKey
    exit 3
}

if (-not (Get-Command powershell -ErrorAction SilentlyContinue)) {
    Write-Warn '[错误] 找不到 powershell.exe，无法启动服务。'
    Wait-ExitKey
    exit 3
}

# [0/3] 提权。用户拒绝 UAC 时**不中断**：server.ps1 会自动退回「仅本机」模式，
# 仍然可以正常在本机使用，只是手机 / 局域网访问不了。
if (-not (Test-Administrator)) {
    Write-Step '[0/3] 正在请求管理员权限（用于手机 / 局域网访问）...'
    try {
        # 提权后的那份必须**带上原样参数**：否则 `launch.ps1 -Port 9000` 会变成
        # 「启动器等 9000、服务跑在 8000」→ 20 秒后误报「未能连上服务」，实际服务是好的。
        $relaunchArguments = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Port $Port -NoPause"
        if ($NoBrowser) { $relaunchArguments += ' -NoBrowser' }
        [void](Start-DetachedProcess -FileName 'powershell.exe' -Verb 'runas' -Arguments $relaunchArguments)
        exit 0
    } catch {
        Write-Warn '[0/3] 未获得管理员权限，改为「仅本机」模式启动：手机 / 局域网暂时访问不了。'
        Write-Host '       需要手机访问时，请关掉本窗口，右键启动脚本选「以管理员身份运行」。' -ForegroundColor DarkGray
    }
} else {
    Write-Ok '[0/3] 已获得管理员权限，手机 / 局域网可访问。'
}

# [1/3] 清理旧服务进程
Write-Host ''
Write-Step "[1/3] 清理旧服务进程（端口 $Port）..."
$stale = @(Get-StaleWorkstationProcess -Port $Port)
if ($stale.Count -eq 0) {
    Write-Host '       未发现旧进程，无需清理。' -ForegroundColor DarkGray
} else {
    foreach ($staleId in $stale) {
        try {
            $info = Get-Process -Id $staleId -ErrorAction SilentlyContinue
            $name = if ($info) { $info.ProcessName } else { '未知' }
            Stop-Process -Id $staleId -Force -ErrorAction Stop
            Write-Warn "       已停止旧进程 PID=$staleId ($name)"
        } catch {
            Write-Warn "       PID=$staleId 停止失败：$($_.Exception.Message)"
        }
    }
}
# 给 HTTP.sys 一点时间释放端口上的 URL 前缀注册，否则紧接着启动的新进程可能绑不上。
Start-Sleep -Seconds 2

# [2/3] 启动服务并等待就绪
Write-Host ''
Write-Step "[2/3] 正在启动 MiniMax H3 视频工作站（端口 $Port）..."
[void](Start-WorkstationService -ServerScript $serverScript -Port $Port)
Write-Host '       等待服务就绪...' -ForegroundColor DarkGray
$status = Wait-StationReady -Port $Port -TimeoutSeconds 20
if ($status -gt 0) {
    Write-Ok '       服务已就绪。'
    if ($status -ne 200) {
        Write-Warn "       提示：服务返回 HTTP $status，多半是 ComfyUI 还没启动或未连上；工作站界面仍可正常打开。"
    }
} else {
    Write-Warn '       警告：20 秒内未能连上服务，请查看「MiniMax H3 工作站服务」窗口里的报错。'
    Write-Host '       常见原因：端口被其它程序占用；安全软件拦截了 PowerShell 的端口监听。' -ForegroundColor DarkGray
}

# [3/3] 打开浏览器
Write-Host ''
Write-Step '[3/3] 正在打开浏览器...'
if (-not $NoBrowser) {
    try {
        [void](Start-DetachedProcess -FileName "http://127.0.0.1:$Port/")
    } catch {
        Write-Warn "       自动打开失败，请手动访问 http://127.0.0.1:$Port/"
    }
}

Write-Host ''
Write-Host '  ============================================' -ForegroundColor DarkCyan
Write-Host '   工作站已启动' -ForegroundColor Green
Write-Host "   访问地址：http://127.0.0.1:$Port/" -ForegroundColor White
Write-Host "   停止服务：关闭名为「$serviceTitle」的黑色窗口" -ForegroundColor White
Write-Host '  ============================================' -ForegroundColor DarkCyan
Write-Host ''
Write-Host '  本窗口 5 秒后自动关闭（后台服务不受影响）。' -ForegroundColor DarkGray
Start-Sleep -Seconds 5
