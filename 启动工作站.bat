@echo off
chcp 65001 >nul
net session >nul 2>&1
if not "%errorlevel%"=="0" (
  echo.
  echo  正在请求管理员权限，以启用手机和局域网访问...
  powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
  exit /b
)
title MiniMax H3 工作站启动器
cd /d "%~dp0"

echo.
echo  ============================================
echo   MiniMax H3 视频工作站
echo  ============================================
echo.

REM ============================================================
REM  [1/3] 清理旧服务进程
REM
REM  为什么必须做这一步：
REM    server.ps1 的代码改动只有在进程重启后才会生效。而 HttpListener 注册在
REM    Windows 内核的 HTTP.sys 上，旧进程只要还活着就会一直霸占 8000 端口，
REM    新进程绑不上端口，结果就是「明明重启了、窗口也新开了，但跑的还是旧代码」。
REM
REM  匹配方式（双条件，避免误杀）：
REM    1) 窗口标题精确等于 / 开头是「管理员: MiniMax H3 工作站服务」
REM       —— 这是本脚本用 start "..." 起的窗口标题，最可靠；
REM       提权进程的 CommandLine 在普通权限下读不到，所以不能只靠命令行匹配。
REM    2) 监听 8000 端口的进程
REM       —— 兜底：万一窗口标题被改过也能找出来。
REM ============================================================
echo  [1/3] 清理旧服务进程...
powershell -NoProfile -ExecutionPolicy Bypass -Command "$ids = New-Object 'System.Collections.Generic.HashSet[int]'; foreach ($p in (Get-Process -ErrorAction SilentlyContinue)) { if ($p.MainWindowTitle -like '*MiniMax H3 工作站服务*') { [void]$ids.Add($p.Id) } }; foreach ($c in (Get-NetTCPConnection -LocalPort 8000 -State Listen -ErrorAction SilentlyContinue)) { if ($c.OwningProcess -ne 4 -and $c.OwningProcess -ne 0) { [void]$ids.Add([int]$c.OwningProcess) } }; if ($ids.Count -eq 0) { Write-Host '      未发现旧进程，无需清理' -ForegroundColor DarkGray } else { foreach ($id in $ids) { try { $pr = Get-Process -Id $id -ErrorAction SilentlyContinue; $nm = if ($pr) { $pr.ProcessName } else { '?' }; Stop-Process -Id $id -Force -ErrorAction Stop; Write-Host \"      已停止旧进程 PID=$id ($nm)\" -ForegroundColor Yellow } catch { Write-Host \"      PID=$id 停止失败：$($_.Exception.Message)\" -ForegroundColor Red } } }"

REM 给 HTTP.sys 一点时间释放 8000 端口的 URL 前缀注册
ping -n 3 127.0.0.1 >nul
echo.

REM ============================================================
REM  [2/3] 启动服务
REM ============================================================
echo  [2/3] 正在启动 MiniMax H3 视频工作站...
start "MiniMax H3 工作站服务" powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0server.ps1"

REM 轮询等待服务真正就绪：最多等 20 秒。
REM 不用固定 ping 秒数，是因为慢机器上会误判「已启动」而实际还没起来。
echo       等待服务就绪...
powershell -NoProfile -ExecutionPolicy Bypass -Command "$ok = $false; for ($i = 0; $i -lt 40; $i++) { Start-Sleep -Milliseconds 500; try { $r = Invoke-WebRequest -Uri 'http://127.0.0.1:8000/api/capabilities' -UseBasicParsing -TimeoutSec 3 -ErrorAction Stop; if ($r.StatusCode -eq 200) { $ok = $true; break } } catch {} }; if ($ok) { Write-Host '      服务已就绪' -ForegroundColor Green } else { Write-Host '      警告：20 秒内未能连上服务，请查看工作站窗口的报错。' -ForegroundColor Red; Write-Host '      常见原因：ComfyUI 未启动、8000 端口被其它程序占用。' -ForegroundColor DarkGray }"

echo.
echo  [3/3] 打开浏览器...
start "" "http://127.0.0.1:8000/"
echo.
echo  ============================================
echo   工作站已启动
echo   停止服务：关闭名为「MiniMax H3 工作站服务」的黑色窗口
echo  ============================================
echo.
timeout /t 8 >nul
