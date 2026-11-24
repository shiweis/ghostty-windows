# Scoped native acceptance cases loaded by test_tab_bar.ps1 -Case native-settings.
# All posted input goes to HWNDs verified to belong to the fixture process.
function Set-TestConfig($run, $pane, [string[]]$lines) {
    Add-Content -LiteralPath $run.Config -Value $lines
    [TabBarTestNative]::Key($pane, 0x75) # F6 = reload_config
}

function Run-HoverFocus {
    $run = Start-Run 1.0 'settings-focus' -extraConfig @(
        'focus-follows-mouse = false', 'keybind = f8=new_split:right',
        'keybind = f7=new_window', 'keybind = f6=reload_config')
    $first = Shell-Pid $run
    $second = Add-Pane $run $first -Split
    $left, $right = $run.Panes[$first], $run.Panes[$second]
    Wait-For $run 'right pane has keyboard focus in the app' { [TabBarTestNative]::Focus($right) -eq $right }
    [TabBarTestNative]::Post($left, 0x200, 0, 0x00140014)
    # A child acknowledgement is a FIFO barrier for the preceding posted move.
    [TabBarTestNative]::Key($right, 0x58)
    Wait-For $run 'right child acknowledges x' { ((State $run $second).Keys -join '') -eq 'x' }
    Check ([TabBarTestNative]::Focus($left) -eq $right) 'disabled hover keeps the active split' @{}

    Set-TestConfig $run $right @('focus-follows-mouse = true', 'window-show-tab-bar = never')
    Wait-For $run 'reload hides tab bar before next mouse move' {
        @([TabBarTestNative]::Find('GhosttyChrome', [IntPtr]::Zero, $true)).Count -eq 0
    }
    $foreground = [TabBarTestNative]::Foreground($run.Top)
    [TabBarTestNative]::Post($left, 0x200, 0, 0x00150015)
    if ($foreground) {
        Wait-For $run 'enabled hover selects left split' { [TabBarTestNative]::Focus($right) -eq $left -and (Shell-Pid $run) -eq $first }
        [TabBarTestNative]::Post($right, 0x200, 0, 0x00160016)
        Wait-For $run 'enabled hover returns focus to right split' { [TabBarTestNative]::Focus($left) -eq $right -and (Shell-Pid $run) -eq $second }
    } else {
        # A shared desktop can keep another application in front. Check
        # that real case here; the Windows Zig fixture supplies the owner
        # for its foreground case without activating a user's window.
        [TabBarTestNative]::Key($right, 0x5a)
        Wait-For $run 'right pane acknowledges background hover' { ((State $run $second).Keys -join '') -eq 'xz' }
        Check ([TabBarTestNative]::Focus($left) -eq $right) 'hover over the background app preserves its active split' @{}
    }
    [TabBarTestNative]::Key($right, 0x76)
    Wait-For $run 'new window owns the app keyboard focus' {
        $other = @([TabBarTestNative]::Find('GhosttyWindow', [IntPtr]::Zero, $true) | Where-Object { $_ -ne $run.Top })
        if ($other.Count -ne 1 -or [TabBarTestNative]::Foreground($run.Top)) { return $false }
        $panes = @([TabBarTestNative]::Find('GhosttyTerminal', $other[0], $true))
        if ($panes.Count -ne 1 -or [TabBarTestNative]::Focus($left) -ne $panes[0]) { return $false }
        $run.Other = $other[0]
        $run.OtherPane = $panes[0]
        return [TabBarTestNative]::Text($run.Other) -match '^tab-probe-\d+$'
    }
    $otherPid = [int]([TabBarTestNative]::Text($run.Other) -replace '^tab-probe-','')
    [TabBarTestNative]::Post($left, 0x200, 0, 0x00170017)
    [TabBarTestNative]::Key($run.OtherPane, 0x59)
    Wait-For $run 'foreground child acknowledges y' { ((State $run $otherPid).Keys -join '') -eq 'y' }
    Check (-not [TabBarTestNative]::Foreground($run.Top) -and [TabBarTestNative]::Focus($left) -eq $run.OtherPane -and (Shell-Pid $run) -eq $second) 'hover over inactive window preserves both active pane and keyboard focus' @{FirstWindowHadForeground=$foreground}
    Stop-RunCleanly $run
}

function Read-TestPixel($captureWindow, [int]$screenX, [int]$screenY) {
    $rect = [TabBarTestNative]::PaneBounds($captureWindow)
    $bitmap = [TabBarTestNative]::WindowBitmap($captureWindow)
    try { return $bitmap.GetPixel($screenX - $rect.Left, $screenY - $rect.Top).ToArgb() -band 0xffffff }
    finally { $bitmap.Dispose() }
}

function Run-ScrollbarPolicy {
    $run = Start-Run 1.0 'settings-scrollbar' -extraConfig @(
        'scrollbar = system', 'mouse-scroll-multiplier = 100',
        'keybind = f1=scroll_to_top', 'keybind = f2=scroll_to_bottom', 'keybind = f6=reload_config')
    $pidValue = Shell-Pid $run
    $pane = $run.Panes[$pidValue]
    $popup = @([TabBarTestNative]::Find('GhosttyScrollbar', [IntPtr]::Zero, $true))[0]
    $dynamic = [Microsoft.Win32.Registry]::GetValue('HKEY_CURRENT_USER\Control Panel\Accessibility', 'DynamicScrollbars', $null)
    $overlay = $null -eq $dynamic -or $dynamic -ne 0
    function PaneColor {
        $rect = [TabBarTestNative]::PaneBounds($pane)
        return Read-TestPixel $run.Top ($rect.Left + 30) ($rect.Top + 30)
    }
    function Query-Bar { return [TabBarTestNative]::Message($popup, 0x401, 0, [IntPtr]::Zero) }
    function Wheel([int]$delta) {
        $rect = [TabBarTestNative]::PaneBounds($pane)
        $point = (($rect.Left + 30) -band 65535) -bor ((($rect.Top + 30) -band 65535) -shl 16)
        [TabBarTestNative]::Post($pane, 0x20a, [long]$delta * 65536, $point)
    }
    function CheckScrollInput($policy) {
        [TabBarTestNative]::Key($pane, 0x70)
        Wait-For $run "$policy scroll-to-top renders retained blue rows" { (PaneColor) -eq 0x24509c }
        [TabBarTestNative]::Key($pane, 0x71)
        Wait-For $run "$policy scroll-to-bottom renders live green rows" { (PaneColor) -eq 0x249c50 }
        Wheel 120
        Wait-For $run "$policy wheel scrolls up to the blue rows" { (PaneColor) -eq 0x24509c }
        Wheel -120
        Wait-For $run "$policy wheel scrolls back to the green rows" { (PaneColor) -eq 0x249c50 }
    }
    $history = [Text.StringBuilder]::new()
    foreach ($index in 0..299) {
        $color = if ($index -lt 250) { '36;80;156' } else { '36;156;80' }
        [void]$history.AppendLine(([string][char]27 + '[48;2;' + $color + 'm        ' + [char]27 + '[0m ' + $index))
    }
    $path = Join-Path $run.State "history-$pidValue"
    [IO.File]::WriteAllText("$path.tmp", $history.ToString())
    [IO.File]::Move("$path.tmp", $path)
    Wait-For $run 'fixture shows live green rows' { (PaneColor) -eq 0x249c50 }
    CheckScrollInput 'system'
    $outer = [TabBarTestNative]::Bounds($run.Top)
    [TabBarTestNative]::Key($pane, 0x58)
    Wait-For $run 'child reports initial grid' { ((State $run $pidValue).Keys -join '') -eq 'x' }
    $before = State $run $pidValue
    # Click the track above the thumb twice to scroll by two pages.
    $barRect = [TabBarTestNative]::PaneBounds($popup)
    $trackPoint = 0x00020001
    foreach ($step in 1..2) {
        [TabBarTestNative]::Post($popup, 0x201, 1, $trackPoint)
        [TabBarTestNative]::Post($popup, 0x202, 0, $trackPoint)
    }
    Wait-For $run 'clicking the track renders historical rows' { (PaneColor) -eq 0x24509c }
    if ($overlay) {
        [TabBarTestNative]::Post($popup, 0x2a3, 0, 0) # WM_MOUSELEAVE
        Wait-For $run 'system overlay fades after pointer leaves' { (Query-Bar) -eq 0 }
    } else {
        Check ((Query-Bar) -eq 2) 'system always-visible scrollbar stays shown' @{}
    }
    Set-TestConfig $run $pane @('scrollbar = never')
    Wait-For $run 'never hides the native popup' {
        (Query-Bar) -eq 0 -and @([TabBarTestNative]::Find('GhosttyScrollbar', [IntPtr]::Zero, $true)).Count -eq 0
    }
    CheckScrollInput 'never'
    Check ((Query-Bar) -eq 0) 'hidden scrollbar stays hidden while scrolling' @{}
    [TabBarTestNative]::Key($pane, 0x59)
    Wait-For $run 'child reports grid with scrollbar disabled' { ((State $run $pidValue).Keys -join '') -eq 'xy' }
    $hidden = State $run $pidValue
    Set-TestConfig $run $pane @('scrollbar = system')
    Wait-For $run 'reload restores native system popup' { $popup -in @([TabBarTestNative]::Find('GhosttyScrollbar', [IntPtr]::Zero, $true)) }
    [TabBarTestNative]::Key($pane, 0x5a)
    Wait-For $run 'child reports restored grid' { ((State $run $pidValue).Keys -join '') -eq 'xyz' }
    $restored = State $run $pidValue
    $gutterOK = if ($overlay) { $hidden.Columns -eq $before.Columns } else { $hidden.Columns -gt $before.Columns }
    Check ($gutterOK -and $before.Columns -eq $restored.Columns -and $before.Rows -eq $restored.Rows -and [TabBarTestNative]::Bounds($run.Top) -eq $outer) 'scrollbar policy round trip restores the grid at fixed window bounds' @{
        SystemOverlay=$overlay; Before=$before.Columns; Hidden=$hidden.Columns; Restored=$restored.Columns; Rows=$restored.Rows; BarWidth=$barRect.Width
    }
    Stop-RunCleanly $run
}

function Read-TabInk($strip) {
    $bitmap = [TabBarTestNative]::WindowBitmap($strip)
    try {
        # An active single tab centers its caption. Exclude the border, plus
        # button and any hover decoration, then measure its real glyph mask.
        $mask = [Collections.Generic.List[byte]]::new()
        $ink = 0
        for ($y = 1; $y -lt $bitmap.Height - 1; $y++) {
            for ($x = [int]($bitmap.Width / 4); $x -lt 3 * $bitmap.Width / 4; $x++) {
                $pixel = $bitmap.GetPixel($x, $y)
                $light = $pixel.R -ge 128 -and $pixel.G -ge 128 -and $pixel.B -ge 128
                $mask.Add([byte]$light)
                if ($light) { $ink++ }
            }
        }
        return @{Ink=$ink; Hash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($mask.ToArray()))}
    } finally { $bitmap.Dispose() }
}

function Run-TabLayoutSettings {
    $run = Start-Run 1.0 'settings-layout' -extraConfig @(
        'window-title-font-family = Consolas', 'split-divider-color = #e74021',
        'keybind = f8=new_split:right', 'keybind = f6=reload_config', 'keybind = f3=toggle_split_zoom')
    $first = Shell-Pid $run
    $second = Add-Pane $run $first -Split
    $left, $right = $run.Panes[$first], $run.Panes[$second]
    $strip = @([TabBarTestNative]::Find('GhosttyChrome', [IntPtr]::Zero, $true))[0]
    $chrome = @([TabBarTestNative]::Find('GhosttyChrome', $run.Top, $true))[0]
    $stripRect = [TabBarTestNative]::PaneBounds($strip)
    $barHeight = $stripRect.Bottom - $stripRect.Top
    $outer = [TabBarTestNative]::Bounds($run.Top)
    $initialLeft = [TabBarTestNative]::PaneBounds($left)
    $initialRight = [TabBarTestNative]::PaneBounds($right)
    function DividerPixel {
        $a, $b = [TabBarTestNative]::PaneBounds($left), [TabBarTestNative]::PaneBounds($right)
        return Read-TestPixel $chrome ([Math]::Floor(($a.Right + $b.Left) / 2)) ([int](($a.Bottom + $a.Top)/2))
    }
    Wait-For $run 'divider uses first configured color' { (DividerPixel) -eq 0xe74021 }
    $dividerX = [int][Math]::Floor(($initialLeft.Right + $initialRight.Left) / 2)
    $dividerY = [int](($initialLeft.Top + $initialLeft.Bottom) / 2)
    [TabBarTestNative]::Key($right, 0x72)
    Wait-For $run 'zoomed pane fills the previous divider position' {
        @(Children $run).Count -eq 1 -and ([TabBarTestNative]::PaneBounds($right)).Left -eq $initialLeft.Left -and
            (Read-TestPixel $run.Top $dividerX $dividerY) -eq 0x1e1e2e
    }
    [TabBarTestNative]::Key($right, 0x72)
    Wait-For $run 'unzoom restores both panes and the colored line' { @(Children $run).Count -eq 2 -and (DividerPixel) -eq 0xe74021 }
    $before = Read-TabInk $strip
    Check ($before.Ink -gt 20) 'tab caption renders legible pixels in the initial font' @{InkPixels=$before.Ink}
    Set-TestConfig $run $right @('window-title-font-family = Times New Roman', 'split-divider-color = #39ca81')
    Wait-For $run 'divider repaints in the new color' { (DividerPixel) -eq 0x39ca81 }
    Wait-For $run 'visible tab glyphs change after font reload' { $ink = Read-TabInk $strip; $ink.Ink -gt 20 -and $ink.Hash -ne $before.Hash }
    $after = Read-TabInk $strip
    Set-TestConfig $run $right @('window-title-font-family = Consolas')
    Wait-For $run 'restoring original family restores the same glyph mask' { (Read-TabInk $strip).Hash -eq $before.Hash }
    Set-TestConfig $run $right @('window-title-font-family = Segoe UI')
    Wait-For $run 'Segoe UI draws a distinct caption' { $ink = Read-TabInk $strip; $ink.Ink -gt 20 -and $ink.Hash -ne $before.Hash }
    $fallback = Read-TabInk $strip
    Set-TestConfig $run $right @('window-title-font-family = This requested font name exceeds the Windows face length', 'split-divider-color = #39ca82')
    Wait-For $run 'invalid face length falls back to Segoe UI on reload' { (DividerPixel) -eq 0x39ca82 -and (Read-TabInk $strip).Hash -eq $fallback.Hash }
    Set-TestConfig $run $right @('window-show-tab-bar = never')
    Wait-For $run 'both panes reclaim the exact hidden tab height' {
        $a, $b = [TabBarTestNative]::PaneBounds($left), [TabBarTestNative]::PaneBounds($right)
        $a.Top -eq $initialLeft.Top - $barHeight -and $b.Top -eq $initialRight.Top - $barHeight -and
            $a.Bottom -eq $initialLeft.Bottom -and $b.Left -eq $initialRight.Left -and
            $strip -notin @([TabBarTestNative]::Find('GhosttyChrome', [IntPtr]::Zero, $true))
    }
    Set-TestConfig $run $right @('window-show-tab-bar = auto')
    $third = Add-Pane $run $second
    Wait-For $run 'auto shows the strip when a second tab opens' { $strip -in @([TabBarTestNative]::Find('GhosttyChrome', [IntPtr]::Zero, $true)) }
    [TabBarTestNative]::TabClick($run.Top, 0, 2)
    Wait-For $run 'split layout restored in the original tab' {
        @(Children $run).Count -eq 2 -and ([TabBarTestNative]::PaneBounds($left)).Top -eq $initialLeft.Top -and
            ([TabBarTestNative]::PaneBounds($right)).Top -eq $initialRight.Top
    }
    Request-Exit $run $third
    Wait-For $run 'auto hides the strip when the second tab closes' { $strip -notin @([TabBarTestNative]::Find('GhosttyChrome', [IntPtr]::Zero, $true)) }
    Set-TestConfig $run $right @('window-show-tab-bar = always')
    Wait-For $run 'always restores tab strip and both panes' {
        $strip -in @([TabBarTestNative]::Find('GhosttyChrome', [IntPtr]::Zero, $true)) -and
            ([TabBarTestNative]::PaneBounds($right)).Top -eq $initialRight.Top
    }
    Check ([TabBarTestNative]::Bounds($run.Top) -eq $outer) 'font and layout reload preserve outer window bounds' @{
        TabBarHeight=$barHeight; ConsolasInk=$before.Ink; TimesInk=$after.Ink; DividerColors=@('e74021', '39ca81')
    }
    Stop-RunCleanly $run
}

function Run-NativeSettings {
    Run-ScrollbarPolicy
    Run-TabLayoutSettings
    Run-HoverFocus
}
