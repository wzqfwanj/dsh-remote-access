# 发现本机 DSH 桌面进程的 Web GUI 端口（每次启动可能变化），写入 runtime\desktop-web-port.txt。
# 用法：powershell -ExecutionPolicy Bypass -File scripts\get-dsh-web-port.ps1
[CmdletBinding()]
param()

. "$PSScriptRoot\common.ps1"

$hostProc = Get-CimInstance Win32_Process -Filter "Name='DeepSeek Harness.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -and $_.CommandLine -match 'dsh-desktop-host' } |
    Select-Object -First 1
if (-not $hostProc) {
    exit 1
}

$candidates = @(Get-NetTCPConnection -State Listen -OwningProcess $hostProc.ProcessId -ErrorAction SilentlyContinue |
    Where-Object { $_.LocalAddress -eq '127.0.0.1' -or $_.LocalAddress -eq '::1' } |
    Select-Object -ExpandProperty LocalPort -Unique)

foreach ($port in $candidates) {
    $body = (curl.exe -s -m 3 -H "Host: 127.0.0.1:$port" "http://127.0.0.1:$port/" 2>$null) -join "`n"
    if ($body -match 'dsh web authentication required') {
        $old = Get-DesktopWebPort
        Set-Content -LiteralPath $DesktopPortFile -Value "$port" -Encoding ASCII
        if ($old -ne $port) {
            Write-DshLog "DSH 桌面 Web GUI 端口：$port（进程 $($hostProc.ProcessId)）" 'relay.log'
        }
        Write-Output $port
        exit 0
    }
}

exit 1
