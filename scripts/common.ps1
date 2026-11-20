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

# 由桌面版 exe 推导 dsh CLI 入口（app.asar 内的 bin.js，用 Electron 以 Node 模式运行）
# 注意：bin.js 在 app.asar 归档内，PowerShell 的 Test-Path 看不到归档内部，只能校验 exe 本身。
$DshBin = Join-Path (Split-Path -Path $DshExe -Parent) 'resources\app.asar\dsh\node_modules\@deepseek-ai\dsh\lib\bin.js'
if (-not (Test-Path -LiteralPath $DshExe)) {
    throw "找不到 DeepSeek Harness 可执行文件：$DshExe（请检查 config.local.ps1 中的 `$DshExe）"
}

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

function Get-TunnelProcesses {
    # 找到本项目的 SSH 反向隧道进程（按 -R 转发参数匹配，避免误杀其他 ssh）
    $needle = "-R 127.0.0.1:$RemotePort`:127.0.0.1:$LocalPort"
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
        $patterns = @("127.0.0.1:$RemotePort ", "*:$RemotePort ")
        foreach ($p in $patterns) { if (($out -join "`n").Contains($p)) { return $true } }
        return $false
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

function Get-DshWebUrl {
    # 读取最近一次 dsh web 启动时打印的带 token 链接（运行时文件，不入库）
    $path = Join-Path $RuntimeDir 'web-url.txt'
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    $line = (Get-Content -LiteralPath $path -ErrorAction SilentlyContinue | Where-Object { $_ } | Select-Object -Last 1)
    if (-not $line) { return $null }
    return $line.Trim()
}

function Save-DshWebUrl {
    param([Parameter(Mandatory = $true)][string]$Url)
    $path = Join-Path $RuntimeDir 'web-url.txt'
    Set-Content -LiteralPath $path -Value $Url -Encoding UTF8
    return $path
}
