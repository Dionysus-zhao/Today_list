# today-tasks

一个装在你自己的机器上、数据存在你自己的文件里的每日清单。

两种用法，互不冲突：

- **直接使用** —— 起一个本地服务，浏览器里就是清单界面
- **接你自己的 agent** —— 它同时是个 MCP server，Claude / Cursor / 任何支持 MCP 的客户端都能直接读写你的任务

零依赖。不需要 `pip install` 任何东西，不需要数据库，不需要联网，不需要注册账号。

```
┌──────────────────────────────────────────┐
│  tasks.json   ← 就是一个文本文件，你的全部数据   │
└──────────────────────────────────────────┘
        ↑                    ↑
   浏览器界面           你的 agent
  (server.py)        (mcp_server.py)
```

---

## 30 秒上手

```bash
git clone <this-repo> today-tasks
cd today-tasks
python3 server.py
```

浏览器会自动打开。左边 `◀ ▶` 翻日期，底部输入框加任务，回车就行。

懒得敲命令就双击启动器：Windows 用 `start.bat`，macOS / Linux 用 `./start.sh`（首次可能要 `chmod +x start.sh`）。

> Windows 上一般用 `python` 或 `py` 代替 `python3`。
> 需要 Python 3.8+，macOS / Linux 基本都自带。

首次运行会在仓库目录下自动建一个空的 `tasks.json`。**没有注册、没有登录、没有联网。**

### 界面速查

**左边一整个月，右边选中那天的详情** —— 一屏看全月，又不用挤格子。

| 想做什么 | 怎么做 |
|---|---|
| 看某天 | 点左边那个格子，右边显示那天 |
| 加任务 | 右边底部输入框，回车（默认加到右边正在看的那天） |
| 加到别的天 | 先点左边那天，再输入；或者直接写「明天 xxx」 |
| 打勾 / 取消 | 点任务左边的小方块 |
| 改标题 | 双击任务文字，回车保存 / Esc 取消 |
| 删除 | 悬停任务右侧的 `×`（删错了点「撤销」） |
| 排顺序 | 右边列表里上下拖 —— 顺序就是优先级 |
| 挪到别的天 | 把任务从右边拖到左边的某个格子里 |
| 翻月份 | 顶部 `◀ ▶`，或 `Alt+←` / `Alt+→` |
| 回到今天 | 顶部的「回到今天」 |

左边格子里的小圆点：**蓝色** = 还没做，**红色** = 逾期没做，**淡绿** = 做完了；超过 6 个显示 `+N`。
那天全部做完，日期数字会变绿。

快捷键：`/` 聚焦输入框，`Alt+←` / `Alt+→` 翻月份。

### 想让它一直开着

服务是普通进程，让它在后台常驻就行：

```bash
python3 server.py --no-open      # --no-open：别弹浏览器
```

之后随时访问 `http://127.0.0.1:17850/`（收藏起来最方便）。

设成开机自启：

- **macOS**：`brew services` 或写个 LaunchAgent，指向上面的命令
- **Linux**：`systemd --user` 服务，或 crontab 里 `@reboot cd ~/today-tasks && python3 server.py --no-open`
- **Windows**：把 `python server.py --no-open` 存成 `.bat`（注意存成 CRLF 换行），然后丢进
  `Win+R` → `shell:startup` 打开的启动文件夹

开机自启之后，`tasks.json` 里做的事就是「数据在你自己机器上、开机就在那儿」。

### 输入框会认日期

直接写，它会自己理解：

| 你写的 | 存到 | 标题 |
|---|---|---|
| `买牛奶` | 今天 | 买牛奶 |
| `明天交周报` | 明天 | 交周报 |
| `周五 牙医` | 最近的周五 | 牙医 |
| `下周三 体检` | 下周三 | 体检 |
| `9/20 高铁票` | 9月20日 | 高铁票 |
| `12月25日 年会` | 12月25日 | 年会 |
| `今天的事` | 今天 | **今天的事**（整句都是标题） |

识别到日期时，输入框右侧会出现蓝色标签告诉你它存到哪天。

---

## 接到你的 agent 上

在 MCP 客户端的配置里加一段：

```json
{
  "mcpServers": {
    "today-tasks": {
      "command": "python3",
      "args": ["/绝对路径/today-tasks/mcp_server.py"]
    }
  }
}
```

Windows 把 `python3` 换成 `python`，路径写成 `C:/Users/你/today-tasks/mcp_server.py`。

想要独立的数据文件（不动默认的 `tasks.json`），加环境变量：

```json
"env": { "TODAY_TASKS_DATA": "/你/想/放/tasks.json" }
```

配好之后就可以直接说人话：

> 「明天下午三点前交周报」→ 它自己调 `add_task`
> 「今天的活儿都干完了吗」→ 它调 `list_tasks`
> 「把取快递提前，这个最急」→ 它调 `move_task`
> 「我这周是不是排太多了」→ 它调 `review` 拿到数据，再跟你分析

### 提供的工具

| 工具 | 用途 |
|---|---|
| `list_tasks` | 看某天（默认今天）的清单，含顺延下来的 |
| `list_upcoming` | 接下来几天各有什么 |
| `add_task` | 加任务，标题里可以带日期 |
| `complete_task` | 打勾 / 取消打勾 |
| `remove_task` | 删除 |
| `rename_task` | 改标题 |
| `reschedule_task` | 挪到别的日期 |
| `move_task` | 调整顺序（顺序就是优先级） |
| `review` | 最近 N 天的完成情况 + 积压任务，给 agent 做复盘用 |
| `undo` | 撤销上一次改动 |

任务可以用**标题片段**指代，不必记 id —— 说「把述职那条打勾」就行。

---

## Windows 增强包：桌面小窗

Windows 上还带一个置顶小窗（WPF，无边框、半透明、常驻桌面角落）。网页要你去点开，小窗是睁眼就在。

**它会自动出现。** 两种方式：

```bash
python3 server.py                # 服务 + 小窗（Windows 上自动拉起）
python3 server.py --no-widget    # 只要服务，不弹小窗
```

不过在 Windows 上，**双击 `start.bat` 是最省事的**：它在最小化窗口里起服务，
然后**由它自己**把小窗拉起来。

这一点不是随手写的，是个坑：**小窗必须从你的桌面会话启动。**
如果交给服务进程去拉，而那个服务恰好跑在服务/沙箱/别的会话里，
窗口会被建在一个看不见的 window station 上 —— `trace.log` 里明明写着「窗口已显示」，
你就是看不到任何窗口。所以别把「拉小窗」这件事只挂在服务身上。

其他平台没有这一步（WPF 是 Windows 专有），`--no-widget` 也会被忽略。

**关键：小窗和网页是同一份数据的两个视图。** 小窗不直接碰 `tasks.json`，
一律走本地服务的 HTTP 接口 —— 所以不会出现「两边各存一份、互相覆盖」，
也不会出现「关掉小窗数据服务就没了」。

小窗能做的事：

- 点整行打勾 / 取消，双击标题改名
- `▲ ▼` 或按住行拖拽排序（顺序就是优先级），拖到上下边缘自动滚动
- `×` 删除，8 秒内可撤销
- 底部输入框加任务，认日期前缀（`明天 交周报` / `周五 牙医` / `9/20 高铁票`）
- 右上角按钮跳到网页版；窗口位置会被记住
- 每 3 秒跟服务的版本号对一次，网页或 agent 改了什么，小窗立刻跟着变

服务没起的时候，小窗会直接说「连不上本地服务」，而不是显示成一个空清单让你以为任务丢了。

单独调试小窗（服务已在跑时）：

```powershell
powershell -sta -NoProfile -ExecutionPolicy Bypass -File desktop\desktop-widget.ps1 -Port 17850
```

改过小窗代码后跑一次自检（87 项：XAML / 接线审计 / 输入链路 / 完整拖拽链路 / 闭包作用域体检。
它会自己另起一个临时服务实例，用临时数据文件，不碰你的真实数据）：

```powershell
powershell -sta -NoProfile -ExecutionPolicy Bypass -File desktop\desktop-widget.ps1 -SelfTest
```

---

## 数据

全部数据就是一个文件：

```json
{
  "version": 1,
  "updatedAt": "2026-09-18T18:25:26+08:00",
  "tasks": [
    {
      "id": "t-20260918-01",
      "title": "练习述职稿件",
      "date": "2026-09-18",
      "status": "pending",
      "rev": 11,
      "doneAt": "2026-09-18"
    }
  ]
}
```

- `id` 唯一编号 · `title` 内容 · `date` 计划哪天做
- `status` `pending` / `done` · `doneAt` 哪天完成的
- `rev` 修订号，每次改动 +1
- `note` 可选备注

**为什么是文件而不是数据库**

- `git init` 一下，你就白拿了版本历史和跨设备同步 —— 二进制数据库做不到这点
- 记事本能打开、能手改，出问题你自己就能救
- 零依赖：clone 下来就能跑，不用先装驱动
- 这个规模（每天十几条）读进内存只要 1 毫秒，索引和查询优化收益是零

代价是「并发靠纪律」：所有写操作都在文件锁里完成，并且先写临时文件再原子替换，所以断电不会写出半截文件。够用，但如果你要多人同时编辑，那就该换后端了。

---

## 顺延规则

**没做完的事不用手动搬。** 打开今天的清单，所有 `date` 在今天之前、还没完成的任务会自动出现在里面，标着「顺延 N 天」。

- 今天做掉了 → 它**留在今天的列表里**（变灰），勾错了还能取消
- 没做 → 明天继续漂着，天数一直累加
- 一件事顺延到第 3 天以上，`review` 会专门把它挑出来

顺延不是惩罚，是镜子：一件事拖了三天，要么太大该拆，要么不想做该删，要么时机不对该挪。

---

## 常用命令

```bash
python3 server.py                    # 启动（默认 127.0.0.1:17850）
python3 server.py --port 9000        # 换端口
python3 server.py --no-open          # 不自动开浏览器
python3 server.py --data ~/me/tasks.json
python3 server.py --verbose          # 打印每个请求

python3 tests/test_store.py          # 数据层测试（33 项）
python3 tests/test_e2e.py            # 端到端：HTTP + MCP（18 项）
```

## HTTP 接口

界面用的就是这些，你也可以直接调（都在 `127.0.0.1`，不对外）：

```
GET  /api/ping
GET  /api/state?date=YYYY-MM-DD      某天的视图（含统计和顺延天数）
GET  /api/month?ym=YYYY-MM           整月概览，给月历副视图用
GET  /api/review?days=7              复盘数据
POST /api/parse      {raw}           解析一行口语，返回日期和标题
POST /api/add        {raw} | {title, date}
POST /api/complete   {id, done}
POST /api/toggle     {id}
POST /api/rename     {id, title}
POST /api/reschedule {id, date}
POST /api/remove     {id}
POST /api/reorder    {orderedIds, draggedId}
POST /api/undo       {}
```

中文一律走请求体（JSON），不要放 query string。

---

## 文件结构

```
today-tasks/
  store.py              数据层：读写、原子写、文件锁、顺延、排序、撤销
  server.py             本地服务：HTTP API + 界面（Windows 上还会拉起小窗）
  mcp_server.py         MCP server（stdio），给 agent 用
  web/index.html        界面，单文件、零依赖
  desktop/              Windows 增强包
    desktop-widget.ps1  置顶小窗（WPF）
    tasks-sync.ps1      小窗的数据层：全部走服务 HTTP，不碰文件
  start.bat             Windows 双击启动
  start.sh              macOS / Linux 启动
  tasks.json            你的数据（首次运行自动创建）
  tests/                测试
```

## 已经踩过的坑（改代码前建议看一眼）

- **`.replace()` 之前必须 fsync 且同目录**：临时文件放在别的分区，原子替换会退化成拷贝
- **星期基准别混**：`date.weekday()` 是周一=0，`isoweekday()` 是周一=1。混用会让「周五」算成周六
- **`X的Y` 不能拆日期**：「今天的事」整句是标题，不是「今天」+「的事」
- **顺延任务勾掉后要留在原地**：不然勾错了就没法取消，只能翻回原日期去找
- **MCP 的 stdout 是协议通道**：任何 `print` 都会破坏协议，日志只能走 stderr
- **stdio 程序不能接管道做诊断**：常驻进程的 stdout 被父进程管道继承后会一直堵着

## License

MIT
