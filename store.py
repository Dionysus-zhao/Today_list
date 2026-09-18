#!/usr/bin/env python3
"""today-tasks · 数据层

唯一数据源是一个纯文本 JSON 文件。四条设计原则：

1. 人可读、人可改 —— 记事本能打开，git diff 看得懂，出问题能自己修
2. 零依赖 —— 只用 Python 标准库
3. 原子写 —— 先写临时文件再 os.replace()，任何时刻断电都不会留下半截文件
4. 跨进程安全 —— 每次改动都在文件锁内完成「读-改-写」

数据格式（向后兼容早期 PowerShell 版本产生的文件）::

    {
      "version": 1,
      "updatedAt": "2026-09-18T18:25:26+08:00",
      "tasks": [
        {"id": "t-20260918-01", "title": "练习述职稿件",
         "date": "2026-09-18", "status": "pending", "rev": 11, "note": ""}
      ]
    }
"""

from __future__ import annotations

import json
import os
import re
import shutil
import tempfile
import time
from contextlib import contextmanager
from datetime import date, datetime, timedelta
from pathlib import Path

SCHEMA_VERSION = 1
DATE_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")
_WEEKDAY_CN = "一二三四五六日"
_DAYMAP = {"一": 1, "二": 2, "三": 3, "四": 4, "五": 5, "六": 6, "日": 7, "天": 7}
"""周一=1 … 周日=7，和 date.isoweekday() 对齐。

不要用 date.weekday()（那个是周一=0、周日=6）—— 两边基准不一致会让「周五」
算成周六。这个坑已经踩过一次。
"""


class StoreError(Exception):
    """数据层可预期的错误（锁超时、文件损坏、校验不过）。"""


# --------------------------------------------------------------------------
# 时间工具
# --------------------------------------------------------------------------

def today() -> date:
    return date.today()


def today_str() -> str:
    return date.today().isoformat()


def parse_day(s):
    """把 'YYYY-MM-DD' 解析成 date；不合法返回 None。"""
    if not isinstance(s, str) or not DATE_RE.match(s.strip()):
        return None
    try:
        return datetime.strptime(s.strip(), "%Y-%m-%d").date()
    except ValueError:
        return None


def human_day(d, base=None):
    """'9/18 周五'，带相对前缀（今天 / 明天 / 后天）。"""
    base = base or today()
    diff = (d - base).days
    wd = _WEEKDAY_CN[d.weekday()]
    body = "%d/%d 周%s" % (d.month, d.day, wd)
    if diff == 0:
        return "今天 · " + body
    if diff == 1:
        return "明天 · " + body
    if diff == 2:
        return "后天 · " + body
    if diff == -1:
        return "昨天 · " + body
    return body


# --------------------------------------------------------------------------
# 口语化日期解析：支持「明天 xxx」「周五 xxx」「下周三 xxx」「9/20 xxx」「12月25日 xxx」
# --------------------------------------------------------------------------

_SEP = r"[\s:：,，、]*"

_DAY_PATTERNS = [
    ("今天", 0, r"^今天" + _SEP, "今天"),
    ("明天", 1, r"^(?:明天|明日|明早)" + _SEP, "明天"),
    ("大后天", 3, r"^大后天" + _SEP, "大后天"),
    ("后天", 2, r"^后天" + _SEP, "后天"),
    ("昨天", -1, r"^昨天" + _SEP, "昨天"),
]

_WEEKDAY_RE = re.compile(
    r"^(下下周|下下星期|下下礼拜|下周|下星期|下礼拜|本周|这周|周|星期|礼拜)\s*([一二三四五六日天])" + _SEP
)

_MONTHDAY_RE = re.compile(r"^(\d{1,2})\s*[月/.\-]\s*(\d{1,2})\s*[日号]?" + _SEP)

_SEP_CHARS = " \t\r\n:：,，、"


def _glued(match):
    """日期词和后面的内容之间有没有分隔符。

    「明天 交周报」→ False（有空格），「明天交周报」→ True（粘着）。
    """
    return match.group(0)[-1] not in _SEP_CHARS


def parse_input(raw, base=None):
    """把一行口语拆成 (title, date)。

    识别不出日期时，date 落回 base（默认今天），整行都是 title。
    识别出日期但后面没内容时，返回 (None, date) —— 调用方据此提示「只写了日期」。
    """
    base = base or today()
    text = (raw or "").strip()
    result = {"title": text, "date": base, "label": "", "hasDate": False}
    if not text:
        return result

    target = None
    label = ""
    consumed = 0
    glued = False

    for name, delta, pattern, lbl in _DAY_PATTERNS:
        m = re.match(pattern, text)
        if m:
            target, label, consumed = base + timedelta(days=delta), lbl, m.end()
            glued = _glued(m)
            break

    if target is None:
        m = _WEEKDAY_RE.match(text)
        if m:
            prefix, ch = m.group(1), m.group(2)
            want = _DAYMAP[ch]                       # 1..7
            monday = base - timedelta(days=base.isoweekday() - 1)
            if prefix.startswith("下下"):
                target = monday + timedelta(days=14 + want - 1)
                label = "下下周" + ch
            elif prefix.startswith("下"):
                target = monday + timedelta(days=7 + want - 1)
                label = "下周" + ch
            elif prefix.startswith(("本周", "这周")):
                target = monday + timedelta(days=want - 1)
                label = "本周" + ch
            else:
                # 只说「周三」= 最近的那个周三，今天正好是就算今天
                target = base + timedelta(days=(want - base.isoweekday()) % 7)
                label = "周" + ch
            consumed = m.end()
            glued = _glued(m)

    if target is None:
        m = _MONTHDAY_RE.match(text)
        if m:
            mo, dd = int(m.group(1)), int(m.group(2))
            if 1 <= mo <= 12 and 1 <= dd <= 31:
                for year in (base.year, base.year + 1):
                    try:
                        cand = date(year, mo, dd)
                    except ValueError:
                        break
                    if cand >= base:
                        target = cand
                        break
                if target:
                    label, consumed = "%d月%d日" % (mo, dd), m.end()
                    glued = _glued(m)

    if target is None:
        return result

    rest = text[consumed:].strip()
    # 「今天的事」「明天的会议」—— 「X的Y」是一个整体，别把「今天」切出去当日期。
    # 只有用户明确加了空格（今天 的事）才照拆不误。
    if glued and rest.startswith("的"):
        return result
    result["date"] = target
    result["label"] = label
    result["hasDate"] = True
    if not rest:
        result["title"] = None  # 有日期没内容
    else:
        result["title"] = rest
    return result


# --------------------------------------------------------------------------
# 文件锁
# --------------------------------------------------------------------------

@contextmanager
def _file_lock(path, timeout=8.0, stale=15.0):
    """跨平台互斥：O_EXCL 创建锁文件。

    比 fcntl/msvcrt 的方案更简单，且两边行为一致；代价是进程被强杀后
    锁文件会残留，因此带「超过 stale 秒即视为过期」的清理。
    """
    lock = str(path) + ".lock"
    deadline = time.time() + timeout
    fd = None
    while fd is None:
        try:
            fd = os.open(lock, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
        except FileExistsError:
            try:
                if time.time() - os.path.getmtime(lock) > stale:
                    os.unlink(lock)
                    continue
            except OSError:
                pass
            if time.time() > deadline:
                raise StoreError("另一个进程正在写入，稍后重试")
            time.sleep(0.02)
    try:
        yield
    finally:
        try:
            os.close(fd)
        finally:
            try:
                os.unlink(lock)
            except OSError:
                pass


# --------------------------------------------------------------------------
# Store
# --------------------------------------------------------------------------

class Store:
    """一个 JSON 文件就是全部。实例是轻量的，可以随手 new。"""

    MAX_UNDO = 20

    def __init__(self, path):
        self.path = Path(path).expanduser().resolve()
        self._undo = []           # 内存撤销栈：每项是变更前的 tasks 列表深拷贝
        self._undo_labels = []

    # ---------------- 读写 ----------------

    def exists(self):
        return self.path.exists()

    def ensure(self):
        """文件不存在就创建一个空的。"""
        if not self.path.exists():
            self.path.parent.mkdir(parents=True, exist_ok=True)
            self._write({"version": SCHEMA_VERSION, "tasks": []})
        return self

    def _read(self):
        try:
            text = self.path.read_text(encoding="utf-8")
        except FileNotFoundError:
            return {"version": SCHEMA_VERSION, "updatedAt": None, "tasks": []}
        except OSError as exc:
            raise StoreError("读不了 %s：%s" % (self.path, exc))
        if not text.strip():
            return {"version": SCHEMA_VERSION, "updatedAt": None, "tasks": []}
        try:
            data = json.loads(text)
        except ValueError as exc:
            # 不静默吞掉 —— 早期版本在这里 return None，导致之后每次点击都无声失败
            raise StoreError("数据文件不是合法 JSON：%s（%s）" % (self.path.name, exc))
        if not isinstance(data, dict) or not isinstance(data.get("tasks"), list):
            raise StoreError("数据文件结构不对：缺少 tasks 数组")
        return data

    def _write(self, data):
        """原子写：临时文件 → fsync → os.replace（同目录，跨平台原子）。"""
        data = dict(data)
        data["version"] = SCHEMA_VERSION
        data["updatedAt"] = datetime.now().astimezone().isoformat(timespec="seconds")
        payload = json.dumps(data, ensure_ascii=False, indent=2) + "\n"

        self.path.parent.mkdir(parents=True, exist_ok=True)
        fd, tmp = tempfile.mkstemp(dir=str(self.path.parent), prefix=".tasks-", suffix=".tmp")
        try:
            with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as fh:
                fh.write(payload)
                fh.flush()
                os.fsync(fh.fileno())
            os.replace(tmp, str(self.path))
        except BaseException:
            try:
                os.unlink(tmp)
            except OSError:
                pass
            raise

    @contextmanager
    def _mutate(self, label=""):
        """锁内 读 → 交给调用方改 → 写回。异常时不落盘。"""
        with _file_lock(self.path):
            data = self._read()
            before = [dict(t) for t in data["tasks"]]
            yield data
            if data["tasks"] != before:
                self._push_undo(before, label)
                self._write(data)

    def _push_undo(self, tasks, label):
        self._undo.append(tasks)
        self._undo_labels.append(label)
        while len(self._undo) > self.MAX_UNDO:
            self._undo.pop(0)
            self._undo_labels.pop(0)

    # ---------------- 查询 ----------------

    def raw_tasks(self):
        return self._read()["tasks"]

    def raw_document(self):
        """整个文档，和文件内容一致。给需要原样拿到的调用方用（桌面小窗走这个）。"""
        return self._read()

    def day_view(self, day=None, base=None):
        """某一天该看到的东西。

        今天：今天的全部 + 更早日期里还没完成的（自动顺延，带天数）
        其他天：就只有那天的任务
        """
        base = base or today()
        day = day or base
        data = self._read()
        items = []

        for t in data["tasks"]:
            td = parse_day(t.get("date"))
            if td is None:
                continue
            status = t.get("status", "pending")
            if day == base:
                if td > day:
                    continue
                # 过去日期的任务只满足一个条件才出现在今天：还没做完，或者
                # 就是今天做完的（doneAt）。少了后面这半句，勾错了就没法取消
                # —— 任务会当场从列表里消失，只能翻回原日期去找它。
                if td < day and status == "done" and t.get("doneAt") != day.isoformat():
                    continue
            else:
                if td != day:
                    continue

            carried = (day - td).days if td < day else 0
            items.append({
                "id": t.get("id", ""),
                "title": t.get("title", ""),
                "date": t.get("date", ""),
                "status": status,
                "rev": int(t.get("rev", 1) or 1),
                "note": t.get("note", ""),
                "done": status == "done",
                "carriedDays": carried,
            })

        # 未完成保持文件顺序在前（文件顺序 = 用户手动排的优先级），已完成沉底
        pending = [i for i in items if not i["done"]]
        done = [i for i in items if i["done"]]
        ordered = pending + done

        return {
            "date": day.isoformat(),
            "label": human_day(day, base),
            "isToday": day == base,
            "updatedAt": data.get("updatedAt"),
            "stats": {
                "total": len(ordered),
                "pending": len(pending),
                "done": len(done),
                "carried": len([i for i in pending if i["carriedDays"] > 0]),
                "carriedMax": max([i["carriedDays"] for i in pending] or [0]),
            },
            "tasks": ordered,
            "future": self.future_summary(base, 7),
        }

    def future_summary(self, base=None, days=7):
        base = base or today()
        buckets = {}
        for t in self._read()["tasks"]:
            td = parse_day(t.get("date"))
            if td is None or td <= base:
                continue
            if (td - base).days > days:
                continue
            bucket = buckets.setdefault(td.isoformat(), {"total": 0, "pending": 0})
            bucket["total"] += 1
            if t.get("status", "pending") != "done":
                bucket["pending"] += 1
        return [
            {"date": k, "label": human_day(parse_day(k), base), **v}
            for k, v in sorted(buckets.items())
        ]

    def month_view(self, ym=None, base=None):
        """整月概览：每天有几件事、做完没有。

        界面上的月历副视图用它 —— 看的是「分布」，不是「今天做什么」。
        """
        base = base or today()
        if ym:
            try:
                year, month = int(str(ym)[:4]), int(str(ym)[5:7])
                first = date(year, month, 1)
            except (ValueError, IndexError):
                raise StoreError("月份格式应该是 YYYY-MM")
        else:
            first = base.replace(day=1)
            year, month = first.year, first.month

        nxt = date(year + 1, 1, 1) if month == 12 else date(year, month + 1, 1)

        doc = self._read()
        buckets = {}
        for t in doc["tasks"]:
            td = parse_day(t.get("date"))
            if td is None or not (first <= td < nxt):
                continue
            key = td.isoformat()
            bucket = buckets.setdefault(key, {"total": 0, "pending": 0, "done": 0, "tasks": []})
            bucket["total"] += 1
            done = t.get("status") == "done"
            if done:
                bucket["done"] += 1
            else:
                bucket["pending"] += 1
            bucket["tasks"].append({
                "id": t.get("id", ""),
                "title": t.get("title", ""),
                "date": key,
                "status": t.get("status", "pending"),
                "done": done,
                "rev": int(t.get("rev", 1) or 1),
            })

        cells = []
        for offset in range((nxt - first).days):
            d = first + timedelta(days=offset)
            info = buckets.get(d.isoformat()) or {"total": 0, "pending": 0, "done": 0, "tasks": []}
            overdue = d < base and info["pending"] > 0     # 逾期未完成 —— 会顺延到今天
            # 每天内部：未完成在前，已完成沉底（和天视图一致）
            rows = [x for x in info["tasks"] if not x["done"]] + [x for x in info["tasks"] if x["done"]]
            cells.append({
                "date": d.isoformat(), "day": d.day,
                "total": info["total"], "pending": info["pending"], "done": info["done"],
                "overdue": overdue,
                "tasks": rows,
            })

        return {
            "month": "%04d-%02d" % (year, month),
            "label": "%d 年 %d 月" % (year, month),
            "firstWeekday": first.isoweekday(),      # 1=周一 … 7=周日
            "today": base.isoformat(),
            "updatedAt": doc.get("updatedAt"),
            "cells": cells,
        }

    def review(self, days=7, base=None):
        """最近 N 天的完成情况 —— 给 agent 做复盘用的原始数据。

        这里只算数，不下结论。判断（任务太大？不想做？时机不对？）交给 agent。
        """
        base = base or today()
        start = base - timedelta(days=days - 1)
        data = self._read()

        per_day = {}
        for i in range(days):
            d = (start + timedelta(days=i)).isoformat()
            per_day[d] = {"done": 0, "total": 0}

        carried = []
        for t in data["tasks"]:
            td = parse_day(t.get("date"))
            if td is None:
                continue
            status = t.get("status", "pending")
            if start <= td <= base:
                per_day[td.isoformat()]["total"] += 1
                if status == "done":
                    per_day[td.isoformat()]["done"] += 1
            if status != "done" and td < base:
                carried.append({
                    "id": t.get("id", ""),
                    "title": t.get("title", ""),
                    "date": t.get("date", ""),
                    "carriedDays": (base - td).days,
                })

        carried.sort(key=lambda x: -x["carriedDays"])
        total_done = sum(v["done"] for v in per_day.values())
        total_planned = sum(v["total"] for v in per_day.values())

        return {
            "range": {"from": start.isoformat(), "to": base.isoformat(), "days": days},
            "perDay": [{"date": k, **v} for k, v in sorted(per_day.items())],
            "totalPlanned": total_planned,
            "totalDone": total_done,
            "carriedOver": carried,
            "stuck": [c for c in carried if c["carriedDays"] >= 3],
        }

    # ---------------- 内置工具 ----------------

    def _find(self, tasks, task_id):
        for t in tasks:
            if t.get("id") == task_id:
                return t
        return None

    def _next_id(self, tasks, day):
        stamp = day.strftime("%Y%m%d")
        pattern = re.compile(r"^t-%s-(\d+)$" % stamp)
        used = [int(m.group(1)) for t in tasks if (m := pattern.match(t.get("id", "")))]
        return "t-%s-%02d" % (stamp, max(used, default=0) + 1)

    def _touch(self, task):
        task["rev"] = int(task.get("rev", 1) or 1) + 1

    def _set_done(self, task, done):
        """完成时记下是哪天完成的（doneAt）。

        day_view 靠它判断「这条虽然是前几天的，但今天刚勾掉」——
        这样它今天还能留在列表里，勾错了能取消。
        """
        task["status"] = "done" if done else "pending"
        if done:
            task["doneAt"] = today().isoformat()
        else:
            task.pop("doneAt", None)
        self._touch(task)

    # ---------------- 变更 ----------------

    def add(self, title, day=None, note=""):
        title = (title or "").strip()
        if not title:
            raise StoreError("任务内容不能为空")
        day = day or today()
        if isinstance(day, str):
            day = parse_day(day)
        if day is None:
            raise StoreError("日期格式应为 YYYY-MM-DD")

        with self._mutate("添加") as data:
            task = {
                "id": self._next_id(data["tasks"], day),
                "title": title,
                "date": day.isoformat(),
                "status": "pending",
                "rev": 1,
            }
            if note:
                task["note"] = note
            data["tasks"].append(task)
        return task

    def toggle(self, task_id):
        with self._mutate("打勾") as data:
            task = self._find(data["tasks"], task_id)
            if task is None:
                raise StoreError("找不到任务 %s" % task_id)
            self._set_done(task, task.get("status") != "done")
            return {"id": task_id, "status": task["status"], "doneAt": task.get("doneAt")}

    def set_status(self, task_id, done):
        with self._mutate("标记") as data:
            task = self._find(data["tasks"], task_id)
            if task is None:
                raise StoreError("找不到任务 %s" % task_id)
            self._set_done(task, bool(done))
            return {"id": task_id, "status": task["status"], "doneAt": task.get("doneAt")}

    def rename(self, task_id, title):
        title = (title or "").strip()
        if not title:
            raise StoreError("新标题不能为空")
        with self._mutate("改名") as data:
            task = self._find(data["tasks"], task_id)
            if task is None:
                raise StoreError("找不到任务 %s" % task_id)
            task["title"] = title
            self._touch(task)
            return {"id": task_id, "title": title}

    def reschedule(self, task_id, day):
        if isinstance(day, str):
            day = parse_day(day)
        if day is None:
            raise StoreError("日期格式应为 YYYY-MM-DD")
        with self._mutate("改日期") as data:
            task = self._find(data["tasks"], task_id)
            if task is None:
                raise StoreError("找不到任务 %s" % task_id)
            task["date"] = day.isoformat()
            self._touch(task)
            return {"id": task_id, "date": task["date"]}

    def remove(self, task_id):
        with self._mutate("删除") as data:
            task = self._find(data["tasks"], task_id)
            if task is None:
                raise StoreError("找不到任务 %s" % task_id)
            data["tasks"] = [t for t in data["tasks"] if t.get("id") != task_id]
            return {"id": task_id, "title": task.get("title", "")}

    def reorder(self, ordered_ids, dragged_id=None):
        """把一组任务在文件里的槽位按新顺序重填。

        这组之外的任何任务，位置完全不动 —— 所以「排今天」不会打乱别天的顺序。
        """
        ids = [str(i) for i in (ordered_ids or []) if i]
        if len(ids) < 2:
            raise StoreError("至少要两条才能排序")
        if len(set(ids)) != len(ids):
            raise StoreError("排序列表里有重复的 id")

        with self._mutate("排序") as data:
            tasks = data["tasks"]
            index = {t.get("id"): t for t in tasks}
            for i in ids:
                if i not in index:
                    raise StoreError("找不到任务 %s" % i)
            slots = [t.get("id") for t in tasks if t.get("id") in ids]
            if len(slots) != len(ids):
                raise StoreError("排序列表和实际任务对不上")

            out, cursor = [], 0
            for t in tasks:
                if t.get("id") in ids:
                    out.append(index[ids[cursor]])
                    cursor += 1
                else:
                    out.append(t)
            data["tasks"] = out

            if dragged_id and dragged_id in index:
                self._touch(index[dragged_id])
            return {"ordered": ids}

    def undo(self):
        """撤销上一次改动（进程内，最多 20 步）。"""
        if not self._undo:
            raise StoreError("没有可撤销的操作")
        tasks = self._undo.pop()
        label = self._undo_labels.pop()
        with _file_lock(self.path):
            data = self._read()
            data["tasks"] = [dict(t) for t in tasks]
            self._write(data)
        return {"undo": label, "remaining": len(self._undo)}

    def can_undo(self):
        return len(self._undo) > 0

    # ---------------- 维护 ----------------

    def backup(self, suffix=None):
        if not self.path.exists():
            raise StoreError("还没有数据文件")
        stamp = suffix or datetime.now().strftime("%Y%m%d-%H%M%S")
        dest = self.path.with_name("%s.%s.bak" % (self.path.name, stamp))
        shutil.copy2(str(self.path), str(dest))
        return str(dest)
