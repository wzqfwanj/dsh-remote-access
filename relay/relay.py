#!/usr/bin/env python3
"""DSH 桌面 Web GUI 本地中继（配合 SSH 反向隧道做公网远程访问）。

架构：
    浏览器 → Caddy(HTTPS + Basic Auth) → 跳板机 127.0.0.1:3080
      → SSH 反向隧道 → 本机 127.0.0.1:3080（本脚本）
      → 本机 DSH 桌面进程自己的 Web GUI 127.0.0.1:<desktop-port>

只监听 127.0.0.1，并做三件事：
  1. 校验 Caddy 注入的 X-Dsh-Relay-Key，防止本机任意程序绕过站点认证使用中继；
  2. 把 Host / Origin / Referer 改写成桌面本机权威，通过 DSH 的 loopback 信任检查；
  3. 注入一个浏览器会话 Cookie（用 ~/.dsh/.credentials.yaml 里的持久签名密钥签发，
     等价于浏览器打开 dsh web 打印的 token 链接后拿到的 Cookie），从而访问到
     与桌面 App 完全相同的 DSH 实例（同一进程、实时运行状态）。

只用 Python 标准库；HTTP/WebSocket 均支持（WebSocket 走双向字节转发）。
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import hmac
import json
import os
import re
import select
import socket
import sys
import threading
import time
import traceback

HOP_BY_HOP = {
    "connection",
    "keep-alive",
    "proxy-connection",
    "transfer-encoding",
    "te",
    "trailer",
    "upgrade",
}

DAY_MS = 24 * 60 * 60 * 1000


def log(msg: str) -> None:
    line = time.strftime("%Y-%m-%d %H:%M:%S") + " " + msg
    print(line, flush=True)


def b64url(value: bytes) -> str:
    return base64.urlsafe_b64encode(value).rstrip(b"=").decode("ascii")


def unb64url(value: str) -> bytes:
    return base64.urlsafe_b64decode(value + "=" * (-len(value) % 4))


class CookieProvider:
    """按权威（Host:Port）签发 DSH 浏览器会话 Cookie；签名密钥来自 DSH 凭证库。"""

    # DSH 的 cookieMaxAgeDays 默认 30，这里留一天余量，避免边界被拒
    LIFETIME_DAYS = 29

    def __init__(self, credentials_path: str) -> None:
        self.credentials_path = credentials_path
        self._secret: bytes | None = None
        self._cache: dict[str, tuple[str, float]] = {}
        self._lock = threading.Lock()

    def _load_secret(self) -> bytes:
        if self._secret is not None:
            return self._secret
        with open(self.credentials_path, "r", encoding="utf-8") as fh:
            text = fh.read()
        match = re.search(
            r"client-connection/browser-session:\s*"
            r"\n\s*kind:\s*grant\s*"
            r"\n\s*payload:\s*"
            r"\n\s*version:\s*1\s*"
            r"\n\s*secret:\s*([A-Za-z0-9_\-]+)",
            text,
        )
        if not match:
            raise RuntimeError(
                "凭证库里没有 client-connection/browser-session 记录，"
                "请先启动一次 DSH 桌面版（它会初始化 Web 会话签名密钥）"
            )
        secret = unb64url(match.group(1))
        if len(secret) != 32:
            raise RuntimeError("browser-session 密钥长度异常")
        self._secret = secret
        return secret

    def cookie_for(self, authority: str) -> str:
        now = time.time()
        with self._lock:
            cached = self._cache.get(authority)
            if cached is not None and now < cached[1]:
                return cached[0]
            secret = self._load_secret()
            issued_at = int(now * 1000) - 60_000
            expires_at = int(now * 1000) + (self.LIFETIME_DAYS * DAY_MS) - 3_600_000
            payload = json.dumps(
                {
                    "version": 1,
                    "authority": authority,
                    "issuedAt": issued_at,
                    "expiresAt": expires_at,
                },
                separators=(",", ":"),
                ensure_ascii=False,
            )
            body = b64url(payload.encode("utf-8"))
            signature = b64url(hmac.new(secret, body.encode("ascii"), hashlib.sha256).digest())
            name = "dsh-auth-" + b64url(hashlib.sha256(authority.encode("utf-8")).digest())
            cookie = f"{name}=v1.{body}.{signature}"
            # 提前一天刷新
            refresh_at = now + (self.LIFETIME_DAYS - 1) * 86400
            self._cache[authority] = (cookie, refresh_at)
            return cookie


def read_until_headers(conn: socket.socket, limit: int = 256 * 1024) -> bytes | None:
    buffer = b""
    while b"\r\n\r\n" not in buffer:
        chunk = conn.recv(65536)
        if not chunk:
            return None
        buffer += chunk
        if len(buffer) > limit:
            return None
    return buffer


def read_port_file(path: str) -> int:
    with open(path, "r", encoding="utf-8") as fh:
        text = fh.read().strip()
    match = re.search(r"\d+", text)
    if not match:
        raise RuntimeError(f"端口文件内容无效：{text!r}")
    return int(match.group(0))


def read_key_file(path: str) -> str:
    with open(path, "r", encoding="utf-8") as fh:
        return fh.read().strip()


class Relay:
    def __init__(self, listen_port: int, port_file: str, key_file: str, cookie_provider: CookieProvider, target_host: str = "127.0.0.1") -> None:
        self.listen_port = listen_port
        self.port_file = port_file
        self.key_file = key_file
        self.cookies = cookie_provider
        self.target_host = target_host
        self._target_port = 0
        self._target_mtime = 0.0

    # ---------- 目标端口发现 ----------
    def target_port(self) -> int:
        try:
            mtime = os.path.getmtime(self.port_file)
        except OSError:
            mtime = 0.0
        if mtime != self._target_mtime:
            self._target_port = read_port_file(self.port_file)
            self._target_mtime = mtime
        if not self._target_port:
            self._target_port = read_port_file(self.port_file)
        return self._target_port

    # ---------- 请求改写 ----------
    def rewrite_head(self, head: bytes, key: str) -> bytes | None:
        """返回改写后的请求头；key 不匹配时返回 None。

        head 是「首部 + 可能已读到的 body 前缀」，必须以首个空行定位首部结束，
        不能假设空行刚好在 buffer 末尾（否则 POST 的 body 前缀会被混进首部）。
        """
        at = head.find(b"\r\n\r\n")
        if at < 0:
            return None
        text = head[:at].decode("latin-1")
        lines = text.split("\r\n")
        request_line = lines[0] if lines else ""

        provided = ""
        upgraded = False
        for line in lines[1:]:
            lowered = line.lower()
            if lowered.startswith("x-dsh-relay-key:"):
                provided = line.split(":", 1)[1].strip()
            if lowered.startswith("connection:") and "upgrade" in lowered:
                upgraded = True
        if not hmac.compare_digest(provided, key):
            return None

        try:
            target_port = self.target_port()
        except OSError:
            return None
        authority = f"{self.target_host}:{target_port}"
        cookie = self.cookies.cookie_for(authority)

        out = [request_line]
        for line in lines[1:]:
            if not line:
                continue
            lowered = line.lower()
            name = lowered.split(":", 1)[0]
            if name in ("host", "origin", "referer", "cookie", "x-dsh-relay-key", "connection"):
                if name == "connection" and "upgrade" in lowered:
                    out.append("Connection: Upgrade")
                continue
            out.append(line)
        out.append(f"Host: {authority}")
        out.append(f"Origin: http://{authority}")
        out.append(f"Referer: http://{authority}/")
        out.append(f"Cookie: {cookie}")
        # 非 WebSocket 用短连接，保证每个请求都经过本中继改写
        if not upgraded:
            out.append("Connection: close")
        return ("\r\n".join(out) + "\r\n\r\n").encode("latin-1")

    # ---------- 连接处理 ----------
    def handle(self, client: socket.socket, peer: tuple) -> None:
        upstream = None
        try:
            client.settimeout(30)
            head = read_until_headers(client)
            if head is None:
                return
            try:
                key = read_key_file(self.key_file)
            except OSError:
                log("中继密钥文件缺失，拒绝请求")
                send_simple(client, 503, "relay key file missing")
                return
            rewritten = self.rewrite_head(head, key)
            if rewritten is None:
                send_simple(client, 403, "relay key mismatch or unknown desktop port")
                return

            leftover = head[head.index(b"\r\n\r\n") + 4:]
            try:
                upstream = socket.create_connection((self.target_host, self.target_port()), timeout=10)
            except OSError as exc:
                log(f"连接桌面 DSH Web 失败：{exc}")
                send_simple(client, 502, "desktop DSH web unreachable")
                return

            upstream.settimeout(None)
            client.settimeout(None)
            for sock in (client, upstream):
                try:
                    sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
                except OSError:
                    pass
            upstream.sendall(rewritten)
            if leftover:
                upstream.sendall(leftover)
            pump(client, upstream)
        except Exception:  # noqa: BLE001 - 单连接失败不能影响服务
            log("连接处理异常：\n" + traceback.format_exc(limit=2))
        finally:
            for sock in (client, upstream):
                if sock is not None:
                    try:
                        sock.close()
                    except OSError:
                        pass

    def serve_forever(self) -> None:
        server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        server.bind(("127.0.0.1", self.listen_port))
        server.listen(128)
        log(f"DSH 桌面中继已启动：127.0.0.1:{self.listen_port} → 127.0.0.1:*（端口取自 {self.port_file}）")
        while True:
            try:
                client, peer = server.accept()
            except OSError:
                continue
            threading.Thread(target=self.handle, args=(client, peer), daemon=True).start()


def send_simple(conn: socket.socket, status: int, message: str) -> None:
    body = (message + "\n").encode("utf-8")
    reason = {403: "Forbidden", 502: "Bad Gateway", 503: "Service Unavailable"}.get(status, "Error")
    head = (
        f"HTTP/1.1 {status} {reason}\r\n"
        "content-type: text/plain; charset=utf-8\r\n"
        f"content-length: {len(body)}\r\n"
        "connection: close\r\n\r\n"
    ).encode("latin-1")
    try:
        conn.sendall(head + body)
    except OSError:
        pass


def pump(a: socket.socket, b: socket.socket) -> None:
    """双向字节转发，直到任一端关闭（HTTP 与 WebSocket 通用）。"""
    sockets = [a, b]
    try:
        while True:
            readable, _, errored = select.select(sockets, [], sockets, 600)
            if errored:
                return
            if not readable:
                return
            for sock in readable:
                data = sock.recv(65536)
                if not data:
                    return
                other = b if sock is a else a
                other.sendall(data)
    except OSError:
        return


def main() -> int:
    # 日志重定向到文件时也能写 UTF-8（Windows 默认是系统代码页）
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(encoding="utf-8", errors="replace")
        except (AttributeError, ValueError):
            pass
    parser = argparse.ArgumentParser(description="DSH 桌面 Web GUI 本地中继")
    parser.add_argument("--listen-port", type=int, default=3080)
    parser.add_argument("--port-file", default=os.path.join("runtime", "desktop-web-port.txt"))
    parser.add_argument("--key-file", default=os.path.join("runtime", "relay-key.txt"))
    parser.add_argument(
        "--credentials",
        default=os.path.join(os.path.expanduser("~"), ".dsh", ".credentials.yaml"),
    )
    args = parser.parse_args()
    provider = CookieProvider(args.credentials)
    provider._load_secret()  # 启动即校验，密钥缺失时直接失败（启动脚本会记录日志）
    Relay(args.listen_port, args.port_file, args.key_file, provider).serve_forever()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
