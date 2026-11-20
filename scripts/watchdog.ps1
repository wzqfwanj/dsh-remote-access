# 看护进程：保证「桌面 Web 端口探测 + 本机中继 + SSH 反向隧道」一直在线。
# 由登录自启（启动文件夹 / HKCU Run）拉起。
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
$lastPortLog = [datetime]::MinValue
while ($true) {
    $loop++

    # 1) 探测桌面 DSH Web 端口（桌面 App 每次启动端口可能变化）
    try {
        $port = Get-DesktopWebPort
        $probe = $false
        if (-not $port) {
            $probe = $true
        } else {
            # 端口文件存在但已失效（桌面 App 重启换了端口/已退出）：按需重新探测
            if (-not (Test-PortListening -Port $port)) { $probe = $true }
        }
        if ($probe) {
            & (Join-Path $PSScriptRoot 'get-dsh-web-port.ps1') | Out-Null
            $port = Get-DesktopWebPort
        }
        if (-not $port -and ((Get-Date) - $lastPortLog).TotalMinutes -ge 5) {
            $lastPortLog = Get-Date
            Write-DshLog "未发现 DSH 桌面 Web 端口：桌面 App 可能未运行，远程会返回 502" 'relay.log'
        }
    } catch {
        Write-DshLog "探测桌面 Web 端口出错：$($_.Exception.Message)" 'relay.log'
    }

    # 2) 本机中继
    try {
        if (-not (Test-PortListening -Port $LocalPort)) {
            if (Get-DesktopWebPort) {
                Write-DshLog "检测到 DSH 中继未监听，尝试启动" 'relay.log'
                & (Join-Path $PSScriptRoot 'start-relay.ps1')
            }
        }
    } catch {
        Write-DshLog "检查 DSH 中继出错：$($_.Exception.Message)" 'relay.log'
    }

    # 3) SSH 反向隧道：每 5 轮（约 100 秒）做一次远端端口实测
    try {
        $tunnels = @(Get-TunnelProcesses)
        if ($tunnels.Count -eq 0) {
            & (Join-Path $PSScriptRoot 'start-tunnel.ps1')
        } elseif ($loop % 5 -eq 1 -and -not (Test-RemoteTunnelPort)) {
            Write-DshLog "隧道进程存在但跳板机端口不监听，重建" 'tunnel.log'
            [void](Stop-TunnelProcesses)
            Start-Sleep -Seconds 2
            & (Join-Path $PSScriptRoot 'start-tunnel.ps1')
        }
    } catch {
        Write-DshLog "检查隧道出错：$($_.Exception.Message)" 'tunnel.log'
    }

    Start-Sleep -Seconds 20
}
