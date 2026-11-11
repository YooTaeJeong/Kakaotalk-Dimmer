param(
    [int]$MinWindowSize = 120,
    [switch]$DisableClipping,
    [switch]$DebugClipping
)

# ---- DPI Awareness (스레드 단위 강제 + 폴백 체인) ----
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class DpiHelper {
    [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr value);
    [DllImport("user32.dll")] public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr dpiContext);
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
}
"@
try {
    $procOk = [DpiHelper]::SetProcessDpiAwarenessContext([IntPtr]::new(-4))
    if (-not $procOk) { [DpiHelper]::SetProcessDPIAware() | Out-Null }
    [DpiHelper]::SetThreadDpiAwarenessContext([IntPtr]::new(-4)) | Out-Null
} catch {
    try { [DpiHelper]::SetProcessDPIAware() | Out-Null } catch { }
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::SetUnhandledExceptionMode([System.Windows.Forms.UnhandledExceptionMode]::CatchException)
[System.Windows.Forms.Application]::EnableVisualStyles()

# ---- 설정/로그 파일 ----
$configDir  = Join-Path $env:APPDATA "KakaoDarkOverlay"
$configFile = Join-Path $configDir "settings.txt"
$debugLog   = Join-Path $configDir "debug.log"
if (-not (Test-Path $configDir)) { New-Item -ItemType Directory -Path $configDir | Out-Null }

function Write-DebugLog($text) {
    try {
        # 창을 드래그하는 동안 클리핑 로그가 많이 쌓이므로 1MB를 넘으면 비운다.
        if ((Test-Path $debugLog) -and (Get-Item $debugLog).Length -gt 1MB) { Clear-Content $debugLog }
        Add-Content -Path $debugLog -Value ("[{0}] {1}" -f (Get-Date -Format "u"), $text)
    } catch { }
}

[System.Windows.Forms.Application]::add_ThreadException({
    param($sender, $e)
    Write-DebugLog ("THREAD EXCEPTION: " + $e.Exception.ToString())
})
[System.AppDomain]::CurrentDomain.add_UnhandledException({
    param($sender, $e)
    Write-DebugLog ("UNHANDLED EXCEPTION: " + $e.ExceptionObject.ToString())
})

# 기본값 + 저장된 설정 불러오기
$script:currentPercent = 40
$script:currentPollMs  = 16
if (Test-Path $configFile) {
    foreach ($line in (Get-Content $configFile -ErrorAction SilentlyContinue)) {
        if ($line -match '^OpacityPercent=(\d+)$') {
            $v = [int]$Matches[1]
            if ($v -ge 0 -and $v -le 90) { $script:currentPercent = $v }
        } elseif ($line -match '^PollIntervalMs=(\d+)$') {
            $v = [int]$Matches[1]
            if ($v -ge 8 -and $v -le 500) { $script:currentPollMs = $v }
        }
    }
}

function Save-Settings {
    Set-Content -Path $configFile -Value @(
        "OpacityPercent=$($script:currentPercent)"
        "PollIntervalMs=$($script:currentPollMs)"
    )
}

# ---- 오버레이 전용 Form 클래스 ----
Add-Type -ReferencedAssemblies "System.Windows.Forms","System.Drawing" -TypeDefinition @"
using System;
using System.Windows.Forms;

public class OverlayForm : Form {
    private const int WM_NCHITTEST = 0x0084;
    private const int HTTRANSPARENT = -1;

    public OverlayForm() {
        FormBorderStyle = FormBorderStyle.None;
        ShowInTaskbar = false;
        StartPosition = FormStartPosition.Manual;
        BackColor = System.Drawing.Color.Black;
        TopMost = true;
    }

    protected override CreateParams CreateParams {
        get {
            var cp = base.CreateParams;
            cp.ExStyle |= 0x00000020; // WS_EX_TRANSPARENT (클릭 통과)
            cp.ExStyle |= 0x00080000; // WS_EX_LAYERED (반투명)
            cp.ExStyle |= 0x00000080; // WS_EX_TOOLWINDOW
            cp.ExStyle |= 0x08000000; // WS_EX_NOACTIVATE
            return cp;
        }
    }

    // .NET이 내부적으로 Show() 시 SW_SHOWNOACTIVATE를 쓰도록 함 (별도 API 호출 불필요)
    protected override bool ShowWithoutActivation {
        get { return true; }
    }

    protected override void WndProc(ref Message m) {
        if (m.Msg == WM_NCHITTEST) { m.Result = (IntPtr)HTTRANSPARENT; return; }
        // 배율(DPI)이 다른 모니터로 넘어갈 때 WinForms가 창 크기/위치를 멋대로 바꾸지 않게 무시.
        // 위치는 타이머에서 SetWindowPos로 물리 픽셀 기준으로 직접 맞춘다.
        if (m.Msg == 0x02E0 /* WM_DPICHANGED */) { m.Result = IntPtr.Zero; return; }
        base.WndProc(ref m);
    }
}
"@

# ---- Win32 API ----
Add-Type @"
using System;
using System.Runtime.InteropServices;
using System.Text;
using System.Collections.Generic;

public class Win32 {
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc enumProc, IntPtr lParam);
    [DllImport("user32.dll")] public static extern int GetWindowThreadProcessId(IntPtr hWnd, out int lpdwProcessId);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hWnd);
    [DllImport("user32.dll", CharSet = CharSet.Auto)] public static extern int GetClassName(IntPtr hWnd, StringBuilder lpClassName, int nMaxCount);
    [DllImport("user32.dll", CharSet = CharSet.Auto)] public static extern int GetWindowText(IntPtr hWnd, StringBuilder lpString, int nMaxCount);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);
    [DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr hWnd, int nIndex);
    [DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr hWnd, int dwAttribute, out int pvAttribute, int cbAttribute);

    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    // 백그라운드로 내려간 UWP 앱(설정, 계산기, 스토어 등)은 IsWindowVisible=true지만 실제로는
    // DWM이 숨겨둔(cloaked) 창이다. 이런 창이 특정 모니터에 걸쳐 있으면 카톡을 가린 것으로
    // 오인해서 그 모니터의 오버레이가 통째로 잘려나갔다.
    public static bool IsCloaked(IntPtr hWnd) {
        int cloaked = 0;
        try {
            if (DwmGetWindowAttribute(hWnd, 14 /* DWMWA_CLOAKED */, out cloaked, sizeof(int)) != 0) return false;
        } catch { return false; }
        return cloaked != 0;
    }

    public static string GetTitleOf(IntPtr hWnd) {
        var sb = new StringBuilder(256);
        GetWindowText(hWnd, sb, 256);
        return sb.ToString();
    }
    public struct RECT { public int Left, Top, Right, Bottom; }

    private static readonly HashSet<string> ShellClassNames = new HashSet<string> {
        "Progman", "WorkerW", "Shell_TrayWnd", "Shell_SecondaryTrayWnd"
    };

    // 툴팁/메뉴/드롭다운처럼 "진짜 보이는 창"이 아니라 OS가 잠깐 띄우는 보조용 창들.
    // 이런 것까지 오버레이 대상에 넣으면 화면 아무 데나 까만 사각형이 깜빡이는 부작용이 생긴다.
    private static readonly HashSet<string> HelperClassNames = new HashSet<string> {
        "tooltips_class32", "#32768", "ComboLBox", "DropDown"
    };

    public static string GetClassNameOf(IntPtr hWnd) {
        var sb = new StringBuilder(256);
        GetClassName(hWnd, sb, 256);
        return sb.ToString();
    }

    public static bool IsShellWindow(IntPtr hWnd) {
        string cls = GetClassNameOf(hWnd);
        if (ShellClassNames.Contains(cls)) return true;
        // HwndWrapper[...]: WPF 기반 백그라운드 유틸리티들이 자신도 모르게 끼어드는 경우가 있어 제외
        if (cls.StartsWith("HwndWrapper[")) return true;
        // 펜/필기 입력용 투명 창. 주 모니터 전체를 덮고 있어서 그 모니터의 오버레이가 통째로 잘렸다.
        if (cls.StartsWith("ShellHandwritingCanvas")) return true;
        // 클릭이 통과하는(WS_EX_TRANSPARENT) 창은 화면을 실제로 가리지 않는 오버레이류이므로 제외
        if ((GetWindowLong(hWnd, -20 /* GWL_EXSTYLE */) & 0x20 /* WS_EX_TRANSPARENT */) != 0) return true;
        return false;
    }

    public static bool IsHelperWindow(IntPtr hWnd) {
        return HelperClassNames.Contains(GetClassNameOf(hWnd));
    }

    public static List<IntPtr> GetAllVisibleWindowsZOrder() {
        var result = new List<IntPtr>();
        EnumWindows((hWnd, lParam) => {
            // 제목(title)이 비어있어도 대상에 포함시킨다 - 카카오톡 내장 이미지/파일 뷰어처럼
            // 제목 없는 팝업도 어둡게 하려면 필요하다. 대신 진짜 보조용 창(툴팁/메뉴 등)은
            // IsHelperWindow로 따로 걸러낸다.
            if (IsWindowVisible(hWnd) && !IsIconic(hWnd) && !IsShellWindow(hWnd) && !IsHelperWindow(hWnd) && !IsCloaked(hWnd)) {
                result.Add(hWnd);
            }
            return true;
        }, IntPtr.Zero);
        return result;
    }
}
"@

Add-Type @"
using System;
using System.Runtime.InteropServices;

public class Win32Extra {
    [DllImport("user32.dll")]
    public static extern bool SetLayeredWindowAttributes(IntPtr hwnd, uint crKey, byte bAlpha, uint dwFlags);
    [DllImport("user32.dll")]
    public static extern bool SetWindowDisplayAffinity(IntPtr hWnd, uint dwAffinity);
    [DllImport("user32.dll")]
    public static extern int SetWindowRgn(IntPtr hWnd, IntPtr hRgn, bool bRedraw);
    [DllImport("user32.dll")]
    public static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, uint uFlags);
    [DllImport("gdi32.dll")]
    public static extern IntPtr CreateRectRgn(int x1, int y1, int x2, int y2);
    [DllImport("gdi32.dll")]
    public static extern int CombineRgn(IntPtr hrgnDest, IntPtr hrgnSrc1, IntPtr hrgnSrc2, int fnCombineMode);
    [DllImport("gdi32.dll")]
    public static extern bool DeleteObject(IntPtr hObject);
    [DllImport("user32.dll")]
    public static extern bool DestroyIcon(IntPtr hIcon);
}
"@

$LWA_ALPHA      = 0x2
$RGN_DIFF       = 4
$HWND_TOPMOST   = [IntPtr]::new(-1)
$SWP_NOACTIVATE = 0x0010

# Windows 10 2004(빌드 19041)부터 지원. 오버레이 창 자체를 화면 캡처에서 제외시켜서
# 내 화면에는 평소처럼 어둡게 보이되, 녹화/화면공유 쪽에는 전혀 찍히지 않게 한다.
$WDA_EXCLUDEFROMCAPTURE = 0x00000011
$script:supportsExcludeFromCapture = [Environment]::OSVersion.Version.Build -ge 19041

$script:overlays = @{}   # hwnd(문자열) -> [PSCustomObject]@{ Form }
$script:lastClipSig = @{}   # hwnd(문자열) -> 마지막으로 기록한 클리핑 상태 (debug.log 중복 방지)

Write-DebugLog "START"
foreach ($s in [System.Windows.Forms.Screen]::AllScreens) {
    Write-DebugLog ("  screen {0} primary={1} bounds={2}" -f $s.DeviceName, $s.Primary, $s.Bounds)
}

function New-OverlayEntry {
    $form = New-Object OverlayForm
    $null = $form.Handle
    if ($script:supportsExcludeFromCapture) {
        if (-not [Win32Extra]::SetWindowDisplayAffinity($form.Handle, $WDA_EXCLUDEFROMCAPTURE)) {
            Write-DebugLog "SetWindowDisplayAffinity(WDA_EXCLUDEFROMCAPTURE) 실패"
        }
    }
    return [PSCustomObject]@{ Form = $form }
}

# ---- Ctrl+C 처리를 UI 스레드로 안전하게 넘기기 위한 숨은 더미 폼 ----
$script:pumpForm = New-Object System.Windows.Forms.Form
$script:pumpForm.ShowInTaskbar = $false
$script:pumpForm.WindowState = 'Minimized'
$null = $script:pumpForm.Handle

# ---- 트레이 아이콘 & 메뉴 ----
$trayIcon = New-Object System.Windows.Forms.NotifyIcon
$iconPath = Join-Path $PSScriptRoot "icon.ico"
if (Test-Path $iconPath) {
    $trayIcon.Icon = New-Object System.Drawing.Icon($iconPath)
} else {
    $trayIcon.Icon = [System.Drawing.SystemIcons]::Application
}
$trayIcon.Visible = $true

$trayMenu = New-Object System.Windows.Forms.ContextMenuStrip

# --- 정보 ---
$infoItem = New-Object System.Windows.Forms.ToolStripMenuItem("정보")
$infoItem.Add_Click({
    [System.Windows.Forms.MessageBox]::Show(
        "Made by 이현섭, 유태정 (Eddie Yoo)`nVersion: Version 2.0.0",
        "정보",
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Information
    ) | Out-Null
})
$trayMenu.Items.Add($infoItem) | Out-Null
$trayMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null

# --- 밝기 서브메뉴 ---
$brightnessMenu = New-Object System.Windows.Forms.ToolStripMenuItem("밝기")
$trayMenu.Items.Add($brightnessMenu) | Out-Null
$percents = 0,10,20,30,40,50,60,70,80,90
$script:percentItems = @{}
foreach ($p in $percents) {
    $label = if ($p -eq 0) { "끄기" } else { "$p%" }
    $item = New-Object System.Windows.Forms.ToolStripMenuItem($label)
    $item.Tag = $p
    $item.Add_Click({
        param($sender, $e)
        $script:currentPercent = [int]$sender.Tag
        foreach ($kv in $script:percentItems.GetEnumerator()) { $kv.Value.Checked = ($kv.Key -eq $script:currentPercent) }
        Update-TrayChecksAndText
        Save-Settings
    })
    $brightnessMenu.DropDownItems.Add($item) | Out-Null
    $script:percentItems[$p] = $item
}

# --- 반응속도 서브메뉴 ---
$speedMenu = New-Object System.Windows.Forms.ToolStripMenuItem("반응속도")
$trayMenu.Items.Add($speedMenu) | Out-Null
$speedOptions = [ordered]@{
    "매우 빠름 (8ms)"   = 8
    "빠름 (16ms)"       = 16
    "보통 (33ms)"       = 33
    "느림 (66ms)"       = 66
    "매우 느림 (100ms)" = 100
}
$script:speedItems = @{}
foreach ($label in $speedOptions.Keys) {
    $ms = $speedOptions[$label]
    $item = New-Object System.Windows.Forms.ToolStripMenuItem($label)
    $item.Tag = $ms
    $item.Add_Click({
        param($sender, $e)
        $script:currentPollMs = [int]$sender.Tag
        $timer.Interval = $script:currentPollMs
        foreach ($kv in $script:speedItems.GetEnumerator()) { $kv.Value.Checked = ($kv.Key -eq $script:currentPollMs) }
        Update-TrayChecksAndText
        Save-Settings
    })
    $speedMenu.DropDownItems.Add($item) | Out-Null
    $script:speedItems[$ms] = $item
}

$trayMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null

# 앞으로 메뉴 항목을 추가할 때는 반드시 이 지점(종료 추가) 이전에 넣을 것 -
# 종료는 항상 메뉴 맨 아래에 고정되어야 한다.
$exitItem = New-Object System.Windows.Forms.ToolStripMenuItem("종료")
$trayMenu.Items.Add($exitItem) | Out-Null

$trayIcon.ContextMenuStrip = $trayMenu

function Update-TrayChecksAndText {
    foreach ($kv in $script:percentItems.GetEnumerator()) { $kv.Value.Checked = ($kv.Key -eq $script:currentPercent) }
    foreach ($kv in $script:speedItems.GetEnumerator()) { $kv.Value.Checked = ($kv.Key -eq $script:currentPollMs) }
    $label = if ($script:currentPercent -eq 0) { "끔" } else { "$($script:currentPercent)%" }
    $trayIcon.Text = "카카오톡 다크모드 ($label / $($script:currentPollMs)ms)"
}
Update-TrayChecksAndText

# ---- PID 캐시 (Get-Process 비용을 아끼기 위해 주기적으로만 갱신) ----
$script:kakaoPidSet = @{}
$script:lastPidRefresh = [DateTime]::MinValue

function Refresh-KakaoPidsIfNeeded {
    if (((Get-Date) - $script:lastPidRefresh).TotalMilliseconds -ge 2500 -or $script:kakaoPidSet.Count -eq 0) {
        $newSet = @{}
        foreach ($p in (Get-Process -Name "KakaoTalk" -ErrorAction SilentlyContinue)) { $newSet[$p.Id] = $true }
        $script:kakaoPidSet = $newSet
        $script:lastPidRefresh = Get-Date
    }
}

# ---- 메인 타이머 ----
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = $script:currentPollMs
$timer.Add_Tick({
  try {
    if ($script:currentPercent -le 0) {
        # 꺼짐 상태: 남아있는 오버레이가 있으면 다 숨기고 리턴
        foreach ($entry in $script:overlays.Values) {
            if (-not $entry.Form.IsDisposed -and $entry.Form.Visible) { $entry.Form.Hide() }
        }
        return
    }

    Refresh-KakaoPidsIfNeeded
    $alphaByte = [byte]([Math]::Round($script:currentPercent * 255.0 / 100.0))

    $allHwnds = [Win32]::GetAllVisibleWindowsZOrder()

    $ownHandles = @{}
    foreach ($entry in $script:overlays.Values) {
        if (-not $entry.Form.IsDisposed) { $ownHandles[$entry.Form.Handle.ToInt64()] = $true }
    }
    if (-not $script:pumpForm.IsDisposed) { $ownHandles[$script:pumpForm.Handle.ToInt64()] = $true }

    $validKeys = @{}
    $higherRectsAll = @()

    foreach ($h in $allHwnds) {
        if ($ownHandles.ContainsKey($h.ToInt64())) { continue }

        $rect = New-Object Win32+RECT
        if (-not [Win32]::GetWindowRect($h, [ref]$rect)) { continue }
        $w = $rect.Right - $rect.Left
        $ht = $rect.Bottom - $rect.Top
        if ($w -le 0 -or $ht -le 0) { continue }

        $procId = 0
        [Win32]::GetWindowThreadProcessId($h, [ref]$procId) | Out-Null
        $isKakao = $script:kakaoPidSet.ContainsKey($procId)

        if ($isKakao -and $w -gt $MinWindowSize -and $ht -gt $MinWindowSize) {
            $key = $h.ToString()
            $validKeys[$key] = $true

            if (-not $script:overlays.ContainsKey($key)) {
                $script:overlays[$key] = New-OverlayEntry
            }
            $entry = $script:overlays[$key]

            if (-not $entry.Form.IsDisposed) {
                [Win32Extra]::SetLayeredWindowAttributes($entry.Form.Handle, 0, $alphaByte, $LWA_ALPHA) | Out-Null
                [Win32Extra]::SetWindowPos($entry.Form.Handle, $HWND_TOPMOST, $rect.Left, $rect.Top, $w, $ht, $SWP_NOACTIVATE) | Out-Null

                $overlapping = @()
                if (-not $DisableClipping) {
                    foreach ($hrItem in $higherRectsAll) {
                        $hr = $hrItem.Rect
                        $ix1 = [Math]::Max($rect.Left, $hr.Left)
                        $iy1 = [Math]::Max($rect.Top, $hr.Top)
                        $ix2 = [Math]::Min($rect.Right, $hr.Right)
                        $iy2 = [Math]::Min($rect.Bottom, $hr.Bottom)
                        if ($ix2 -gt $ix1 -and $iy2 -gt $iy1) { $overlapping += $hrItem }
                    }
                }

                # 어떤 창 때문에 오버레이가 잘렸는지 debug.log에 남긴다 (바뀔 때만 기록).
                $clipSig = ($overlapping | ForEach-Object {
                    "[{0} '{1}' L{2},T{3},R{4},B{5}]" -f [Win32]::GetClassNameOf($_.Hwnd), [Win32]::GetTitleOf($_.Hwnd), $_.Rect.Left, $_.Rect.Top, $_.Rect.Right, $_.Rect.Bottom
                }) -join " "
                $kakaoSig = "L{0},T{1},R{2},B{3}" -f $rect.Left, $rect.Top, $rect.Right, $rect.Bottom
                if ($script:lastClipSig[$key] -ne "$kakaoSig|$clipSig") {
                    $script:lastClipSig[$key] = "$kakaoSig|$clipSig"
                    if ($overlapping.Count -gt 0) { Write-DebugLog ("kakao({0}) clipped by: {1}" -f $kakaoSig, $clipSig) }
                }

                if ($overlapping.Count -gt 0) {
                    if ($DebugClipping) {
                        Write-Host ("[DEBUG] hwnd={0} 이(가) {1}개 창과 겹쳐서 클리핑됨:" -f $h, $overlapping.Count)
                        foreach ($hrItem in $overlapping) {
                            $cls = [Win32]::GetClassNameOf($hrItem.Hwnd)
                            Write-Host ("    -> hwnd={0} class={1} Rect=(L{2},T{3},R{4},B{5})" -f $hrItem.Hwnd, $cls, $hrItem.Rect.Left, $hrItem.Rect.Top, $hrItem.Rect.Right, $hrItem.Rect.Bottom)
                        }
                    }
                    $ownRgn = [Win32Extra]::CreateRectRgn(0, 0, $w, $ht)
                    foreach ($hrItem in $overlapping) {
                        $hr = $hrItem.Rect
                        $lx1 = $hr.Left - $rect.Left; $ly1 = $hr.Top - $rect.Top
                        $lx2 = $hr.Right - $rect.Left; $ly2 = $hr.Bottom - $rect.Top
                        $subRgn = [Win32Extra]::CreateRectRgn($lx1, $ly1, $lx2, $ly2)
                        [Win32Extra]::CombineRgn($ownRgn, $ownRgn, $subRgn, $RGN_DIFF) | Out-Null
                        [Win32Extra]::DeleteObject($subRgn) | Out-Null
                    }
                    [Win32Extra]::SetWindowRgn($entry.Form.Handle, $ownRgn, $true) | Out-Null
                } else {
                    [Win32Extra]::SetWindowRgn($entry.Form.Handle, [IntPtr]::Zero, $true) | Out-Null
                }

                if (-not $entry.Form.Visible) { $entry.Form.Show() }
            }
        }

        $higherRectsAll += [PSCustomObject]@{ Hwnd = $h; Rect = $rect }
    }

    $staleKeys = @()
    foreach ($key in $script:overlays.Keys) {
        if (-not $validKeys.ContainsKey($key)) { $staleKeys += $key }
    }
    foreach ($key in $staleKeys) {
        $entry = $script:overlays[$key]
        if (-not $entry.Form.IsDisposed) { $entry.Form.Close() }
        $script:overlays.Remove($key)
        $script:lastClipSig.Remove($key)
    }
  } catch {
    Write-DebugLog ("TICK ERROR: " + $_.Exception.ToString())
  }
})

# ---- 안전한 종료 절차 ----
$script:isShuttingDown = $false
function Stop-Overlay {
    if ($script:isShuttingDown) { return }
    $script:isShuttingDown = $true
    $timer.Stop()
    $trayIcon.Visible = $false
    $trayIcon.Dispose()
    foreach ($entry in $script:overlays.Values) {
        if (-not $entry.Form.IsDisposed) { $entry.Form.Close() }
    }
    $script:overlays.Clear()
    if (-not $script:pumpForm.IsDisposed) { $script:pumpForm.Close() }
    [System.Windows.Forms.Application]::Exit()
}

$exitItem.Add_Click({ Stop-Overlay })

[Console]::add_CancelKeyPress({
    param($eventSource, $eventArgs)
    $eventArgs.Cancel = $true
    if (-not $script:pumpForm.IsDisposed) {
        $script:pumpForm.BeginInvoke([Action]{ Stop-Overlay }) | Out-Null
    }
})

$timer.Start()
[System.Windows.Forms.Application]::Run()
