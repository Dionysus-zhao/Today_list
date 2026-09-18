# tasks-sync.ps1 —— 桌面小窗（Windows 增强包）的数据层
#
# 重要：这个文件**不再直接读写 tasks.json**。
# 数据由 today-tasks 的本地服务（server.py）独占管理，小窗只是它的一个视图。
#
# 为什么改成走 HTTP：
#   · 小窗（Windows）、网页、agent 看到的是同一份数据，不会各存各的副本
#   · 只有服务一个写入口，不会出现「两边同时写、后写覆盖先写」
#   · 原子写、文件锁、损坏恢复都归服务管，小窗这边不用再操心
#
# 因此小窗必须在服务运行时才有内容；服务没起就显示离线提示。
#
# 需要以 UTF-8 with BOM 保存，否则 Windows PowerShell 5.1 按 GBK 解码会变乱码。

$script:ApiPort   = 17850
$script:ApiBase   = 'http://127.0.0.1:17850'
$script:UiUrl     = 'http://127.0.0.1:17850/'
$script:Available = $false

# 本机回环不走系统代理。有些机器配了 HTTP 代理，会把 127.0.0.1 也代理掉，
# 结果小窗永远连不上自己的服务（表现为「拿不到数据」）。
# 置空默认代理即可 —— 本进程只访问回环地址，没有别的网络请求。
try { [System.Net.WebRequest]::DefaultWebProxy = $null } catch {}

# ---------- 接口 ----------

function script:Set-ApiPort([int]$port) {
    $script:ApiPort = $port
    $script:ApiBase = ('http://127.0.0.1:{0}' -f $port)
    $script:UiUrl   = ('http://127.0.0.1:{0}/' -f $port)
}

function script:Get-UiUrl { return $script:UiUrl }

function script:Invoke-Api([string]$method, [string]$path, $body) {
    $params = @{
        Uri         = ($script:ApiBase + $path)
        Method      = $method
        TimeoutSec  = 8
        ErrorAction = 'Stop'
    }
    if ($null -ne $body) {
        # body 走请求体、不走 query string —— HttpListener 的 QueryString 按 GBK 解码，中文必乱。
        # ConvertTo-Json 会把中文转成 \uXXXX，服务端 json.loads 能正确还原。
        $json = $body | ConvertTo-Json -Depth 6 -Compress
        $params['Body']        = [System.Text.Encoding]::UTF8.GetBytes($json)
        $params['ContentType'] = 'application/json; charset=utf-8'
    }
    try {
        return (Invoke-RestMethod @params)
    } catch {
        return $null
    }
}

# 快速判断端口上有没有人在听。
# 不要直接用 Invoke-RestMethod 去试 —— 连一个没人监听的端口它会磨蹭 2 秒
# （真的量过），端口列表一多就是几十秒的启动延迟。TCP 连接被拒是毫秒级的。
function script:Test-PortOpen([int]$port, [int]$waitMs = 150) {
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $iar = $client.BeginConnect('127.0.0.1', $port, $null, $null)
        if (-not $iar.AsyncWaitHandle.WaitOne($waitMs)) { return $false }
        $client.EndConnect($iar)
        return $true
    } catch {
        return $false
    } finally {
        try { $client.Close() } catch {}
    }
}

# 探测服务端口：先用外部指定的（服务拉起小窗时会传），再依次试 17850 往上
function script:Find-ApiPort([int]$preferred = 0) {
    $cands = New-Object System.Collections.ArrayList
    if ($preferred -gt 0) { $null = $cands.Add($preferred) }
    for ($p = 17850; $p -le 17870; $p++) {
        if ($p -ne $preferred) { $null = $cands.Add($p) }
    }
    foreach ($p in $cands) {
        if (-not (Test-PortOpen $p)) { continue }   # 没监听，直接跳过
        Set-ApiPort $p
        $ping = Invoke-Api 'GET' '/api/ping' $null
        if ($null -ne $ping -and $ping.ok -and $ping.name -eq 'today-tasks') {
            $script:Available = $true
            return $p
        }
    }
    Set-ApiPort 17850
    $script:Available = $false
    return 0
}

function script:Test-Api {
    $ping = Invoke-Api 'GET' '/api/ping' $null
    $script:Available = ($null -ne $ping -and $ping.ok)
    return $script:Available
}

# ---------- 通用 ----------

function Get-Prop($obj, [string]$name, $default) {
    if ($null -eq $obj) { return $default }
    $p = $obj.PSObject.Properties[$name]
    if ($null -ne $p) { return $p.Value }
    return $default
}

# ---------- 读 ----------

# 返回结构：@{ version; updatedAt; tasks = @(...) }
# 元素字段：id / title / date / status / rev / note
function script:Get-TaskData {
    return (Invoke-Api 'GET' '/api/raw' $null)
}

# 数据版本号（服务端每次写入都会更新），用来判断「别人改了没有」
function script:Get-Stamp {
    $view = Invoke-Api 'GET' '/api/state' $null
    if ($null -eq $view) { return $null }
    return [string]$view.updatedAt
}

# 今天该显示的任务：今天的 + 更早日期里还没完成的（自动顺延）。
# 顺序规则：未完成在前（严格保持文件顺序，支持手动排序），已完成沉底。
function script:Get-TodayTasks($data) {
    $today = (Get-Date).ToString('yyyy-MM-dd')
    $list  = New-Object System.Collections.ArrayList
    if ($null -eq $data) { return @($list.ToArray()) }

    $all  = @($data.tasks)
    $all2 = @($all | Where-Object {
        $d = [string](Get-Prop $_ 'date' '')
        $s = [string](Get-Prop $_ 'status' 'pending')
        ($d -eq $today) -or ($d -lt $today -and $s -ne 'done')
    })

    foreach ($t in (@($all2 | Where-Object { (Get-Prop $_ 'status' 'pending') -ne 'done' }) + @($all2 | Where-Object { (Get-Prop $_ 'status' 'pending') -eq 'done' }))) {
        if ($null -eq $t) { continue }
        $d    = [string](Get-Prop $t 'date' '')
        $late = ($d -lt $today)
        $days = 0
        if ($late) {
            try {
                $days = [int]((Get-Date).Date - ([datetime]::ParseExact($d, 'yyyy-MM-dd', $null)).Date).TotalDays
            } catch { $days = 0 }
        }
        $null = $list.Add([pscustomobject]@{
            id          = [string](Get-Prop $t 'id' '')
            title       = [string](Get-Prop $t 'title' '')
            status      = [string](Get-Prop $t 'status' 'pending')
            date        = $d
            late        = $late
            carriedDays = $days
        })
    }
    return @($list.ToArray())
}

# 未来 N 天（不含今天）的任务，按日期分组返回
function script:Get-FutureTasks($data, [int]$days = 7) {
    $today = (Get-Date).ToString('yyyy-MM-dd')
    $end   = (Get-Date).AddDays($days).ToString('yyyy-MM-dd')
    $out   = New-Object System.Collections.ArrayList
    if ($null -eq $data) { return @($out.ToArray()) }

    $byDate = @{}
    foreach ($t in @($data.tasks)) {
        $d = [string](Get-Prop $t 'date' '')
        if ($d -gt $today -and $d -le $end) {
            if (-not $byDate.ContainsKey($d)) { $byDate[$d] = (New-Object System.Collections.ArrayList) }
            $null = $byDate[$d].Add([pscustomobject]@{
                id     = [string](Get-Prop $t 'id' '')
                title  = [string](Get-Prop $t 'title' '')
                status = [string](Get-Prop $t 'status' 'pending')
                date   = $d
                late   = $false
            })
        }
    }
    foreach ($d in ($byDate.Keys | Sort-Object)) {
        $items  = @($byDate[$d].ToArray())
        $sorted = @($items | Where-Object { $_.status -ne 'done' }) + @($items | Where-Object { $_.status -eq 'done' })
        $null = $out.Add([pscustomobject]@{ date = $d; items = $sorted })
    }
    return @($out.ToArray())
}

# ---------- 写（全部交给服务） ----------

function script:Toggle-Task([string]$id) {
    $r = Invoke-Api 'POST' '/api/toggle' @{ id = $id }
    return ($null -ne $r -and $r.ok)
}

function script:Add-Task([string]$title, [string]$date) {
    $body = @{ title = $title }
    if ($date) { $body['date'] = $date }
    $r = Invoke-Api 'POST' '/api/add' $body
    if ($null -eq $r -or -not $r.ok) { return $false }
    return $r
}

function script:Add-TodayTask([string]$title) {
    return [bool](Add-Task -Title $title -Date ((Get-Date).ToString('yyyy-MM-dd')))
}

function script:Rename-Task([string]$id, [string]$title) {
    $r = Invoke-Api 'POST' '/api/rename' @{ id = $id; title = $title }
    return ($null -ne $r -and $r.ok)
}

function script:Reschedule-Task([string]$id, [string]$date) {
    $r = Invoke-Api 'POST' '/api/reschedule' @{ id = $id; date = $date }
    return ($null -ne $r -and $r.ok)
}

# 删除。返回快照（Task / Index，形状与旧版一致）供调用方显示撤销提示；
# 真正的撤销动作由 Restore-Task 走服务端的 undo 栈完成。
function script:Remove-Task([string]$id) {
    $before = Get-TaskData
    $idx  = -1
    $task = $null
    if ($null -ne $before) {
        $items = @($before.tasks)
        for ($i = 0; $i -lt $items.Count; $i++) {
            if ((Get-Prop $items[$i] 'id' '') -eq $id) { $idx = $i; $task = $items[$i]; break }
        }
    }
    $r = Invoke-Api 'POST' '/api/remove' @{ id = $id }
    if ($null -eq $r -or -not $r.ok) { return $false }
    if ($null -eq $task) { $task = [pscustomobject]@{ id = $id; title = [string]$r.title } }
    return [pscustomobject]@{ Task = $task; Index = $idx }
}

function script:Restore-Task($snapshot) {
    if ($null -eq $snapshot) { return $false }
    $r = Invoke-Api 'POST' '/api/undo' @{}
    return ($null -ne $r -and $r.ok)
}

# 上移 / 下移一位：拉当前视图，算出新顺序，整组写回
function script:Move-Task([string]$id, [string]$dir) {
    $view = Invoke-Api 'GET' '/api/state' $null
    if ($null -eq $view) { return $false }

    $ids = @($view.tasks | Where-Object { -not $_.done } | ForEach-Object { [string]$_.id })
    $pos = [array]::IndexOf($ids, $id)
    if ($pos -lt 0) { return $false }

    $swap = -1
    if ($dir -eq 'up'   -and $pos -gt 0)                { $swap = $pos - 1 }
    if ($dir -eq 'down' -and $pos -lt ($ids.Count - 1)) { $swap = $pos + 1 }
    if ($swap -lt 0) { return $false }

    $new = New-Object System.Collections.ArrayList
    for ($i = 0; $i -lt $ids.Count; $i++) {
        if     ($i -eq $pos)  { $null = $new.Add($ids[$swap]) }
        elseif ($i -eq $swap) { $null = $new.Add($ids[$pos]) }
        else                  { $null = $new.Add($ids[$i]) }
    }
    return [bool](Reorder-Tasks -orderedIds ([string[]]@($new.ToArray())) -draggedId $id)
}

# 拖拽排序：整组按新顺序写回（服务端保证这组之外的槽位不动）
function script:Reorder-Tasks([string[]]$orderedIds, [string]$draggedId) {
    if ($null -eq $orderedIds -or $orderedIds.Count -lt 2) { return $false }
    $r = Invoke-Api 'POST' '/api/reorder' @{
        orderedIds = [string[]]$orderedIds
        draggedId  = $draggedId
    }
    return ($null -ne $r -and $r.ok)
}
