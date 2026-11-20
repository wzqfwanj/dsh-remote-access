# 建立/修复到跳板机的 SSH 反向隧道：跳板机 127.0.0.1:$RemotePort → 本机 127.0.0.1:$LocalPort
# 用法：powershell -ExecutionPolicy Bypass -File scripts\start-tunnel.ps1
[CmdletBinding()]
param()

. "$PSScriptRoot\common.ps1"

$existing = @(Get-TunnelProcesses)
if ($existing.Count -gt 0) {
    if (Test-RemoteTunnelPort) {
        Write-DshLog "SSH 反向隧道正常（$SshHost 127.0.0.1:$RemotePort → 本机 127.0.0.1:$LocalPort）" 'tunnel.log'
        return
    }
    Write-DshLog "隧道进程存在但跳板机端口未监听，重建" 'tunnel.log'
    [void](Stop-TunnelProcesses)
    Start-Sleep -Seconds 2
}

# 先确认跳板机可达，避免无意义重试刷日志
& ssh -o BatchMode=yes -o ConnectTimeout=10 -o LogLevel=ERROR $SshHost "true" 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-DshLog "跳板机 $SshHost 连接失败，稍后重试（检查 ~/.ssh/config 与密钥）" 'tunnel.log'
    return
}

$errLog = Join-Path $LogDir 'tunnel.err.log'
if ((Test-Path -LiteralPath $errLog) -and ((Get-Item -LiteralPath $errLog).Length -gt 2MB)) {
    Move-Item -LiteralPath $errLog -Destination "$errLog.old" -Force -ErrorAction SilentlyContinue
}

$sshArgs = @(
    '-N',
    '-o', 'BatchMode=yes',
    '-o', 'ExitOnForwardFailure=yes',
    '-o', 'ConnectTimeout=15',
    '-o', 'ServerAliveInterval=15',
    '-o', 'ServerAliveCountMax=3',
    '-o', 'LogLevel=ERROR',
    '-R', "127.0.0.1:$RemotePort`:127.0.0.1:$LocalPort",
    $SshHost
)

Write-DshLog "建立 SSH 反向隧道：$SshHost 127.0.0.1:$RemotePort → 本机 127.0.0.1:$LocalPort" 'tunnel.log'
$outLog = Join-Path $LogDir 'tunnel.out.log'
# stdout/stderr 都重定向，避免长驻的 ssh 继承调用方管道句柄（否则父脚本会一直等 EOF）
Start-Process -FilePath 'ssh' -ArgumentList $sshArgs `
    -RedirectStandardOutput $outLog -RedirectStandardError $errLog -WindowStyle Hidden | Out-Null

for ($i = 1; $i -le 20; $i++) {
    Start-Sleep -Seconds 1
    if (Test-RemoteTunnelPort) {
        Write-DshLog "SSH 反向隧道就绪" 'tunnel.log'
        return
    }
}
Write-DshLog "SSH 反向隧道未就绪（20 秒内跳板机端口未监听），详见 $errLog" 'tunnel.log'
