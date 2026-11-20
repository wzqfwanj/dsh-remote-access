# 启动 DSH 桌面 Web GUI 本地中继（只绑定 127.0.0.1）。
# 中继把请求转发到「桌面 DSH 进程自己的 Web 端口」，因此远程看到的就是本地同一实例（实时状态）。
# 用法：powershell -ExecutionPolicy Bypass -File scripts\start-relay.ps1
[CmdletBinding()]
param()

. "$PSScriptRoot\common.ps1"

if (Test-PortListening -Port $LocalPort) {
    Write-DshLog "DSH 中继已在 127.0.0.1:$LocalPort 监听，跳过启动" 'relay.log'
    return
}

# 中继密钥（Caddy 会带同一个值，缺了就生成）
[void](Get-RelayKey)

# 探测桌面 DSH Web 端口
if (-not (Get-DesktopWebPort)) {
    & (Join-Path $PSScriptRoot 'get-dsh-web-port.ps1') | Out-Null
}
$desktopPort = Get-DesktopWebPort
if (-not $desktopPort) {
    Write-DshLog "未发现 DSH 桌面 Web 端口（桌面 App 可能未运行），暂不启动中继" 'relay.log'
    return
}

# 清理残留中继进程
$stale = @(Get-RelayProcesses)
foreach ($p in $stale) { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue }

$python = Get-PythonExe
$outLog = Join-Path $LogDir 'relay.out.log'
$errLog = Join-Path $LogDir 'relay.err.log'
foreach ($f in @($outLog, $errLog)) {
    if ((Test-Path -LiteralPath $f) -and ((Get-Item -LiteralPath $f).Length -gt 2MB)) {
        Move-Item -LiteralPath $f -Destination "$f.old" -Force -ErrorAction SilentlyContinue
    }
}

$credentials = Join-Path $env:USERPROFILE '.dsh\.credentials.yaml'
$arguments = @(
    ('"' + (Join-Path $RepoRoot 'relay\relay.py') + '"'),
    '--listen-port', "$LocalPort",
    '--port-file', ('"' + $DesktopPortFile + '"'),
    '--key-file', ('"' + $RelayKeyFile + '"'),
    '--credentials', ('"' + $credentials + '"')
)

$env:PYTHONIOENCODING = 'utf-8'
Write-DshLog "启动 DSH 中继：127.0.0.1:$LocalPort → 127.0.0.1:$desktopPort（桌面 DSH 实例）" 'relay.log'
Start-Process -FilePath $python -ArgumentList $arguments -WorkingDirectory $RepoRoot `
    -RedirectStandardOutput $outLog -RedirectStandardError $errLog -WindowStyle Hidden | Out-Null

for ($i = 1; $i -le 20; $i++) {
    Start-Sleep -Seconds 1
    if (Test-PortListening -Port $LocalPort) {
        Write-DshLog "DSH 中继就绪（桌面端口 $desktopPort）" 'relay.log'
        return
    }
}
$tail = (Get-Content -LiteralPath $errLog -ErrorAction SilentlyContinue | Select-Object -Last 5) -join ' | '
Write-DshLog "DSH 中继启动失败（20 秒内未监听），详见 $errLog：$tail" 'relay.log'
