#!/usr/bin/env python3
"""today-tasks · MCP server（stdio）

用标准输入输出讲 JSON-RPC，让任意支持 MCP 的 agent 直接读写你的任务清单。
零依赖：只用 Python 标准库，不需要 `pip install mcp`。

配置示例（Claude Desktop / Cursor / 任何 MCP 客户端）:

    {
      "mcpServers": {
        "today-tasks": {
          "command": "python3",
          "args": ["/绝对路径/today-tasks/mcp_server.py"]
        }
      }
    }

Windows 上把 command 换成 python 或 py，args 里的路径用正斜杠或双反斜杠。

调试：MCP_DEBUG=1 时把收到的每条消息打到 stderr（stdout 是协议通道，不能碰）。
"""

from __future__ import annotations

import json
import os
import sys
import traceback
from datetime import timedelta
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from store import (  # noqa: E402
    Store, StoreError, human_day, parse_day, parse_input, today, today_str,
)

VERSION = "1.0.0"
SERVER_NAME = "today-tasks"
PROTOCOL_FALLBACK = "2024-11-05"
DATA_PATH = os.environ.get("TODAY_TASKS_DATA") or str(Path(__file__).resolve().parent / "tasks.json")
DEBUG = os.environ.get("MCP_DEBUG") == "1"


def log(msg):
    if DEBUG:
        sys.stderr.write("[today-tasks] %s\n" % msg)
        sys.stderr.flush()


# --------------------------------------------------------------------------
# 参数解析辅助
# --------------------------------------------------------------------------

def resolve_day(text, base=None):
    """'2026-09-20' / '明天' / '周五' / '9/20' → date"""
    base = base or today()
    if not text:
        return base
    day = parse_day(text)
    if day:
        return day
    parsed = parse_input(str(text), base)
    if parsed["hasDate"]:
        return parsed["date"]
    raise StoreError("看不懂日期「%s」。用 YYYY-MM-DD，或「明天」「周五」「9/20」这类说法。" % text)


def resolve_task(store, ref):
    """按 id，或按标题（唯一匹配）找到一条任务。"""
    ref = str(ref or "").strip()
    if not ref:
        raise StoreError("要指定是哪条任务：可以用它的标题，或者 id。")
    tasks = store.raw_tasks()

    for t in tasks:
        if t.get("id") == ref:
            return t

    exact = [t for t in tasks if str(t.get("title", "")).strip() == ref]
    if len(exact) == 1:
        return exact[0]

    hits = [t for t in tasks if ref in str(t.get("title", ""))]
    if len(hits) == 1:
        return hits[0]
    if len(hits) > 1:
        names = " / ".join(str(t.get("title", "")) for t in hits[:6])
        raise StoreError("「%s」匹配到 %d 条：%s。说得更具体一点，或者直接用 id。" % (ref, len(hits), names))
    raise StoreError("找不到「%s」这条任务。" % ref)


# --------------------------------------------------------------------------
# 输出格式（给 agent 读的紧凑文本）
# --------------------------------------------------------------------------

def fmt_day(view):
    s = view["stats"]
    head = "%s · 共 %d 项" % (view["label"], s["total"])
    bits = []
    if s["pending"]:
        bits.append("待办 %d" % s["pending"])
    if s["done"]:
        bits.append("已完成 %d" % s["done"])
    if s["carried"]:
        bits.append("顺延 %d（最多 %d 天）" % (s["carried"], s["carriedMax"]))
    if bits:
        head += "（" + " · ".join(bits) + "）"

    lines = [head]
    if not view["tasks"]:
        lines.append("（这一天没有任务）")
        return "\n".join(lines)

    pending = [t for t in view["tasks"] if not t["done"]]
    done = [t for t in view["tasks"] if t["done"]]

    for i, t in enumerate(pending, 1):
        extra = ""
        if t["carriedDays"]:
            extra = "  [顺延 %d 天，原定 %s]" % (t["carriedDays"], t["date"])
        elif t["date"] != view["date"]:
            extra = "  [原定 %s]" % t["date"]
        lines.append("%d. [ ] %s  (id: %s)%s" % (i, t["title"], t["id"], extra))

    if done:
        lines.append("已完成：")
        for t in done:
            lines.append("   [x] %s  (id: %s)" % (t["title"], t["id"]))
    return "\n".join(lines)


def ok(text):
    return {"content": [{"type": "text", "text": text}]}


def fail(text):
    return {"content": [{"type": "text", "text": text}], "isError": True}


# --------------------------------------------------------------------------
# 工具实现
# --------------------------------------------------------------------------

def tool_list_tasks(store, args):
    day = resolve_day(args.get("date"), None) if args.get("date") else None
    view = store.day_view(day)
    text = fmt_day(view)
    if not day and view["future"]:
        bits = ", ".join("%s %d 项" % (f["label"].split(" · ")[0], f["total"]) for f in view["future"][:5])
        text += "\n\n接下来几天：" + bits
    return ok(text)


def tool_add_task(store, args):
    raw = args.get("title") or args.get("raw") or ""
    if not str(raw).strip():
        return fail("要给我任务内容。")
    day = resolve_day(args.get("date"), None) if args.get("date") else None

    if day is None:
        parsed = parse_input(str(raw))
        title, day = parsed["title"], parsed["date"]
        if not title:
            return fail("只写了日期，没写要做什么。")
    else:
        title = str(raw).strip()

    task = store.add(title, day, args.get("note", ""))
    when = human_day(day)
    return ok("已添加：「%s」→ %s (id: %s)" % (task["title"], when, task["id"]))


def tool_complete_task(store, args):
    task = resolve_task(store, args.get("task") or args.get("id"))
    done = args.get("done")
    done = True if done is None else bool(done)
    result = store.set_status(task["id"], done)
    verb = "已完成" if done else "已恢复为待办"
    return ok("%s：「%s」" % (verb, task.get("title", "")))


def tool_remove_task(store, args):
    task = resolve_task(store, args.get("task") or args.get("id"))
    store.remove(task["id"])
    return ok("已删除：「%s」。如果删错了，调用 undo 可以恢复。" % task.get("title", ""))


def tool_rename_task(store, args):
    task = resolve_task(store, args.get("task") or args.get("id"))
    title = str(args.get("title") or "").strip()
    if not title:
        return fail("新标题不能是空的。")
    store.rename(task["id"], title)
    return ok("已改名：「%s」→「%s」" % (task.get("title", ""), title))


def tool_reschedule_task(store, args):
    task = resolve_task(store, args.get("task") or args.get("id"))
    day = resolve_day(args.get("date"))
    store.reschedule(task["id"], day)
    return ok("「%s」已挪到 %s" % (task.get("title", ""), human_day(day)))


def tool_move_task(store, args):
    task = resolve_task(store, args.get("task") or args.get("id"))
    view = store.day_view()
    ids = [t["id"] for t in view["tasks"] if not t["done"]]
    if task["id"] not in ids:
        return fail("「%s」不在今天的待办里，排不了。只能调整今天待办之间的顺序。" % task.get("title", ""))

    index = ids.index(task["id"])
    ids.pop(index)

    direction = str(args.get("direction") or "").lower()
    position = args.get("position")
    if direction in ("up", "上移", "上"):
        target = max(0, index - 1)
    elif direction in ("down", "下移", "下"):
        target = min(len(ids), index)
    elif direction in ("top", "置顶", "最前"):
        target = 0
    elif direction in ("bottom", "置底", "最后"):
        target = len(ids)
    elif position is not None:
        try:
            target = max(0, min(len(ids), int(position) - 1))
        except (TypeError, ValueError):
            return fail("position 得是个数字。")
    else:
        return fail("要说清怎么挪：给 direction（up/down/top/bottom）或 position（第几位）。")

    ids.insert(target, task["id"])
    store.reorder(ids, task["id"])
    return ok("「%s」已挪到第 %d 位。" % (task.get("title", ""), ids.index(task["id"]) + 1))


def tool_review(store, args):
    days = args.get("days") or 7
    try:
        days = max(1, min(int(days), 90))
    except (TypeError, ValueError):
        days = 7
    data = store.review(days)

    lines = ["复盘原始数据（最近 %d 天，%s ~ %s）" % (days, data["range"]["from"], data["range"]["to"]),
             "计划 %d 项，完成 %d 项，完成率 %d%%" % (
                 data["totalPlanned"], data["totalDone"],
                 round(100 * data["totalDone"] / data["totalPlanned"]) if data["totalPlanned"] else 0),
             "", "按天："]
    for d in data["perDay"]:
        bar = "#" * d["done"] + "." * max(0, d["total"] - d["done"])
        lines.append("  %s  %s  %d/%d" % (d["date"], bar, d["done"], d["total"]))

    if data["carriedOver"]:
        lines.append("")
        lines.append("还在顺延中（按拖的天数排）：")
        for c in data["carriedOver"][:15]:
            lines.append("  %d 天  %s  (id: %s, 原定 %s)" % (c["carriedDays"], c["title"], c["id"], c["date"]))
    if data["stuck"]:
        lines.append("")
        lines.append("注意：有 %d 条拖了 3 天以上。" % len(data["stuck"]))

    lines.append("")
    lines.append("（这里只有数字。该砍、该拆、该挪，需要你结合了解来判断。）")
    return ok("\n".join(lines))


def tool_undo(store, args):
    result = store.undo()
    return ok("已撤销上一次「%s」。还能再撤 %d 步。" % (result["undo"], result["remaining"]))


def tool_list_upcoming(store, args):
    days = args.get("days") or 7
    try:
        days = max(1, min(int(days), 60))
    except (TypeError, ValueError):
        days = 7
    summary = store.future_summary(None, days)
    if not summary:
        return ok("接下来 %d 天没有安排。" % days)

    base = today()
    lines = ["接下来 %d 天：" % days]
    for f in summary:
        day = parse_day(f["date"])
        rows = [t for t in store.raw_tasks() if t.get("date") == f["date"]]
        lines.append("%s · %d 项" % (human_day(day, base), f["total"]))
        for t in rows:
            mark = "[x]" if t.get("status") == "done" else "[ ]"
            lines.append("   %s %s  (id: %s)" % (mark, t.get("title", ""), t.get("id", "")))
    return ok("\n".join(lines))


TOOLS = [
    {
        "name": "list_tasks",
        "description": (
            "查看某一天的任务清单。不传 date 就是今天。\n"
            "今天会自动包含更早日期里还没完成的任务（顺延下来），并标出拖了几天。\n"
            "想知道「今天还有什么没做」「明天安排了什么」时用它。"
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "date": {"type": "string",
                         "description": "YYYY-MM-DD，或口语（明天 / 周五 / 9/20）。省略 = 今天"},
            },
        },
    },
    {
        "name": "list_upcoming",
        "description": "看接下来几天各有什么安排（默认 7 天）。用于「这周还有什么」这类问题。",
        "inputSchema": {
            "type": "object",
            "properties": {"days": {"type": "integer", "description": "看几天，默认 7"}},
        },
    },
    {
        "name": "add_task",
        "description": (
            "添加一条任务。标题里带日期前缀会自动识别，例如「明天 交周报」「周五 牙医」「9/20 高铁票」。\n"
            "也可以显式传 date 参数。用户一次说了几件事，就分几次调用。"
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "title": {"type": "string", "description": "任务内容，可带日期前缀"},
                "date": {"type": "string", "description": "可选。YYYY-MM-DD 或口语说法；不填则从标题里识别，识别不出就是今天"},
                "note": {"type": "string", "description": "可选备注"},
            },
            "required": ["title"],
        },
    },
    {
        "name": "complete_task",
        "description": "把一条任务标记为完成（或取消完成）。用户说「X 做完了」时用它。",
        "inputSchema": {
            "type": "object",
            "properties": {
                "task": {"type": "string", "description": "任务标题（可只写其中几个字），或任务 id"},
                "done": {"type": "boolean", "description": "true = 完成（默认），false = 取消完成"},
            },
            "required": ["task"],
        },
    },
    {
        "name": "remove_task",
        "description": "删除一条任务。删错了可以调用 undo 恢复。",
        "inputSchema": {
            "type": "object",
            "properties": {"task": {"type": "string", "description": "任务标题或 id"}},
            "required": ["task"],
        },
    },
    {
        "name": "rename_task",
        "description": "改一条任务的标题。",
        "inputSchema": {
            "type": "object",
            "properties": {
                "task": {"type": "string", "description": "任务标题或 id"},
                "title": {"type": "string", "description": "新的标题"},
            },
            "required": ["task", "title"],
        },
    },
    {
        "name": "reschedule_task",
        "description": "把一条任务挪到别的日期。",
        "inputSchema": {
            "type": "object",
            "properties": {
                "task": {"type": "string", "description": "任务标题或 id"},
                "date": {"type": "string", "description": "YYYY-MM-DD 或口语（明天 / 下周三 / 9/20）"},
            },
            "required": ["task", "date"],
        },
    },
    {
        "name": "move_task",
        "description": (
            "调整今天待办之间的先后顺序。顺序 = 优先级，第一条是最重要的。\n"
            "用户说「把 X 提前」「这件事先做」「X 排到第 2 位」时用它。"
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "task": {"type": "string", "description": "任务标题或 id"},
                "direction": {"type": "string", "enum": ["up", "down", "top", "bottom"],
                              "description": "上移一位 / 下移一位 / 置顶 / 置底"},
                "position": {"type": "integer", "description": "也可以直接给目标名次（1 = 第一位）"},
            },
            "required": ["task"],
        },
    },
    {
        "name": "review",
        "description": (
            "拉出最近几天的完成情况和积压任务，用于复盘。\n"
            "用户问「这周怎么样」「我是不是排太多了」「哪件事一直没做完」时用它。\n"
            "返回的是原始数据（每天完成数、还在顺延的任务及天数），结论由你来给。"
        ),
        "inputSchema": {
            "type": "object",
            "properties": {"days": {"type": "integer", "description": "看最近几天，默认 7，最多 90"}},
        },
    },
    {
        "name": "undo",
        "description": "撤销上一次改动（删除、打勾、排序等都能撤）。最多往回撤 20 步。",
        "inputSchema": {"type": "object", "properties": {}},
    },
]

HANDLERS = {
    "list_tasks": tool_list_tasks,
    "list_upcoming": tool_list_upcoming,
    "add_task": tool_add_task,
    "complete_task": tool_complete_task,
    "remove_task": tool_remove_task,
    "rename_task": tool_rename_task,
    "reschedule_task": tool_reschedule_task,
    "move_task": tool_move_task,
    "review": tool_review,
    "undo": tool_undo,
}


# --------------------------------------------------------------------------
# JSON-RPC
# --------------------------------------------------------------------------

def reply(mid, result=None, error=None):
    msg = {"jsonrpc": "2.0", "id": mid}
    if error is not None:
        msg["error"] = error
    else:
        msg["result"] = result
    return msg


def handle(store, msg):
    if not isinstance(msg, dict):
        return None
    method = msg.get("method")
    mid = msg.get("id")
    params = msg.get("params") or {}

    if mid is None:            # 通知（notifications/*），不需要回
        log("notification: %s" % method)
        return None

    if method == "initialize":
        want = params.get("protocolVersion") or PROTOCOL_FALLBACK
        return reply(mid, {
            "protocolVersion": want,
            "capabilities": {"tools": {"listChanged": False}},
            "serverInfo": {"name": SERVER_NAME, "version": VERSION},
        })

    if method == "ping":
        return reply(mid, {})

    if method == "tools/list":
        return reply(mid, {"tools": TOOLS})

    if method == "tools/call":
        name = params.get("name")
        args = params.get("arguments") or {}
        handler = HANDLERS.get(name)
        if handler is None:
            return reply(mid, fail("没有叫 %s 的工具。" % name))
        try:
            return reply(mid, handler(store, args))
        except StoreError as exc:
            return reply(mid, fail(str(exc)))
        except Exception as exc:
            traceback.print_exc(file=sys.stderr)
            return reply(mid, fail("内部错误：%s: %s" % (type(exc).__name__, exc)))

    return reply(mid, error={"code": -32601, "message": "不支持的方法 %s" % method})


def main():
    store = Store(DATA_PATH).ensure()
    log("started, data=%s" % store.path)

    for raw in sys.stdin.buffer:
        raw = raw.strip()
        if not raw:
            continue
        try:
            msg = json.loads(raw.decode("utf-8"))
        except (ValueError, UnicodeDecodeError) as exc:
            log("bad message: %s" % exc)
            continue

        log("recv: %s" % (msg.get("method") or msg))

        response = handle(store, msg)
        if response is None:
            continue
        payload = json.dumps(response, ensure_ascii=False)
        sys.stdout.buffer.write(payload.encode("utf-8") + b"\n")
        sys.stdout.buffer.flush()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
