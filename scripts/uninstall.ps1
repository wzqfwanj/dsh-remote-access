# 卸载：移除登录自启项，停止看护/dsh web/SSH 隧道。
# 用法：powershell -ExecutionPolicy Bypass -File scripts\uninstall.ps1
[CmdletBinding()]
param()

. "$PSScriptRoot\common.ps1"

# 1) 移除登录自启（启动文件夹 + HKCU Run）
$startupDir = [Environment]::GetFolderPath('Startup')
$vbsPath = Join-Path $startupDir 'DSH-Web-Remote.vbs'
if (Test-Path -LiteralPath $vbsPath) {
    Remove-Item -LiteralPath $vbsPath -Force -ErrorAction SilentlyContinue
    Write-DshLog "已删除登录自启：$vbsPath"
}
try {
    $runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
    if (Get-ItemProperty -Path $runKey -Name 'DSH-Web-Remote' -ErrorAction SilentlyContinue) {
        Remove-ItemProperty -Path $runKey -Name 'DSH-Web-Remote' -Force -ErrorAction SilentlyContinue
        Write-DshLog "已删除 HKCU Run 自启项"
    }
} catch { }

# 2) 停 watchdog
$watchdogs = Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -and $_.CommandLine -match 'watchdog\.ps1' }
foreach ($w in @($watchdogs)) { Stop-Process -Id $w.ProcessId -Force -ErrorAction SilentlyContinue }
if (@($watchdogs).Count -gt 0) { Write-DshLog "已停止 watchdog（$(($watchdogs | ForEach-Object { $_.ProcessId }) -join ',')）" }

# 3) 停 SSH 反向隧道
$n = Stop-TunnelProcesses
if ($n -gt 0) { Write-DshLog "已停止 SSH 反向隧道（$n 个进程）" }

# 4) 停本机 dsh web
$servers = Get-CimInstance Win32_Process -Filter "Name='DeepSeek Harness.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -and $_.CommandLine.Contains('dsh\lib\bin.js') -and $_.CommandLine.Contains(' web ') }
foreach ($s in @($servers)) { Stop-Process -Id $s.ProcessId -Force -ErrorAction SilentlyContinue }
if (@($servers).Count -gt 0) { Write-DshLog "已停止本机 dsh web" }

Write-DshLog "卸载完成。跳板机 Caddy 配置可保留（无隧道时访问返回 502）。"
