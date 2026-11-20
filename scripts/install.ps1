# 安装：注册「登录自启」（当前用户启动文件夹 + HKCU Run），并立即启动看护进程。
# 说明：本机不是管理员环境时无法写「任务计划程序」，所以用当前用户级自启；
#       看护进程负责「桌面 Web 端口探测 + 本机中继 + SSH 反向隧道」的断线重连。
# 用法：powershell -ExecutionPolicy Bypass -File scripts\install.ps1
[CmdletBinding()]
param()

. "$PSScriptRoot\common.ps1"

$watchdog = Join-Path $PSScriptRoot 'watchdog.ps1'
$template = Join-Path $RepoRoot 'deploy\startup.vbs.template'
if (-not (Test-Path -LiteralPath $template)) { throw "缺少启动器模板：$template" }

# 0) 准备中继密钥（Caddy 端配置的 X-Dsh-Relay-Key 必须与它一致）
$key = Get-RelayKey
Write-DshLog "中继密钥已就绪（runtime\relay-key.txt）；跳板机 Caddy 需配置相同的 X-Dsh-Relay-Key" 'relay.log'

# 1) 生成 VBS 启动器到当前用户「启动」文件夹
$vbs = (Get-Content -LiteralPath $template -Raw -Encoding UTF8).Replace('__WATCHDOG_PATH__', $watchdog)
$startupDir = [Environment]::GetFolderPath('Startup')
$vbsPath = Join-Path $startupDir 'DSH-Web-Remote.vbs'
Set-Content -LiteralPath $vbsPath -Value $vbs -Encoding ASCII
Write-DshLog "已写入登录自启：$vbsPath" 'relay.log'

# 2) 额外写 HKCU Run（双保险；watchdog 自身有单实例保护，不会重复运行）
$runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
try {
    New-Item -Path $runKey -Force | Out-Null
    Set-ItemProperty -Path $runKey -Name 'DSH-Web-Remote' -Value ('wscript.exe "{0}"' -f $vbsPath)
    Write-DshLog "已写入 HKCU Run 自启项 DSH-Web-Remote" 'relay.log'
} catch {
    Write-DshLog "写入 HKCU Run 失败（不影响启动文件夹自启）：$($_.Exception.Message)" 'relay.log'
}

# 3) 立即启动看护（经 explorer 启动，进程不挂在当前终端下，终端退出不受影响）
Start-Process -FilePath 'explorer.exe' -ArgumentList ('"{0}"' -f $vbsPath)
Write-DshLog "已通过 explorer 启动看护，等待服务就绪…" 'relay.log'

Start-Sleep -Seconds 15
& (Join-Path $PSScriptRoot 'status.ps1')
