# DSH 远程访问（dsh-remote-access）

把**桌面电脑上运行的 DeepSeek Harness（DSH）**安全地暴露到公网，让你用手机/任意电脑的浏览器就能远程控制它。

- 复用 DSH 官方 Web GUI：不重造轮子，浏览器里就是完整的 DSH 界面（会话、工作区、工具、终端）
- 只走 **SSH 反向隧道**：桌面机不开放任何公网端口，不依赖内网穿透服务
- **两层认证**：Caddy Basic Auth（站点账号密码）+ DSH 启动 token（HttpOnly Cookie，默认 30 天）
- 断线自愈 + 登录自启：网络抖动/进程崩溃后由 watchdog 自动恢复

## 架构

```
 手机 / 笔记本浏览器
        │  https://dsh.example.com/
        ▼
 ┌──────────────────────────────┐
 │ 跳板机（有公网 IP 的 Linux）   │
 │  Caddy：TLS + Basic Auth      │
 │  反代 127.0.0.1:3080          │
 └──────────────┬───────────────┘
                │ SSH 反向隧道（由桌面机主动发起，无需公网入站端口）
                ▼
 ┌──────────────────────────────┐
 │ 桌面 Windows                  │
 │  127.0.0.1:3080  dsh web      │
 │      └─ 同一个 ~/.dsh：凭证、   │
 │         会话、skills 全部共享   │
 └──────────────────────────────┘
```

关键点：

- 隧道方向是「桌面 → 跳板机」，所以桌面机**不需要**公网 IP、不需要开端口、不需要改路由器。
- `dsh web` 只绑定 `127.0.0.1`；外网只能通过跳板机的 Caddy 进入，且必须先过 Basic Auth。
- `dsh web` 是**独立于桌面 App 的第二个 DSH 实例**，与桌面 App 共用 `~/.dsh`（同一套账号凭证、会话记录、工作区、skills）；两个实例可以同时运行。
- 首次登录必须打开 `dsh web` 启动时打印的**带 `?token=` 的链接**（脚本会保存到 `runtime/web-url.txt`），之后浏览器靠 Cookie 保持登录（默认 30 天；Cookie 秘钥持久化，dsh web 重启不会掉登录）。

## 环境要求

| 项目 | 要求 |
| --- | --- |
| 桌面机 | Windows 10/11，已安装 DSH 桌面版并登录 |
| 跳板机 | 一台有公网 IP 的 Linux（示例用阿里云 ECS），已装 [Caddy](https://caddyserver.com/)；`~/.ssh/config` 里能用密钥免密 `ssh` 登录 |
| DNS | 一个（子）域名的 A 记录指向跳板机公网 IP（Caddy 申请证书前必须生效） |
| PowerShell | Windows PowerShell 5.1+（系统自带即可） |

## 目录结构

```
scripts/            PowerShell 脚本（服务/隧道/看护/安装/状态）
  common.ps1         共用函数与配置加载
  start-dsh-web.ps1  启动本机 dsh web（127.0.0.1），保存 token 链接
  start-tunnel.ps1   建立 SSH 反向隧道
  watchdog.ps1       看护进程：断线重连（核心常驻进程）
  install.ps1        安装登录自启并立即启动
  uninstall.ps1      卸载自启并停止所有进程
  status.ps1         查看当前状态、登录链接、凭据（并生成可双击的 login.url）
  open-url.ps1       把当前 token 链接复制到剪贴板并用默认浏览器打开（避免手抄出错）
deploy/
  Caddyfile.dsh.snippet  跳板机 Caddy 反代配置模板
  startup.vbs.template   登录自启启动器模板（由 install.ps1 生成）
config.example.ps1   配置模板（复制为 config.local.ps1 使用）
logs/                运行日志（不入库）
runtime/             token 链接、Basic Auth 凭据等运行时文件（不入库）
```

## 快速开始

### 1. 桌面机：准备配置并安装

```powershell
# 1) 把本仓库放到桌面机（路径任意，脚本按自身位置推导）
cd <仓库目录>
Copy-Item config.example.ps1 config.local.ps1

# 2) 按实际情况修改 config.local.ps1：
#    $SshHost      跳板机的 SSH Host（~/.ssh/config 里的别名）
#    $PublicUrl    对外访问根地址，如 https://dsh.example.com/
#    $TrustedHost  对外域名，如 dsh.example.com
notepad config.local.ps1

# 3) 安装：写登录自启（启动文件夹 + HKCU Run），并立即启动看护进程
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\install.ps1
```

安装完成后 `status.ps1` 会打印状态与**带 token 的登录链接**，链接同时保存在 `runtime/web-url.txt`。

### 2. 跳板机：配置 Caddy 反代

```bash
# 生成 Basic Auth 密码哈希（替换成你自己的密码）
caddy hash-password --plaintext '你的强密码'

# 备份并编辑 Caddyfile（把 dsh.example.com 换成你的域名、哈希替换到 dsh 用户名后）
cp -a /etc/caddy/Caddyfile /etc/caddy/Caddyfile.bak-$(date +%Y%m%d-%H%M%S)
# 参考 deploy/Caddyfile.dsh.snippet 追加两个站点块

# 校验并热加载（不要 restart）
caddy validate --config /etc/caddy/Caddyfile && systemctl reload caddy
```

> 反向代理必须保留原始 `Host`（Caddy 默认行为）；`dsh web` 启动时带了
> `--public-url` 与 `--trusted-host`，否则 `/api` 的 Host 白名单会拒绝反代域名
> （表现为页面能打开、但功能全部 403）。脚本已处理这两项。

### 3. 使用

1. 浏览器打开 `runtime/web-url.txt` 里的链接（形如 `https://dsh.example.com/?token=...`）。
   也可以运行 `scripts\open-url.ps1`：它会自动把**完整链接**复制到剪贴板并用默认浏览器打开，避免手抄时多带 `\`、空格等字符导致 401。
2. 输入跳板机 Caddy 配置的 Basic Auth 账号密码。
3. 进入 DSH Web GUI，即可远程使用；之后 30 天内再访问 `https://dsh.example.com/` 无需再带 token。

## 日常运维

```powershell
# 查看状态（服务/隧道/自启/登录链接/凭据）
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\status.ps1

# 手动修复（等价于 watchdog 做的一次检查）
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\start-dsh-web.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\start-tunnel.ps1

# 卸载（移除自启、停止所有进程；跳板机 Caddy 配置保留）
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\uninstall.ps1
```

日志（`logs/`）：

| 文件 | 内容 |
| --- | --- |
| `watchdog.log` | 看护动作（启动/重连） |
| `dsh-web.log` | dsh web 启动记录 |
| `dsh-web.out.log` / `dsh-web.err.log` | dsh web 原始输出 |
| `tunnel.log` | 隧道建立/重连记录 |
| `tunnel.err.log` | ssh 错误输出 |

## 故障排查

| 现象 | 原因与处理 |
| --- | --- |
| 浏览器 401（Basic Auth 弹窗反复） | 用户名/密码不对：重新 `caddy hash-password` 后更新 Caddyfile 并 reload |
| 浏览器 502 | 隧道没建立：`ssh` 到跳板机执行 `ss -lnt \| grep 3080` 应为 `127.0.0.1:3080`；桌面运行 `start-tunnel.ps1`，看 `logs/tunnel.err.log` |
| 页面 401 且提示 `dsh web authentication required` | 1）链接被多抄了字符：注意结尾不要带 `\`、空格或换行，`token` 只有 43 个字符；2）没带 token 且无有效 Cookie：重新打开 `runtime/web-url.txt` 的链接（每个 dsh web 进程的 token 不同，脚本会自动更新该文件）；3）最省事：运行 `scripts\open-url.ps1`（自动复制并打开） |
| 页面能开但操作全部 403 / 报 Host 不匹配 | `dsh web` 启动时缺 `--trusted-host`：确认 `config.local.ps1` 的 `$TrustedHost` 与域名一致，重启服务 |
| 链路恢复后仍打不开 | 等 watchdog 下一轮（约 20 秒）；或手动跑 `watchdog` 做的那两个脚本 |
| 电脑休眠/关机 | 远程不可用（隧道在桌面机上）。需要远程常在线时请关闭睡眠，或使用带 UPS 的常开机器 |

## 安全建议（重要）

- 远程 Web GUI 里的 DSH 以**当前用户权限**运行，且 Web profile 的默认权限预设通常是 `danger-full-access`，即**远程等于远程桌面控制权**。请务必：
  - 使用强密码（Caddy Basic Auth），不要把带 token 的链接发到公开渠道；
  - 担心误操作时，把 `%USERPROFILE%\.dsh\profiles\web\cordis.patch.yml` 里的
    `defaultPreset` 改为 `workspace-write` 或 `read-only`；
  - 不需要远程时运行 `uninstall.ps1`，或在跳板机停用/删除 dsh 站点配置。
- Basic Auth 密码哈希只存在于跳板机 Caddyfile；本仓库不含任何真实密码、token、IP 或域名。
- `runtime/`、`logs/`、`config.local.ps1` 均被 `.gitignore` 排除。

## 已知限制

- 只支持单用户（就是你）；不适合多租户。
- 桌面机关机/休眠/断网时无法访问，恢复后 watchdog 会自动重建链路。
- 首次登录依赖 token 链接；token 每次 `dsh web` 进程重启都会变化（脚本自动落盘，浏览器 Cookie 不受影响）。
- 不提供「在网页上给 DSH 换模型/改配置」之外的 DSH 原生功能之外的东西——就是 DSH 官方 Web UI。

## License

MIT
