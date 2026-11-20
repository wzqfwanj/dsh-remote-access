# ============================================================
#  DSH 远程访问 · 本机配置（示例）
#  用法：复制本文件为 config.local.ps1，按实际环境修改。
#        config.local.ps1 含主机名/域名等部署信息，已在 .gitignore 中排除。
#
#  架构：浏览器 → 跳板机 Caddy(HTTPS+BasicAuth) → SSH 反向隧道
#        → 本机 127.0.0.1:$LocalPort（relay.py 中继）
#        → DSH 桌面进程自己的 Web GUI 端口（自动探测）
# ============================================================

# 本机中继监听端口（只绑 127.0.0.1，不直接暴露到局域网/公网）
$LocalPort = 3080

# 跳板机 SSH Host：~/.ssh/config 中的别名（推荐用密钥登录）
$SshHost = "aliyun"

# 跳板机上的隧道监听端口；Caddy 反代目标为 127.0.0.1:$RemotePort
$RemotePort = 3080

# 对外访问根地址（Caddy 站点地址，必须与跳板机上的配置一致）
$PublicUrl = "https://dsh.example.com/"

# Python 解释器（中继脚本用；PATH 里有 python 时可保持默认）
$PythonExe = "python"
