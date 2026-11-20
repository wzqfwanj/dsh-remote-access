# 看护进程：保证 dsh web 与 SSH 反向隧道一直在线；由计划任务「DSH-Web-Remote」在登录时启动。
# 用法：powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File scripts\watchdog.ps1
[CmdletBinding()]
param()

. "$PSScriptRoot\common.ps1"

# 单实例：已有 watchdog 在跑就直接退出
$others = Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -and $_.CommandLine -match 'watchdog\.ps1' -and $_.ProcessId -ne $PID }
if ($others) {
    Write-Host ("已有 watchdog 在运行（PID {0}），本实例退出" -f (($others | ForEach-Object { $_.ProcessId }) -join ','))
    exit 0
}

Write-DshLog "watchdog 启动（PID $PID）"

$loop = 0
while ($true) {
    $loop++

    # 1) 本机 dsh web
    try {
        if (-not (Test-PortListening -Port $LocalPort)) {
            Write-DshLog "检测到 dsh web 未监听，尝试启动"
            & (Join-Path $PSScriptRoot 'start-dsh-web.ps1')
        }
    } catch {
        Write-DshLog "检查 dsh web 出错：$($_.Exception.Message)"
    }

    # 2) SSH 反向隧道：每 5 轮（约 100 秒）做一次远端端口实测
    try {
        $tunnels = @(Get-TunnelProcesses)
        if ($tunnels.Count -eq 0) {
            & (Join-Path $PSScriptRoot 'start-tunnel.ps1')
        } elseif ($loop % 5 -eq 1 -and -not (Test-RemoteTunnelPort)) {
            Write-DshLog "隧道进程存在但跳板机端口不监听，重建"
            [void](Stop-TunnelProcesses)
            Start-Sleep -Seconds 2
            & (Join-Path $PSScriptRoot 'start-tunnel.ps1')
        }
    } catch {
        Write-DshLog "检查隧道出错：$($_.Exception.Message)"
    }

    Start-Sleep -Seconds 20
}
