# Loaded by test_tab_bar.ps1 -Case pane-menu. All messages target the
# staged application, including its standard USER32 popup menu and dialog.
function Open-PaneMenu($run, $pane) {
    [TabBarTestNative]::Post($pane, 0x204, 2, 0x00140014)
    Wait-For $run 'real pane popup menu' {
        $menus = @([TabBarTestNative]::Find('#32768', [IntPtr]::Zero, $true))
        if ($menus.Count -ne 1 -or [TabBarTestNative]::MenuIndex($menus[0], 'Close Split') -lt 0) { return $false }
        $run.Menu = $menus[0]
        return $true
    }
    return $run.Menu
}

function Add-MenuSplit($run, $source, $label) {
    $prior = @(Children $run)
    $priorPids = @(Child-Pids $run)
    $menu = Open-PaneMenu $run $source
    [TabBarTestNative]::ChooseMenuItem($menu, $label)
    Wait-For $run "$label creates one new terminal and child" {
        $visible = @(Children $run)
        $new = @($visible | Where-Object { $_ -notin $prior })
        $pidValue = Shell-Pid $run
        if ($visible.Count -ne $prior.Count + 1 -or $new.Count -ne 1 -or
            $pidValue -in $priorPids -or $pidValue -notin @(Child-Pids $run)) { return $false }
        $run.Panes[$pidValue] = $new[0]
        return $true
    }
    return Shell-Pid $run
}

function Run-PaneMenu {
    $run = Start-Run 1.0 'pane-menu' $true -extraConfig @('right-click-action = context-menu', 'keybind = f5=toggle_readonly')
    $firstPid = Shell-Pid $run
    $first = $run.Panes[$firstPid]
    $menu = Open-PaneMenu $run $first
    foreach ($label in @('Split Right','Split Left','Split Down','Split Up','Close Split')) {
        Check ([TabBarTestNative]::MenuIndex($menu, $label) -ge 0) "unsplit pane offers $label" @{}
    }
    [TabBarTestNative]::ChooseMenuItem($menu, 'Close Split')
    Wait-For $run 'close of the only running pane asks for confirmation' { @(Dialogs $run).Count -eq 1 }
    Answer-Dialog $run 2
    Wait-For $run 'declining close dismisses confirmation' { @(Dialogs $run).Count -eq 0 }
    Check ((Shell-Pid $run) -eq $firstPid -and @(Children $run).Count -eq 1) 'cancel keeps the original pane and child' @{}

    $leftPid = Add-MenuSplit $run $first 'Split Left'
    $left = $run.Panes[$leftPid]
    Check (([TabBarTestNative]::PaneBounds($left)).Right -le ([TabBarTestNative]::PaneBounds($first)).Left) 'Split Left places the new child on the left' @{}
    $upperPid = Add-MenuSplit $run $left 'Split Up'
    $upper = $run.Panes[$upperPid]
    Check (([TabBarTestNative]::PaneBounds($upper)).Bottom -le ([TabBarTestNative]::PaneBounds($left)).Top) 'Split Up places the new child above the target' @{}

    $menu = Open-PaneMenu $run $upper
    [TabBarTestNative]::ChooseMenuItem($menu, 'Close Split')
    Wait-For $run 'running split asks for confirmation' { @(Dialogs $run).Count -eq 1 }
    Answer-Dialog $run 1
    Wait-For $run 'confirmed close removes only its child' {
        $visible = @(Children $run)
        $visible.Count -eq 2 -and $left -in $visible -and $first -in $visible -and -not (Child-ProcessAlive $upperPid)
    }

    # The menu's nested loop can process the originating shell's exit and
    # select a surviving pane before it returns a command.
    $menu = Open-PaneMenu $run $left
    Request-Exit $run $leftPid
    Wait-For $run 'menu target exits while native menu is open' { @(Children $run).Count -eq 1 -and -not (Child-ProcessAlive $leftPid) }
    $menuStillOpen = $menu -in @([TabBarTestNative]::Find('#32768', [IntPtr]::Zero, $true))
    if ($menuStillOpen) {
        [TabBarTestNative]::ChooseMenuItem($menu, 'Close Split')
    }
    [TabBarTestNative]::Key($first, 0x58)
    Wait-For $run 'remaining child accepts input after stale menu returns' { ((State $run $firstPid).Keys -join '') -eq 'x' }
    Check (@(Dialogs $run).Count -eq 0) 'stale menu does not request closing the next pane' @{SelectedAfterTargetExit=$menuStillOpen}

    Request-Prompt $run $firstPid
    Wait-For $run 'last child reports a semantic prompt' { [TabBarTestNative]::Text($run.Top) -eq "tab-probe-$firstPid-prompt" }
    [TabBarTestNative]::Key($first, 0x74)
    $menu = Open-PaneMenu $run $first
    [TabBarTestNative]::ChooseMenuItem($menu, 'Close Split')
    Wait-For $run 'a read-only pane at a prompt still asks for confirmation' { @(Dialogs $run).Count -eq 1 }
    Answer-Dialog $run 2
    Wait-For $run 'read-only prompt is dismissed' { @(Dialogs $run).Count -eq 0 }
    [TabBarTestNative]::Key($first, 0x74)
    $menu = Open-PaneMenu $run $first
    [TabBarTestNative]::ChooseMenuItem($menu, 'Close Split')
    Check ($run.Process.WaitForExit(10000) -and $run.Process.ExitCode -eq 0) 'closing the final pane at a prompt exits cleanly without a dialog' @{}
}
