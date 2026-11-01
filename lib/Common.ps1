# Common.ps1 - shared helpers for winxp-decrapify.
# Dot-sourced by Decrapify.ps1, Install-XPTheme.ps1 and Undo.ps1.
#
# Design rules:
#  * Every function that changes the system calls ShouldProcess, so -WhatIf
#    on the calling script prints what would happen and changes nothing.
#  * Every change records the PRIOR value in a JSON state file, so Undo.ps1
#    can put things back exactly. The first recorded prior value wins, which
#    keeps re-runs idempotent (a second run never overwrites the original).
#  * Failures are logged and the script carries on.

$script:KitVersion = '1.0.0'
$script:StateDir   = Join-Path $env:LOCALAPPDATA 'winxp-decrapify'
$script:StateFile  = Join-Path $script:StateDir 'state.json'
$script:LogDir     = Join-Path $env:USERPROFILE 'decrapify-logs'
$script:LogFile    = $null
$script:State      = $null

# ---------------------------------------------------------------- logging
function Initialize-Log {
    param([Parameter(Mandatory)][string]$Name)
    if ($WhatIfPreference) {
        Write-Host "[WhatIf] No log file is written in -WhatIf mode." -ForegroundColor Cyan
        return
    }
    if (-not (Test-Path $script:LogDir)) {
        New-Item -ItemType Directory -Path $script:LogDir -Force -WhatIf:$false | Out-Null
    }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $script:LogFile = Join-Path $script:LogDir "$Name-$stamp.log"
    Write-KitLog "winxp-decrapify $script:KitVersion - $Name started"
}

function Write-KitLog {
    param([string]$Message, [ValidateSet('INFO','OK','SKIP','WARN','FAIL')][string]$Level = 'INFO')
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    $color = @{ INFO = 'Gray'; OK = 'Green'; SKIP = 'DarkGray'; WARN = 'Yellow'; FAIL = 'Red' }[$Level]
    Write-Host $line -ForegroundColor $color
    # Use .NET directly so logging is not affected by $WhatIfPreference.
    if ($script:LogFile) { [System.IO.File]::AppendAllText($script:LogFile, $line + [Environment]::NewLine) }
}

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# ---------------------------------------------------------------- state file
function Get-KitState {
    if ($script:State) { return $script:State }
    $s = @{ Registry = @(); Services = @(); Tasks = @(); Wallpaper = $null; OpenShellInstalledByKit = $false; RemovedApps = @() }
    if (Test-Path $script:StateFile) {
        try {
            $j = Get-Content $script:StateFile -Raw | ConvertFrom-Json
            if ($j.Registry)    { $s.Registry    = @($j.Registry) }
            if ($j.Services)    { $s.Services    = @($j.Services) }
            if ($j.Tasks)       { $s.Tasks       = @($j.Tasks) }
            if ($j.RemovedApps) { $s.RemovedApps = @($j.RemovedApps) }
            if ($j.Wallpaper)   { $s.Wallpaper   = $j.Wallpaper }
            if ($j.OpenShellInstalledByKit) { $s.OpenShellInstalledByKit = [bool]$j.OpenShellInstalledByKit }
        } catch {
            Write-KitLog "Could not read state file $($script:StateFile): $($_.Exception.Message)" 'WARN'
        }
    }
    $script:State = $s
    return $s
}

function Save-KitState {
    if ($WhatIfPreference) { return }
    if (-not $script:State) { return }
    if (-not (Test-Path $script:StateDir)) { New-Item -ItemType Directory -Path $script:StateDir -Force -WhatIf:$false | Out-Null }
    $json = $script:State | ConvertTo-Json -Depth 6
    [System.IO.File]::WriteAllText($script:StateFile, $json)
}

# ---------------------------------------------------------------- registry
function Set-RegValue {
    # Sets a registry value and records what was there before.
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)]$Value,
        [ValidateSet('DWord','String','MultiString','ExpandString','QWord')][string]$Type = 'DWord'
    )
    try {
        $keyExisted = Test-Path $Path
        $existed = $false; $old = $null; $oldKind = $null
        if ($keyExisted) {
            $item = Get-Item $Path
            if ($item.GetValueNames() -contains $Name) {
                $existed = $true
                $old = $item.GetValue($Name, $null, 'DoNotExpandEnvironmentNames')
                $oldKind = $item.GetValueKind($Name).ToString()
            }
        }
        if ($existed -and $oldKind -eq $Type -and (($old -join '|') -eq ($Value -join '|'))) {
            Write-KitLog "Already set: $Path\$Name" 'SKIP'; return
        }
        if ($PSCmdlet.ShouldProcess("$Path\$Name", "Set to '$($Value -join ', ')' ($Type)")) {
            $st = Get-KitState
            if (-not ($st.Registry | Where-Object { $_.Path -eq $Path -and $_.Name -eq $Name })) {
                $st.Registry += [pscustomobject]@{ Path = $Path; Name = $Name; KeyExisted = $keyExisted; Existed = $existed; Value = $old; Kind = $oldKind }
                Save-KitState
            }
            if (-not $keyExisted) { New-Item -Path $Path -Force | Out-Null }
            New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType $Type -Force | Out-Null
            Write-KitLog "Set $Path\$Name = $($Value -join ', ')" 'OK'
        }
    } catch {
        Write-KitLog "Failed to set $Path\$Name : $($_.Exception.Message)" 'FAIL'
    }
}

# ---------------------------------------------------------------- services
function Disable-ServiceTracked {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$Name)
    try {
        $svc = Get-Service -Name $Name -ErrorAction SilentlyContinue
        if (-not $svc) { Write-KitLog "Service not present: $Name" 'SKIP'; return }
        if ($svc.StartType -eq 'Disabled') { Write-KitLog "Service already disabled: $Name" 'SKIP'; return }
        if ($PSCmdlet.ShouldProcess($Name, 'Stop service and set startup type to Disabled')) {
            $st = Get-KitState
            if (-not ($st.Services | Where-Object { $_.Name -eq $Name })) {
                $st.Services += [pscustomobject]@{ Name = $Name; StartType = $svc.StartType.ToString() }
                Save-KitState
            }
            Stop-Service -Name $Name -Force -ErrorAction SilentlyContinue
            Set-Service -Name $Name -StartupType Disabled -ErrorAction Stop
            Write-KitLog "Disabled service $Name (was $($svc.StartType))" 'OK'
        }
    } catch {
        Write-KitLog "Failed to disable service $Name : $($_.Exception.Message)" 'FAIL'
    }
}

# ---------------------------------------------------------------- scheduled tasks
function Disable-TaskTracked {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$FullPath)   # e.g. \Microsoft\Windows\Feedback\Siuf\DmClient
    try {
        $folder = $FullPath.Substring(0, $FullPath.LastIndexOf('\') + 1)
        $leaf   = $FullPath.Substring($FullPath.LastIndexOf('\') + 1)
        $task = Get-ScheduledTask -TaskPath $folder -TaskName $leaf -ErrorAction SilentlyContinue
        if (-not $task) { Write-KitLog "Task not present: $FullPath" 'SKIP'; return }
        if ($task.State -eq 'Disabled') { Write-KitLog "Task already disabled: $FullPath" 'SKIP'; return }
        if ($PSCmdlet.ShouldProcess($FullPath, 'Disable scheduled task')) {
            $st = Get-KitState
            if (-not ($st.Tasks | Where-Object { $_.Path -eq $FullPath })) {
                $st.Tasks += [pscustomobject]@{ Path = $FullPath }
                Save-KitState
            }
            Disable-ScheduledTask -TaskPath $folder -TaskName $leaf -ErrorAction Stop | Out-Null
            Write-KitLog "Disabled task $FullPath" 'OK'
        }
    } catch {
        Write-KitLog "Failed to disable task $FullPath : $($_.Exception.Message)" 'FAIL'
    }
}

# ---------------------------------------------------------------- appx packages
function Remove-AppxTracked {
    # Removes a Store (appx) package. -AllUsers also removes the provisioned
    # copy so it is not reinstalled for new user profiles. NOT reversible by
    # script; the name is recorded so Undo.ps1 can list what to reinstall.
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$Name, [switch]$AllUsers)
    try {
        if ($AllUsers) {
            $pkgs = @(Get-AppxPackage -AllUsers -Name $Name -ErrorAction SilentlyContinue)
            $prov = @(Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -eq $Name })
        } else {
            $pkgs = @(Get-AppxPackage -Name $Name -ErrorAction SilentlyContinue)
            $prov = @()
        }
        if ($pkgs.Count -eq 0 -and $prov.Count -eq 0) { Write-KitLog "App not installed: $Name" 'SKIP'; return }
        $scope = 'current user'; if ($AllUsers) { $scope = 'all users + provisioned' }
        if ($PSCmdlet.ShouldProcess($Name, "Remove app package ($scope)")) {
            $st = Get-KitState
            if ($st.RemovedApps -notcontains $Name) { $st.RemovedApps += $Name; Save-KitState }
            foreach ($p in $pkgs) {
                try {
                    if ($AllUsers) { Remove-AppxPackage -Package $p.PackageFullName -AllUsers -ErrorAction Stop }
                    else           { Remove-AppxPackage -Package $p.PackageFullName -ErrorAction Stop }
                    Write-KitLog "Removed $($p.PackageFullName)" 'OK'
                } catch { Write-KitLog "Could not remove $($p.PackageFullName): $($_.Exception.Message)" 'FAIL' }
            }
            foreach ($p in $prov) {
                try {
                    Remove-AppxProvisionedPackage -Online -PackageName $p.PackageName -ErrorAction Stop | Out-Null
                    Write-KitLog "Deprovisioned $($p.PackageName)" 'OK'
                } catch { Write-KitLog "Could not deprovision $($p.PackageName): $($_.Exception.Message)" 'FAIL' }
            }
        }
    } catch {
        Write-KitLog "Failed on app $Name : $($_.Exception.Message)" 'FAIL'
    }
}

function Restart-Explorer {
    [CmdletBinding(SupportsShouldProcess)]
    param()
    if ($PSCmdlet.ShouldProcess('explorer.exe', 'Restart to apply taskbar and theme changes')) {
        Get-Process explorer -ErrorAction SilentlyContinue | Stop-Process -Force
        Start-Sleep -Seconds 2
        if (-not (Get-Process explorer -ErrorAction SilentlyContinue)) { Start-Process explorer.exe }
        Write-KitLog 'Explorer restarted' 'OK'
    }
}
