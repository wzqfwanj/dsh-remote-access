# 状态检查：本机 dsh web、SSH 反向隧道、登录自启、访问链接与凭据
# 用法：powershell -ExecutionPolicy Bypass -File scripts\status.ps1
[CmdletBinding()]
param()

. "$PSScriptRoot\common.ps1"

$localUp = Test-PortListening -Port $LocalPort
$tunnelProcs = @(Get-TunnelProcesses)
$remoteUp = Test-RemoteTunnelPort
$watchdogs = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -and $_.CommandLine -match 'watchdog\.ps1' })
$startupDir = [Environment]::GetFolderPath('Startup')
$startupVbs = Join-Path $startupDir 'DSH-Web-Remote.vbs'
$url = Get-DshWebUrl

function Format-State([bool]$Condition) {
    if ($Condition) { return '正常' } else { return '异常' }
}

Write-Host ''
Write-Host '================ DSH 远程访问状态 ================'
Write-Host ("本机 dsh web（127.0.0.1:{0}） : {1}" -f $LocalPort, (Format-State $localUp))
Write-Host ("SSH 隧道进程                  : {0} 个" -f $tunnelProcs.Count)
Write-Host ("跳板机 {0} 端口 {1}     : {2}" -f $SshHost, $RemotePort, (Format-State $remoteUp))
Write-Host ("看护进程 watchdog             : {0} 个" -f $watchdogs.Count)
Write-Host ("登录自启（启动文件夹）        : {0}" -f (Format-State (Test-Path -LiteralPath $startupVbs)))
Write-Host ''
if ($url) {
    $url = $url.Trim()
    Write-Host '带 token 的登录链接（首次/换浏览器时打开，cookie 有效期 30 天）：'
    Write-Host "  $url"
    # 同时写一个 .url 快捷方式，双击即可用默认浏览器打开（避免手抄长链接）
    try {
        $loginUrlFile = Join-Path $RuntimeDir 'login.url'
        Set-Content -LiteralPath $loginUrlFile -Value @('[InternetShortcut]', "URL=$url") -Encoding ASCII
        Write-Host "  （已生成可双击打开的快捷方式：$loginUrlFile）"
    } catch { }
    Write-Host '  复制/打开可运行：powershell -ExecutionPolicy Bypass -File scripts\open-url.ps1'
} else {
    Write-Host "尚未记录登录链接：$RuntimeDir\web-url.txt 不存在（运行 start-dsh-web.ps1 后生成）"
}
$authFile = Join-Path $RuntimeDir 'basic-auth.txt'
if (Test-Path -LiteralPath $authFile) {
    Write-Host ''
    Write-Host '站点 Basic Auth 账号密码（runtime\basic-auth.txt）：'
    Write-Host ("  {0}" -f ((Get-Content -LiteralPath $authFile -Raw).Trim()))
}
Write-Host ('  Caddy 站点入口：{0}' -f $PublicUrl)
Write-Host '=================================================='
Write-Host ''
