# 共用函数：加载配置、日志、端口/隧道检测。
# 所有脚本通过 ` . "$PSScriptRoot\common.ps1" ` 引入（点源，变量与函数落在调用方作用域）。

$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Path $PSScriptRoot -Parent
$ConfigPath = Join-Path $RepoRoot 'config.local.ps1'
if (-not (Test-Path -LiteralPath $ConfigPath)) {
    throw "缺少 config.local.ps1。请先复制 config.example.ps1 为 config.local.ps1 并按实际环境填写。"
}
. $ConfigPath

$LogDir = Join-Path $RepoRoot 'logs'
$RuntimeDir = Join-Path $RepoRoot 'runtime'
New-Item -ItemType Directory -Force -Path $LogDir, $RuntimeDir | Out-Null

$RelayScript = Join-Path $RepoRoot 'relay\relay.py'
$RelayKeyFile = Join-Path $RuntimeDir 'relay-key.txt'
$DesktopPortFile = Join-Path $RuntimeDir 'desktop-web-port.txt'

function Write-DshLog {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [string]$File = 'watchdog.log'
    )
    $line = "{0} {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Add-Content -LiteralPath (Join-Path $LogDir $File) -Value $line -Encoding UTF8
    Write-Host $line
}

function Test-PortListening {
    param([Parameter(Mandatory = $true)][int]$Port)
    $conn = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
    return [bool]$conn
}

function Get-PythonExe {
    # 返回可用的 Python 解释器（配置里的 $PythonExe 优先，其次 PATH 上的 python）
    if ($PythonExe) {
        $cmd = Get-Command $PythonExe -ErrorAction SilentlyContinue
        if ($cmd) { return $cmd.Source }
    }
    $fallback = Get-Command python -ErrorAction SilentlyContinue
    if ($fallback) { return $fallback.Source }
    throw "找不到 Python。请安装 Python 3.9+ 并加入 PATH，或在 config.local.ps1 里设置 `$PythonExe。"
}

function Get-RelayKey {
    # 读取中继密钥（与跳板机 Caddy 的 X-Dsh-Relay-Key 一致）；缺失时生成
    if (Test-Path -LiteralPath $RelayKeyFile) {
        $value = (Get-Content -LiteralPath $RelayKeyFile -Raw -ErrorAction SilentlyContinue).Trim()
        if ($value) { return $value }
    }
    $chars = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789'.ToCharArray()
    $value = -join (1..40 | ForEach-Object { $chars[(Get-Random -Maximum $chars.Length)] })
    Set-Content -LiteralPath $RelayKeyFile -Value $value -NoNewline -Encoding ASCII
    return $value
}

function Get-RelayProcesses {
    # 本项目中继的 Python 进程（按 relay.py 命令行匹配，避免误杀其他 Python）
    $relayName = Split-Path -Path $RelayScript -Leaf
    Get-CimInstance Win32_Process -Filter "Name='python.exe' OR Name='python3.exe' OR Name='py.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -and $_.CommandLine.Contains($relayName) }
}

function Get-DesktopWebPort {
    # 读取 DSH 桌面进程 Web GUI 端口（由 get-dsh-web-port.ps1 探测写入）
    if (-not (Test-Path -LiteralPath $DesktopPortFile)) { return $null }
    $text = (Get-Content -LiteralPath $DesktopPortFile -Raw -ErrorAction SilentlyContinue).Trim()
    if ($text -match '^\d+$') { return [int]$text }
    return $null
}

function Get-TunnelProcesses {
    # 找到本项目的 SSH 反向隧道进程（按 -R 转发参数匹配，避免误杀其他 ssh）
    $needleNoSpace = "127.0.0.1:$RemotePort`:127.0.0.1:$LocalPort"
    Get-CimInstance Win32_Process -Filter "Name='ssh.exe'" -ErrorAction SilentlyContinue |
        Where-Object {
            $_.CommandLine -and
            $_.CommandLine.Contains($needleNoSpace) -and
            $_.CommandLine.Contains($SshHost)
        }
}

function Test-RemoteTunnelPort {
    # 在跳板机上确认反向隧道端口正在监听（成功返回 $true）
    try {
        $out = & ssh -o BatchMode=yes -o ConnectTimeout=10 -o LogLevel=ERROR $SshHost "ss -lnt 2>/dev/null" 2>$null
        if ($LASTEXITCODE -ne 0) { return $false }
        $joined = $out -join "`n"
        return ($joined.Contains("127.0.0.1:$RemotePort ") -or $joined.Contains("*:$RemotePort "))
    } catch {
        return $false
    }
}

function Stop-TunnelProcesses {
    $procs = @(Get-TunnelProcesses)
    foreach ($p in $procs) {
        Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
    }
    return $procs.Count
}

function Stop-RelayProcesses {
    $procs = @(Get-RelayProcesses)
    foreach ($p in $procs) {
        Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
    }
    return $procs.Count
}
