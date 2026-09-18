# desktop-widget.ps1 —— 今日任务桌面插件
#
# 无边框、透明、置顶的小窗口，显示今天的任务（含自动顺延）和未来 7 天预览。
#
# 它是 today-tasks 的 Windows 增强包：**数据不归它管**，一律走本地服务
# （server.py）的 HTTP 接口 —— 小窗、网页、agent 看到的是同一份数据，
# 而且只有服务一个写入入口。服务没起时窗口里会明说，不会显示成空清单。
# 零依赖：Windows 自带 .NET/WPF，不需要装任何东西。
#
# 用法：
#   双击「启动.bat」                          正常启动
#   powershell -File 本文件 -SelfTest         自检（不弹窗）
#
# 注意：本文件需以 UTF-8 with BOM 保存。

param(
    [switch]$SelfTest,      # 自检模式：不弹窗、不启定时器，只跑断言
    [int]$Port = 0          # 服务端口。0 = 自己探测（服务拉起小窗时会显式传进来）
)

$Self = $MyInvocation.MyCommand.Path
# 仓库根目录（本文件在 desktop/ 下）—— 自检要起临时服务实例时用来找 server.py
$script:RepoRoot = Split-Path -Parent (Split-Path -Parent $Self)

# ---------- 启动留痕 ----------
# 历史上出现过「双击了但什么都没发生、也查不到原因」。
# 从脚本第一行起就把每一步记进 trace.log：只要双击过，就一定留痕，
# 之后凭时间戳就能判断是「根本没启动」还是「启动了但窗口没出来」。
$script:TraceFile = Join-Path (Split-Path -Parent $Self) 'trace.log'
function script:Boot-Trace([string]$msg) {
    try {
        [System.IO.File]::AppendAllText($script:TraceFile,
            ((Get-Date).ToString('yyyy-MM-dd HH:mm:ss') + '  ' + $msg + "`r`n"),
            (New-Object System.Text.UTF8Encoding($false)))
    } catch {}
}
script:Boot-Trace ('---- boot  pid=' + $PID + '  argv=' + ($MyInvocation.Line))

# ---------- 必须是 STA（WPF 要求） ----------
if ([System.Threading.Thread]::CurrentThread.GetApartmentState().ToString() -ne 'STA') {
    script:Boot-Trace 'not-STA -> relaunching with -sta'
    $a = @('-sta', '-WindowStyle', 'Hidden', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $Self))
    if ($SelfTest) {
        $a += '-SelfTest'
        Start-Process -FilePath 'powershell.exe' -ArgumentList $a -Wait -NoNewWindow | Out-Null
    } else {
        Start-Process -FilePath 'powershell.exe' -ArgumentList $a | Out-Null
    }
    exit
}

# ---------- 数据层 ----------
# 小窗不直接读写数据文件 —— 一切通过本地服务（server.py）的 HTTP 接口。
# 所以第一步是找到服务在哪：优先用外部传进来的端口，否则从 17850 往上探测。
. (Join-Path (Split-Path -Parent $Self) 'tasks-sync.ps1')
$script:ApiFound = Find-ApiPort $Port
if ($script:ApiFound -gt 0) {
    script:Boot-Trace ('data-layer loaded, service at 127.0.0.1:' + $script:ApiFound)
} else {
    script:Boot-Trace 'data-layer loaded, but NO local service (offline)'
}

# ---------- 加载 WPF ----------
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml -ErrorAction Stop
script:Boot-Trace 'wpf assemblies loaded'

$script:PosFile = Join-Path (Split-Path -Parent $Self) 'window.json'
$script:ErrFile = Join-Path (Split-Path -Parent $Self) 'error.log'
$script:BC      = New-Object System.Windows.Media.BrushConverter

# ---------- 跨事件共享的 UI 状态 ----------
# 必须放 $global:，不能放 $script:。原因是行内那些处理器（按下/移动/抬起/双击/悬停/打勾）
# 全是用 `.GetNewClosure()` 造的闭包，而闭包有**自己的作用域**。实测结论：
#   · 闭包内 `$script:X = v` 写不回外部脚本作用域（外层读到的还是旧值）
#   · 闭包内读 `$script:X` 恒为 $null（连 hashtable 变量本身都读不到）
# 这个坑曾造成：按下时记的拖拽状态移动时读不到 → 拖拽永远不启动；
# 按下时说好「别打勾」抬起时读不到 → 拖一下顺手把任务勾了。
# 所以凡是**跨事件共享**的状态一律放这张全局哈希表（引用类型，各闭包副本指向同一对象）。
# 控件引用不必进表：闭包创建前用局部变量接一下就行（同上，引用共享同一控件）。
$global:TTW = @{
    # 控件引用（闭包内读不到 $script:，只能从这张表取）
    Window         = $null
    List           = $null
    ListScroll     = $null
    # 拖拽 / 编辑状态
    DragSrcId      = $null   # 按下的那一行 id
    DragRow        = $null   # 按下的那一行对象（拖动中做半透明）
    DragAnchorX    = 0.0     # 按下位置（窗口坐标）
    DragAnchorY    = 0.0
    DragThreshold  = 8.0     # 超过多少像素才算拖动（抓握条 3px，行空白 8px）
    DragActive     = $false  # 是否已真的进入拖动
    SuppressToggle = $false  # 这次抬起不许当成「点了一下打勾」
    DropTargetId   = ''      # 当前落点对应的任务 id
    DropAfter      = $false  # 落点在该行的上面还是下面
    DropMarkRow    = $null   # 落点指示所在的行
    DropMarkAfter  = $false
    EditRowId      = $null   # 正在双击改名的行 id
}

# 自检模式：不弹任何对话框、不真的拉浏览器、不启定时器，只跑断言
$script:TestMode   = $false
$script:LastAction = ''

# 出错时把异常写到 error.log，方便排查（窗口是 Hidden 的，看不见报错）
trap {
    try {
        $msg = (Get-Date).ToString('s') + " [trap]`n" + $_.Exception.ToString() + "`n"
        [System.IO.File]::AppendAllText($script:ErrFile, $msg, (New-Object System.Text.UTF8Encoding($false)))
    } catch {}
    continue
}

function script:Brush([string]$hex) { return $script:BC.ConvertFromString($hex) }
function script:Th([double]$n) { return (New-Object System.Windows.Thickness($n)) }
function script:Log-Err([string]$where, $ex) {
    try {
        $msg = (Get-Date).ToString('s') + ' [' + $where + "]`n" + $ex.ToString() + "`n"
        [System.IO.File]::AppendAllText($script:ErrFile, $msg, (New-Object System.Text.UTF8Encoding($false)))
    } catch {}
}

# ---------- 界面 ----------
$Xaml = @'
<Window
  xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
  xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
  Title="今日任务"
  WindowStyle="None"
  AllowsTransparency="True"
  Background="Transparent"
  ResizeMode="NoResize"
  ShowInTaskbar="False"
  Topmost="True"
  Width="322"
  SizeToContent="Height"
  MaxHeight="700"
  SnapsToDevicePixels="True"
  WindowStartupLocation="Manual">
  <Window.Resources>
    <Style x:Key="IconBtn" TargetType="Button">
      <Setter Property="Width" Value="22"/>
      <Setter Property="Height" Value="22"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Foreground" Value="#8B9099"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd" Background="{TemplateBinding Background}" CornerRadius="5">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bd" Property="Background" Value="#F0F2F6"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>
  <Border Margin="10" CornerRadius="14" Background="#FFFFFF"
          BorderBrush="#E6E8EC" BorderThickness="1">
    <Border.Effect>
      <DropShadowEffect Color="#000000" BlurRadius="18" ShadowDepth="0" Opacity="0.13"/>
    </Border.Effect>
    <Grid Margin="14,12,14,8">
      <Grid.RowDefinitions>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
      </Grid.RowDefinitions>

      <Grid Grid.Row="0" x:Name="DragBar" Background="Transparent">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <TextBlock x:Name="DateText" Grid.Column="0" Text="--"
                   FontSize="14" FontWeight="SemiBold" Foreground="#1F2329"
                   VerticalAlignment="Center" ToolTip="v3.1 · 拖这里移动窗口"/>
        <Button x:Name="CalBtn"   Grid.Column="1" Style="{StaticResource IconBtn}"
                Content="&#9638;" ToolTip="打开完整日历" Margin="0,0,2,0"/>
        <Button x:Name="CloseBtn" Grid.Column="2" Style="{StaticResource IconBtn}"
                Content="&#10005;" ToolTip="关闭"/>
      </Grid>

      <Grid Grid.Row="1" Margin="0,4,0,6">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <TextBlock x:Name="StatText" Grid.Column="0" Text="" FontSize="11"
                   Foreground="#8B9099" VerticalAlignment="Center"/>
        <Border x:Name="DateChip" Grid.Column="1" Background="#EAF1FF" CornerRadius="8"
                Padding="6,1,6,1" Visibility="Collapsed">
          <TextBlock x:Name="DateChipText" FontSize="10" Foreground="#3B6FD4" Text=""/>
        </Border>
      </Grid>

      <Border x:Name="ToastBar" Grid.Row="2" Margin="0,0,0,8" Padding="8,6,8,6"
              Background="#FFF6E0" CornerRadius="8" Visibility="Collapsed">
        <Grid>
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="Auto"/>
            <ColumnDefinition Width="Auto"/>
          </Grid.ColumnDefinitions>
          <TextBlock x:Name="ToastText" Grid.Column="0" FontSize="11" Foreground="#8A6100"
                     VerticalAlignment="Center" TextWrapping="Wrap" Text=""/>
          <Button x:Name="ToastBtn" Grid.Column="1" Content="撤销" FontSize="11"
                  Foreground="#1F6FEB" Background="Transparent" BorderThickness="0"
                  Padding="6,0,2,0" Cursor="Hand" ToolTip="放回原来的位置"/>
          <TextBlock x:Name="ToastTick" Grid.Column="2" FontSize="10" Foreground="#B08A2E"
                     VerticalAlignment="Center" Text=""/>
        </Grid>
      </Border>

      <ScrollViewer x:Name="ListScroll" Grid.Row="3" MaxHeight="330"
                    VerticalScrollBarVisibility="Auto"
                    HorizontalScrollBarVisibility="Disabled"
                    PanningMode="VerticalOnly"
                    Background="Transparent">
        <StackPanel x:Name="List" Background="Transparent"/>
      </ScrollViewer>

      <Border x:Name="FutureHeader" Grid.Row="4" Padding="2,5,2,2"
              Background="Transparent" Cursor="Hand" Visibility="Collapsed">
        <TextBlock x:Name="FutureHeaderText" FontSize="11" Foreground="#8B9099" Text=""/>
      </Border>

      <Border x:Name="FutureBox" Grid.Row="5" Visibility="Collapsed">
        <ScrollViewer MaxHeight="140" VerticalScrollBarVisibility="Auto"
                      HorizontalScrollBarVisibility="Disabled" PanningMode="VerticalOnly">
          <StackPanel x:Name="FutureList"/>
        </ScrollViewer>
      </Border>

      <Grid Grid.Row="6" Margin="0,8,0,0">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <Grid Grid.Column="0">
          <TextBox x:Name="AddBox" Height="28" FontSize="12.5"
                   VerticalContentAlignment="Center" Padding="9,0,9,0"
                   BorderBrush="#E6E8EC" BorderThickness="1"
                   Background="#FFFFFF" Foreground="#1F2329" MaxLength="120">
            <TextBox.Resources>
              <Style TargetType="{x:Type Border}">
                <Setter Property="CornerRadius" Value="8"/>
              </Style>
            </TextBox.Resources>
          </TextBox>
          <TextBlock x:Name="AddHint" Text="加一件事，回车确认" FontSize="12"
                     Foreground="#B7BCC4" Margin="10,0,0,0"
                     VerticalAlignment="Center" IsHitTestVisible="False"/>
        </Grid>
        <Button x:Name="AddBtn" Grid.Column="1" Content="添加" Height="28"
                Padding="11,0,11,0" Margin="7,0,0,0" FontSize="12"
                Background="#F0F2F6" Foreground="#4A5058"
                BorderThickness="0" Cursor="Hand">
          <Button.Resources>
            <Style TargetType="{x:Type Border}">
              <Setter Property="CornerRadius" Value="8"/>
            </Style>
          </Button.Resources>
        </Button>
      </Grid>

      <TextBlock Grid.Row="7" Text="点整行打勾 · 双击改标题 · 按住任务拖动排序"
                 FontSize="10" Foreground="#B7BCC4" Margin="0,7,0,0"/>
    </Grid>
  </Border>
</Window>
'@

# ---------- 输入解析：支持「明天 xxx」「周五 xxx」「9/20 xxx」 ----------

function script:Parse-Input([string]$raw) {
    $today = Get-Date
    $def   = $today.ToString('yyyy-MM-dd')
    $out   = @{ title = ($raw + ''); date = $def; label = '' }

    $t = ($raw + '').Trim()
    if (-not $t) { return $out }

    $map = @{ '一' = 1; '二' = 2; '三' = 3; '四' = 4; '五' = 5; '六' = 6; '日' = 0; '天' = 0 }
    $dte = $null
    $lbl = ''
    $sep = '[\s:：,，、]*'

    if ($t -match ('^今天' + $sep)) {
        $dte = $today; $lbl = '今天'
    } elseif ($t -match ('^(明天|明日|明早)' + $sep)) {
        $dte = $today.AddDays(1); $lbl = '明天'
    } elseif ($t -match ('^大后天' + $sep)) {
        $dte = $today.AddDays(3); $lbl = '大后天'
    } elseif ($t -match ('^后天' + $sep)) {
        $dte = $today.AddDays(2); $lbl = '后天'
    } elseif ($t -match ('^(下下周|下下星期|下下礼拜|下周|下星期|下礼拜|周|星期|礼拜)\s*([一二三四五六日天])' + $sep)) {
        $prefix  = [string]$Matches[1]
        $dayCh   = [string]$Matches[2]
        $target  = $map[$dayCh]
        $diff    = ($target - [int]$today.DayOfWeek + 7) % 7
        if ($prefix.StartsWith('下下')) {
            $lbl = '下下周' + $dayCh
            if ($diff -eq 0) { $diff = 7 } else { $diff = $diff + 14 }
        } elseif ($prefix.StartsWith('下')) {
            $lbl = '下周' + $dayCh
            if ($diff -eq 0) { $diff = 7 } else { $diff = $diff + 7 }
        } else {
            $lbl = '周' + $dayCh
        }
        $dte = $today.AddDays($diff)
    } elseif ($t -match ('^(\d{1,2})\s*[月/.\-]\s*(\d{1,2})\s*[日号]?' + $sep)) {
        $mo = [int]$Matches[1]; $dd = [int]$Matches[2]
        if ($mo -ge 1 -and $mo -le 12 -and $dd -ge 1 -and $dd -le 31) {
            try { $dte = (Get-Date -Year $today.Year -Month $mo -Day $dd) } catch { $dte = $null }
            if ($null -ne $dte -and $dte.Date -lt $today.Date) {
                try { $dte = (Get-Date -Year ($today.Year + 1) -Month $mo -Day $dd) } catch { $dte = $null }
            }
            if ($null -ne $dte) { $lbl = ('{0}月{1}日' -f $mo, $dd) }
        }
    }

    if ($null -eq $dte) { return $out }

    $rest = $t.Substring($Matches[0].Length).Trim()
    if ([string]::IsNullOrWhiteSpace($rest)) { return $out }

    $out.date  = $dte.ToString('yyyy-MM-dd')
    $out.title = $rest
    $out.label = $lbl
    return $out
}

function script:Day-Label([datetime]$d) {
    $today = (Get-Date).Date
    $diff  = [int]($d.Date - $today).TotalDays
    $wd    = @('日','一','二','三','四','五','六')[[int]$d.DayOfWeek]
    $base  = ('{0}/{1} 周{2}' -f $d.Month, $d.Day, $wd)
    if ($diff -eq 1) { return ('明天 · ' + $base) }
    if ($diff -eq 2) { return ('后天 · ' + $base) }
    return $base
}

# ---------- 渲染 ----------

# 判断事件源头是否在 Button 内部。
# 注意：Content 为纯文字的按钮，OriginalSource 往往是按钮模板里的 TextBlock，
# 直接判断 -is [Button] 会漏判，必须沿可视树向上找。
function script:Test-InInteractive($src) {
    # 沿可视树向上找，判断坐标点落在「按钮 / 输入框 / 勾选框」上。
    # 行的打勾、双击、起拖都必须避开这些控件，否则会抢走它们自己的交互。
    while ($null -ne $src) {
        if ($src -is [System.Windows.Controls.Button]) { return $true }
        if ($src -is [System.Windows.Controls.Primitives.ToggleButton]) { return $true }
        if ($src -is [System.Windows.Controls.TextBox]) { return $true }
        try { $src = [System.Windows.Media.VisualTreeHelper]::GetParent($src) } catch { return $false }
    }
    return $false
}

# 判断事件源头是否落在「⠿ 抓握条」上（抓握条是拖动排序的明确入口）。
# 抓握条刻意做成 Border 而不是 Button：Button 会跟行级拖动逻辑抢鼠标按下事件，
# 而且按钮被点击时本身还会产生 Click 语义，没必要。
function script:Test-InGrip($src) {
    while ($null -ne $src) {
        try {
            if ($src -is [System.Windows.FrameworkElement] -and [string]$src.Tag -eq 'drag-grip') { return $true }
        } catch {}
        try { $src = [System.Windows.Media.VisualTreeHelper]::GetParent($src) } catch { return $false }
    }
    return $false
}

# 构建一行任务。$AllowMove：是否给 ▲▼ 排序按钮和 ⠿ 抓握条（未来任务区两者都不给）。
# 注意：函数内所有 .Add() 都必须用 $null = 接住返回值（WPF 的 Add 返回索引），
# 否则返回值会漏进管道，函数就变成返回数组，外层 Add 直接报「找不到重载」。
function script:New-TaskRow($item, [int]$FontSize = 13, [bool]$AllowMove = $true) {
    $done  = ($item.status -eq 'done')
    $rowId = [string]$item.id
    $title = [string]$item.title

    $row = New-Object System.Windows.Controls.Border
    $row.Tag = $rowId            # 落点计算与自检都靠它找回这一行对应的任务
    $row.Cursor = 'Hand'
    $row.Padding = New-Object System.Windows.Thickness(4, 6, 4, 6)
    $row.Background = (Brush '#FFFFFF')
    $row.Margin = New-Object System.Windows.Thickness(0, 0, 0, 1)

    $grid = New-Object System.Windows.Controls.Grid
    $c1 = New-Object System.Windows.Controls.ColumnDefinition; $c1.Width = 'Auto'
    $c2 = New-Object System.Windows.Controls.ColumnDefinition; $c2.Width = '*'
    $c3 = New-Object System.Windows.Controls.ColumnDefinition; $c3.Width = 'Auto'
    $null = $grid.ColumnDefinitions.Add($c1)
    $null = $grid.ColumnDefinitions.Add($c2)
    $null = $grid.ColumnDefinitions.Add($c3)

    $cb = New-Object System.Windows.Controls.CheckBox
    $cb.IsChecked = $done
    $cb.VerticalAlignment = 'Center'
    $cb.Margin = New-Object System.Windows.Thickness(0, 0, 8, 0)
    $cb.IsHitTestVisible = $false
    [System.Windows.Controls.Grid]::SetColumn($cb, 0)
    $null = $grid.Children.Add($cb)

    # 正常态：标题 + 顺延标签
    $sp = New-Object System.Windows.Controls.StackPanel
    $sp.Orientation = 'Horizontal'
    $sp.VerticalAlignment = 'Center'

    $tb = New-Object System.Windows.Controls.TextBlock
    $tb.Text = $title
    $tb.FontSize = $FontSize
    $tb.TextWrapping = 'Wrap'
    $tb.MaxWidth = 170
    $tb.VerticalAlignment = 'Center'
    if ($done) {
        $tb.TextDecorations = [System.Windows.TextDecorations]::Strikethrough
        $tb.Foreground = (Brush '#8B9099')
    } else {
        $tb.Foreground = (Brush '#1F2329')
    }
    $null = $sp.Children.Add($tb)

    if ($item.late -and -not $done) {
        $tag = New-Object System.Windows.Controls.Border
        $tag.Background = (Brush '#FDECEC')
        $tag.CornerRadius = New-Object System.Windows.CornerRadius(9)
        $tag.Padding = New-Object System.Windows.Thickness(5, 1, 5, 1)
        $tag.Margin = New-Object System.Windows.Thickness(6, 0, 0, 0)
        $tag.VerticalAlignment = 'Center'
        $tt = New-Object System.Windows.Controls.TextBlock
        try {
            $d = [datetime]::ParseExact([string]$item.date, 'yyyy-MM-dd', $null)
            $tt.Text = ('顺延 {0}/{1}' -f $d.Month, $d.Day)
        } catch {
            $tt.Text = '顺延'
        }
        $tt.FontSize = 10
        $tt.Foreground = (Brush '#E5484D')
        $tag.Child = $tt
        $null = $sp.Children.Add($tag)
    }

    [System.Windows.Controls.Grid]::SetColumn($sp, 1)
    $null = $grid.Children.Add($sp)

    # 编辑态：标题输入框（默认隐藏）
    $eb = New-Object System.Windows.Controls.TextBox
    $eb.Text = $title
    $eb.FontSize = $FontSize
    $eb.Visibility = 'Collapsed'
    $eb.Padding = New-Object System.Windows.Thickness(5, 2, 5, 2)
    $eb.BorderBrush = (Brush '#3B6FD4')
    $eb.BorderThickness = (Th 1)
    $eb.Background = (Brush '#FFFFFF')
    $eb.Foreground = (Brush '#1F2329')
    $eb.MaxLength = 120
    $eb.VerticalAlignment = 'Center'
    [System.Windows.Controls.Grid]::SetColumn($eb, 1)
    $null = $grid.Children.Add($eb)

    # 操作按钮组：▲ 上移 / ▼ 下移 / × 删除，悬停才出现
    $ops = New-Object System.Windows.Controls.StackPanel
    $ops.Orientation = 'Horizontal'
    $ops.VerticalAlignment = 'Center'
    $ops.Visibility = 'Hidden'
    [System.Windows.Controls.Grid]::SetColumn($ops, 2)

    $moveBtns = @()

    # 抓握条 ⠿：鼠标悬停时跟着操作按钮一起出现，按住它就能拖动整行排序。
    # 没有它的话「这一行可以拖」是完全不可见的 —— 用户不会凭空想到去拖任务行。
    if ($AllowMove -and -not $done) {
        $grip = New-Object System.Windows.Controls.Border
        $grip.Tag = 'drag-grip'
        $grip.Cursor = 'SizeAll'
        $grip.Width = 11
        $grip.VerticalAlignment = 'Center'
        $grip.Margin = New-Object System.Windows.Thickness(0, 0, 2, 0)
        # 背景必须是实色或 Transparent：Background 为 null 的 Border 不参与命中测试，
        # 那样鼠标按到抓握条上会直接穿过去，等于抓握条不存在。
        $grip.Background = (Brush 'Transparent')
        $grip.ToolTip = '按住拖动，把这条排到别的位置'
        $gt = New-Object System.Windows.Controls.TextBlock
        $gt.Text = '⠿'
        $gt.FontSize = 11
        $gt.Foreground = (Brush '#C6CCD5')
        $gt.VerticalAlignment = 'Center'
        $gt.HorizontalAlignment = 'Center'
        $grip.Child = $gt
        $null = $ops.Children.Add($grip)
    }
    if ($AllowMove -and -not $done) {
        foreach ($spec in @(@('▲', '上移一位', 'up'), @('▼', '下移一位', 'down'))) {
            $mb = New-Object System.Windows.Controls.Button
            $mb.Content = $spec[0]
            $mb.ToolTip = $spec[1]
            $mb.FontSize = 9
            $mb.Foreground = (Brush '#9AA1AB')
            $mb.Background = (Brush 'Transparent')
            $mb.BorderThickness = (Th 0)
            $mb.Padding = New-Object System.Windows.Thickness(2, 0, 2, 0)
            $mb.Margin = New-Object System.Windows.Thickness(1, 0, 0, 0)
            $mb.Cursor = 'Hand'
            $dir = $spec[2]
            # 这里绝不能拦 PreviewMouseLeftButtonDown/Up：
            # 一旦拦下「按下」，WPF 的 ButtonBase 收不到 MouseLeftButtonDown → 不捕获鼠标、
            # 也吞不掉「抬起」→ Click 永不触发，抬起事件还会冒泡到行上被执行成「打勾」。
            # 防止拖动逻辑抢按钮点击，靠的是行级 Test-InInteractive，不是按钮自己拦截。
            $mb.Add_Click({ Do-Move -Id $rowId -Dir $dir; Refresh-Now }.GetNewClosure())
            $null = $ops.Children.Add($mb)
            $moveBtns += $mb
        }
    }

    $del = New-Object System.Windows.Controls.Button
    $del.Content = '×'
    $del.FontSize = 14
    $del.Foreground = (Brush '#C6CCD5')
    $del.Background = (Brush 'Transparent')
    $del.BorderThickness = (Th 0)
    $del.Padding = New-Object System.Windows.Thickness(3, 0, 3, 0)
    $del.Margin = New-Object System.Windows.Thickness(2, 0, 0, 0)
    $del.Cursor = 'Hand'
    $del.ToolTip = '移除这条'
    # 同上：不拦 Preview 事件，否则 Click 不触发
    $del.Add_Click({ Do-Remove -Id $rowId }.GetNewClosure())
    $null = $ops.Children.Add($del)

    $null = $grid.Children.Add($ops)

    $row.Child = $grid

    # ---------- 拖拽排序（仅未完成且允许移动的行） ----------
    # 闭包创建前先把窗口 / 列表引用接成局部变量：闭包内读不到外层脚本作用域的变量
    # （见文件顶部说明），但局部引用会被 GetNewClosure 复制，且副本指向同一个控件。
    $W  = $global:TTW.Window
    $L  = $global:TTW.List
    $LS = $global:TTW.ListScroll
    if ($AllowMove -and -not $done) {
        # 标记「这一行可以排序」——Find-DropRow 靠它筛落点。
        # 不用 AllowDrop：那是会向下继承的依赖属性，已完成的行会被误判成可落点。
        $row | Add-Member -MemberType NoteProperty -Name 'Sortable' -Value $true -Force

        # 按下：只登记待拖状态，不打扰单击打勾 / 双击编辑
        $row.Add_PreviewMouseLeftButtonDown({
            param($s, $e)
            if ($e.ClickCount -gt 1) { return }
            $G = $global:TTW
            if ($null -ne $G.EditRowId -and $G.EditRowId -ne '') { return }
            $onGrip = Test-InGrip $e.OriginalSource
            $pt = $e.GetPosition($W)
            if (-not (Begin-RowDrag $row $rowId $pt.X $pt.Y $onGrip (Test-InInteractive $e.OriginalSource))) { return }
            # 抓住鼠标：按下的同时指针滑出行外也能继续拖。
            # 不抓的话，指针一离开这一行预览移动事件就不再来了，拖动永远起不来。
            try { $null = $row.CaptureMouse() } catch {}
        }.GetNewClosure())

        # 移动：超过阈值才进入拖动，拖动中实时算落点（手工拖拽，不走 OLE 拖放）
        $row.Add_PreviewMouseMove({
            param($s, $e)
            $pt   = $e.GetPosition($W)
            $down = ($e.LeftButton -eq [System.Windows.Input.MouseButtonState]::Pressed)
            $st   = Update-RowDrag $rowId $down $pt.X $pt.Y ($e.GetPosition($L).Y) ($e.GetPosition($LS).Y)
            if ($st -eq 'move') { $e.Handled = $true }   # 拖动中吞掉移动，避免顺带选中文本
        }.GetNewClosure())

        # 抬起：拖过就按落点写回顺序，并且**必须吞掉这次抬起** ——
        # 否则行级的打勾逻辑会接住它，把任务勾掉（历史 bug）。
        # 注意顺序：先 Finish（读完状态）再释放捕获（释放会触发 LostMouseCapture 复位状态）。
        $row.Add_PreviewMouseLeftButtonUp({
            param($s, $e)
            $consumed = Finish-RowDrag $rowId
            try { $row.ReleaseMouseCapture() } catch {}
            if ($consumed) { $e.Handled = $true }
        }.GetNewClosure())

        # 捕获被抢走（例如别的窗口抢焦点）时复位状态，避免留下「拖动中」的残影
        $row.Add_LostMouseCapture({
            param($s, $e)
            if ($global:TTW.DragSrcId -eq $rowId) { Cancel-RowDrag }
        }.GetNewClosure())
    }

    # 编辑态的保存 / 取消
    # 注意：$commit / $cancel 也是闭包，同样不能用 $script:（读不到外部脚本作用域）
    $commit = {
        $G = $global:TTW
        if ($G.EditRowId -ne $rowId) { return }
        $G.EditRowId = $null
        $newText = $eb.Text
        if ($newText.Trim() -and $newText.Trim() -ne $title) {
            $null = Rename-Task -Id $rowId -Title $newText
        }
        Invoke-Refresh
    }.GetNewClosure()

    $cancel = {
        $G = $global:TTW
        if ($G.EditRowId -ne $rowId) { return }
        $G.EditRowId = $null
        Invoke-Refresh
    }.GetNewClosure()

    $eb.Add_KeyDown({
        param($s, $e)
        if ($e.Key -eq 'Return') { $e.Handled = $true; & $commit }
        elseif ($e.Key -eq 'Escape') { $e.Handled = $true; & $cancel }
    }.GetNewClosure())
    $eb.Add_LostFocus({ param($s, $e) & $commit }.GetNewClosure())
    # 编辑框不拦 Preview 事件：行级的打勾/双击/起拖已经用 Test-InInteractive 排除了输入框，
    # 在这里拦反而会干扰 TextBox 自己的双击选词、光标定位。

    # 双击进入编辑
    $row.Add_PreviewMouseLeftButtonDown({
        param($s, $e)
        if ($e.ClickCount -ne 2) { return }
        $G = $global:TTW
        if ($null -ne $G.EditRowId -and $G.EditRowId -ne '') { return }
        if (Test-InInteractive $e.OriginalSource) { return }
        $G.EditRowId = $rowId
        $sp.Visibility = 'Collapsed'
        $eb.Text = $title
        $eb.Visibility = 'Visible'
        $e.Handled = $true
        # 强制先布局再聚焦，而不是丢给 Dispatcher 延迟执行。
        # 原因：BeginInvoke(priority, [action]{...}) 在 PowerShell 5.1 里重载解析会踩坑，
        # 委托被传成 null → ArgumentNullException（error.log 里抓到过这个异常），
        # 结果双击改名直接失灵。UpdateLayout 是同步的，等价且更稳。
        $eb.UpdateLayout()
        $null = $eb.Focus()
        $eb.SelectAll()
    }.GetNewClosure())

    $row.Add_MouseEnter({
        param($s, $e)
        if ($global:TTW.EditRowId -eq $rowId) { return }
        $s.Background = (Brush '#F7F8FA'); $ops.Visibility = 'Visible'
    }.GetNewClosure())
    $row.Add_MouseLeave({
        param($s, $e)
        if ($global:TTW.EditRowId -eq $rowId) { return }
        $s.Background = (Brush '#FFFFFF'); $ops.Visibility = 'Hidden'
    }.GetNewClosure())

    # 点整行打勾（点在按钮/输入框/抓握条上不算——否则点 ▲▼× 会顺手把这行勾掉）
    # 「拖过之后不许打勾」由 PreviewMouseLeftButtonUp 里的 Finish-RowDrag 直接吞掉抬起事件，
    # 走不到这里；所以这里只剩纯粹的一次点击。
    $row.Add_MouseLeftButtonUp({
        param($s, $e)
        try { $row.ReleaseMouseCapture() } catch {}
        if ($null -ne $global:TTW.EditRowId -and $global:TTW.EditRowId -ne '') { return }
        if (Test-InInteractive $e.OriginalSource) { return }
        if (Test-InGrip $e.OriginalSource) { return }
        $null = Toggle-Task -Id $rowId
        Refresh-Now
    }.GetNewClosure())

    return , $row
}

function script:Invoke-Refresh {
    if ($null -eq $script:Window) { return }
    # 显式 [System.Action] + InvokeAsync：避免 BeginInvoke(priority, [action]{}) 的重载歧义
    $act = [System.Action]{ Refresh-Now }
    $null = $script:Window.Dispatcher.InvokeAsync($act, [System.Windows.Threading.DispatcherPriority]::Background)
}

function script:Do-Move([string]$id, [string]$dir) {
    $null = Move-Task -Id $id -Dir $dir
}

# 打开网页版界面（同一个服务、同一份数据；TestMode 下不真拉浏览器，只记录动作供断言）
function script:Open-Calendar {
    if ($script:TestMode) { $script:LastAction = 'open-calendar'; return }
    Start-Process -FilePath (Get-UiUrl)
}

# ---------- 拖拽排序的辅助 ----------

# 插入位置指示：目标行的上沿或下沿画一条 2px 蓝线
function script:Set-DropMark($Row, [bool]$After) {
    $G = $global:TTW
    if ($G.DropMarkRow -eq $Row -and $G.DropMarkAfter -eq $After) { return }
    Clear-DropMark
    $G.DropMarkRow   = $Row
    $G.DropMarkAfter = $After
    if ($After) { $Row.BorderThickness = New-Object System.Windows.Thickness(0, 0, 0, 2) }
    else        { $Row.BorderThickness = New-Object System.Windows.Thickness(0, 2, 0, 0) }
    $Row.BorderBrush = (Brush '#3B6FD4')
}

function script:Clear-DropMark {
    $G = $global:TTW
    if ($null -ne $G.DropMarkRow) {
        try {
            $G.DropMarkRow.BorderThickness = New-Object System.Windows.Thickness(0)
            $G.DropMarkRow.BorderBrush = (Brush 'Transparent')
        } catch {}
        $G.DropMarkRow = $null
    }
}

# 判断这一行是不是「可排序的行」（未完成、允许移动）。
# 用 PowerShell 附加属性 Sortable 标记，而**不是** WPF 的 AllowDrop：
# AllowDrop 是**会向下继承**的依赖属性——容器一旦设成 True，
# 里面连已完成的行读出来也是 True，落点会算到根本不能排的行上（历史 bug）。
function script:Is-SortableRow($row) {
    if (-not ($row -is [System.Windows.FrameworkElement])) { return $false }
    $p = $row.PSObject.Properties['Sortable']
    if ($null -eq $p) { return $false }
    return [bool]$p.Value
}

# 在容器里按 Y 坐标找落点行：落在某行上半 = 插到它前面，下半 = 插到它后面；
# 落在所有行下方（列表末尾的空白）= 接到最后一行之后。
# $rowH / $topStep 只在自检里显式传：自检环境的窗口从未真正显示过，布局跑不出来
# （ActualHeight 与 TranslatePoint 恒为 0），上半行/下半行就分不出来，
# 于是用「每行等高、依次排列」的合成几何去验证落点规则本身。
function script:Find-DropRow($container, [double]$y, [double]$rowH = 0, [double]$topStep = 0) {
    $idx  = 0
    $last = $null
    foreach ($c in @($container.Children)) {
        if (-not ($c -is [System.Windows.Controls.Border])) { continue }
        $h = $rowH
        if ($h -le 0) { $h = [double]$c.ActualHeight }
        if ($h -le 0) { $h = 24 }
        $top = 0.0
        if ($topStep -gt 0) {
            $top = $idx * $topStep
        } else {
            try { $top = [double]$c.TranslatePoint((New-Object System.Windows.Point(0, 0)), $container).Y } catch { $top = 0 }
        }
        $idx++
        if (-not (Is-SortableRow $c)) { continue }   # 已完成的行不是落点
        if ($y -lt ($top + $h / 2)) { return @{ Row = $c; After = $false } }
        $last = $c
    }
    if ($null -ne $last) { return @{ Row = $last; After = $true } }
    return $null
}

# 拖动时指针贴近列表上下边缘就自动滚动，否则任务一多就拖不到看不见的位置。
# 参数是「指针在滚动区内的 Y」，不依赖拖拽事件参数 —— 自检也能喂坐标进来。
function script:Auto-ScrollList([double]$yInScroll) {
    try {
        $sv = $script:ListScroll
        if ($null -eq $sv -or $sv.ScrollableHeight -le 0) { return }
        if ($yInScroll -lt 20) { $sv.ScrollToVerticalOffset([Math]::Max(0, $sv.VerticalOffset - 10)); return }
        if ($yInScroll -gt ($sv.ActualHeight - 20)) {
            $sv.ScrollToVerticalOffset([Math]::Min($sv.ScrollableHeight, $sv.VerticalOffset + 10))
        }
    } catch {}
}

# ---------- 拖拽排序的核心逻辑（手工实现，不走 OLE 拖放） ----------
# 为什么不用 [DragDrop]::DoDragDrop：那条链路依赖 WPF 的 OLE 拖放，
# 而 DragEventArgs 在非交互会话里根本构造不出来 → 落点计算、顺序写回这些
# 真正出过 bug 的地方，自检永远跑不到。手工拖拽（按下记锚点 → 移动算落点 →
# 抬起写回）全程都是普通代码路径，自检可以直接喂坐标把整条链路跑一遍。

# 按下：登记「这一行可能要被拖」。返回 $true 表示进入待拖状态。
# $interactive：按在 ▲▼× 这些控件上；$onGrip：按在 ⠿ 抓握条上。
function script:Begin-RowDrag($row, [string]$rowId, [double]$x, [double]$y, [bool]$onGrip, [bool]$interactive) {
    # 按在按钮上：这一下交给按钮自己，既不算拖、也不算打勾
    if ($interactive -and -not $onGrip) {
        $global:TTW.DragSrcId      = $null
        $global:TTW.SuppressToggle = $false
        return $false
    }
    $G = $global:TTW
    $G.DragSrcId      = $rowId
    $G.DragRow        = $row
    $G.DragAnchorX    = $x
    $G.DragAnchorY    = $y
    $G.DragActive     = $false
    $G.DragThreshold  = 8.0
    $G.SuppressToggle = $false
    # 抓握条是明确的「我要排序」信号：阈值更小，且这次抬起绝不能算成打勾
    if ($onGrip) { $G.DragThreshold = 3.0; $G.SuppressToggle = $true }
    return $true
}

# 移动：超过阈值才真正进入拖动；拖动中实时算落点并画指示线。
# 返回 'idle'（还没到阈值，什么都不该做）/ 'move'（已在拖动）/ 'cancel'（键已松开）
function script:Update-RowDrag([string]$rowId, [bool]$leftDown, [double]$x, [double]$y, [double]$listY, [double]$scrollY, [double]$rowH = 0, [double]$topStep = 0) {
    $G = $global:TTW
    if ($G.DragSrcId -ne $rowId) { return 'idle' }
    if (-not $leftDown) { Cancel-RowDrag; return 'cancel' }
    if (-not $G.DragActive) {
        $dx = [Math]::Abs($x - $G.DragAnchorX)
        $dy = [Math]::Abs($y - $G.DragAnchorY)
        if ($dx -lt $G.DragThreshold -and $dy -lt $G.DragThreshold) { return 'idle' }
        $G.DragActive     = $true
        $G.SuppressToggle = $true    # 拖过了就不能再算「点了一下」
        try { $G.DragRow.Opacity = 0.45 } catch {}
        $script:LastAction = 'drag-begin'   # 自检观察点
    }
    Auto-ScrollList $scrollY
    $t = Find-DropRow $script:List $listY $rowH $topStep
    if ($null -eq $t) { Clear-DropMark }
    else {
        Set-DropMark -Row $t.Row -After ([bool]$t.After)
        $G.DropTargetId = [string]$t.Row.Tag
        $G.DropAfter    = [bool]$t.After
    }
    return 'move'
}

# 抬起：真的拖动过就按落点写回顺序；没拖过就只是普通点击（放行给打勾）。
# 返回 $true 表示这次抬起已被拖拽消费掉，调用方**必须**标记 Handled ——
# 否则行级的打勾逻辑会接住这次抬起，把任务勾掉（历史 bug）。
function script:Finish-RowDrag([string]$rowId) {
    $G = $global:TTW
    if ($G.DragSrcId -ne $rowId) { return $false }
    $wasActive = [bool]$G.DragActive
    $srcId     = [string]$G.DragSrcId
    $targetId  = [string]$G.DropTargetId
    $after     = [bool]$G.DropAfter
    $suppress  = [bool]$G.SuppressToggle
    Cancel-RowDrag
    if (-not $wasActive) { return $suppress }   # 抓握条上点一下：不打勾，也没什么可写回
    if ($targetId) { Complete-Drop -SrcId $srcId -TargetId $targetId -After $after }
    $script:LastAction = 'drag-drop'
    return $true
}

# 复位所有拖拽状态（取消拖动 / 丢捕获 / 收尾都走这里）
function script:Cancel-RowDrag {
    $G = $global:TTW
    if ($null -ne $G.DragRow) { try { $G.DragRow.Opacity = 1 } catch {} }
    Clear-DropMark
    $G.DragSrcId      = $null
    $G.DragRow        = $null
    $G.DragActive     = $false
    $G.DropTargetId   = ''
    $G.DropAfter      = $false
    $G.SuppressToggle = $false
}

# （原先的 Handle-RowDragOver / Handle-RowDrop 已删除：那是给 OLE 拖放的
#   DragOver / Drop 事件用的。现在拖拽是手工实现 —— 落点在 Update-RowDrag 里算、
#   顺序写回走 Finish-RowDrag —— 两者都是普通函数，自检可以直接喂坐标验证。）

# 落点确定：把 srcId 插到 targetId 前/后，整组顺序写回 tasks.json
function script:Complete-Drop([string]$SrcId, [string]$TargetId, [bool]$After) {
    if (-not $SrcId -or -not $TargetId) { return }
    if ($SrcId -eq $TargetId) { return }
    $list = Get-TodayTasks (Get-TaskData)
    $ids  = New-Object System.Collections.ArrayList
    foreach ($it in $list) { if ($it.status -ne 'done') { $null = $ids.Add([string]$it.id) } }
    if ($ids.IndexOf($SrcId) -lt 0 -or $ids.IndexOf($TargetId) -lt 0) { return }
    $ids.Remove($SrcId)
    $pos = $ids.IndexOf($TargetId)
    if ($After) { $pos++ }
    $ids.Insert($pos, $SrcId)
    $null = Reorder-Tasks -orderedIds ([string[]]@($ids.ToArray())) -draggedId $SrcId
    # 走 Dispatcher 异步刷新：在 Drop 处理器里同步重建整棵列表，
    # 等于在拖放操作还没收尾时就把落点那行从可视树上拆掉，容易出怪问题。
    Invoke-Refresh
}

function script:Render-Future {
    $groups = Get-FutureTasks (Get-TaskData) 7
    $total  = 0
    foreach ($g in $groups) { $total += @($g.items).Count }

    if ($total -eq 0) {
        $script:FutureHeader.Visibility = 'Collapsed'
        $script:FutureBox.Visibility    = 'Collapsed'
        return
    }

    $script:FutureHeader.Visibility = 'Visible'
    $arrow = '▸'
    if ($script:FutureOpen) { $arrow = '▾' }
    $script:FutureHeaderText.Text = ('未来 7 天 · {0} 件  {1}' -f $total, $arrow)

    if (-not $script:FutureOpen) {
        $script:FutureBox.Visibility = 'Collapsed'
        return
    }

    $script:FutureBox.Visibility = 'Visible'
    $script:FutureList.Children.Clear()
    foreach ($g in $groups) {
        $head = New-Object System.Windows.Controls.TextBlock
        try {
            $d = [datetime]::ParseExact([string]$g.date, 'yyyy-MM-dd', $null)
            $head.Text = Day-Label $d
        } catch {
            $head.Text = [string]$g.date
        }
        $head.FontSize = 10.5
        $head.FontWeight = 'SemiBold'
        $head.Foreground = (Brush '#8B9099')
        $head.Margin = New-Object System.Windows.Thickness(3, 5, 0, 1)
        $null = $script:FutureList.Children.Add($head)

        foreach ($it in @($g.items)) {
            try {
                $r = New-TaskRow $it 12 $false
                if ($r -is [System.Windows.Controls.Border]) {
                    $null = $script:FutureList.Children.Add($r)
                } else {
                    Log-Err 'Render-Future/row-type' (New-Object System.Exception(('New-TaskRow 返回 ' + $r.GetType().FullName)))
                }
            } catch {
                Log-Err 'Render-Future/row' $_.Exception
            }
        }
    }
}

function script:Refresh-Now {
    if ($null -eq $script:Window) { return }
    try {
        # 每次刷新都记下数据版本，避免轮询器马上再刷一遍
        $newStamp = Get-Stamp
        if ($newStamp) { $script:Stamp = $newStamp }

        $d = Get-Date
        $script:DateText.Text = ('{0}月{1}日 周{2}' -f $d.Month, $d.Day, @('日','一','二','三','四','五','六')[[int]$d.DayOfWeek])

        $data = Get-TaskData
        if ($null -eq $data) {
            # 连不上服务就直说，别让用户对着空列表猜「是不是任务丢了」
            $script:List.Children.Clear()
            $script:StatText.Foreground = (Brush '#E5484D')
            $script:StatText.Text = '连不上本地服务：先双击 start.bat（或跑 python server.py）'
            $script:FutureHeader.Visibility = 'Collapsed'
            $script:FutureBox.Visibility = 'Collapsed'
            return
        }
        $script:StatText.Foreground = (Brush '#8B9099')

        $global:TTW.EditRowId = $null
        $list = Get-TodayTasks $data
        $script:List.Children.Clear()

        $total = $list.Count
        $doneN = @($list | Where-Object { $_.status -eq 'done' }).Count
        $lateN = @($list | Where-Object { $_.late -and $_.status -ne 'done' }).Count

        if ($total -eq 0) {
            $empty = New-Object System.Windows.Controls.TextBlock
            $empty.Text = '今天还没有安排'
            $empty.FontSize = 12
            $empty.Foreground = (Brush '#B7BCC4')
            $empty.Margin = New-Object System.Windows.Thickness(2, 10, 0, 10)
            $null = $script:List.Children.Add($empty)
            $script:StatText.Text = ''
        } else {
            $s = ('共 {0} 项 · 已完成 {1}' -f $total, $doneN)
            if ($lateN -gt 0) { $s += (' · 顺延 {0}' -f $lateN) }
            $script:StatText.Text = $s
            foreach ($it in $list) {
                try {
                    $r = New-TaskRow $it 13 $true
                    if ($r -is [System.Windows.Controls.Border]) {
                        $null = $script:List.Children.Add($r)
                    } else {
                        Log-Err 'Refresh-Now/row-type' (New-Object System.Exception(('New-TaskRow 返回 ' + $r.GetType().FullName)))
                    }
                } catch {
                    Log-Err 'Refresh-Now/row' $_.Exception
                }
            }
        }

        Render-Future
    } catch {
        Log-Err 'Refresh-Now' $_.Exception
    }
}

# ---------- Toast（撤销 / 提示 通用） ----------

function script:Show-Toast([string]$kind, [string]$msg, $snap, [int]$sec) {
    $script:ToastKind = $kind
    $script:UndoSnap  = $snap
    $script:UndoLeft  = $sec
    if ($kind -eq 'undo') {
        $script:ToastBar.Background    = (Brush '#FFF6E0')
        $script:ToastText.Foreground   = (Brush '#8A6100')
        $script:ToastTick.Foreground   = (Brush '#B08A2E')
        $script:ToastBtn.Visibility    = 'Visible'
    } else {
        $script:ToastBar.Background    = (Brush '#E8F7EE')
        $script:ToastText.Foreground   = (Brush '#1D7A46')
        $script:ToastTick.Foreground   = (Brush '#58A97B')
        $script:ToastBtn.Visibility    = 'Collapsed'
    }
    $script:ToastText.Text = $msg
    $script:ToastTick.Text = (' {0}s' -f $sec)
    $script:ToastBar.Visibility = 'Visible'
    $script:UndoTimer.Start()
}

function script:Hide-Toast {
    $script:UndoTimer.Stop()
    $script:UndoSnap = $null
    $script:ToastBar.Visibility = 'Collapsed'
}

function script:Show-Undo($snap) {
    $ttl = [string](Get-Prop $snap.Task 'title' '')
    if ($ttl.Length -gt 12) { $ttl = $ttl.Substring(0, 12) + '…' }
    Show-Toast 'undo' ('已移除「' + $ttl + '」') $snap 8
}

function script:Show-Info([string]$msg, [int]$sec = 5) {
    Show-Toast 'info' $msg $null $sec
}

function script:Do-Undo {
    $snap = $script:UndoSnap
    if ($null -eq $snap) { return }
    $ok = Restore-Task $snap
    Hide-Toast
    if ($ok) { Refresh-Now }
}

function script:Do-Remove([string]$id) {
    $data = Get-TaskData
    if ($null -eq $data) { return }
    $hit = @($data.tasks) | Where-Object { (Get-Prop $_ 'id' '') -eq $id } | Select-Object -First 1
    if ($null -eq $hit) { return }

    $ttl = [string](Get-Prop $hit 'title' '这条任务')
    if (-not $script:TestMode) {
        $ans = [System.Windows.MessageBox]::Show(
            ('确定移除「{0}」？' -f $ttl),
            '移除任务',
            [System.Windows.MessageBoxButton]::YesNo,
            [System.Windows.MessageBoxImage]::Question)
        if ($ans -ne [System.Windows.MessageBoxResult]::Yes) { return }
    }

    $snap = Remove-Task -Id $id
    if ($snap) { Show-Undo $snap }
    Refresh-Now
}

# ---------- 新增 ----------

function script:Update-DateChip {
    if ($null -eq $script:DateChip) { return }
    $p = Parse-Input $script:AddBox.Text
    if ($p.label) {
        try {
            $dt = [datetime]::ParseExact([string]$p.date, 'yyyy-MM-dd', $null)
            $script:DateChipText.Text = ('{0} {1}/{2}' -f $p.label, $dt.Month, $dt.Day)
            $script:DateChip.Visibility = 'Visible'
        } catch {
            $script:DateChip.Visibility = 'Collapsed'
        }
    } else {
        $script:DateChip.Visibility = 'Collapsed'
    }
}

function script:Do-Add {
    $raw = $script:AddBox.Text
    $p = Parse-Input $raw
    if ([string]::IsNullOrWhiteSpace($p.title)) {
        if ([string]::IsNullOrWhiteSpace($raw)) { return }
        Show-Info '只写了日期，没写要做的事，没加上' 5
        return
    }
    $new = Add-Task -Title ([string]$p.title) -Date ([string]$p.date)
    if (-not $new) {
        Show-Info '写入失败，tasks.json 可能损坏' 6
        return
    }
    $script:AddBox.Clear()
    Update-DateChip
    $today = (Get-Date).ToString('yyyy-MM-dd')
    if ([string]$p.date -ne $today) {
        $script:FutureOpen = $true
        try {
            $dt = [datetime]::ParseExact([string]$p.date, 'yyyy-MM-dd', $null)
            Show-Info ('已存到 ' + $dt.Month + '/' + $dt.Day + '，见下方「未来 7 天」') 6
        } catch {}
    } else {
        # 加到今天：给明确反馈并滚动到新任务所在位置
        $ttl = [string]$p.title
        if ($ttl.Length -gt 14) { $ttl = $ttl.Substring(0, 14) + '…' }
        Show-Info ('已添加「' + $ttl + '」') 3
    }
    Refresh-Now
    # 布局完成后再滚到底，确保新行进入视野
    $actScroll = [System.Action]{
        try { $script:ListScroll.ScrollToEnd() } catch {}
    }
    $null = $script:Window.Dispatcher.InvokeAsync($actScroll, [System.Windows.Threading.DispatcherPriority]::Background)
}

function script:Poll-Now {
    if ($null -eq $script:Window) { return }
    $d = (Get-Date).ToString('yyyy-MM-dd')
    if ($d -ne $script:Day) { $script:Day = $d; Refresh-Now; return }   # 过零点
    # 数据归服务管，这里只看「版本号变没变」——
    # 不管是网页改的、agent 改的，都能看到
    $t = Get-Stamp
    if ($null -eq $t) {
        if ($script:Available) { $script:Available = $false }   # 服务掉了
        return
    }
    if (-not $script:Available) { $script:Available = $true; Refresh-Now; return }  # 服务回来了
    if ($t -ne $script:Stamp) { $script:Stamp = $t; Refresh-Now }
}

# ---------- 本地 HTTP 服务：已移除 ----------
# 以前小窗自己监听 127.0.0.1:17850，专门给 calendar.html 用。
# 现在数据服务由 today-tasks 的 server.py 提供（跨平台、带 MCP、原子写、文件锁），
# 小窗只是它的客户端。两边都监听同一个端口会直接冲突，
# 所以这一段（Send-ApiJson / Handle-Api / Start-Api / Stop-Api / Pump-Api
# 以及 250ms 的 apiTimer）整个删掉了 —— 那也正是旧版卡顿的来源之一。

# ---------- 控件绑定（建窗后调用，主流程与自检共用） ----------
function script:Bind-Controls {
    $script:List        = $script:Window.FindName('List')
    $script:ListScroll  = $script:Window.FindName('ListScroll')
    $script:DateText    = $script:Window.FindName('DateText')
    $script:StatText    = $script:Window.FindName('StatText')
    $script:ToastBar    = $script:Window.FindName('ToastBar')
    $script:ToastText   = $script:Window.FindName('ToastText')
    $script:ToastTick   = $script:Window.FindName('ToastTick')
    $script:ToastBtn    = $script:Window.FindName('ToastBtn')
    $script:DateChip    = $script:Window.FindName('DateChip')
    $script:DateChipText= $script:Window.FindName('DateChipText')
    $script:FutureHeader= $script:Window.FindName('FutureHeader')
    $script:FutureHeaderText = $script:Window.FindName('FutureHeaderText')
    $script:FutureBox   = $script:Window.FindName('FutureBox')
    $script:FutureList  = $script:Window.FindName('FutureList')
    $script:AddBox      = $script:Window.FindName('AddBox')
    $script:AddHint     = $script:Window.FindName('AddHint')
    $global:TTW.EditRowId = $null
    $script:UndoSnap    = $null
    $script:UndoLeft    = 0
    $script:ToastKind   = ''
    $script:FutureOpen  = $false
    # 控件引用也放全局表：New-TaskRow 里的闭包要用窗口 / 列表，
    # 而闭包内 $script: 读不到（见文件顶部说明）
    $global:TTW.Window     = $script:Window
    $global:TTW.List       = $script:List
    $global:TTW.ListScroll = $script:ListScroll
    # 拖拽状态统一在全局表里（跨闭包共享，放 $script: 闭包读不到，见文件顶部说明），
    # 用一次复位函数清干净
    Cancel-RowDrag
    $global:TTW.DragThreshold = 8.0
    $script:Day         = (Get-Date).ToString('yyyy-MM-dd')
    $script:Stamp       = ''
    $stamp = Get-Stamp
    if ($stamp) { $script:Stamp = $stamp }
}

# ---------- 事件接线（主流程与自检共用；只接线，不启动定时器） ----------
function script:Wire-Events {
    $script:UndoTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:UndoTimer.Interval = [System.TimeSpan]::FromSeconds(1)
    $script:UndoTimer.Add_Tick({
        if ($script:ToastBar.Visibility -ne 'Visible') { $script:UndoTimer.Stop(); return }
        $script:UndoLeft = $script:UndoLeft - 1
        if ($script:UndoLeft -le 0) { Hide-Toast; return }
        $script:ToastTick.Text = (' {0}s' -f $script:UndoLeft)
    })
    $script:ToastBtn.Add_Click({ param($s, $e) if ($script:ToastKind -eq 'undo') { Do-Undo } })

    $script:FutureHeader.Add_MouseLeftButtonUp({
        param($s, $e)
        $script:FutureOpen = -not $script:FutureOpen
        Refresh-Now
    })

    $script:Window.FindName('DragBar').Add_PreviewMouseLeftButtonDown({
        param($s, $e)
        if (Test-InInteractive $e.OriginalSource) { return }
        $script:Window.DragMove()
    })

    # 列表容器不需要接拖拽：拖拽是手工实现的，落点由 Update-RowDrag 按鼠标
    # 在列表坐标系里的 Y 算出（行间缝隙、末尾空白都算得出落点），
    # 不再依赖 OLE 拖放的 DragOver/Drop 事件。

    $script:AddBox.Add_TextChanged({
        param($s, $e)
        if ([string]::IsNullOrEmpty($script:AddBox.Text)) { $script:AddHint.Visibility = 'Visible' }
        else { $script:AddHint.Visibility = 'Hidden' }
        Update-DateChip
    })
    $script:AddBox.Add_KeyDown({
        param($s, $e)
        if ($e.Key -eq 'Return') { Do-Add; $e.Handled = $true }
        elseif ($e.Key -eq 'Escape') { $script:AddBox.Clear() }
    })
    $script:Window.FindName('AddBtn').Add_Click({ param($s, $e) Do-Add })

    $script:Window.FindName('CalBtn').Add_Click({ Open-Calendar })
    $script:Window.FindName('CloseBtn').Add_Click({ $script:Window.Close() })

    $script:Window.Add_Closing({
        # 关窗只关自己 —— 数据服务是独立的进程，不该跟着小窗一起死
        try { Remove-Item -LiteralPath $script:PidFile -Force -ErrorAction SilentlyContinue } catch {}
        try {
            $json = '{{"left":{0},"top":{1}}}' -f [int]$script:Window.Left, [int]$script:Window.Top
            [System.IO.File]::WriteAllText($script:PosFile, $json, (New-Object System.Text.UTF8Encoding($false)))
        } catch {}
    })
}

# ---------- 自检 ----------
if ($SelfTest) {
    # 自检输出同时落一份日志：控制台代码页会把中文变成乱码（自动跑时尤其难读），
    # 落盘后无论如何都能读回完整报告。
    $script:SelfTestLog = Join-Path (Split-Path -Parent $Self) 'selftest.log'
    try {
        if (Test-Path -LiteralPath $script:SelfTestLog) { Remove-Item -LiteralPath $script:SelfTestLog -Force -ErrorAction SilentlyContinue }
        Start-Transcript -Path $script:SelfTestLog -Force | Out-Null
    } catch {}
    $x = [xml]$Xaml
    $r = New-Object System.Xml.XmlNodeReader $x
    try {
        $w = [System.Windows.Markup.XamlReader]::Load($r)
        Write-Output '[ok] XAML 解析通过'
        foreach ($n in @('List','ListScroll','DateText','StatText','AddBox','AddHint','ToastBar','ToastText','ToastBtn','ToastTick','DateChip','DateChipText','FutureHeader','FutureHeaderText','FutureBox','FutureList','CalBtn','CloseBtn','AddBtn','DragBar')) {
            $o = $w.FindName($n)
            if ($null -eq $o) { Write-Output ('[x] 找不到控件: ' + $n); exit 1 }
        }
        Write-Output '[ok] 控件绑定通过（20 个）'
    } catch {
        Write-Output ('[x] XAML 解析失败: ' + $_.Exception.Message)
        exit 1
    }

    # 渲染冒烟测试：New-TaskRow 必须返回单个 Border（历史上因 .Add() 返回值
    # 泄漏导致函数返回数组、整列渲染失败，任务全部「看不到」）
    $global:TTW.EditRowId = $null
    $testItem = [pscustomobject]@{ id = 't-selftest'; title = '自检任务'; status = 'pending'; date = (Get-Date).ToString('yyyy-MM-dd'); late = $true }
    $row = New-TaskRow $testItem 13 $true
    if ($row -isnot [System.Windows.Controls.Border]) {
        Write-Output ('[x] New-TaskRow 返回类型异常: ' + $(if ($null -eq $row) { 'null' } else { $row.GetType().FullName }))
        exit 1
    }
    $rowDone = New-TaskRow ([pscustomobject]@{ id = 't-selftest2'; title = '已完成'; status = 'done'; date = (Get-Date).ToString('yyyy-MM-dd'); late = $false }) 13 $true
    if ($rowDone -isnot [System.Windows.Controls.Border]) {
        Write-Output '[x] New-TaskRow（已完成态）返回类型异常'
        exit 1
    }
    Write-Output '[ok] New-TaskRow 渲染冒烟测试通过（未完成/已完成两态）'

    $data = Get-TaskData
    if ($null -eq $data) { Write-Output '[x] 拿不到数据 —— 本地服务没在跑？先 python server.py'; exit 1 }
    $items = Get-TodayTasks $data
    Write-Output ('[ok] 数据源: ' + $script:ApiBase + '/api/raw')
    Write-Output ('[ok] 今天共 {0} 项' -f $items.Count)
    foreach ($i in $items) {
        $mark = ' '; if ($i.status -eq 'done') { $mark = 'x' }
        $suffix = ''; if ($i.late) { $suffix = ('  (顺延自 {0})' -f $i.date) }
        Write-Output ('     [{0}] {1}{2}' -f $mark, $i.title, $suffix)
    }
    $fg = Get-FutureTasks $data 7
    $fn = 0; foreach ($g in $fg) { $fn += @($g.items).Count }
    Write-Output ('[ok] 未来 7 天共 {0} 项（{1} 天）' -f $fn, @($fg).Count)

    Write-Output '[ok] 输入解析：'
    foreach ($raw in @('买牛奶', '明天交周报', '后天 牙医', '周五下午三点开会', '9/20 高铁票', '12月25日 年会', '周三 复盘')) {
        $p = Parse-Input $raw
        Write-Output ('     "{0}"  ->  {1}   [{2}]' -f $raw, $p.date, $p.title)
    }

    # ============================================================
    # 事件体检
    # 一、接线审计：读 WPF 内部 EventHandlersStore，数每个事件的处理器个数
    # 二、动态激发：真的 RaiseEvent，验证副作用落到临时数据文件
    # ============================================================
    $script:Fail = 0
    function Check([string]$label, [bool]$ok, [string]$detail) {
        if ($ok) { Write-Output ('[ok] ' + $label) }
        else { Write-Output ('[x] ' + $label + '  ' + $detail); $script:Fail++ }
    }
    function Get-ECount($el, $evt) {
        try {
            $flags = [System.Reflection.BindingFlags]'Instance,NonPublic'
            $prop  = [System.Windows.UIElement].GetProperty('EventHandlersStore', $flags)
            if ($null -eq $prop) { return -1 }
            $store = $prop.GetValue($el, $null)
            if ($null -eq $store) { return 0 }
            # GetRoutedEventHandlers 是内部方法，必须带 NonPublic 标志找
            $mi = $store.GetType().GetMethod('GetRoutedEventHandlers',
                    [System.Reflection.BindingFlags]'Instance,Public,NonPublic', $null,
                    [Type[]]@([System.Windows.RoutedEvent]), $null)
            if ($null -eq $mi) { return -2 }
            $arr = $mi.Invoke($store, @($evt))
            if ($null -eq $arr) { return 0 }
            return @($arr).Count
        } catch { return -3 }
    }

    # 接线（与主流程同一套代码）——必须在审计之前执行
    $script:Window = $w
    Bind-Controls
    Wire-Events

    $btnClick   = [System.Windows.Controls.Primitives.ButtonBase]::ClickEvent
    $mouseUp    = [System.Windows.UIElement]::MouseLeftButtonUpEvent
    $prevDown   = [System.Windows.UIElement]::PreviewMouseLeftButtonDownEvent
    $prevMove   = [System.Windows.UIElement]::PreviewMouseMoveEvent
    $prevUpEvt  = [System.Windows.UIElement]::PreviewMouseLeftButtonUpEvent
    $lostCap    = [System.Windows.UIElement]::LostMouseCaptureEvent
    $mouseEnter = [System.Windows.UIElement]::MouseEnterEvent
    $mouseLeave = [System.Windows.UIElement]::MouseLeaveEvent
    $keyDown    = [System.Windows.UIElement]::KeyDownEvent
    $lostFocus  = [System.Windows.UIElement]::LostFocusEvent
    $textChg    = [System.Windows.Controls.Primitives.TextBoxBase]::TextChangedEvent

    # 取一行的操作按钮组（▲▼×）
    function Get-OpsButtons($row) {
        if ($null -eq $row -or $null -eq $row.Child) { return @() }
        foreach ($c in $row.Child.Children) {
            if ($c -is [System.Windows.Controls.StackPanel]) {
                $bs = @($c.Children | Where-Object { $_ -is [System.Windows.Controls.Button] })
                if ($bs.Count -gt 0) { return $bs }
            }
        }
        return @()
    }
    # 取一行的标题（标题 StackPanel 的第一个 TextBlock）
    function Get-RowTitle($row) {
        if ($null -eq $row -or $null -eq $row.Child) { return '' }
        foreach ($c in $row.Child.Children) {
            if ($c -is [System.Windows.Controls.StackPanel]) {
                $tb = @($c.Children | Where-Object { $_ -is [System.Windows.Controls.TextBlock] })
                if ($tb.Count -gt 0 -and @($c.Children | Where-Object { $_ -is [System.Windows.Controls.Button] }).Count -eq 0) {
                    return [string]$tb[0].Text
                }
            }
        }
        return ''
    }
    # 按标题找行
    function Find-RowByTitle([string]$t) {
        foreach ($r in @($script:List.Children | Where-Object { $_ -is [System.Windows.Controls.Border] })) {
            if ((Get-RowTitle $r) -eq $t) { return $r }
        }
        return $null
    }

    $probe = New-TaskRow ([pscustomobject]@{ id = 't-probe'; title = '接线探针'; status = 'pending'; date = (Get-Date).ToString('yyyy-MM-dd'); late = $false }) 13 $true
    $opsB  = Get-OpsButtons $probe
    $ebProbe = @($probe.Child.Children | Where-Object { $_ -is [System.Windows.Controls.TextBox] })[0]
    $opsUp = @($opsB | Where-Object { [string]$_.Content -eq '▲' })[0]
    $opsDn = @($opsB | Where-Object { [string]$_.Content -eq '▼' })[0]
    $opsX  = @($opsB | Where-Object { [string]$_.Content -eq '×' })[0]

    Write-Output '--- 一、接线审计（处理器个数）---'
    $audit = @(
        @('拖动栏 PreviewMouseLeftButtonDown', (Get-ECount $w.FindName('DragBar') $prevDown), 1),
        @('日历按钮 Click',                     (Get-ECount $w.FindName('CalBtn') $btnClick), 1),
        @('关闭按钮 Click',                     (Get-ECount $w.FindName('CloseBtn') $btnClick), 1),
        @('添加按钮 Click',                     (Get-ECount $w.FindName('AddBtn') $btnClick), 1),
        @('提示条按钮 Click',                   (Get-ECount $w.FindName('ToastBtn') $btnClick), 1),
        @('输入框 TextChanged',                 (Get-ECount $w.FindName('AddBox') $textChg), 1),
        @('输入框 KeyDown',                     (Get-ECount $w.FindName('AddBox') $keyDown), 1),
        @('未来区 MouseLeftButtonUp',           (Get-ECount $w.FindName('FutureHeader') $mouseUp), 1),
        @('任务行 MouseLeftButtonUp（打勾）',   (Get-ECount $probe $mouseUp), 1),
        @('任务行 MouseEnter',                  (Get-ECount $probe $mouseEnter), 1),
        @('任务行 MouseLeave',                  (Get-ECount $probe $mouseLeave), 1),
        @('任务行 PreviewMouseLeftButtonDown（锚点+双击）', (Get-ECount $probe $prevDown), 2),
        @('任务行 PreviewMouseMove（起拖）',    (Get-ECount $probe $prevMove), 1),
        @('任务行 PreviewMouseLeftButtonUp（拖拽收尾）', (Get-ECount $probe $prevUpEvt), 1),
        @('任务行 LostMouseCapture（状态复位）', (Get-ECount $probe $lostCap), 1),
        @('上移按钮 Click',                     (Get-ECount $opsUp $btnClick), 1),
        @('下移按钮 Click',                     (Get-ECount $opsDn $btnClick), 1),
        @('删除按钮 Click',                     (Get-ECount $opsX $btnClick), 1),
        @('编辑框 KeyDown',                     (Get-ECount $ebProbe $keyDown), 1),
        @('编辑框 LostFocus',                   (Get-ECount $ebProbe $lostFocus), 1)
    )
    foreach ($a in $audit) {
        Check $a[0] ($a[1] -eq $a[2]) ('实际 ' + $a[1] + '，期望 ' + $a[2])
    }

    # ---------- 一之二、输入链路安全（防回归） ----------
    # 历史 bug：给 ▲▼× 按钮挂 PreviewMouseLeftButtonDown 并标记 Handled，
    # 会让 ButtonBase 收不到鼠标按下 → 不捕获鼠标、不吞抬起 → Click 永不触发，
    # 而抬起的冒泡会落到行上被执行成「打勾」。表现就是「点▲▼没反应，任务却被勾了」。
    # 断言：按钮上不允许存在任何 Preview 拦截。
    Write-Output '--- 一之二、输入链路（按钮不得被 Preview 拦截）---'
    $prevUp = [System.Windows.UIElement]::PreviewMouseLeftButtonUpEvent
    foreach ($pair in @(@('上移 ▲', $opsUp), @('下移 ▼', $opsDn), @('删除 ×', $opsX))) {
        $b = $pair[1]
        Check ($pair[0] + ' 无 PreviewMouseLeftButtonDown') ((Get-ECount $b $prevDown) -eq 0) ('实际 ' + (Get-ECount $b $prevDown))
        Check ($pair[0] + ' 无 PreviewMouseLeftButtonUp')   ((Get-ECount $b $prevUp)   -eq 0) ('实际 ' + (Get-ECount $b $prevUp))
    }
    Check 'Test-InInteractive 识别按钮'   (Test-InInteractive $opsUp)   '按钮没被识别成交互控件'
    Check 'Test-InInteractive 识别输入框' (Test-InInteractive $ebProbe) '输入框没被识别成交互控件'

    # 双击改名的聚焦链路：历史上 BeginInvoke 的委托被传成 null，
    # 双击任务行直接抛异常、改名彻底失灵（error.log 里抓到过）。
    $focusOk = $true; $focusMsg = ''
    try {
        $ebProbe.Visibility = 'Visible'
        $ebProbe.UpdateLayout()
        $null = $ebProbe.Focus()
        $ebProbe.SelectAll()
    } catch { $focusOk = $false; $focusMsg = $_.Exception.Message }
    Check '编辑框聚焦链路（双击改名）' $focusOk $focusMsg

    # ---------- 一之三、拖动排序入口 ----------
    # 拖动排序必须有「看得见的入口」：悬停时出现的 ⠿ 抓握条。
    # 之前的实现只在行的空白处能起拖，界面上完全看不出来，用户不可能想到去拖它。
    Write-Output '--- 一之三、拖动排序入口 ---'
    $grip = $null
    foreach ($c in @($probe.Child.Children)) {
        if ($c -is [System.Windows.Controls.StackPanel]) {
            foreach ($g in @($c.Children)) { if ([string]$g.Tag -eq 'drag-grip') { $grip = $g } }
        }
    }
    Check '抓握条存在（拖动排序的可见入口）' ($null -ne $grip) '没找到 Tag=drag-grip 的元素'
    if ($null -ne $grip) {
        # Background 为 null 的 Border 不参与命中测试 → 鼠标按上去直接穿过去，抓握条等于不存在
        Check '抓握条可命中（背景非 null）' ($null -ne $grip.Background) '背景为 null，鼠标按不到'
        Check '抓握条光标已设置' ($null -ne $grip.Cursor -and [string]$grip.Cursor -like '*SizeAll*') ('实际 ' + [string]$grip.Cursor)
        Check '抓握条无 PreviewMouseLeftButtonDown' ((Get-ECount $grip $prevDown) -eq 0) ('实际 ' + (Get-ECount $grip $prevDown))
        Check 'Test-InGrip 识别抓握条' (Test-InGrip $grip) '抓握条没被识别'
        Check 'Test-InInteractive 不把抓握条当按钮' (-not (Test-InInteractive $grip)) '抓握条被误判为按钮 → 无法起拖'
    }
    Check 'Test-InGrip 不误判普通行' (-not (Test-InGrip $probe)) '普通行被当成抓握条'
    Check '任务行 Tag 存了任务 id（落点计算要用）' ([string]$probe.Tag -eq 't-probe') ('实际 ' + [string]$probe.Tag)
    Check '任务行标记为可排序（落点筛选用）' (Is-SortableRow $probe) 'Is-SortableRow 为 false'
    Check '拖动阈值已初始化' ($global:TTW.DragThreshold -gt 0) ('实际 ' + $global:TTW.DragThreshold)
    Write-Output ('[i] 抓握条：背景=' + [string]$grip.Background + ' 光标=' + [string]$grip.Cursor + ' 阈值=' + $global:TTW.DragThreshold + 'px')

    # ---------- 二、动态激发（另起一个临时服务实例，不碰真数据） ----------
    # 小窗已经改成走 HTTP 了，所以隔离方式也跟着变：不再复制数据文件了，
    # 而是起一个独立服务进程 —— 数据文件指向临时副本、端口换一个。
    # 下面所有写操作都落在那个实例上，真实数据一个字节都不会动。
    Write-Output '--- 二、动态激发事件 ---'
    $script:TestMode = $true
    $realPort = $script:ApiPort
    $tmpDir   = Join-Path $env:TEMP ('ttw-selftest-' + [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $tmpDir -Force
    $tmpData  = Join-Path $tmpDir 'tasks.json'

    $realDoc = Invoke-Api 'GET' '/api/raw' $null
    $seedJson = '{"version":1,"tasks":[]}'
    if ($null -ne $realDoc -and $null -ne $realDoc.tasks) {
        $seedJson = (@{ version = 1; tasks = @($realDoc.tasks) } | ConvertTo-Json -Depth 8)
    }
    [System.IO.File]::WriteAllText($tmpData, $seedJson, (New-Object System.Text.UTF8Encoding($false)))

    $srv    = $null
    $testPy = $null
    foreach ($cand in @('python', 'py', 'python3')) {
        $c = Get-Command $cand -ErrorAction SilentlyContinue
        if ($null -ne $c) { $testPy = $c.Source; break }
    }
    $testPort = 19150 + (Get-Random -Minimum 0 -Maximum 700)
    if ($null -ne $testPy) {
        $srvArgs = @(
            (Join-Path $script:RepoRoot 'server.py'), '--no-open', '--no-widget',
            '--port', [string]$testPort, '--data', $tmpData
        )
        try { $srv = Start-Process -FilePath $testPy -ArgumentList $srvArgs -PassThru -WindowStyle Hidden }
        catch { $srv = $null }
        Set-ApiPort $testPort
        for ($i = 0; $i -lt 40; $i++) {
            Start-Sleep -Milliseconds 150
            if (Test-Api) { break }
        }
    }

    if (-not (Test-Api)) {
        Write-Output ('[x] 起不了临时测试服务（端口 ' + $testPort + '）—— 自检需要 python 在 PATH 上')
        if ($null -ne $srv) { try { Stop-Process -Id $srv.Id -Force -ErrorAction SilentlyContinue } catch {} }
        Remove-Item -LiteralPath $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
        Set-ApiPort $realPort
        $script:TestMode = $false
        exit 1
    }
    Write-Output ('[ok] 临时测试服务已就绪：' + $script:ApiBase + '（数据 ' + $tmpData + '）')

    try {
        # 测试数据不足时补两条
        $d0 = Get-TaskData
        $today = (Get-Date).ToString('yyyy-MM-dd')
        $pend = @(@($d0.tasks) | Where-Object { $_.status -ne 'done' -and $_.date -le $today })
        if (@($pend).Count -lt 3) {
            $null = Add-Task -Title '体检A' -Date $today
            $null = Add-Task -Title '体检B' -Date $today
            $null = Add-Task -Title '体检C' -Date $today
        }

        $script:Window = $w
        Refresh-Now

        # 1) 添加按钮
        $n0 = @((Get-TaskData).tasks).Count
        $script:AddBox.Text = '事件体检-新增'
        $w.FindName('AddBtn').RaiseEvent((New-Object System.Windows.RoutedEventArgs($btnClick)))
        $n1 = @((Get-TaskData).tasks).Count
        $added = @((Get-TaskData).tasks) | Where-Object { $_.title -eq '事件体检-新增' }
        Check '添加按钮 Click → 数据+1' ($n1 -eq ($n0 + 1)) ('前 ' + $n0 + ' 后 ' + $n1)
        Check '添加后输入框清空' ([string]::IsNullOrEmpty($script:AddBox.Text)) ('残留: ' + $script:AddBox.Text)
        Check '添加后提示条可见' ($script:ToastBar.Visibility -eq 'Visible') ('实际 ' + $script:ToastBar.Visibility)
        Check '新增任务写入正确' ($null -ne $added) '未找到新增任务'

        # 2) 打勾（真的激发行上的 MouseLeftButtonUp，按标题精确定位那一行）
        $target = Find-RowByTitle '事件体检-新增'
        $mouseOk = $false
        if ($null -ne $target) {
            try {
                $dev  = [System.Windows.Input.Mouse]::PrimaryDevice
                $args = New-Object System.Windows.Input.MouseButtonEventArgs($dev, 0, [System.Windows.Input.MouseButton]::Left)
                $args.RoutedEvent = $mouseUp
                $target.RaiseEvent($args)
                $mouseOk = $true
            } catch { $mouseOk = $false }
        }
        if ($mouseOk) {
            $dDone = @((Get-TaskData).tasks) | Where-Object { $_.status -eq 'done' -and $_.title -eq '事件体检-新增' }
            Check '任务行 MouseLeftButtonUp → 打勾生效' ($null -ne $dDone) '标题状态未变'
            # 再点一次应该能取消勾选
            Refresh-Now
            $again = Find-RowByTitle '事件体检-新增'
            if ($null -ne $again) {
                try {
                    $a2 = New-Object System.Windows.Input.MouseButtonEventArgs([System.Windows.Input.Mouse]::PrimaryDevice, 0, [System.Windows.Input.MouseButton]::Left)
                    $a2.RoutedEvent = $mouseUp
                    $again.RaiseEvent($a2)
                    $dUndo = @((Get-TaskData).tasks) | Where-Object { $_.id -eq [string]$added.id }
                    Check '任务行 MouseLeftButtonUp → 取消勾选' ($dUndo.status -ne 'done') ('实际 ' + $dUndo.status)
                } catch { Check '任务行 MouseLeftButtonUp → 取消勾选' $false '第二次激发失败' }
            }
        } else {
            Write-Output '[!] 无法构造鼠标事件（非交互环境），打勾链路改由「点击处理函数」验证'
            $null = Toggle-Task -Id ([string]$added.id)
            $dg = @((Get-TaskData).tasks) | Where-Object { $_.id -eq [string]$added.id }
            Check '打勾链路 → 状态写入' ($dg.status -eq 'done') ('实际 ' + $dg.status)
        }

        # 3) 上移按钮（第 2 行上移）
        Refresh-Now
        $rows = @($script:List.Children | Where-Object { $_ -is [System.Windows.Controls.Border] })
        $before = @((Get-TaskData).tasks) | Where-Object { $_.status -ne 'done' } | ForEach-Object { $_.id }
        $r2 = $null
        foreach ($r in $rows) {
            $bs = @(Get-OpsButtons $r | Where-Object { [string]$_.Content -eq '▲' })
            if ($bs.Count -gt 0) { $r2 = $r; break }
        }
        if ($null -ne $r2) {
            $up = @(Get-OpsButtons $r2 | Where-Object { [string]$_.Content -eq '▲' })[0]
            # 取第 2 个可上移的行，避免顶行上移无效
            $cand = @($rows | Where-Object { @(Get-OpsButtons $_ | Where-Object { [string]$_.Content -eq '▲' }).Count -gt 0 })
            if ($cand.Count -ge 2) { $up = @(Get-OpsButtons $cand[1] | Where-Object { [string]$_.Content -eq '▲' })[0] }
            $up.RaiseEvent((New-Object System.Windows.RoutedEventArgs($btnClick)))
            $afterIds = @((Get-TaskData).tasks) | Where-Object { $_.status -ne 'done' } | ForEach-Object { $_.id }
            Check '上移按钮 Click → 顺序变化' (($before -join ',') -ne ($afterIds -join ',')) '顺序未变'
        } else {
            Check '上移按钮 Click → 顺序变化' $false '没找到可上移的行'
        }

        # 4) 删除按钮 + 撤销
        Refresh-Now
        $rows = @($script:List.Children | Where-Object { $_ -is [System.Windows.Controls.Border] })
        $delRow = $null
        foreach ($r in $rows) { if (@(Get-OpsButtons $r | Where-Object { [string]$_.Content -eq '×' }).Count -gt 0) { $delRow = $r; break } }
        $cntBefore = @((Get-TaskData).tasks).Count
        if ($null -ne $delRow) {
            $x = @(Get-OpsButtons $delRow | Where-Object { [string]$_.Content -eq '×' })[0]
            $x.RaiseEvent((New-Object System.Windows.RoutedEventArgs($btnClick)))
            $cntAfter = @((Get-TaskData).tasks).Count
            Check '删除按钮 Click → 数据-1' ($cntAfter -eq ($cntBefore - 1)) ('前 ' + $cntBefore + ' 后 ' + $cntAfter)
            Check '删除后提示条可见（撤销用）' ($script:ToastBar.Visibility -eq 'Visible' -and $script:ToastKind -eq 'undo') ('kind=' + $script:ToastKind)
            $script:ToastBtn.RaiseEvent((New-Object System.Windows.RoutedEventArgs($btnClick)))
            $cntBack = @((Get-TaskData).tasks).Count
            Check '撤销按钮 Click → 数据还原' ($cntBack -eq $cntBefore) ('期望 ' + $cntBefore + ' 实际 ' + $cntBack)
        } else {
            Check '删除按钮 Click → 数据-1' $false '没找到带删除按钮的行'
        }

        # 5) 日历按钮（TestMode 下只记录动作）
        $script:LastAction = ''
        $w.FindName('CalBtn').RaiseEvent((New-Object System.Windows.RoutedEventArgs($btnClick)))
        Check '日历按钮 Click → 触发打开动作' ($script:LastAction -eq 'open-calendar') ('实际 ' + $script:LastAction)

        # 6) 输入框 TextChanged → 提示语与日期标签
        $script:AddBox.Text = '明天 交周报'
        $hintHidden = ($script:AddHint.Visibility -eq 'Hidden')
        $chipShown  = ($script:DateChip.Visibility -eq 'Visible')
        Check '输入框 TextChanged → 占位提示隐藏' $hintHidden ('实际 ' + $script:AddHint.Visibility)
        Check '输入框 TextChanged → 日期标签出现' $chipShown ('实际 ' + $script:DateChip.Visibility)
        $script:AddBox.Clear()

        # 7) 未来区折叠（MouseLeftButtonUp）
        $null = Add-Task -Title '体检-明天' -Date ((Get-Date).AddDays(1).ToString('yyyy-MM-dd'))
        Refresh-Now
        $openBefore = $script:FutureOpen
        try {
            $a3 = New-Object System.Windows.Input.MouseButtonEventArgs([System.Windows.Input.Mouse]::PrimaryDevice, 0, [System.Windows.Input.MouseButton]::Left)
            $a3.RoutedEvent = $mouseUp
            $w.FindName('FutureHeader').RaiseEvent($a3)
            Check '未来区 MouseLeftButtonUp → 折叠状态翻转' ($script:FutureOpen -ne $openBefore) ('实际 ' + $script:FutureOpen)
        } catch {
            Check '未来区 MouseLeftButtonUp → 折叠状态翻转' $false ('激发失败: ' + $_.Exception.Message)
        }

        # 8) 拖拽落点逻辑（Complete-Drop）：把第一条拖到最后一条之后
        Refresh-Now
        $ids = @((Get-TaskData).tasks | Where-Object { $_.status -ne 'done' -and $_.date -le (Get-Date).ToString('yyyy-MM-dd') } | ForEach-Object { $_.id })
        if ($ids.Count -ge 2) {
            $srcI = [string]$ids[0]
            $dstI = [string]$ids[-1]
            Complete-Drop -SrcId $srcI -TargetId $dstI -After $true
            $ids2 = @((Get-TaskData).tasks | Where-Object { $_.status -ne 'done' -and $_.date -le (Get-Date).ToString('yyyy-MM-dd') } | ForEach-Object { $_.id })
            Check '拖拽落点 Complete-Drop → 顺序写回' ([string]$ids2[-1] -eq $srcI) ('末位=' + $ids2[-1] + ' 期望=' + $srcI)
            Check '拖拽落点 → 集合数量不变' ($ids2.Count -eq $ids.Count) ('前 ' + $ids.Count + ' 后 ' + $ids2.Count)
        } else {
            Check '拖拽落点 Complete-Drop → 顺序写回' $false '可拖拽任务不足 2 条'
        }

        # 8b) 完整的手工拖拽链路：按下 → 移动（超阈值）→ 落点 → 抬起写回。
        # 这些全是普通函数，自检可以直接喂坐标把整条链路跑一遍 ——
        # 之前用 OLE 拖放时这一层永远测不到（DragEventArgs 构造不出来），
        # 而 bug 恰好就藏在这一层。
        Refresh-Now
        # 自检环境里窗口从未显示过 → 布局没跑过 → ActualHeight 恒为 0，
        # 「上半行 / 下半行」就区分不出来，所以手动跑一次 Measure/Arrange。
        try {
            $w.Measure((New-Object System.Windows.Size(322, 700)))
            $w.Arrange((New-Object System.Windows.Rect(0, 0, 322, 700)))
            $w.UpdateLayout()
        } catch { Write-Output ('[!] 手动布局失败：' + $_.Exception.Message) }

        $rowsX = @($script:List.Children | Where-Object { $_ -is [System.Windows.Controls.Border] -and (Is-SortableRow $_) })
        if ($rowsX.Count -lt 2) {
            Check '拖拽链路（按下→移动→抬起）' $false '可排序的行不足 2 条'
        } else {
            $srcRow = $rowsX[0]
            $dstRow = $rowsX[-1]
            $srcIdX = [string]$srcRow.Tag
            # 合成几何：自检环境里窗口从未真正显示过，布局跑不出来
            # （ActualHeight 与 TranslatePoint 恒为 0），上半行/下半行分不出来。
            # 所以用「每行 24px、依次排列」喂给落点判定，验证的是判定规则本身。
            $step    = 24.0
            $borders = @($script:List.Children | Where-Object { $_ -is [System.Windows.Controls.Border] })
            $dstIdx  = [array]::IndexOf($borders, $dstRow)
            if ($dstIdx -lt 0) { $dstIdx = 0 }
            $dstBelow = $dstIdx * $step + ($step - 1)   # 目标行的下半 → 应插到它后面
            $dstAbove = $dstIdx * $step + 1             # 目标行的上半 → 应插到它前面
            $realH = 0.0
            try { $realH = [double]$dstRow.ActualHeight } catch {}
            if ($realH -gt 0) { Write-Output ('[i] 真实布局可用，行高 ' + [math]::Round($realH, 1) + 'px') }
            else              { Write-Output '[i] 自检环境无布局（ActualHeight=0），落点用合成几何 24px/行 验证规则' }

            # 已完成的行不是落点（不能靠 AllowDrop 判断：那是会向下继承的依赖属性）
            $doneProbe = New-TaskRow ([pscustomobject]@{ id = 't-done-probe'; title = '已完成探针'; status = 'done'; date = (Get-Date).ToString('yyyy-MM-dd'); late = $false }) 13 $true
            Check '已完成行不算可排序行' (-not (Is-SortableRow $doneProbe)) '已完成行被当成可排序行'
            Check '未完成行算可排序行' (Is-SortableRow $srcRow) '未完成行没被识别为可排序行'
            $t0 = Find-DropRow $script:List 9999
            Check 'Find-DropRow 忽略已完成行（落到末尾取最后一条待办）' ([string]$t0.Row.Tag -eq [string]$dstRow.Tag) ('落点=' + [string]$t0.Row.Tag + ' 期望=' + [string]$dstRow.Tag)

            # --- 按下：登记待拖状态 ---
            Cancel-RowDrag
            $null = Begin-RowDrag $srcRow $srcIdX 100.0 100.0 $false $false
            Check '按下 → 进入待拖状态' ($global:TTW.DragSrcId -eq $srcIdX) ('DragSrcId=' + [string]$global:TTW.DragSrcId)
            Check '按下 → 尚未进入拖动' (-not $global:TTW.DragActive) '不该已激活'

            # --- 移动 3px：不够阈值，什么都不该发生 ---
            $st = Update-RowDrag $srcIdX $true 102.0 101.0 $dstBelow 5.0 $step $step
            Check '轻微移动（未到阈值）→ 不启动拖动' ($st -eq 'idle' -and -not $global:TTW.DragActive) ('返回 ' + $st)

            # --- 移动超过阈值：进入拖动 ---
            $null = Update-RowDrag $srcIdX $true 100.0 140.0 $dstBelow 5.0 $step $step
            Check '移动超过阈值 → 进入拖动状态' ([bool]$global:TTW.DragActive) 'DragActive 仍为 false'
            Check '拖动中 → 源行变半透明' ([double]$srcRow.Opacity -lt 1) ('Opacity=' + $srcRow.Opacity)

            # --- 落点：末行下半 → 插到它后面 ---
            Check '拖到末行下半 → 落点指示在目标行' ($global:TTW.DropMarkRow -eq $dstRow) ('DropMarkRow=' + [string]$global:TTW.DropMarkRow)
            Check '拖到末行下半 → 判定插到后面' ($global:TTW.DropAfter -eq $true) ('实际 ' + $global:TTW.DropAfter)
            Check '拖动中 → 落点行已着色' ($null -ne $dstRow.BorderBrush) '边框刷为空'

            # --- 落点：末行上半 → 插到它前面 ---
            $null = Update-RowDrag $srcIdX $true 100.0 140.0 $dstAbove 5.0 $step $step
            Check '拖到末行上半 → 判定插到前面' ($global:TTW.DropAfter -eq $false) ('实际 ' + $global:TTW.DropAfter)

            # --- 抬起：写回顺序，并且必须吞掉这次抬起（否则会顺手打勾）---
            $null = Update-RowDrag $srcIdX $true 100.0 140.0 $dstBelow 5.0 $step $step
            $consumed = Finish-RowDrag $srcIdX
            Check '抬起 → 抬起事件被拖拽消费（不会顺手打勾）' ([bool]$consumed) '返回 false，抬起会落到行上执行打勾'
            $ids4 = @((Get-TaskData).tasks | Where-Object { $_.status -ne 'done' -and $_.date -le (Get-Date).ToString('yyyy-MM-dd') } | ForEach-Object { $_.id })
            Check '抬起 → 拖动项确实被挪到末尾' ([string]$ids4[-1] -eq $srcIdX) ('末位=' + $ids4[-1] + ' 期望=' + $srcIdX)
            Check '抬起 → 集合数量不变' ($ids4.Count -eq $ids.Count) ('前 ' + $ids.Count + ' 后 ' + $ids4.Count)
            Check '抬起后落点指示已清除' ($null -eq $global:TTW.DropMarkRow) ('残留=' + [string]$global:TTW.DropMarkRow)
            Check '抬起后源行恢复不透明' ([double]$srcRow.Opacity -eq 1) ('Opacity=' + $srcRow.Opacity)
            Check '抬起后拖拽状态已复位' ($null -eq $global:TTW.DragSrcId -and -not $global:TTW.DragActive) '状态残留'

            # --- 在抓握条上点一下（没拖）：不能打勾，也不该改顺序 ---
            $idsBefore = @((Get-TaskData).tasks | ForEach-Object { $_.id })
            Cancel-RowDrag
            $null = Begin-RowDrag $srcRow $srcIdX 100.0 100.0 $true $false   # 第 5 个参数 $true = 按在抓握条上
            $consumed2 = Finish-RowDrag $srcIdX
            Check '抓握条上点一下 → 吞掉抬起（不打勾）' ([bool]$consumed2) '返回 false，会被当成点击打勾'
            $idsAfter = @((Get-TaskData).tasks | ForEach-Object { $_.id })
            Check '抓握条上点一下 → 顺序未变' (($idsAfter -join ',') -eq ($idsBefore -join ',')) '顺序被改动了'

            # --- 按在 ▲▼× 上：不进入待拖，交给按钮自己 ---
            Cancel-RowDrag
            $began = Begin-RowDrag $srcRow $srcIdX 100.0 100.0 $false $true    # $interactive = $true
            Check '按在按钮上 → 不进入待拖（不抢按钮点击）' ((-not $began) -and ($null -eq $global:TTW.DragSrcId)) ('began=' + $began)
        }

        # 8c) 闭包作用域体检（防回归，这一条最要紧）。
        # 行内处理器全是 .GetNewClosure() 造的闭包，而闭包内 `$script:` 既读不到
        # 外部脚本作用域、也写不回去。曾经因此出现「拖拽不启动 + 拖一下顺手打勾」。
        # 断言一：跨闭包共享的状态确实能共享（走 $global:）。
        Cancel-RowDrag
        $ca = { $global:TTW.DragSrcId = 'closure-probe' }.GetNewClosure()
        $cb = { return [string]$global:TTW.DragSrcId }.GetNewClosure()
        & $ca
        Check '闭包间共享状态（$global:TTW）' ((& $cb) -eq 'closure-probe') ('闭包读到 ' + [string](& $cb))
        Cancel-RowDrag
        # 断言二：静态扫描 —— New-TaskRow 里不许出现 $script:（那里的处理器全是闭包）。
        $srcText = ''
        try { $srcText = [System.IO.File]::ReadAllText($Self, [System.Text.Encoding]::UTF8) } catch {}
        $fnA = $srcText.IndexOf('function script:New-TaskRow')
        $fnB = $srcText.IndexOf('function script:Invoke-Refresh')
        if ($fnA -ge 0 -and $fnB -gt $fnA) {
            $body = $srcText.Substring($fnA, $fnB - $fnA)
            # 只统计代码行：纯注释行里提到 $script: 不算（那是说明文字）
            $bad = @()
            foreach ($ln in ($body -split "`n")) {
                $tt = $ln.Trim()
                if ($tt.StartsWith('#')) { continue }
                if ($tt -match '\$script:') { $bad += $tt }
            }
            Check 'New-TaskRow 内不出现 $script:（闭包内读不到）' ($bad.Count -eq 0) ('发现 ' + $bad.Count + ' 处：' + (($bad | Select-Object -First 3) -join ' | '))
        } else {
            Write-Output '[!] 源码定位失败，跳过 New-TaskRow 静态扫描'
        }

        # 9) 键盘事件（回车添加 / 编辑提交）——当前环境构造得出才测
        $keyOk = $false
        $ka = $null
        try {
            $ks  = [System.Windows.Input.Keyboard]::PrimaryDevice
            $src = [System.Windows.PresentationSource]::FromVisual($w)
            $ka  = New-Object System.Windows.Input.KeyEventArgs($ks, $src, 0, [System.Windows.Input.Key]::Return)
            $keyOk = $true
        } catch { $keyOk = $false }
        if ($keyOk) {
            $n0 = @((Get-TaskData).tasks).Count
            $script:AddBox.Text = '事件体检-回车'
            $ka.RoutedEvent = $keyDown
            $script:AddBox.RaiseEvent($ka)
            $n1 = @((Get-TaskData).tasks).Count
            Check '输入框 KeyDown(回车) → 新增任务' ($n1 -eq ($n0 + 1)) ('前 ' + $n0 + ' 后 ' + $n1)

            Refresh-Now
            $er = Find-RowByTitle '事件体检-回车'
            if ($null -ne $er) {
                $eb = @($er.Child.Children | Where-Object { $_ -is [System.Windows.Controls.TextBox] })[0]
                $global:TTW.EditRowId = 'x'   # 让双击守卫放行
                try {
                    $tid = @((Get-TaskData).tasks | Where-Object { $_.title -eq '事件体检-回车' })[0].id
                    $global:TTW.EditRowId = [string]$tid
                    $eb.Text = '事件体检-已改名'
                    $ka2 = New-Object System.Windows.Input.KeyEventArgs($ks, $src, 0, [System.Windows.Input.Key]::Return)
                    $ka2.RoutedEvent = $keyDown
                    $eb.RaiseEvent($ka2)
                    $hit = @((Get-TaskData).tasks) | Where-Object { $_.title -eq '事件体检-已改名' }
                    Check '编辑框 KeyDown(回车) → 标题保存' ($null -ne $hit) '标题未变'
                } catch {
                    Check '编辑框 KeyDown(回车) → 标题保存' $false ('激发失败: ' + $_.Exception.Message)
                } finally { $global:TTW.EditRowId = $null }
            } else {
                Check '编辑框 KeyDown(回车) → 标题保存' $false '没找到刚加的行'
            }
        } else {
            Write-Output '[!] 无法构造键盘事件（需真人按键），回车添加/编辑提交由接线审计覆盖'
        }

        # 10) 确认测试操作没有污染真实数据
        $tmpCount = @((Get-TaskData).tasks).Count
        Set-ApiPort $realPort
        $realCount = @((Get-TaskData).tasks).Count
        Set-ApiPort $testPort
        Write-Output ('[i] 临时库 ' + $tmpCount + ' 条 / 真库 ' + $realCount + ' 条（两者独立）')
    } finally {
        Set-ApiPort $realPort
        if ($null -ne $srv -and -not $srv.HasExited) {
            try { Stop-Process -Id $srv.Id -Force -ErrorAction SilentlyContinue } catch {}
        }
        $script:TestMode = $false
        Remove-Item -LiteralPath $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    if ($script:Fail -gt 0) {
        Write-Output ('[x] 事件体检未通过：' + $script:Fail + ' 项')
        try { Stop-Transcript | Out-Null } catch {}
        exit 1
    }
    Write-Output '[ok] 事件体检全部通过'
    try { Stop-Transcript | Out-Null } catch {}
    exit 0
}

# ---------- 单实例保护 + 旧实例自动清理 ----------
# 历史上出过「旧版进程残留、新实例起不来或两窗叠在一起」的问题。
# 规则：拿到互斥锁就写自己的 PID 到 widget.pid；拿不到时按 PID 文件
# 核实旧进程确实是本插件（命令行含 desktop-widget.ps1）后结束它，再重试一次。
$script:PidFile  = Join-Path (Split-Path -Parent $Self) 'widget.pid'
$script:AppMutex = $null
$created = $false
try {
    $script:AppMutex = New-Object System.Threading.Mutex($true, 'Global\TodayTasksWidget', [ref]$created)
} catch {
    $script:AppMutex = $null
    $created = $true
}

if (-not $created) {
    script:Boot-Trace 'mutex busy -> 检测旧实例'
    $killed = $false
    try {
        if (Test-Path -LiteralPath $script:PidFile) {
            $oldPid = [int](Get-Content -LiteralPath $script:PidFile -Raw -ErrorAction Stop).Trim()
            if ($oldPid -ne $PID) {
                $p = Get-CimInstance Win32_Process -Filter ('ProcessId=' + $oldPid) -ErrorAction SilentlyContinue
                if ($p -and ([string]$p.CommandLine) -like '*desktop-widget.ps1*') {
                    Stop-Process -Id $oldPid -Force -ErrorAction Stop
                    Start-Sleep -Milliseconds 800
                    $killed = $true
                    script:Boot-Trace ('已结束旧实例 pid=' + $oldPid)
                } else {
                    script:Boot-Trace ('pid 文件里的 ' + $oldPid + ' 不是本插件，忽略')
                }
            }
        } else {
            script:Boot-Trace 'mutex 被占但没有 pid 文件'
        }
    } catch { script:Boot-Trace ('清理旧实例出错: ' + $_.Exception.Message) }
    if ($killed) {
        try {
            $script:AppMutex = New-Object System.Threading.Mutex($true, 'Global\TodayTasksWidget', [ref]$created)
        } catch { $created = $false }
    }
    if (-not $created) {
        script:Boot-Trace '已有实例在运行 -> 弹提示后退出'
        $null = [System.Windows.MessageBox]::Show(
            '「今日任务」已经在运行了。如果看不到窗口，请在任务管理器里结束旧的 powershell 进程后再启动。',
            '今日任务', [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information)
        exit
    }
}

try { [System.IO.File]::WriteAllText($script:PidFile, [string]$PID, (New-Object System.Text.UTF8Encoding($false))) } catch {}
script:Boot-Trace ('单实例通过 pid=' + $PID)

# ---------- 建窗 ----------
$reader = New-Object System.Xml.XmlNodeReader ([xml]$Xaml)
$script:Window      = [System.Windows.Markup.XamlReader]::Load($reader)
script:Boot-Trace '窗口已构建（尚未显示）'

# 启动后主动抢一次焦点，避免「其实开了、但被别的窗口压住看不见」
$script:Window.Add_Loaded({
    try {
        $script:Window.Activate() | Out-Null
        script:Boot-Trace '窗口已显示'
    } catch { script:Boot-Trace ('Activate 失败: ' + $_.Exception.Message) }
})

# 全局兜底：界面线程 / 后台线程的未处理异常一律记进 error.log，
# 不允许再出现「窗口无声无息消失、什么痕迹都没留」的情况。
try {
    [System.Windows.Threading.Dispatcher]::CurrentDispatcher.add_UnhandledException({
        param($s, $e)
        Log-Err 'dispatcher-unhandled' $e.Exception
        $e.Handled = $true
    })
} catch {}
try {
    [AppDomain]::CurrentDomain.add_UnhandledException({
        param($s, $e)
        try {
            $ex = $e.ExceptionObject -as [Exception]
            if ($null -eq $ex) { $ex = New-Object Exception([string]$e.ExceptionObject) }
            Log-Err 'appdomain-unhandled' $ex
        } catch {}
    })
} catch {}

Bind-Controls
Wire-Events

# 位置：默认右上角，之后记住上次拖到哪
$wa = [System.Windows.SystemParameters]::WorkArea
$script:Window.Left = $wa.Right - 350
$script:Window.Top  = $wa.Top + 110
if (Test-Path -LiteralPath $script:PosFile) {
    try {
        $p = Get-Content -LiteralPath $script:PosFile -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($p.left) { $script:Window.Left = [double]$p.left }
        if ($p.top)  { $script:Window.Top  = [double]$p.top }
    } catch {}
}
if ($script:Window.Left -lt $wa.Left) { $script:Window.Left = $wa.Left }
if ($script:Window.Top -lt $wa.Top) { $script:Window.Top = $wa.Top }
if ($script:Window.Left -gt ($wa.Right - 120)) { $script:Window.Left = $wa.Right - 340 }
if ($script:Window.Top -gt ($wa.Bottom - 80)) { $script:Window.Top = $wa.Bottom - 120 }

# 轮询：3 秒看一次数据版本变没变（网页改的、agent 改的，都能看到）
$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [System.TimeSpan]::FromSeconds(3)
$timer.Add_Tick({ param($s, $e) Poll-Now })
$timer.Start()

Refresh-Now

script:Boot-Trace ('准备进入消息循环 left=' + [int]$script:Window.Left + ' top=' + [int]$script:Window.Top + ' w=' + 322)

$app = New-Object System.Windows.Application
$null = $app.Run($script:Window)
