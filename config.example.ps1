# ============================================================
#  DSH 远程访问 · 本机配置（示例）
#  用法：复制本文件为 config.local.ps1，按实际环境修改。
#        config.local.ps1 含主机名/域名等部署信息，已在 .gitignore 中排除。
# ============================================================

# DSH 桌面版可执行文件（Windows 默认安装位置）
$DshExe = "$env:LOCALAPPDATA\Programs\DeepSeek Harness\DeepSeek Harness.exe"

# DSH 数据目录（桌面版默认 ~/.dsh，内含凭证、会话、skills）
$DshHome = "$env:USERPROFILE\.dsh"

# 本机 dsh web 监听端口（脚本只绑定 127.0.0.1，不直接暴露到局域网/公网）
$LocalPort = 3080

# 跳板机 SSH Host：~/.ssh/config 中的别名（推荐用密钥登录）
$SshHost = "aliyun"

# 跳板机上的隧道监听端口；Caddy 反代目标为 127.0.0.1:$RemotePort
$RemotePort = 3080

# 对外访问根地址（Caddy 站点地址，必须与跳板机上的配置一致）
$PublicUrl = "https://dsh.example.com/"

# 对外域名（DSH /api 的 Host 白名单；必须与 $PublicUrl 的 host 一致）
$TrustedHost = "dsh.example.com"
