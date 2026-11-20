# 打开（或复制）当前带 token 的远程访问链接，避免手抄长链接出错
# 用法：powershell -ExecutionPolicy Bypass -File scripts\open-url.ps1
#       powershell -ExecutionPolicy Bypass -File scripts\open-url.ps1 -NoOpen   # 只复制到剪贴板
[CmdletBinding()]
param(
    [switch]$NoOpen
)

. "$PSScriptRoot\common.ps1"

$url = Get-DshWebUrl
if (-not $url) {
    Write-Host "尚未记录登录链接（runtime\web-url.txt 不存在）。先运行 start-dsh-web.ps1。" -ForegroundColor Yellow
    exit 1
}

# 打开前确认链接没有混入空白/反斜杠等杂字符
$url = $url.Trim()
if ($url -match '[\s\\]') {
    Write-Host "链接里含空白或反斜杠，可能复制出错：$url" -ForegroundColor Yellow
}

$copied = $false
try {
    Set-Clipboard -Value $url
    $copied = $true
} catch {
    Write-Host "复制到剪贴板失败（可手动复制）：$($_.Exception.Message)" -ForegroundColor Yellow
}

Write-Host ''
Write-Host '带 token 的登录链接：'
Write-Host "  $url"
if ($copied) { Write-Host '（已复制到剪贴板）' }
Write-Host ''
Write-Host '提示：站点 Basic Auth 账号密码见 runtime\basic-auth.txt。'
Write-Host ''

if (-not $NoOpen) {
    Start-Process $url
    Write-Host '已尝试用默认浏览器打开。'
}
