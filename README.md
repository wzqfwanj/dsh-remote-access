# DSH 远程访问（dsh-remote-access）

把**桌面电脑上正在运行的 DeepSeek Harness（DSH）**安全地暴露到公网，用手机 / 任意电脑的浏览器远程控制**同一个实例**：看到的会话、运行状态、工作区与桌面 App 完全一致（不是另起一个进程）。

- 复用 DSH 官方 Web GUI，不重造轮子
- 只走 **SSH 反向隧道**：桌面机不开放任何公网端口、不需要公网 IP
- 两层保护：Caddy Basic Auth（站点账号密码）+ 中继密钥（只允许跳板机访问本机中继）
- 断线自愈 + 登录自启：网络抖动、进程崩溃、桌面 App 重启后自动恢复
- 桌面 App 每次重启可能换 Web 端口，脚本会自动重新探测

## 架构

```
 手机 / 笔记本浏览器
        │  https://dsh.example.com/   （只需要站点账号密码）
        ▼
 ┌──────────────────────────────┐
 │ 跳板机（有公网 IP 的 Linux）   │
 │  Caddy：TLS + Basic Auth      │
 │  反代 127.0.0.1:3080          │
 │  并注入 X-Dsh-Relay-Key       │
 └──────────────┬───────────────┘
                │ SSH 反向隧道（桌面机主动连出，无需公网入站端口）
                ▼
 ┌─────────────────────────────────────────────┐
 │ 桌面 Windows                                 │
 │  relay.py 监听 127.0.0.1:3080                │
 │    ├─ 校验 X-Dsh-Relay-Key（防本机程序滥用）  │
 │    ├─ 改写 Host / Origin / Referer            │
 │    └─ 注入 DSH 浏览器会话 Cookie              │
 │         ↓                                    │
 │  桌面 DSH 进程自己的 Web GUI（127.0.0.1:52898，│
 │  端口自动探测）—— 与桌面窗口是同一个实例       │
 └─────────────────────────────────────────────┘
```

### 为什么能控制「同一个实例」

DSH 桌面版进程本身就在 localhost 上开了一个 Web GUI（带临时 token 的 HTTP 服务）。直接用浏览器访问它需要先拿到 token 换 Cookie，而且它只信任本机 Host。

`relay.py` 做了三件事：
1. 校验 `X-Dsh-Relay-Key`（由跳板机 Caddy 注入），保证只有跳板机转发的请求能进来；
2. 把 `Host` / `Origin` / `Referer` 改写为桌面本机权威，通过 DSH 的 loopback 信任检查；
3. 用 `~/.dsh/.credentials.yaml` 里持久保存的 `client-connection/browser-session` 签名密钥，**代签一个浏览器会话 Cookie**（等价于浏览器打开 token 链接后拿到的 Cookie）。

因为连的是桌面进程本身，所以远程页面里的「运行中 / 已停止」、流式输出、任务进度都是实时的。

## 环境要求

| 项目 | 要求 |
| --- | --- |
| 桌面机 | Windows 10/11，DSH 桌面版**正在运行**并已登录 |
| Python | Python 3.9+（中继脚本只用标准库） |
| 跳板机 | 有公网 IP 的 Linux（示例用阿里云 ECS），已装 [Caddy](https://caddyserver.com/)；`~/.ssh/config` 里可用密钥免密 `ssh` |
| DNS | 一个（子）域名的 A 记录指向跳板机公网 IP（Caddy 申请 Let's Encrypt 证书前必须生效） |

## 目录结构

```
relay/relay.py           本地中继（HTTP + WebSocket，只绑 127.0.0.1）
scripts/
  common.ps1             共用函数与配置加载
  get-dsh-web-port.ps1   探测桌面 DSH 进程的 Web GUI 端口
  start-relay.ps1        启动 / 修复本地中继
  start-tunnel.ps1       建立 / 修复 SSH 反向隧道
  watchdog.ps1           看护进程：端口探测 + 中继 + 隧道自动恢复（核心常驻进程）
  install.ps1            安装登录自启并立即启动
  uninstall.ps1          卸载自启并停止所有进程
  status.ps1             查看当前状态与访问入口
deploy/
  Caddyfile.dsh.snippet  跳板机 Caddy 反代配置模板
  startup.vbs.template   登录自启启动器模板（由 install.ps1 生成）
config.example.ps1       配置模板（复制为 config.local.ps1 使用）
logs/                    运行日志（不入库）
runtime/                 中继密钥、桌面端口等运行时文件（不入库）
```

## 快速开始

### 1. 桌面机：准备配置并安装

```powershell
cd <仓库目录>
Copy-Item config.example.ps1 config.local.ps1
notepad config.local.ps1     # 改 $SshHost / $PublicUrl 等

# 安装：写登录自启（启动文件夹 + HKCU Run），立即启动看护进程
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\install.ps1
```

`install.ps1` 会在 `runtime\relay-key.txt` 生成一个中继密钥，**下一步配置 Caddy 时要用同一个值**。

### 2. 跳板机：配置 Caddy 反代

```bash
# 生成 Basic Auth 密码哈希（换成你自己的密码）
caddy hash-password --plaintext '你的强密码'

cp -a /etc/caddy/Caddyfile /etc/caddy/Caddyfile.bak-$(date +%Y%m%d-%H%M%S)
# 参考 deploy/Caddyfile.dsh.snippet 追加站点块，注意：
#   - dsh.example.com 换成你的域名
#   - __BASIC_AUTH_HASH__ 换成上一步的哈希
#   - __RELAY_KEY__ 换成桌面机 runtime\relay-key.txt 的内容

caddy validate --config /etc/caddy/Caddyfile && systemctl reload caddy
```

### 3. 使用

浏览器打开 `https://dsh.example.com/`，输入 Basic Auth 账号密码即可。
**没有额外的 token 链接要抄**——中继已经用持久密钥代签了 Cookie。

## 日常运维

```powershell
# 查看状态（桌面端口 / 中继 / 隧道 / 自启 / 访问入口）
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\status.ps1

# 手动修复（等价于 watchdog 的一次检查）
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\start-relay.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\start-tunnel.ps1

# 卸载（移除自启、停止所有进程；跳板机 Caddy 配置保留）
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\uninstall.ps1
```

日志（`logs/`）：

| 文件 | 内容 |
| --- | --- |
| `watchdog.log` | 看护进程动作 |
| `relay.log` | 中继启动 / 端口探测 / 重建 |
| `relay.out.log` / `relay.err.log` | 中继进程原始输出与异常 |
| `tunnel.log` / `tunnel.err.log` | SSH 反向隧道 |

## 故障排查

| 现象 | 原因与处理 |
| --- | --- |
| 浏览器 401（Basic Auth 弹窗反复） | 账号密码不对：重新 `caddy hash-password` 后更新 Caddyfile 并 reload |
| 浏览器 502 | 链路断了：`status.ps1` 看「中继 / 隧道 / 桌面 Web」哪一项异常；桌面 App 未运行时中继会拒绝启动 |
| 中继返回 403 `relay key mismatch` | 跳板机 Caddy 的 `X-Dsh-Relay-Key` 与桌面机 `runtime\relay-key.txt` 不一致；改成一致后 `systemctl reload caddy` |
| 页面能开但一直空白 / 接口报错 | 桌面 App 刚重启换了端口：等 watchdog 下一轮（≤20 秒）自动重新探测；或用 `get-dsh-web-port.ps1` 手动确认 |
| 远程看到的会话状态和本地不一致 | 理论上不会：远程连的是同一个桌面进程。若出现，先看 `relay.log` 是哪个桌面端口、`status.ps1` 是否正常 |
| 电脑休眠/关机 | 远程不可用（隧道在桌面机上）。需要常在线请关闭睡眠 |

## 安全建议（重要）

- 远程页面里的 DSH 以**当前用户权限**运行，且权限预设通常是 `danger-full-access`，即**远程等于远程桌面控制权**。请务必：
  - 使用强密码（Caddy Basic Auth），不要外泄链接和密码；
  - 担心误操作时，把 `%USERPROFILE%\.dsh\profiles\web\cordis.patch.yml` 的 `defaultPreset` 改为 `workspace-write` 或 `read-only`（注意这也会影响桌面 App 的 web 会话策略，按需设置）；
  - 不需要远程时运行 `uninstall.ps1`，或在跳板机停用/删除 dsh 站点配置。
- 中继密钥（`runtime\relay-key.txt`）与 Caddyfile 里的值必须一致；它保证本机其他程序不能绕过站点认证使用中继。
- 中继签发的 Cookie 来自 DSH 凭证库里的持久签名密钥（有效期按 DSH 配置，默认 30 天），不写入 Cookie 文件、不落盘明文密码。
- 本仓库不含任何真实密码、token、IP 或域名；`runtime/`、`logs/`、`config.local.ps1` 均被 `.gitignore` 排除。

## 已知限制

- 只支持单用户（就是你）；远程访问要求桌面 App 正在运行。
- 桌面 App 重启后 Web 端口可能变化：watchdog 会在 ≤20 秒内自动重新探测并恢复。
- 不重写 DSH 的界面与功能：看到的就是 DSH 官方 Web GUI。
- Windows 非管理员环境无法注册「任务计划程序」，因此登录自启用「启动文件夹 + HKCU Run」实现（对个人电脑足够）。

## License

MIT
