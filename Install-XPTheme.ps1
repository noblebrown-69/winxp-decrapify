<#
.SYNOPSIS
    Gives Windows 11 a Windows XP look: Open-Shell classic Start menu with an
    XP-style start button, XP-blue taskbar, Bliss-style wallpaper, left taskbar.

.DESCRIPTION
    1. Downloads Open-Shell 4.4.198 from its official GitHub release, checks the
       SHA256 hash (aborts on mismatch) and installs it silently. Needs admin.
       Skipped with -SkipOpenShell or if Open-Shell is already installed.
    2. Copies the kit's assets to %LOCALAPPDATA%\winxp-decrapify\assets.
    3. Writes the Open-Shell Start menu settings (HKCU).
    4. Sets the wallpaper, XP-blue accent (#245EDC), no transparency, dark
       taskbar/system theme with light apps.
    5. Hides search box, Task View, Widgets and Chat; left-aligns the taskbar.
    6. Restarts explorer.exe.

    Prior values are saved to %LOCALAPPDATA%\winxp-decrapify\state.json so
    Undo.ps1 can restore them. Run with -WhatIf first.

    Run it from the account you want themed. If you elevate, elevate the SAME
    account, or the theme lands in the admin account's profile.

.EXAMPLE
    .\Install-XPTheme.ps1 -WhatIf
.EXAMPLE
    .\Install-XPTheme.ps1                 # elevated: installs Open-Shell too
.EXAMPLE
    .\Install-XPTheme.ps1 -SkipOpenShell  # colors, wallpaper, taskbar only; no admin
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [switch]$SkipOpenShell,
    # Keep the taskbar centered instead of left-aligned.
    [switch]$CenterTaskbar
)

$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'lib\Common.ps1')
Initialize-Log -Name 'Install-XPTheme'

# Pinned Open-Shell release. The installer is NOT shipped with this kit.
$OpenShellUrl    = 'https://github.com/Open-Shell/Open-Shell-Menu/releases/download/v4.4.198/OpenShellSetup_4_4_198.exe'
$OpenShellSha256 = 'a4d2d4459de55b5e962ba2a14f7bb794170511649138173dfa72949837b48c3f'

$srcAssets  = Join-Path $PSScriptRoot 'assets'
$destAssets = Join-Path $script:StateDir 'assets'
$button     = Join-Path $destAssets 'xp_start_button.png'
$wallpaper  = Join-Path $destAssets 'xp_style_wallpaper.jpg'

function Get-OpenShellEntry {
    $roots = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    Get-ItemProperty $roots -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -like 'Open-Shell*' } | Select-Object -First 1
}

# =====================================================================
# 1. Open-Shell
# =====================================================================
if (-not $SkipOpenShell) {
    if (Get-OpenShellEntry) {
        Write-KitLog 'Open-Shell is already installed; skipping install' 'SKIP'
    } elseif (-not (Test-IsAdmin)) {
        Write-KitLog 'Installing Open-Shell needs an elevated PowerShell. Re-run as Administrator, or use -SkipOpenShell.' 'FAIL'
        exit 1
    } elseif ($PSCmdlet.ShouldProcess($OpenShellUrl, 'Download, verify SHA256 and install Open-Shell (StartMenu, ClassicExplorer)')) {
        $exe = Join-Path $env:TEMP 'OpenShellSetup_4_4_198.exe'
        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
            $ProgressPreference = 'SilentlyContinue'
            Invoke-WebRequest -Uri $OpenShellUrl -OutFile $exe -UseBasicParsing -ErrorAction Stop
            $hash = (Get-FileHash -Path $exe -Algorithm SHA256).Hash.ToLower()
            if ($hash -ne $OpenShellSha256) {
                Remove-Item $exe -Force -ErrorAction SilentlyContinue
                Write-KitLog "SHA256 MISMATCH for Open-Shell installer (got $hash). Aborting; nothing installed." 'FAIL'
                exit 1
            }
            Write-KitLog 'Open-Shell installer hash verified' 'OK'
            $p = Start-Process -FilePath $exe -ArgumentList '/qn', 'ADDLOCAL=StartMenu,ClassicExplorer' -PassThru -Wait -ErrorAction Stop
            Write-KitLog "Open-Shell installer exit code $($p.ExitCode)" 'OK'
            if ($p.ExitCode -eq 0 -or $p.ExitCode -eq 3010) {
                $st = Get-KitState; $st.OpenShellInstalledByKit = $true; Save-KitState
            }
            Remove-Item $exe -Force -ErrorAction SilentlyContinue
        } catch {
            Write-KitLog "Open-Shell install failed: $($_.Exception.Message)" 'FAIL'
            exit 1
        }
    }
}

# =====================================================================
# 2. Assets to a stable per-user folder (Open-Shell reads the button from here).
# =====================================================================
if ($PSCmdlet.ShouldProcess($destAssets, 'Copy start button and wallpaper')) {
    try {
        New-Item -ItemType Directory -Path $destAssets -Force | Out-Null
        Copy-Item -Path (Join-Path $srcAssets '*') -Destination $destAssets -Force -ErrorAction Stop
        Write-KitLog "Assets copied to $destAssets" 'OK'
    } catch { Write-KitLog "Asset copy failed: $($_.Exception.Message)" 'FAIL' }
}

# =====================================================================
# 3. Open-Shell Start menu settings (values exported from the tested setup).
#    Classic two-column menu, custom XP-style start button, skip Metro screen.
# =====================================================================
if (-not $SkipOpenShell) {
    $os = 'HKCU:\Software\OpenShell\StartMenu\Settings'
    Set-RegValue $os 'Version'           67371206 'DWord'    # 4.4.198 settings format
    Set-RegValue $os 'MenuStyle'         'Classic2' 'String'
    Set-RegValue $os 'Skin1'             'Windows XP Luna' 'String'
    Set-RegValue $os 'SkinC2'            'Immersive' 'String'
    Set-RegValue $os 'SkinOptionsC2'     @('NO_ICONS=1', 'USER_IMAGE=1', 'CENTER_NAME=0', 'SMALL_ICONS=0', 'LARGE_FONT=0', 'ICON_FRAMES=1', 'OPAQUE=0') 'MultiString'
    Set-RegValue $os 'EnableStartButton' 1 'DWord'
    Set-RegValue $os 'StartButtonType'   'CustomButton' 'String'
    Set-RegValue $os 'StartButtonPath'   $button 'String'
    Set-RegValue $os 'StartButtonAlign'  0 'DWord'
    Set-RegValue $os 'SkipMetro'         1 'DWord'
    # Skip Open-Shell's first-run "pick a style" dialog and toolbar prompt.
    Set-RegValue 'HKCU:\Software\OpenShell\StartMenu' 'ShowedStyle2' 1 'DWord'
    Set-RegValue 'HKCU:\Software\OpenShell\ClassicExplorer' 'ShowedToolbar' 1 'DWord'
}

# =====================================================================
# 4. Wallpaper (registry + SystemParametersInfo so it applies now).
#    The previous wallpaper is saved for Undo.ps1.
# =====================================================================
$desk = 'HKCU:\Control Panel\Desktop'
$st = Get-KitState
if (-not $st.Wallpaper) {
    $cur = Get-ItemProperty $desk -ErrorAction SilentlyContinue
    if ($PSCmdlet.ShouldProcess($script:StateFile, 'Record current wallpaper for undo')) {
        $st.Wallpaper = [pscustomobject]@{ Path = $cur.WallPaper; Style = $cur.WallpaperStyle; Tile = $cur.TileWallpaper }
        Save-KitState
    }
}
Set-RegValue $desk 'WallpaperStyle' '10' 'String'   # 10 = Fill
Set-RegValue $desk 'TileWallpaper'  '0'  'String'
Set-RegValue $desk 'WallPaper' $wallpaper 'String'
if ($PSCmdlet.ShouldProcess($wallpaper, 'Apply wallpaper now (SystemParametersInfo)')) {
    try {
        if (-not ('WinXPKit.Native' -as [type])) {
            Add-Type -Namespace WinXPKit -Name Native -MemberDefinition '[DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)] public static extern bool SystemParametersInfo(int uAction, int uParam, string lpvParam, int fuWinIni);'
        }
        # 0x0014 = SPI_SETDESKWALLPAPER; 0x01|0x02 = update ini + broadcast change
        [void][WinXPKit.Native]::SystemParametersInfo(0x0014, 0, $wallpaper, 0x03)
        Write-KitLog 'Wallpaper applied' 'OK'
    } catch { Write-KitLog "Wallpaper apply failed: $($_.Exception.Message)" 'FAIL' }
}

# =====================================================================
# 5. Colors: XP blue #245EDC on taskbar and Start, no transparency,
#    dark system (taskbar) with light apps.
#    DWORDs are ABGR: 0xFFDC5E24 = opaque #245EDC.
# =====================================================================
$pers = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'
Set-RegValue $pers 'ColorPrevalence'      1
Set-RegValue $pers 'EnableTransparency'   0
Set-RegValue $pers 'AppsUseLightTheme'    1
Set-RegValue $pers 'SystemUsesLightTheme' 0
$xpBlue = [int]0xFFDC5E24          # negative Int32 is how a DWORD above 0x7FFFFFFF is stored
$xpGlow = [int]0xC4245EDC          # ARGB form used by ColorizationColor
$accent = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Accent'
Set-RegValue $accent 'AccentColorMenu' $xpBlue
Set-RegValue $accent 'StartColorMenu'  $xpBlue
$dwm = 'HKCU:\Software\Microsoft\Windows\DWM'
Set-RegValue $dwm 'AccentColor'              $xpBlue
Set-RegValue $dwm 'ColorizationColor'        $xpGlow
Set-RegValue $dwm 'ColorizationAfterglow'    $xpGlow
Set-RegValue $dwm 'ColorPrevalence'          1
Set-RegValue $dwm 'EnableWindowColorization' 0
Set-RegValue $desk 'AutoColorization' 0 'DWord'     # do not pick accent from wallpaper

# =====================================================================
# 6. Taskbar: hide search, Task View, Widgets, Chat; left-align.
# =====================================================================
$adv = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
Set-RegValue 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search' 'SearchboxTaskbarMode' 0
Set-RegValue $adv 'ShowTaskViewButton' 0
Set-RegValue $adv 'TaskbarDa' 0      # Widgets; newer builds may refuse this (see README)
Set-RegValue $adv 'TaskbarMn' 0
Set-RegValue $adv 'ShowCopilotButton' 0
if ($CenterTaskbar) { Set-RegValue $adv 'TaskbarAl' 1 } else { Set-RegValue $adv 'TaskbarAl' 0 }

# =====================================================================
# 7. Restart Explorer so the taskbar and Start button pick everything up.
# =====================================================================
Restart-Explorer

Write-KitLog 'XP theme done. If the Start button still looks like Windows 11, sign out and back in.' 'OK'
if ($script:LogFile) { Write-Host "Log: $script:LogFile" }
