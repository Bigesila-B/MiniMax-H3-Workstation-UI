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
echo  正在启动 MiniMax H3 视频工作站...
echo.
start "MiniMax H3 工作站服务" powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0server.ps1"
ping -n 3 127.0.0.1 >nul
start "" "http://127.0.0.1:8000/"
echo  工作站已启动，浏览器应已自动打开。
echo  如未打开，请手动访问 http://127.0.0.1:8000/
echo.
echo  停止服务：关闭名为「MiniMax H3 工作站服务」的黑色窗口。
timeout /t 6 >nul
