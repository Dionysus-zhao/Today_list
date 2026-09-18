#!/usr/bin/env python3
"""today-tasks · 本地服务

一个进程同时提供两件事：

  · 浏览器界面   http://127.0.0.1:17850
  · 本地 HTTP API  界面、脚本、自动化都用它

零依赖，只用 Python 标准库。

    python3 server.py                 # 启动，自动开浏览器
    python3 server.py --no-open       # 只起服务
    python3 server.py --port 9000     # 指定端口
    python3 server.py --data ~/tasks.json
"""

from __future__ import annotations

import argparse
import json
import shutil
import socket
import subprocess
import sys
import threading
import time
import traceback
import urllib.request
import webbrowser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse, parse_qs

sys.path.insert(0, str(Path(__file__).resolve().parent))

from store import Store, StoreError, parse_day, parse_input, today_str  # noqa: E402

VERSION = "1.0.0"
ROOT = Path(__file__).resolve().parent
WEB_DIR = ROOT / "web"
DEFAULT_PORT = 17850

# 访问本机回环不该走系统代理。
# 有些机器（包括我这边的运行环境）配了 HTTP 代理，会把 127.0.0.1 也代理掉，
# 于是「检测本地服务」永远失败 —— 实测到过 502 upstream connect failed。
# 显式给一个空 ProxyHandler 就绕开了。
_NO_PROXY = urllib.request.build_opener(urllib.request.ProxyHandler({}))


# --------------------------------------------------------------------------
# 路由
# --------------------------------------------------------------------------

def api_ping(store, q, body):
    return {"ok": True, "name": "today-tasks", "version": VERSION,
            "data": str(store.path), "today": today_str()}


def api_state(store, q, body):
    day = parse_day(q.get("date", "")) if q.get("date") else None
    if q.get("date") and day is None:
        raise StoreError("date 应为 YYYY-MM-DD")
    view = store.day_view(day)
    view["ok"] = True
    view["canUndo"] = store.can_undo()
    return view


def api_parse(store, q, body):
    """把一行口语拆成标题 + 日期。界面输入时实时调用，用来显示日期标签。"""
    raw = (body or {}).get("raw", "")
    p = parse_input(raw)
    return {"ok": True, "title": p["title"], "date": p["date"].isoformat(),
            "label": p["label"], "hasDate": p["hasDate"]}


def api_add(store, q, body):
    body = body or {}
    raw = body.get("raw")
    if raw:
        p = parse_input(raw)
        if not p["title"]:
            raise StoreError("只写了日期，没写要做的事")
        title, day = p["title"], p["date"]
    else:
        title = body.get("title", "")
        day = parse_day(body.get("date", "")) if body.get("date") else None
        if body.get("date") and day is None:
            raise StoreError("date 应为 YYYY-MM-DD")
    task = store.add(title, day)
    task["ok"] = True
    return task


def api_toggle(store, q, body):
    return {"ok": True, **store.toggle((body or {}).get("id", ""))}


def api_complete(store, q, body):
    body = body or {}
    return {"ok": True, **store.set_status(body.get("id", ""), bool(body.get("done")))}


def api_rename(store, q, body):
    body = body or {}
    return {"ok": True, **store.rename(body.get("id", ""), body.get("title", ""))}


def api_reschedule(store, q, body):
    body = body or {}
    return {"ok": True, **store.reschedule(body.get("id", ""), body.get("date", ""))}


def api_remove(store, q, body):
    return {"ok": True, **store.remove((body or {}).get("id", ""))}


def api_reorder(store, q, body):
    body = body or {}
    return {"ok": True, **store.reorder(body.get("orderedIds") or [], body.get("draggedId"))}


def api_undo(store, q, body):
    return {"ok": True, **store.undo()}


def api_review(store, q, body):
    days = int(q.get("days") or 7)
    return {"ok": True, **store.review(max(1, min(days, 90)))}


def api_month(store, q, body):
    return {"ok": True, **store.month_view(q.get("ym"))}


def api_raw(store, q, body):
    """原样返回整份数据。给桌面小窗（Windows 增强包）当数据源用 ——
    小窗不直接碰文件，一律走这里，这样数据只有一个写入口。"""
    doc = store.raw_document()
    return {
        "ok": True,
        "version": doc.get("version", 1),
        "updatedAt": doc.get("updatedAt"),
        "tasks": doc.get("tasks", []),
    }


ROUTES = {
    ("GET", "/api/ping"): api_ping,
    ("GET", "/api/state"): api_state,
    ("GET", "/api/review"): api_review,
    ("GET", "/api/month"): api_month,
    ("GET", "/api/raw"): api_raw,
    ("POST", "/api/parse"): api_parse,
    ("POST", "/api/add"): api_add,
    ("POST", "/api/toggle"): api_toggle,
    ("POST", "/api/complete"): api_complete,
    ("POST", "/api/rename"): api_rename,
    ("POST", "/api/reschedule"): api_reschedule,
    ("POST", "/api/remove"): api_remove,
    ("POST", "/api/reorder"): api_reorder,
    ("POST", "/api/undo"): api_undo,
}


# --------------------------------------------------------------------------
# HTTP 处理器
# --------------------------------------------------------------------------

class QuietServer(ThreadingHTTPServer):
    """浏览器/curl 提前断开是家常便饭，不该每次都甩一段 traceback 到日志里。"""

    daemon_threads = True

    def handle_error(self, request, client_address):
        exc = sys.exc_info()[1]
        if isinstance(exc, (ConnectionResetError, BrokenPipeError, ConnectionAbortedError)):
            return
        super().handle_error(request, client_address)


class Handler(BaseHTTPRequestHandler):
    server_version = "today-tasks/" + VERSION
    protocol_version = "HTTP/1.1"
    quiet = False

    # ---- 工具 ----

    def _send(self, code, payload=None, ctype="application/json; charset=utf-8", raw=None):
        if raw is None:
            raw = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(raw)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        try:
            self.wfile.write(raw)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def _file(self, path, ctype):
        try:
            raw = path.read_bytes()
        except OSError:
            self._send(404, {"ok": False, "error": "not found"})
            return
        self._send(200, raw=raw, ctype=ctype)

    def _body(self):
        try:
            length = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            return {}
        if length <= 0:
            return {}
        raw = self.rfile.read(length)
        try:
            value = json.loads(raw.decode("utf-8"))
        except (ValueError, UnicodeDecodeError):
            raise StoreError("请求体不是合法 JSON")
        return value if isinstance(value, dict) else {}

    def log_message(self, fmt, *args):  # 默认太吵，只在 --verbose 时输出
        if not self.quiet:
            return
        sys.stderr.write("  %s %s\n" % (self.address_string(), fmt % args))

    # ---- 动词 ----

    def do_OPTIONS(self):
        self.send_response(204)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_GET(self):
        self._dispatch("GET")

    def do_POST(self):
        self._dispatch("POST")

    def _dispatch(self, method):
        parsed = urlparse(self.path)
        path = parsed.path
        query = {k: v[0] for k, v in parse_qs(parsed.query).items()}

        if method == "GET" and not path.startswith("/api/"):
            return self._static(path)

        handler = ROUTES.get((method, path))
        if handler is None:
            return self._send(404, {"ok": False, "error": "未知接口 %s %s" % (method, path)})

        try:
            body = self._body() if method == "POST" else {}
            result = handler(self.server.store, query, body)
            self._send(200, result)
        except StoreError as exc:
            self._send(400, {"ok": False, "error": str(exc)})
        except Exception as exc:  # 兜底：任何意外都回 500 且打印，绝不静默
            traceback.print_exc()
            self._send(500, {"ok": False, "error": "%s: %s" % (type(exc).__name__, exc)})

    def _static(self, path):
        if path in ("/", "/index.html"):
            return self._file(WEB_DIR / "index.html", "text/html; charset=utf-8")
        if path == "/favicon.ico":
            return self._send(204)
        rel = path.lstrip("/")
        if ".." in rel:
            return self._send(400, {"ok": False, "error": "bad path"})
        target = (WEB_DIR / rel).resolve()
        if not str(target).startswith(str(WEB_DIR)) or not target.is_file():
            return self._send(404, {"ok": False, "error": "not found"})
        ctype = {
            ".html": "text/html; charset=utf-8",
            ".js": "application/javascript; charset=utf-8",
            ".css": "text/css; charset=utf-8",
            ".svg": "image/svg+xml",
            ".png": "image/png",
        }.get(target.suffix, "application/octet-stream")
        self._file(target, ctype)


# --------------------------------------------------------------------------
# 启动
# --------------------------------------------------------------------------

def pick_port(preferred, tries=25):
    for port in range(preferred, preferred + tries):
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            try:
                sock.bind(("127.0.0.1", port))
                return port
            except OSError:
                continue
    return 0


def port_open(port, timeout=0.2):
    """端口上有没有人在听。TCP 探测，对没人的端口是毫秒级返回的。"""
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.settimeout(timeout)
        return sock.connect_ex(("127.0.0.1", port)) == 0


def find_running_service(start_port, tries=25):
    """已经有 today-tasks 在跑吗？返回它的端口，没有就返回 0。

    为什么要这个：桌面图标会被反复双击，开机自启也可能已经起了一个。
    没有这层检查就会起出第二个、第三个服务，各占一个端口。
    """
    for port in range(start_port, start_port + tries):
        if not port_open(port):
            continue
        try:
            with _NO_PROXY.open("http://127.0.0.1:%d/api/ping" % port, timeout=1.5) as res:
                data = json.loads(res.read().decode("utf-8"))
        except Exception:
            continue
        if isinstance(data, dict) and data.get("name") == "today-tasks":
            return port
    return 0


def launch_widget(port):
    """在 Windows 上把桌面小窗拉起来。

    小窗是这个项目的**增强包**，只在 Windows 有意义（WPF 是 Windows 专有）。
    其他平台直接跳过。找不到 powershell / 小窗文件也安静跳过 —— 服务本身照常。
    """
    if not sys.platform.startswith("win"):
        return None
    script = ROOT / "desktop" / "desktop-widget.ps1"
    if not script.exists():
        return None
    shell = shutil.which("powershell") or shutil.which("pwsh")
    if not shell:
        return None

    flags = 0
    for name in ("DETACHED_PROCESS", "CREATE_NEW_PROCESS_GROUP"):
        flags |= getattr(subprocess, name, 0)
    try:
        proc = subprocess.Popen(
            [shell, "-sta", "-NoProfile", "-ExecutionPolicy", "Bypass",
             "-File", str(script), "-Port", str(port)],
            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            creationflags=flags, cwd=str(script.parent),
        )
    except OSError as exc:
        print("  小窗启动失败：%s" % exc, file=sys.stderr)
        return None

    # 等一小会儿看它有没有当场就死 —— 「进程起来了但立刻退出」比「压根没起来」
    # 难查得多，这里直接把它标出来。
    time.sleep(1.0)
    if proc.poll() is not None:
        print("  小窗启动后立刻退出（退出码 %s）—— 看 desktop\\trace.log" % proc.returncode,
              file=sys.stderr)
        return None
    return proc


def main(argv=None):
    try:
        sys.stdout.reconfigure(encoding="utf-8")
        sys.stderr.reconfigure(encoding="utf-8")
    except Exception:
        pass

    parser = argparse.ArgumentParser(description="today-tasks 本地服务（零依赖）")
    parser.add_argument("--data", default=str(ROOT / "tasks.json"),
                        help="数据文件路径（默认 ./tasks.json）")
    parser.add_argument("--port", type=int, default=DEFAULT_PORT, help="端口（默认 17850）")
    parser.add_argument("--no-open", action="store_true", help="启动后不自动打开浏览器")
    parser.add_argument("--no-widget", action="store_true",
                        help="Windows 上不自动拉起桌面小窗（增强包）")
    parser.add_argument("--verbose", action="store_true", help="打印每个请求")
    args = parser.parse_args(argv)

    store = Store(args.data).ensure()

    # 已经有一个在跑？那就别起第二个，把界面叫出来就完事。
    # 桌面图标会被反复双击，开机自启也可能已经起了一个 —— 没有这层检查
    # 就会起出第二个服务、占第二个端口，小窗连哪个全看运气。
    already = find_running_service(args.port)
    if already:
        print("today-tasks 已经在跑了（端口 %d），不重复启动。" % already)
        if not args.no_widget and launch_widget(already) is not None:
            print("  桌面小窗  已叫出来")
        if not args.no_open:
            webbrowser.open("http://127.0.0.1:%d/" % already)
        return 0

    port = pick_port(args.port)
    if port == 0:
        print("找不到可用端口，退出。", file=sys.stderr)
        return 1

    Handler.quiet = args.verbose
    httpd = QuietServer(("127.0.0.1", port), Handler)
    httpd.store = store

    url = "http://127.0.0.1:%d/" % port
    print("today-tasks %s" % VERSION)
    print("  数据文件  %s" % store.path)
    print("  界面      %s" % url)
    print("  接口      同端口 /api/*     （Ctrl+C 退出）")
    if port != args.port:
        print("  注意：%d 被占用，已改用 %d" % (args.port, port))

    if not args.no_widget and launch_widget(port) is not None:
        print("  桌面小窗  已启动（Windows 增强包；关掉它不影响服务）")

    if not args.no_open:
        threading.Timer(0.5, lambda: webbrowser.open(url)).start()

    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\n已退出。")
    finally:
        httpd.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
