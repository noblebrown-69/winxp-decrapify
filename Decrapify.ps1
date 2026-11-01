<#
.SYNOPSIS
    Strips ads, Copilot, telemetry and preinstalled junk from Windows 11.

.DESCRIPTION
    Default run (no admin needed): current-user app removal plus HKCU tweaks
    for privacy, ads, Copilot, Bing search, widgets and taskbar clutter.

    -Machine (run as Administrator): restore point first, then all-users app
    removal + deprovisioning, machine policies, telemetry services and tasks,
    and the Copilot desktop app uninstall.

    Optional switches cover judgment calls: -RemoveOemBloat, -RemoveXbox, -RemoveMailAndOneNote,
    -DisableSysMain, -RemoveStartupItems.

    Run with -WhatIf first. It prints every change and makes none.
    Every change is logged to %USERPROFILE%\decrapify-logs and prior values
    are saved to %LOCALAPPDATA%\winxp-decrapify\state.json for Undo.ps1.
    Safe to run more than once.

.EXAMPLE
    .\Decrapify.ps1 -WhatIf
.EXAMPLE
    .\Decrapify.ps1                        # user level only
.EXAMPLE
    .\Decrapify.ps1 -Machine -RemoveOemBloat   # from an elevated PowerShell
.EXAMPLE
    .\Decrapify.ps1 -RemoveStartupItems -StartupPattern 'Spotify|Discord'
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    # Admin tier: all-users removal, HKLM policies, services, tasks, Copilot app.
    [switch]$Machine,
    # Remove PC-maker (HP, Dell, Lenovo, Asus, Acer) helper apps and HP services.
    [switch]$RemoveOemBloat,
    # Remove Xbox apps and services. Breaks Game Pass / Xbox sign-in in games.
    [switch]$RemoveXbox,
    # Also remove new Outlook, Mail & Calendar and OneNote (Store). Kept by default.
    [switch]$RemoveMailAndOneNote,
    # Disable SysMain (Superfetch). Fine on an SSD, can slow an HDD. Needs -Machine.
    [switch]$DisableSysMain,
    # Remove current-user startup entries whose name matches -StartupPattern.
    [switch]$RemoveStartupItems,
    # Regex matched against startup entry names. Empty by default = remove nothing.
    [string]$StartupPattern = '',
    # App package names to keep even if they are on a removal list.
    [string[]]$Keep = @()
)

$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'lib\Common.ps1')
Initialize-Log -Name 'Decrapify'

if ($Machine -and -not (Test-IsAdmin)) {
    Write-KitLog '-Machine needs an elevated PowerShell (Run as Administrator). Stopping.' 'FAIL'
    exit 1
}
if ($DisableSysMain -and -not $Machine) { Write-KitLog '-DisableSysMain only works together with -Machine; ignoring it.' 'WARN' }

# =====================================================================
# App lists. Review these before running. Add names to -Keep to skip.
# =====================================================================

# Microsoft consumer apps, ads and Copilot. None are needed by Windows itself.
$CoreApps = @(
    'Microsoft.Copilot',
    'Microsoft.Windows.Ai.Copilot.Provider',
    'Microsoft.BingNews',
    'Microsoft.BingSearch',
    'Microsoft.BingWeather',
    'Microsoft.GetHelp',
    'Microsoft.Messaging',
    'Microsoft.Microsoft3DViewer',
    'Microsoft.MicrosoftOfficeHub',
    'Microsoft.MicrosoftSolitaireCollection',
    'Microsoft.MixedReality.Portal',
    'Microsoft.OneConnect',
    'Microsoft.People',
    'Microsoft.Print3D',
    'Microsoft.SkypeApp',
    'Microsoft.Todos',
    'Microsoft.WindowsFeedbackHub',
    'Microsoft.WindowsMaps',
    'Microsoft.WindowsSoundRecorder',
    'Microsoft.YourPhone',
    'MicrosoftWindows.CrossDevice',
    'Microsoft.PowerAutomateDesktop',
    'Microsoft.ZuneVideo',
    'MicrosoftCorporationII.MicrosoftFamily',
    'MicrosoftCorporationII.QuickAssist',
    'Microsoft.Windows.DevHome',
    'Microsoft.MicrosoftStickyNotes',
    'Microsoft.WindowsAlarms',
    'MicrosoftWindows.Client.WebExperience',   # Widgets board
    'Microsoft.WidgetsPlatformRuntime',
    'Clipchamp.Clipchamp',
    '4DF9E0F8.Netflix'
)

# Mail/Outlook and OneNote. Kept by default; removed only with -RemoveMailAndOneNote.
$MailApps = @(
    'Microsoft.OutlookForWindows',
    'microsoft.windowscommunicationsapps',
    'Microsoft.Office.OneNote'
)

$XboxApps = @(
    'Microsoft.XboxApp', 'Microsoft.Xbox.TCUI', 'Microsoft.XboxGameOverlay',
    'Microsoft.XboxGamingOverlay', 'Microsoft.XboxIdentityProvider',
    'Microsoft.XboxSpeechToTextOverlay', 'Microsoft.GamingApp', 'Microsoft.Edge.GameAssist'
)
$XboxServices = @('XblAuthManager', 'XblGameSave', 'XboxGipSvc', 'XboxNetApiSvc')

# PC-maker helper apps. Generic list; names that are not installed are skipped.
$OemApps = @(
    'AD2F1837.HPJumpStarts', 'AD2F1837.HPPrinterControl', 'AD2F1837.HPPrivacySettings',
    'AD2F1837.HPInc.EnergyStar', 'AD2F1837.HPPCHardwareDiagnosticsWindows',
    'AD2F1837.myHP', 'AD2F1837.HPSupportAssistant', 'AD2F1837.HPQuickDrop',
    'AD2F1837.HPSystemInformation', 'AD2F1837.HPPowerManager',
    'DellInc.DellDigitalDelivery', 'DellInc.DellSupportAssistforPCs', 'DellInc.PartnerPromo',
    'E046963F.LenovoCompanion', 'E046963F.LenovoSettingsforEnterprise', 'E0469640.LenovoUtility',
    'B9ECED6F.ASUSPCAssistant', 'B9ECED6F.MyASUS',
    'AcerIncorporated.AcerCareCenterS', 'AcerIncorporated.QuickAccess'
)
# HP telemetry / analytics services seen on HP consumer laptops.
$OemServices = @('HPAppHelperCap', 'HPDiagsCap', 'HPNetworkCap', 'HPSysInfoCap', 'HpTouchpointAnalyticsService')
# Desktop (MSI) OEM programs, matched by uninstall DisplayName.
$OemPrograms = @('HP Connection Optimizer')

$apps = @($CoreApps)
if ($RemoveXbox)     { $apps += $XboxApps }
if ($RemoveMailAndOneNote) { $apps += $MailApps }
if ($RemoveOemBloat) { $apps += $OemApps }
$apps = $apps | Where-Object { $Keep -notcontains $_ }

# =====================================================================
# Machine tier step 1: restore point BEFORE anything else changes.
# =====================================================================
if ($Machine) {
    if ($PSCmdlet.ShouldProcess('System drive', 'Create a System Restore point')) {
        try {
            Enable-ComputerRestore -Drive "$env:SystemDrive\" -ErrorAction Stop
            Checkpoint-Computer -Description 'Before winxp-decrapify' -RestorePointType MODIFY_SETTINGS -ErrorAction Stop
            Write-KitLog 'Restore point created' 'OK'
        } catch {
            # Windows allows one restore point per 24h by default; that is a warning, not a stop.
            Write-KitLog "Restore point not created: $($_.Exception.Message)" 'WARN'
        }
    }
}

# =====================================================================
# Apps. User tier: current user only. Machine tier: all users + deprovision
# so the apps do not come back for new user accounts.
# =====================================================================
Write-KitLog "Removing $($apps.Count) app packages (missing ones are skipped)"
foreach ($n in $apps) {
    if ($Machine) { Remove-AppxTracked -Name $n -AllUsers } else { Remove-AppxTracked -Name $n }
}

# =====================================================================
# HKCU tweaks (no admin). Each line says what it turns off.
# =====================================================================
Write-KitLog 'Applying current-user privacy, ads and taskbar tweaks'
$adv = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
Set-RegValue $adv 'TaskbarDa' 0                    # Widgets button (Windows may block this; the -Machine policy covers it)
Set-RegValue $adv 'TaskbarMn' 0                    # Chat / Teams button
Set-RegValue $adv 'ShowTaskViewButton' 0           # Task View button
Set-RegValue $adv 'ShowCopilotButton' 0            # Copilot button
Set-RegValue $adv 'ShowSyncProviderNotifications' 0  # OneDrive/M365 ads in Explorer
Set-RegValue $adv 'Start_IrisRecommendations' 0    # "Recommended" tips in Start
Set-RegValue $adv 'Start_AccountNotifications' 0   # Account nags in Start
Set-RegValue $adv 'Start_TrackProgs' 0             # Track app launches for Start
Set-RegValue $adv 'HideFileExt' 0                  # Show file extensions (safer)
Set-RegValue 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search' 'SearchboxTaskbarMode' 0   # Hide taskbar search box
Set-RegValue 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search' 'BingSearchEnabled' 0      # No Bing results in Start search
Set-RegValue 'HKCU:\Software\Microsoft\Windows\CurrentVersion\SearchSettings' 'IsDynamicSearchBoxEnabled' 0  # No "search highlights"
Set-RegValue 'HKCU:\Software\Policies\Microsoft\Windows\Explorer' 'DisableSearchBoxSuggestions' 1   # No web suggestions
Set-RegValue 'HKCU:\Software\Policies\Microsoft\Windows\WindowsCopilot' 'TurnOffWindowsCopilot' 1  # Copilot off (user policy)
Set-RegValue 'HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo' 'Enabled' 0          # Advertising ID
Set-RegValue 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Privacy' 'TailoredExperiencesWithDiagnosticDataEnabled' 0
Set-RegValue 'HKCU:\Software\Microsoft\Windows\CurrentVersion\BackgroundAccessApplications' 'GlobalUserDisabled' 1  # Store apps cannot run in background
Set-RegValue 'HKCU:\System\GameConfigStore' 'GameDVR_Enabled' 0                                      # Game DVR recording
Set-RegValue 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR' 'AppCaptureEnabled' 0
Set-RegValue 'HKCU:\Software\Microsoft\Windows\CurrentVersion\UserProfileEngagement' 'ScoobeSystemSettingEnabled' 0  # "Finish setting up" nag

# Content Delivery Manager: suggested apps, silent app installs, lock screen
# and Start ads, "tips and tricks".
$cdm = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
foreach ($v in 'ContentDeliveryAllowed', 'SubscribedContentEnabled', 'SystemPaneSuggestionsEnabled',
               'SoftLandingEnabled', 'RotatingLockScreenOverlayEnabled', 'SilentInstalledAppsEnabled',
               'PreInstalledAppsEnabled', 'OemPreInstalledAppsEnabled', 'PreInstalledAppsEverEnabled',
               'SubscribedContent-310093Enabled', 'SubscribedContent-314563Enabled',
               'SubscribedContent-338387Enabled', 'SubscribedContent-338388Enabled',
               'SubscribedContent-338389Enabled', 'SubscribedContent-338393Enabled',
               'SubscribedContent-353694Enabled', 'SubscribedContent-353696Enabled',
               'SubscribedContent-353698Enabled') {
    Set-RegValue $cdm $v 0
}

# New Teams auto-start (only matters if Teams is installed). 1 = disabled by user.
$teamsTask = 'HKCU:\Software\Classes\Local Settings\Software\Microsoft\Windows\CurrentVersion\AppModel\SystemAppData\MSTeams_8wekyb3d8bbwe\TeamsStartupTask'
if (Test-Path $teamsTask) { Set-RegValue $teamsTask 'State' 1 }

# =====================================================================
# Optional: current-user startup entries matching -StartupPattern.
# Removed entries are backed up into the state file so Undo can restore them.
# =====================================================================
if ($RemoveStartupItems) {
    if ([string]::IsNullOrWhiteSpace($StartupPattern)) {
        Write-KitLog '-RemoveStartupItems given without -StartupPattern; nothing removed. Current entries:' 'WARN'
    }
    $run = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
    $props = @((Get-ItemProperty $run -ErrorAction SilentlyContinue).PSObject.Properties | Where-Object { $_.Name -notlike 'PS*' })
    foreach ($p in $props) {
        if (-not [string]::IsNullOrWhiteSpace($StartupPattern) -and $p.Name -match $StartupPattern) {
            if ($PSCmdlet.ShouldProcess("$run\$($p.Name)", 'Remove startup entry')) {
                try {
                    $st = Get-KitState
                    if (-not ($st.Registry | Where-Object { $_.Path -eq $run -and $_.Name -eq $p.Name })) {
                        $st.Registry += [pscustomobject]@{ Path = $run; Name = $p.Name; KeyExisted = $true; Existed = $true; Value = $p.Value; Kind = 'String' }
                        Save-KitState
                    }
                    Remove-ItemProperty -Path $run -Name $p.Name -ErrorAction Stop
                    Write-KitLog "Removed startup entry $($p.Name)" 'OK'
                } catch { Write-KitLog "Could not remove startup entry $($p.Name): $($_.Exception.Message)" 'FAIL' }
            }
        } else {
            Write-KitLog "Startup entry kept: $($p.Name)" 'SKIP'
        }
    }
}

# =====================================================================
# Machine tier (admin): policies, services, tasks, Copilot app.
# =====================================================================
if ($Machine) {
    Write-KitLog 'Applying machine policies'
    Set-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot' 'TurnOffWindowsCopilot' 1
    Set-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI' 'DisableAIDataAnalysis' 1      # Recall snapshots
    Set-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent' 'DisableWindowsConsumerFeatures' 1  # Auto-installed promo apps
    Set-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent' 'DisableSoftLanding' 1      # Tips
    Set-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Feeds' 'EnableFeeds' 0           # News and interests
    Set-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Dsh' 'AllowNewsAndInterests' 0                  # Widgets
    Set-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' 'AllowTelemetry' 0       # 0 is fully honored only on Enterprise/Education
    Set-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AdvertisingInfo' 'DisabledByGroupPolicy' 1
    Set-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' 'StartupBoostEnabled' 0     # Edge preloading at boot
    Set-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' 'BackgroundModeEnabled' 0   # Edge running after close
    Set-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' 'HubsSidebarEnabled' 0      # Edge sidebar / Copilot pane
    Set-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' 'CopilotCDPPageContext' 0   # Copilot reading page content
    Set-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' 'HideFirstRunExperience' 1

    Write-KitLog 'Disabling telemetry and unused services'
    # DiagTrack = Connected User Experiences and Telemetry; dmwappushservice = WAP push routing for telemetry.
    foreach ($s in 'DiagTrack', 'dmwappushservice', 'MapsBroker', 'RetailDemo', 'PhoneSvc', 'WMPNetworkSvc', 'Fax') {
        Disable-ServiceTracked -Name $s
    }
    if ($RemoveXbox)     { foreach ($s in $XboxServices) { Disable-ServiceTracked -Name $s } }
    if ($RemoveOemBloat) { foreach ($s in $OemServices)  { Disable-ServiceTracked -Name $s } }
    if ($DisableSysMain) { Disable-ServiceTracked -Name 'SysMain' }

    Write-KitLog 'Disabling telemetry scheduled tasks'
    foreach ($t in '\Microsoft\Windows\Application Experience\Microsoft Compatibility Appraiser',
                   '\Microsoft\Windows\Application Experience\ProgramDataUpdater',
                   '\Microsoft\Windows\Application Experience\StartupAppTask',
                   '\Microsoft\Windows\Customer Experience Improvement Program\Consolidator',
                   '\Microsoft\Windows\Customer Experience Improvement Program\UsbCeip',
                   '\Microsoft\Windows\Feedback\Siuf\DmClient',
                   '\Microsoft\Windows\Feedback\Siuf\DmClientOnScenarioDownload') {
        Disable-TaskTracked -FullPath $t
    }

    # Copilot desktop app (Chromium-based, not an appx). Find its installer
    # instead of hardcoding a version folder.
    Write-KitLog 'Looking for the Copilot desktop app'
    $roots = @("${env:ProgramFiles(x86)}\Microsoft\Copilot\Application", "$env:ProgramFiles\Microsoft\Copilot\Application") | Where-Object { $_ -and (Test-Path $_) }
    $setup = $roots | ForEach-Object { Get-ChildItem -Path $_ -Filter 'copilot_setup.exe' -Recurse -ErrorAction SilentlyContinue } |
             Sort-Object { $_.VersionInfo.FileVersionRaw } -Descending | Select-Object -First 1
    if ($setup) {
        if ($PSCmdlet.ShouldProcess($setup.FullName, 'Run Copilot uninstaller')) {
            try {
                $p = Start-Process -FilePath $setup.FullName -ArgumentList '--uninstall --mscopilot --channel=stable --system-level --verbose-logging' -PassThru -ErrorAction Stop
                if ($p.WaitForExit(180000)) { Write-KitLog "Copilot uninstaller exit code $($p.ExitCode)" 'OK' }
                else { Write-KitLog 'Copilot uninstaller timed out' 'WARN'; Stop-Process $p -Force -ErrorAction SilentlyContinue }
            } catch { Write-KitLog "Copilot uninstall failed: $($_.Exception.Message)" 'FAIL' }
        }
    } else { Write-KitLog 'Copilot desktop app not found' 'SKIP' }

    # OEM desktop programs (MSI) by display name.
    if ($RemoveOemBloat) {
        $uninstallRoots = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
        foreach ($name in $OemPrograms) {
            $entries = @(Get-ItemProperty $uninstallRoots -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -eq $name -and $_.PSChildName -match '^\{[0-9A-Fa-f\-]+\}$' })
            if ($entries.Count -eq 0) { Write-KitLog "Program not installed: $name" 'SKIP'; continue }
            foreach ($e in $entries) {
                if ($PSCmdlet.ShouldProcess("$name $($e.PSChildName)", 'Uninstall MSI quietly')) {
                    try {
                        $p = Start-Process -FilePath "$env:windir\System32\msiexec.exe" -ArgumentList "/x $($e.PSChildName) /qn /norestart" -PassThru -Wait -ErrorAction Stop
                        Write-KitLog "$name uninstall exit code $($p.ExitCode)" 'OK'
                    } catch { Write-KitLog "$name uninstall failed: $($_.Exception.Message)" 'FAIL' }
                }
            }
        }
    }
}

Write-KitLog 'Done. Sign out and back in (or reboot) to see every change.' 'OK'
if ($script:LogFile) { Write-Host "Log: $script:LogFile" }
