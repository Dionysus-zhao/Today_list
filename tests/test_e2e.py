#!/usr/bin/env python3
"""端到端测试：HTTP API + MCP 协议。

    python3 tests/test_e2e.py

会在临时目录起真的 server / mcp_server 子进程，不碰你自己的数据。

注意：被测进程是**常驻**的，所以 stdout/stderr 一律不能接管道
（管道被子进程继承后会一直堵着，表现为「命令跑几分钟不返回」）。
MCP 那个必须接管道，因为要讲协议。
"""

from __future__ import annotations

import json
import socket
import subprocess
import sys
import tempfile
import time
import unittest
import urllib.error
import urllib.request
from datetime import date, timedelta
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

SERVER = ROOT / "server.py"
MCP = ROOT / "mcp_server.py"

# 本机回环不走系统代理 —— 有些环境配了 HTTP 代理会把 127.0.0.1 也代理掉，
# 请求会变成 502 upstream connect failed，测试跟着一起失败。
_OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}))


def free_port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def call(port, path, body=None):
    url = "http://127.0.0.1:%d%s" % (port, path)
    if body is None:
        req = urllib.request.Request(url)
    else:
        req = urllib.request.Request(
            url, data=json.dumps(body).encode("utf-8"),
            headers={"Content-Type": "application/json"}, method="POST")
    try:
        with _OPENER.open(req, timeout=10) as res:
            status, raw = res.status, res.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as exc:
        status, raw = exc.code, exc.read().decode("utf-8", "replace")
    try:
        return status, json.loads(raw)
    except ValueError:
        # 服务还没把路由挂上、或者回了非 JSON —— 把原文带出去，不要在这里炸掉
        return status, {"ok": False, "raw": raw[:400]}


class ServerTestCase(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        cls.data = Path(cls.tmp.name) / "tasks.json"
        cls.port = free_port()
        cls.proc = subprocess.Popen(
            [sys.executable, str(SERVER), "--no-open", "--no-widget",
             "--port", str(cls.port), "--data", str(cls.data)],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, cwd=str(ROOT))

        deadline = time.time() + 20
        last = None
        while time.time() < deadline:
            try:
                status, data = call(cls.port, "/api/ping")
                if status == 200 and data.get("ok"):
                    break
                last = (status, data)
            except OSError as exc:
                last = exc
            time.sleep(0.15)
        else:
            cls.proc.kill()
            raise RuntimeError("server 没能启动，最后一次响应：%r" % (last,))

    @classmethod
    def tearDownClass(cls):
        cls.proc.terminate()
        try:
            cls.proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            cls.proc.kill()
        cls.tmp.cleanup()

    # ---- 基础 ----

    def test_ping(self):
        status, data = call(self.port, "/api/ping")
        self.assertEqual(status, 200)
        self.assertTrue(data["ok"])
        self.assertEqual(data["name"], "today-tasks")

    def test_index_page_is_served(self):
        with _OPENER.open("http://127.0.0.1:%d/" % self.port, timeout=10) as res:
            html = res.read().decode("utf-8")
        self.assertIn("today-tasks", html)
        self.assertIn("<script>", html)

    def test_unknown_endpoint_404(self):
        status, data = call(self.port, "/api/nope")
        self.assertEqual(status, 404)
        self.assertFalse(data["ok"])

    # ---- 增删改查 ----

    def test_add_with_chinese_and_parse(self):
        status, data = call(self.port, "/api/add", {"raw": "写季度汇报"})
        self.assertEqual(status, 200, data)
        self.assertEqual(data["title"], "写季度汇报")
        self.assertEqual(data["date"], date.today().isoformat())

    def test_add_with_natural_date(self):
        status, data = call(self.port, "/api/add", {"raw": "明天 交周报"})
        self.assertEqual(status, 200, data)
        self.assertEqual(data["title"], "交周报")
        self.assertEqual(data["date"], (date.today() + timedelta(days=1)).isoformat())

        status, parsed = call(self.port, "/api/parse", {"raw": "下周三 体检"})
        self.assertTrue(parsed["hasDate"])
        self.assertEqual(parsed["title"], "体检")

    def test_add_empty_title_rejected(self):
        status, data = call(self.port, "/api/add", {"raw": "明天"})
        self.assertEqual(status, 400)
        self.assertIn("日期", data["error"])

    def test_state_today_vs_other_day(self):
        _, mine = call(self.port, "/api/add", {"raw": "写今天的总结"})
        _, today_view = call(self.port, "/api/state")
        self.assertIn(mine["id"], [t["id"] for t in today_view["tasks"]])

        future = (date.today() + timedelta(days=2)).isoformat()
        _, other = call(self.port, "/api/add", {"title": "后天的事", "date": future})
        _, other_view = call(self.port, "/api/state?date=" + future)
        self.assertEqual([t["id"] for t in other_view["tasks"]], [other["id"]])
        self.assertFalse(other_view["isToday"])

    def test_carried_over_and_toggle_roundtrip(self):
        old = (date.today() - timedelta(days=3)).isoformat()
        _, task = call(self.port, "/api/add", {"title": "拖了三天的事", "date": old})

        _, view = call(self.port, "/api/state")
        row = [t for t in view["tasks"] if t["id"] == task["id"]][0]
        self.assertEqual(row["carriedDays"], 3)

        status, _ = call(self.port, "/api/complete", {"id": task["id"], "done": True})
        self.assertEqual(status, 200)

        _, view = call(self.port, "/api/state")
        row = [t for t in view["tasks"] if t["id"] == task["id"]]
        self.assertEqual(len(row), 1, "勾掉之后应该还在今天，否则没法取消")
        self.assertTrue(row[0]["done"])

        call(self.port, "/api/complete", {"id": task["id"], "done": False})
        _, view = call(self.port, "/api/state")
        row = [t for t in view["tasks"] if t["id"] == task["id"]][0]
        self.assertFalse(row["done"])

    def test_rename_reschedule_and_remove_undo(self):
        _, task = call(self.port, "/api/add", {"title": "原名"})
        _, renamed = call(self.port, "/api/rename", {"id": task["id"], "title": "改名了"})
        self.assertEqual(renamed["title"], "改名了")

        target = (date.today() + timedelta(days=4)).isoformat()
        call(self.port, "/api/reschedule", {"id": task["id"], "date": target})
        _, view = call(self.port, "/api/state?date=" + target)
        self.assertEqual([t["title"] for t in view["tasks"]], ["改名了"])

        call(self.port, "/api/remove", {"id": task["id"]})
        _, view = call(self.port, "/api/state?date=" + target)
        self.assertEqual(view["tasks"], [])

        status, _ = call(self.port, "/api/undo", {})
        self.assertEqual(status, 200)
        _, view = call(self.port, "/api/state?date=" + target)
        self.assertEqual([t["title"] for t in view["tasks"]], ["改名了"])

    def test_reorder(self):
        ids = []
        for i in range(3):
            _, t = call(self.port, "/api/add", {"title": "排序 %d" % i})
            ids.append(t["id"])
        reversed_ids = list(reversed(ids))
        status, _ = call(self.port, "/api/reorder",
                         {"orderedIds": reversed_ids, "draggedId": reversed_ids[0]})
        self.assertEqual(status, 200)
        _, view = call(self.port, "/api/state")
        got = [t["id"] for t in view["tasks"] if t["id"] in ids]
        self.assertEqual(got, reversed_ids)

    def test_reorder_rejects_bad_payload(self):
        status, data = call(self.port, "/api/reorder", {"orderedIds": ["t-nope", "t-nope2"]})
        self.assertEqual(status, 400)
        self.assertFalse(data["ok"])

    def test_month_endpoint(self):
        status, data = call(self.port, "/api/month")
        self.assertEqual(status, 200, data)
        self.assertTrue(data["ok"])
        self.assertTrue(data["cells"])
        self.assertEqual(data["month"], date.today().strftime("%Y-%m"))

        status, bad = call(self.port, "/api/month?ym=nope")
        self.assertEqual(status, 400)
        self.assertFalse(bad["ok"])

    def test_state_survives_repeated_writes(self):
        """写 30 次之后文件仍然是合法 JSON，且没有残留临时文件。"""
        for i in range(30):
            call(self.port, "/api/add", {"raw": "压测 %d" % i})
        payload = json.loads(self.data.read_text(encoding="utf-8"))
        self.assertGreaterEqual(len(payload["tasks"]), 30)
        leftovers = [p.name for p in self.data.parent.iterdir() if p.suffix == ".tmp"]
        self.assertEqual(leftovers, [])


class McpTestCase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.data = Path(self.tmp.name) / "tasks.json"

    def tearDown(self):
        self.tmp.cleanup()

    def start(self):
        env = dict(**__import__("os").environ)
        env["TODAY_TASKS_DATA"] = str(self.data)
        env["PYTHONIOENCODING"] = "utf-8"
        proc = subprocess.Popen(
            [sys.executable, str(MCP)], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL, env=env, cwd=str(ROOT))
        self.addCleanup(lambda: (proc.terminate(), proc.wait(timeout=5)))
        return proc

    def send(self, proc, msg):
        proc.stdin.write((json.dumps(msg) + "\n").encode("utf-8"))
        proc.stdin.flush()

    def recv(self, proc):
        line = proc.stdout.readline()
        if not line:
            raise AssertionError("MCP 进程没有回应就退出了")
        return json.loads(line.decode("utf-8"))

    def rpc(self, proc, mid, method, params=None):
        msg = {"jsonrpc": "2.0", "id": mid, "method": method}
        if params is not None:
            msg["params"] = params
        self.send(proc, msg)
        return self.recv(proc)

    def call_tool(self, proc, mid, name, args=None):
        res = self.rpc(proc, mid, "tools/call", {"name": name, "arguments": args or {}})
        return res["result"]

    def test_handshake_list_and_call(self):
        proc = self.start()

        res = self.rpc(proc, 1, "initialize", {
            "protocolVersion": "2024-11-05",
            "capabilities": {},
            "clientInfo": {"name": "test", "version": "1"},
        })
        self.assertEqual(res["result"]["protocolVersion"], "2024-11-05")
        self.assertEqual(res["result"]["serverInfo"]["name"], "today-tasks")
        self.assertIn("tools", res["result"]["capabilities"])

        # 通知不应有回应
        self.send(proc, {"jsonrpc": "2.0", "method": "notifications/initialized"})

        res = self.rpc(proc, 2, "tools/list")
        tools = res["result"]["tools"]
        names = [t["name"] for t in tools]
        for expected in ("list_tasks", "add_task", "complete_task", "remove_task",
                         "move_task", "review", "undo", "reschedule_task"):
            self.assertIn(expected, names)
        for tool in tools:
            self.assertIn("description", tool)
            self.assertIn("inputSchema", tool)
            self.assertTrue(tool["description"].strip())

        # 添加 → 列表里能看到
        result = self.call_tool(proc, 3, "add_task", {"title": "练习述职稿件"})
        self.assertFalse(result.get("isError"))
        self.assertIn("练习述职稿件", result["content"][0]["text"])

        result = self.call_tool(proc, 4, "list_tasks", {})
        text = result["content"][0]["text"]
        self.assertIn("练习述职稿件", text)

        # 按标题片段打勾（agent 不会记 id）
        result = self.call_tool(proc, 5, "complete_task", {"task": "述职"})
        self.assertFalse(result.get("isError"), result)
        self.assertIn("已完成", result["content"][0]["text"])

        # 完成的任务还在今天的列表里
        result = self.call_tool(proc, 6, "list_tasks", {})
        self.assertIn("[x] 练习述职稿件", result["content"][0]["text"])

    def test_natural_language_and_review(self):
        proc = self.start()
        self.call_tool(proc, 1, "add_task", {"title": "明天 交周报"})
        self.call_tool(proc, 2, "add_task", {"title": "周五 复盘"})
        self.call_tool(proc, 3, "add_task", {"title": "拖了很久的事", "date": "2026-09-10"})

        result = self.call_tool(proc, 4, "list_upcoming", {"days": 7})
        self.assertFalse(result.get("isError"))
        self.assertIn("交周报", result["content"][0]["text"])

        result = self.call_tool(proc, 5, "review", {"days": 7})
        text = result["content"][0]["text"]
        self.assertIn("复盘原始数据", text)
        self.assertIn("拖了很久的事", text)

    def test_errors_are_reported_as_tool_errors(self):
        proc = self.start()
        self.call_tool(proc, 1, "add_task", {"title": "存在的任务"})

        # 找不到的任务 → isError（不是 JSON-RPC error，这样 agent 能看到并纠正）
        result = self.call_tool(proc, 2, "complete_task", {"task": "根本不存在的任务"})
        self.assertTrue(result["isError"])
        self.assertIn("找不到", result["content"][0]["text"])

        # 没给标题
        result = self.call_tool(proc, 3, "add_task", {})
        self.assertTrue(result["isError"])

        # 不存在的工具
        result = self.call_tool(proc, 4, "no_such_tool", {})
        self.assertTrue(result["isError"])

        # 未知方法 → JSON-RPC error
        res = self.rpc(proc, 5, "unknown/method")
        self.assertIn("error", res)

    def test_undo_through_mcp(self):
        proc = self.start()
        self.call_tool(proc, 1, "add_task", {"title": "会被删掉的"})
        self.call_tool(proc, 2, "remove_task", {"task": "会被删掉"})
        result = self.call_tool(proc, 3, "list_tasks", {})
        self.assertNotIn("[ ] 会被删掉的", result["content"][0]["text"])

        result = self.call_tool(proc, 4, "undo", {})
        self.assertFalse(result.get("isError"))
        result = self.call_tool(proc, 5, "list_tasks", {})
        self.assertIn("会被删掉的", result["content"][0]["text"])

    def test_move_task(self):
        proc = self.start()
        for i in range(3):
            self.call_tool(proc, 10 + i, "add_task", {"title": "任务%d" % i})
        result = self.call_tool(proc, 20, "move_task", {"task": "任务2", "direction": "top"})
        self.assertFalse(result.get("isError"), result)

        text = self.call_tool(proc, 21, "list_tasks", {})["content"][0]["text"]
        self.assertLess(text.index("任务2"), text.index("任务0"))


if __name__ == "__main__":
    unittest.main(verbosity=2)
