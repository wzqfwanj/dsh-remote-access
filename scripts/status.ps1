# 状态检查：桌面 DSH Web 端口、本机中继、SSH 反向隧道、登录自启、访问入口与凭据
# 用法：powershell -ExecutionPolicy Bypass -File scripts\status.ps1
[CmdletBinding()]
param()

. "$PSScriptRoot\common.ps1"

$desktopPort = Get-DesktopWebPort
$desktopUp = if ($desktopPort) { Test-PortListening -Port $desktopPort } else { $false }
$relayUp = Test-PortListening -Port $LocalPort
$relayProcs = @(Get-RelayProcesses)
$tunnelProcs = @(Get-TunnelProcesses)
$remoteUp = Test-RemoteTunnelPort
$watchdogs = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -and $_.CommandLine -match 'watchdog\.ps1' })
$startupDir = [Environment]::GetFolderPath('Startup')
$startupVbs = Join-Path $startupDir 'DSH-Web-Remote.vbs'

function Format-State([bool]$Condition) {
    if ($Condition) { return '正常' } else { return '异常' }
}

Write-Host ''
Write-Host '================ DSH 远程访问状态 ================'
if ($desktopPort) {
    Write-Host ("桌面 DSH Web（127.0.0.1:{0}）  : {1}" -f $desktopPort, (Format-State $desktopUp))
} else {
    Write-Host '桌面 DSH Web                   : 未探测到（桌面 App 可能未运行）'
}
Write-Host ("本机中继（127.0.0.1:{0}）     : {1}，进程 {2} 个" -f $LocalPort, (Format-State $relayUp), $relayProcs.Count)
Write-Host ("SSH 隧道进程                  : {0} 个" -f $tunnelProcs.Count)
Write-Host ("跳板机 {0} 端口 {1}     : {2}" -f $SshHost, $RemotePort, (Format-State $remoteUp))
Write-Host ("看护进程 watchdog             : {0} 个" -f $watchdogs.Count)
Write-Host ("登录自启（启动文件夹）        : {0}" -f (Format-State (Test-Path -LiteralPath $startupVbs)))
Write-Host ''
Write-Host ('远程入口：{0}   （浏览器打开后输入下面账号密码）' -f $PublicUrl)
$authFile = Join-Path $RuntimeDir 'basic-auth.txt'
if (Test-Path -LiteralPath $authFile) {
    Write-Host ("Basic Auth：{0}" -f ((Get-Content -LiteralPath $authFile -Raw).Trim()))
}
$keyFile = $RelayKeyFile
if (Test-Path -LiteralPath $keyFile) {
    Write-Host "中继密钥：已配置（runtime\relay-key.txt；必须与跳板机 Caddy 的 X-Dsh-Relay-Key 一致）"
}
Write-Host '=================================================='
Write-Host ''
