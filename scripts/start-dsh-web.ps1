# 启动本机 dsh web（只绑定 127.0.0.1），并把带 token 的登录链接保存到 runtime/web-url.txt
# 用法：powershell -ExecutionPolicy Bypass -File scripts\start-dsh-web.ps1
[CmdletBinding()]
param()

. "$PSScriptRoot\common.ps1"

if (Test-PortListening -Port $LocalPort) {
    Write-DshLog "dsh web 已在 127.0.0.1:$LocalPort 监听，跳过启动" 'dsh-web.log'
    return
}

# 端口没监听但存在残留的 dsh web 进程（崩溃/半启动）：先清掉，避免多实例
$stale = Get-CimInstance Win32_Process -Filter "Name='DeepSeek Harness.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -and $_.CommandLine.Contains('dsh\lib\bin.js') -and $_.CommandLine.Contains(' web ') }
foreach ($p in @($stale)) {
    Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
}

$outLog = Join-Path $LogDir 'dsh-web.out.log'
$errLog = Join-Path $LogDir 'dsh-web.err.log'
foreach ($f in @($outLog, $errLog)) {
    if ((Test-Path -LiteralPath $f) -and ((Get-Item -LiteralPath $f).Length -gt 2MB)) {
        Move-Item -LiteralPath $f -Destination "$f.old" -Force -ErrorAction SilentlyContinue
    }
}

# dsh CLI 需要以 Electron 的 Node 模式运行；DSH_HOME 指向桌面版同一数据目录
$env:ELECTRON_RUN_AS_NODE = '1'
$env:DSH_HOME = $DshHome

$arguments = @(
    ('"' + $DshBin + '"'),
    'web',
    '--port', "$LocalPort",
    '--host', '127.0.0.1',
    '--no-open',
    '--public-url', $PublicUrl,
    '--trusted-host', $TrustedHost
)

Write-DshLog "启动 dsh web：127.0.0.1:$LocalPort → $PublicUrl" 'dsh-web.log'
Start-Process -FilePath $DshExe -ArgumentList $arguments `
    -RedirectStandardOutput $outLog -RedirectStandardError $errLog -WindowStyle Hidden | Out-Null

# 等待端口监听
$ok = $false
for ($i = 1; $i -le 90; $i++) {
    Start-Sleep -Seconds 1
    if (Test-PortListening -Port $LocalPort) { $ok = $true; break }
}
if (-not $ok) {
    Write-DshLog "dsh web 启动失败：90 秒内 127.0.0.1:$LocalPort 未监听，详见 $errLog" 'dsh-web.log'
    return
}

# 从启动日志里抓取 `dsh web: https://...?token=...`（token 每个进程不同；cookie 秘钥跨重启保留）
$url = $null
for ($i = 1; $i -le 40; $i++) {
    $m = Select-String -Path $outLog -Pattern '^dsh web: (\S+)$' -ErrorAction SilentlyContinue | Select-Object -Last 1
    if ($m) { $url = $m.Matches[0].Groups[1].Value.Trim(); break }
    Start-Sleep -Milliseconds 500
}

if ($url) {
    $saved = Save-DshWebUrl -Url $url
    Write-DshLog "dsh web 就绪；带 token 的登录链接已保存：$saved" 'dsh-web.log'
} else {
    Write-DshLog "dsh web 已监听，但未捕获到 token 链接（已有浏览器 cookie 时仍可访问）；详见 $outLog" 'dsh-web.log'
}
