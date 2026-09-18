#!/usr/bin/env python3
"""数据层测试：`python3 -m unittest discover -s tests -v`

不碰真实数据 —— 每个用例都在临时目录里跑。
"""

from __future__ import annotations

import json
import sys
import tempfile
import threading
import unittest
from datetime import date, timedelta
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from store import Store, StoreError, human_day, parse_day, parse_input, today  # noqa: E402


class StoreTestCase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.path = Path(self.tmp.name) / "tasks.json"
        self.store = Store(self.path).ensure()

    def tearDown(self):
        self.tmp.cleanup()

    def raw(self):
        return json.loads(self.path.read_text(encoding="utf-8"))

    # ---------------- 基础 ----------------

    def test_creates_file_and_is_valid_json(self):
        self.assertTrue(self.path.exists())
        data = self.raw()
        self.assertEqual(data["version"], 1)
        self.assertEqual(data["tasks"], [])
        self.assertIn("updatedAt", data)

    def test_add_and_reload(self):
        task = self.store.add("写周报")
        self.assertEqual(task["title"], "写周报")
        self.assertEqual(task["date"], today().isoformat())
        self.assertEqual(task["status"], "pending")

        again = Store(self.path)
        titles = [t["title"] for t in again.raw_tasks()]
        self.assertEqual(titles, ["写周报"])

    def test_id_is_unique_and_zero_padded(self):
        a = self.store.add("a")
        b = self.store.add("b")
        stamp = today().strftime("%Y%m%d")
        self.assertEqual(a["id"], "t-%s-01" % stamp)
        self.assertEqual(b["id"], "t-%s-02" % stamp)

    def test_empty_title_rejected(self):
        with self.assertRaises(StoreError):
            self.store.add("   ")

    # ---------------- 顺延 ----------------

    def test_carried_over_shows_up_today(self):
        old = today() - timedelta(days=2)
        self.store.add("两天前没做完的事", old)

        view = self.store.day_view()
        self.assertEqual(len(view["tasks"]), 1)
        self.assertEqual(view["tasks"][0]["carriedDays"], 2)
        self.assertEqual(view["stats"]["carried"], 1)

    def test_done_today_stays_visible_and_can_be_undone(self):
        """顺延过来的任务，今天勾掉之后必须还留在列表里 —— 否则勾错了没法取消。"""
        old = today() - timedelta(days=2)
        task = self.store.add("两天前没做完的事", old)
        self.store.set_status(task["id"], True)

        view = self.store.day_view()
        self.assertEqual(len(view["tasks"]), 1)
        self.assertTrue(view["tasks"][0]["done"])
        self.assertEqual(view["tasks"][0]["carriedDays"], 2)  # 拖了几天就如实说
        self.assertEqual(view["stats"]["carried"], 0)         # 但不再计入「待顺延」

        self.store.set_status(task["id"], False)
        self.assertFalse(self.store.day_view()["tasks"][0]["done"])

    def test_task_finished_before_today_is_not_shown(self):
        old = today() - timedelta(days=3)
        self.store.add("三天前就做完的", old)
        raw = self.raw()
        raw["tasks"][0]["status"] = "done"
        raw["tasks"][0]["doneAt"] = old.isoformat()
        self.path.write_text(json.dumps(raw, ensure_ascii=False), encoding="utf-8")
        self.assertEqual(self.store.day_view()["tasks"], [])

    def test_future_task_not_in_today(self):
        self.store.add("下周的事", today() + timedelta(days=5))
        view = self.store.day_view()
        self.assertEqual(view["tasks"], [])
        self.assertEqual(view["stats"]["total"], 0)

    def test_past_day_view_is_history(self):
        day = today() - timedelta(days=3)
        t = self.store.add("那天做的", day)
        self.store.set_status(t["id"], True)

        view = self.store.day_view(day)
        self.assertEqual(len(view["tasks"]), 1)
        self.assertTrue(view["tasks"][0]["done"])
        self.assertFalse(view["isToday"])

    def test_done_sinks_to_bottom(self):
        a = self.store.add("第一")
        self.store.add("第二")
        self.store.set_status(a["id"], True)

        view = self.store.day_view()
        self.assertEqual([t["title"] for t in view["tasks"]], ["第二", "第一"])

    # ---------------- 排序 ----------------

    def test_reorder_only_touches_given_group(self):
        tomorrow = today() + timedelta(days=1)
        t1 = self.store.add("今天一")
        t2 = self.store.add("今天二")
        t3 = self.store.add("今天三")
        other = self.store.add("明天的事", tomorrow)

        self.store.reorder([t3["id"], t1["id"], t2["id"]], t3["id"])

        ids = [t["id"] for t in self.store.raw_tasks()]
        self.assertEqual(ids, [t3["id"], t1["id"], t2["id"], other["id"]])

    def test_reorder_rejects_unknown_or_duplicate(self):
        t1 = self.store.add("一")
        t2 = self.store.add("二")
        with self.assertRaises(StoreError):
            self.store.reorder([t1["id"], "t-nope"])
        with self.assertRaises(StoreError):
            self.store.reorder([t1["id"], t1["id"]])
        with self.assertRaises(StoreError):
            self.store.reorder([t2["id"]])          # 少于两条
        self.assertEqual(len(self.store.raw_tasks()), 2)

    # ---------------- 撤销 ----------------

    def test_undo_restores_removed_task(self):
        t = self.store.add("会被误删的")
        self.store.remove(t["id"])
        self.assertEqual(self.store.raw_tasks(), [])
        self.store.undo()
        self.assertEqual([x["title"] for x in self.store.raw_tasks()], ["会被误删的"])

    def test_undo_works_for_toggle_and_reorder(self):
        a = self.store.add("甲")
        b = self.store.add("乙")
        self.store.reorder([b["id"], a["id"]], b["id"])
        self.store.undo()
        self.assertEqual([t["title"] for t in self.store.raw_tasks()], ["甲", "乙"])

        self.store.set_status(a["id"], True)
        self.store.undo()
        self.assertEqual(self.store.raw_tasks()[0]["status"], "pending")

    def test_undo_empty_raises(self):
        with self.assertRaises(StoreError):
            self.store.undo()

    # ---------------- 健壮性 ----------------

    def test_corrupt_file_raises_instead_of_silent_empty(self):
        self.path.write_text("{ this is not json", encoding="utf-8")
        with self.assertRaises(StoreError):
            self.store.raw_tasks()

    def test_write_leaves_no_temp_files(self):
        for i in range(5):
            self.store.add("任务 %d" % i)
        leftovers = [p.name for p in self.path.parent.iterdir() if p.suffix == ".tmp"]
        self.assertEqual(leftovers, [])
        self.assertEqual(len(self.raw()["tasks"]), 5)

    def test_rename_and_reschedule(self):
        t = self.store.add("原名")
        self.store.rename(t["id"], "新名")
        day = today() + timedelta(days=3)
        self.store.reschedule(t["id"], day)
        row = self.store.raw_tasks()[0]
        self.assertEqual(row["title"], "新名")
        self.assertEqual(row["date"], day.isoformat())
        self.assertGreater(row["rev"], 1)

    def test_missing_task_raises(self):
        with self.assertRaises(StoreError):
            self.store.toggle("t-does-not-exist")

    def test_concurrent_writers_do_not_lose_tasks(self):
        """10 个「进程」同时加任务，一条都不能丢。"""
        results = []
        errors = []

        def worker(n):
            try:
                independent = Store(self.path)
                task = independent.add("并发 %d" % n)
                results.append(task["id"])
            except Exception as exc:  # noqa: BLE001
                errors.append("%s: %s" % (type(exc).__name__, exc))

        threads = [threading.Thread(target=worker, args=(i,)) for i in range(10)]
        for t in threads:
            t.start()
        for t in threads:
            t.join()

        self.assertEqual(errors, [])
        stored = self.store.raw_tasks()
        self.assertEqual(len(stored), 10)
        self.assertEqual(len(set(t["id"] for t in stored)), 10)

    # ---------------- 复盘 ----------------

    def test_review_counts(self):
        for i in range(3):
            t = self.store.add("完成 %d" % i)
            self.store.set_status(t["id"], True)
        self.store.add("今天还没做的")                              # 不算顺延
        self.store.add("拖了很久的", today() - timedelta(days=5))
        self.store.add("昨天没做的", today() - timedelta(days=1))

        data = self.store.review(7)
        self.assertEqual(data["totalDone"], 3)
        self.assertEqual(len(data["carriedOver"]), 2)
        self.assertEqual(data["stuck"][0]["title"], "拖了很久的")

    # ---------------- 月历 ----------------

    def test_month_view_shape_and_counts(self):
        base = today()
        first = base.replace(day=1)
        month_end = (first.replace(day=28) + timedelta(days=4)).replace(day=1)

        self.store.add("月初的事", first)
        self.store.add("今天的事")
        done = self.store.add("明天要做的", base + timedelta(days=1))
        self.store.set_status(done["id"], True)

        view = self.store.month_view()
        self.assertEqual(view["month"], base.strftime("%Y-%m"))
        self.assertEqual(view["firstWeekday"], first.isoweekday())
        self.assertEqual(len(view["cells"]), (month_end - first).days)
        self.assertEqual(view["today"], base.isoformat())

        cells = {c["date"]: c for c in view["cells"]}
        self.assertEqual(cells[base.isoformat()]["pending"], 1)
        self.assertEqual(cells[(base + timedelta(days=1)).isoformat()]["done"], 1)
        self.assertEqual(cells[first.isoformat()]["total"], 1)

    def test_month_view_explicit_ym_and_bad_input(self):
        view = self.store.month_view("2026-01")
        self.assertEqual(view["month"], "2026-01")
        self.assertEqual(view["firstWeekday"], date(2026, 1, 1).isoweekday())
        self.assertEqual(len(view["cells"]), 31)

        with self.assertRaises(StoreError):
            self.store.month_view("nope")

    def test_month_cells_carry_task_details(self):
        """月历格子里要能直接画出任务，所以每个 cell 得带上明细。"""
        first = today().replace(day=1)
        second = first + timedelta(days=1)
        self.store.add("第一天的事", first)
        done = self.store.add("第二天的事", second)
        self.store.set_status(done["id"], True)

        cells = {c["date"]: c for c in self.store.month_view()["cells"]}
        cell1 = cells[first.isoformat()]
        self.assertEqual([x["title"] for x in cell1["tasks"]], ["第一天的事"])
        self.assertFalse(cell1["tasks"][0]["done"])
        for key in ("id", "title", "date", "status", "done", "rev"):
            self.assertIn(key, cell1["tasks"][0])

        cell2 = cells[second.isoformat()]
        self.assertEqual(len(cell2["tasks"]), 1)
        self.assertTrue(cell2["tasks"][0]["done"])
        self.assertEqual(cell2["pending"], 0)
        self.assertEqual(cell2["done"], 1)

    def test_month_lists_pending_before_done(self):
        day = today().replace(day=1) + timedelta(days=2)
        done = self.store.add("先做的", day)
        self.store.set_status(done["id"], True)
        self.store.add("还没做的", day)

        cell = {c["date"]: c for c in self.store.month_view()["cells"]}[day.isoformat()]
        self.assertEqual([x["title"] for x in cell["tasks"]], ["还没做的", "先做的"])

    def test_month_marks_overdue(self):
        base = today()
        first = base.replace(day=1)
        if base.day == 1:
            self.skipTest("今天是 1 号，本月没有已过的日期")
        self.store.add("本月初没做的", first)
        self.store.add("今天才加的")

        cells = {c["date"]: c for c in self.store.month_view()["cells"]}
        self.assertTrue(cells[first.isoformat()]["overdue"])
        self.assertFalse(cells[base.isoformat()]["overdue"])


class ParseInputTestCase(unittest.TestCase):
    def test_plain_title_has_no_date(self):
        p = parse_input("买牛奶")
        self.assertFalse(p["hasDate"])
        self.assertEqual(p["title"], "买牛奶")
        self.assertEqual(p["date"], today())

    def test_relative_days(self):
        for word, delta in (("今天", 0), ("明天", 1), ("后天", 2), ("大后天", 3)):
            p = parse_input("%s 交周报" % word)
            self.assertTrue(p["hasDate"], word)
            self.assertEqual(p["date"], today() + timedelta(days=delta))
            self.assertEqual(p["title"], "交周报")

    def test_weekday(self):
        p = parse_input("周五 复盘")
        self.assertTrue(p["hasDate"])
        self.assertEqual(p["date"].weekday(), 4)
        self.assertEqual(p["title"], "复盘")

    def test_next_week(self):
        p = parse_input("下周三 体检")
        self.assertTrue(p["hasDate"])
        self.assertEqual(p["date"].weekday(), 2)
        self.assertGreater((p["date"] - today()).days, 0)

    def test_month_day(self):
        p = parse_input("9/20 高铁票")
        self.assertTrue(p["hasDate"])
        self.assertEqual((p["date"].month, p["date"].day), (9, 20))
        self.assertEqual(p["title"], "高铁票")

        p = parse_input("12月25日 年会")
        self.assertEqual((p["date"].month, p["date"].day), (12, 25))
        self.assertEqual(p["title"], "年会")

    def test_date_only_returns_no_title(self):
        p = parse_input("明天")
        self.assertTrue(p["hasDate"])
        self.assertIsNone(p["title"])

    def test_no_separator_needed(self):
        p = parse_input("明天交周报")
        self.assertTrue(p["hasDate"])
        self.assertEqual(p["title"], "交周报")

    def test_possessive_title_is_not_split(self):
        """「今天的事」「明天的会议」整体都是标题 —— 「X的Y」不能拆。"""
        for raw in ("今天的事", "明天的会议", "昨天的复盘", "周五的例会"):
            p = parse_input(raw)
            self.assertFalse(p["hasDate"], raw)
            self.assertEqual(p["title"], raw)

    def test_explicit_separator_always_splits(self):
        p = parse_input("今天 的事")
        self.assertTrue(p["hasDate"])
        self.assertEqual(p["title"], "的事")


if __name__ == "__main__":
    unittest.main(verbosity=2)
