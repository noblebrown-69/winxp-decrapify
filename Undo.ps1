<#
.SYNOPSIS
    Reverts what Decrapify.ps1 and Install-XPTheme.ps1 changed, using the
    state file they wrote (%LOCALAPPDATA%\winxp-decrapify\state.json).

.DESCRIPTION
    - Registry values: restored to their recorded prior value, or deleted if
      the kit created them. Keys the kit created are removed if left empty.
    - Services and scheduled tasks: only the ones the kit disabled are set
      back to their recorded startup type / re-enabled.
    - Wallpaper: the recorded previous wallpaper is re-applied.
    - Open-Shell: uninstalled only if the kit installed it (-KeepOpenShell to skip).
    - Removed apps CANNOT be restored by script. Their names are printed with
      Microsoft Store / winget instructions.

    HKLM values, services and tasks need an elevated PowerShell; without admin
    those items are reported and left for an elevated re-run.
    Run with -WhatIf first.
#>
[CmdletBinding(SupportsShouldProcess)]
param([switch]$KeepOpenShell)

$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'lib\Common.ps1')
Initialize-Log -Name 'Undo'

if (-not (Test-Path $script:StateFile)) {
    Write-KitLog "No state file at $($script:StateFile). Nothing recorded, nothing to undo." 'WARN'
    exit 0
}
$st = Get-KitState
$admin = Test-IsAdmin
$remaining = @()   # registry items left for an elevated re-run

# ------------------------------------------------------------- registry
foreach ($r in @($st.Registry)) {
    $isMachine = $r.Path -like 'HKLM:*'
    if ($isMachine -and -not $admin) { Write-KitLog "Needs admin, skipped: $($r.Path)\$($r.Name)" 'WARN'; $remaining += $r; continue }
    $action = 'Delete value (kit created it)'
    if ($r.Existed) { $action = "Restore previous value '$($r.Value -join ', ')'" }
    if ($PSCmdlet.ShouldProcess("$($r.Path)\$($r.Name)", $action)) {
        try {
            if ($r.Existed) {
                if (-not (Test-Path $r.Path)) { New-Item -Path $r.Path -Force | Out-Null }
                $kind = $r.Kind; if (-not $kind) { $kind = 'DWord' }
                $val = $r.Value
                if ($kind -eq 'MultiString') { $val = [string[]]@($r.Value) }
                New-ItemProperty -Path $r.Path -Name $r.Name -Value $val -PropertyType $kind -Force | Out-Null
            } elseif (Test-Path $r.Path) {
                Remove-ItemProperty -Path $r.Path -Name $r.Name -ErrorAction SilentlyContinue
                if (-not $r.KeyExisted) {
                    $k = Get-Item $r.Path -ErrorAction SilentlyContinue
                    if ($k -and $k.ValueCount -eq 0 -and $k.SubKeyCount -eq 0) { Remove-Item $r.Path -Force -ErrorAction SilentlyContinue }
                }
            }
            Write-KitLog "Reverted $($r.Path)\$($r.Name)" 'OK'
        } catch { Write-KitLog "Could not revert $($r.Path)\$($r.Name): $($_.Exception.Message)" 'FAIL'; $remaining += $r }
    } else { $remaining += $r }
}

# ------------------------------------------------------------- services
$svcLeft = @()
foreach ($s in @($st.Services)) {
    if (-not $admin) { Write-KitLog "Needs admin, skipped service $($s.Name)" 'WARN'; $svcLeft += $s; continue }
    if ($PSCmdlet.ShouldProcess($s.Name, "Set startup type back to $($s.StartType)")) {
        try {
            $type = $s.StartType
            if ($type -notin 'Automatic', 'Manual', 'Disabled') { $type = 'Manual' }   # e.g. 'Boot'/'System' never apply here
            Set-Service -Name $s.Name -StartupType $type -ErrorAction Stop
            if ($type -eq 'Automatic') { Start-Service -Name $s.Name -ErrorAction SilentlyContinue }
            Write-KitLog "Service $($s.Name) set to $type" 'OK'
        } catch { Write-KitLog "Could not restore service $($s.Name): $($_.Exception.Message)" 'FAIL'; $svcLeft += $s }
    } else { $svcLeft += $s }
}

# ------------------------------------------------------------- tasks
$taskLeft = @()
foreach ($t in @($st.Tasks)) {
    if (-not $admin) { Write-KitLog "Needs admin, skipped task $($t.Path)" 'WARN'; $taskLeft += $t; continue }
    if ($PSCmdlet.ShouldProcess($t.Path, 'Re-enable scheduled task')) {
        try {
            $folder = $t.Path.Substring(0, $t.Path.LastIndexOf('\') + 1)
            $leaf   = $t.Path.Substring($t.Path.LastIndexOf('\') + 1)
            Enable-ScheduledTask -TaskPath $folder -TaskName $leaf -ErrorAction Stop | Out-Null
            Write-KitLog "Re-enabled task $($t.Path)" 'OK'
        } catch { Write-KitLog "Could not re-enable $($t.Path): $($_.Exception.Message)" 'FAIL'; $taskLeft += $t }
    } else { $taskLeft += $t }
}

# ------------------------------------------------------------- wallpaper
if ($st.Wallpaper) {
    $wp = $st.Wallpaper
    if ($PSCmdlet.ShouldProcess("$($wp.Path)", 'Re-apply previous wallpaper')) {
        try {
            if (-not ('WinXPKit.Native' -as [type])) {
                Add-Type -Namespace WinXPKit -Name Native -MemberDefinition '[DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)] public static extern bool SystemParametersInfo(int uAction, int uParam, string lpvParam, int fuWinIni);'
            }
            $path = [string]$wp.Path; if (-not $path) { $path = '' }
            [void][WinXPKit.Native]::SystemParametersInfo(0x0014, 0, $path, 0x03)
            Write-KitLog "Wallpaper restored to '$path'" 'OK'
            $st.Wallpaper = $null
        } catch { Write-KitLog "Wallpaper restore failed: $($_.Exception.Message)" 'FAIL' }
    }
}

# ------------------------------------------------------------- Open-Shell
if ($st.OpenShellInstalledByKit -and -not $KeepOpenShell) {
    $roots = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    $e = Get-ItemProperty $roots -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -like 'Open-Shell*' -and $_.PSChildName -match '^\{[0-9A-Fa-f\-]+\}$' } | Select-Object -First 1
    if (-not $e) { Write-KitLog 'Open-Shell not found; nothing to uninstall' 'SKIP'; $st.OpenShellInstalledByKit = $false }
    elseif (-not $admin) { Write-KitLog 'Uninstalling Open-Shell needs admin; skipped' 'WARN' }
    elseif ($PSCmdlet.ShouldProcess("Open-Shell $($e.PSChildName)", 'Uninstall quietly (msiexec /x)')) {
        try {
            $p = Start-Process "$env:windir\System32\msiexec.exe" -ArgumentList "/x $($e.PSChildName) /qn /norestart" -PassThru -Wait -ErrorAction Stop
            Write-KitLog "Open-Shell uninstall exit code $($p.ExitCode)" 'OK'
            if ($p.ExitCode -eq 0 -or $p.ExitCode -eq 3010) { $st.OpenShellInstalledByKit = $false }
        } catch { Write-KitLog "Open-Shell uninstall failed: $($_.Exception.Message)" 'FAIL' }
    }
}

# ------------------------------------------------------------- save what is left
if (-not $WhatIfPreference) {
    $st.Registry = @($remaining); $st.Services = @($svcLeft); $st.Tasks = @($taskLeft)
    Save-KitState
}

Restart-Explorer

# ------------------------------------------------------------- apps
if (@($st.RemovedApps).Count -gt 0) {
    Write-Host ''
    Write-Host 'Removed apps cannot be restored by script. To get one back:' -ForegroundColor Yellow
    Write-Host '  - Open Microsoft Store, search the app name, click Get; or'
    Write-Host '  - winget search "<name>" then winget install --id <Id> --source msstore'
    Write-Host 'Apps this kit removed:'
    $st.RemovedApps | ForEach-Object { Write-Host "  $_" }
}
if ($remaining.Count + $svcLeft.Count + $taskLeft.Count -gt 0) {
    Write-KitLog 'Some items need an elevated PowerShell. Run Undo.ps1 again as Administrator.' 'WARN'
}
Write-KitLog 'Undo finished. Sign out and back in to see every change.' 'OK'
