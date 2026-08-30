# ============================================================
#  dsh-offline-bundle target-machine installer (runs OFFLINE).
#
#  Installs: portable Node + dsh npm tree + pre-baked ~/.dsh
#  profile + the dsh-web-manager tray app, wires the manager to
#  the bundled dsh via config (DshCommand), optionally adds the
#  bundle bin dir to the user PATH. Idempotent: re-running with
#  a newer bundle upgrades in place (the manager never downgrades).
#
#  Usage (from the extracted bundle root):
#    powershell -ExecutionPolicy Bypass -File Install-Offline.ps1
#    powershell -ExecutionPolicy Bypass -File Install-Offline.ps1 -AutoStart -SkipLaunch
#
#  Testing: honours DSH_WEB_MANAGER_HOME (manager files land in the
#  sandbox home instead of the real %LOCALAPPDATA% install).
# ============================================================
[CmdletBinding()]
param(
    # NOTE: defaults are resolved in the body, not in param(): under
    # `powershell -File` the PS 5.1 $PSScriptRoot can be empty inside parameter
    # default expressions, which made Join-Path fail with "argument to
    # parameter 'Path' is an empty string".
    [string]$BundleDir = '',
    [string]$TargetRoot = '',
    [switch]$NoPath,        # do not touch the user PATH
    [switch]$NoShortcut,    # let the manager installer skip its shortcuts
    [switch]$AutoStart,     # HKCU Run entry for the tray manager
    [switch]$SkipLaunch,    # install without starting the tray
    [switch]$SkipManager,   # node+dsh+profile only (no tray app)
    [switch]$WithWsl,       # force the WSL-side install (error when the payload is absent)
    [switch]$SkipWsl,       # never touch WSL, even when the payload is embedded
    [string]$WslDistro = '' # target distro; empty = auto-detect (prefer a running, non-helper distro)
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

if (-not $BundleDir) { $BundleDir = $PSScriptRoot }
if (-not $BundleDir) { throw 'BundleDir could not be determined (pass -BundleDir explicitly).' }
if (-not $TargetRoot) { $TargetRoot = Join-Path $env:LOCALAPPDATA 'dsh-bundle' }

# Testing sandbox (TESTING.md): when DSH_WEB_MANAGER_HOME is set, every
# machine-scope write below (manager files, profile, shared config) lands
# inside that home instead of the real user profile.
$sandboxHome = $env:DSH_WEB_MANAGER_HOME

# ---------- 0. Preflight ----------
$manifestPath = Join-Path $BundleDir 'bundle.json'
$manifest = $null
if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    Write-Host "[offline] bundle: v$($manifest.BundleVersion) node=$($manifest.Node.Version) dsh=$($manifest.Dsh.Version) manager=$($manifest.Manager.Version)"
}
# Two delivery layouts share this installer:
#   Layout B (exe setup): heavy trees (node/dsh/profile-web/wsl) travel as ONE
#     payload.zip; Install-Offline extracts it straight to $TargetRoot with
#     the system tar (single stream, no per-file copy).
#   Layout A (portable zip): the trees sit unpacked beside this script.
$payloadZip = Join-Path $BundleDir 'payload.zip'
$treeLayoutB = Test-Path -LiteralPath $payloadZip -PathType Leaf
if ($treeLayoutB) {
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        throw "Bundle incomplete: bundle.json missing under $BundleDir."
    }
} else {
    foreach ($part in @('node\node.exe', 'dsh\@deepseek-ai\dsh\package.json')) {
        if (-not (Test-Path -LiteralPath (Join-Path $BundleDir $part) -PathType Leaf)) {
            throw "Bundle incomplete: $part missing under $BundleDir (rebuild with scripts\Build-Bundle.ps1)."
        }
    }
}
if (-not [Environment]::Is64BitOperatingSystem) { throw 'This bundle targets Windows x64 only.' }

# WebView2 Runtime: informational. Missing runtime is not fatal — the manager
# auto-falls back to the Edge app-window mode (see ManagerService.ResolveWindowBackend).
$wv2Ok = $false
foreach ($probe in @(
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}',
    'HKLM:\SOFTWARE\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}',
    'HKCU:\SOFTWARE\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}')) {
    if (Test-Path -LiteralPath $probe) { $wv2Ok = $true; break }
}
if ($wv2Ok) { Write-Host '[offline] WebView2 Runtime: present (embedded window backend active)' }
else { Write-Warning '[offline] WebView2 Runtime not found: the tray manager will fall back to Edge app windows (taskbar shows the Edge icon).' }

# ---------- 1. Portable node + dsh tree ----------
# Same-volume fast path: hard-link the (immutable-at-runtime) node/dsh trees
# from the extracted bundle instead of copying ~1.4 GB twice. Falls back to
# robocopy /MIR on any failure (cross-volume, reparse points, locked files).
function Sync-Dir([string]$src, [string]$dst) {
    if (-not (Test-Path -LiteralPath $src)) { throw "Bundle component missing: $src" }
    $srcAbs = (Resolve-Path -LiteralPath $src).Path
    $srcRoot = [System.IO.Path]::GetPathRoot($srcAbs)
    $dstAbs = [System.IO.Path]::GetFullPath($dst)
    $dstRoot = [System.IO.Path]::GetPathRoot($dstAbs)
    if ($srcRoot -ieq $dstRoot) {
        try {
            if (Test-Path -LiteralPath $dst) { Remove-Item -LiteralPath $dst -Recurse -Force }
            [System.IO.Directory]::CreateDirectory($dstAbs) | Out-Null
            # Breadth-first walk creating one hard link per file; directories are
            # never linked (only files). Any reparse point (junction/symlink) in
            # the source aborts the pass so the robocopy fallback handles it.
            $queue = New-Object System.Collections.Generic.Queue[string]
            $queue.Enqueue($srcAbs)
            while ($queue.Count -gt 0) {
                $dir = $queue.Dequeue()
                foreach ($sub in @(Get-ChildItem -LiteralPath $dir -Directory -Force -ErrorAction Stop)) {
                    $rel = $sub.FullName.Substring($srcAbs.Length).TrimStart('\')
                    [System.IO.Directory]::CreateDirectory((Join-Path $dstAbs $rel)) | Out-Null
                    $queue.Enqueue($sub.FullName)
                }
                foreach ($f in @(Get-ChildItem -LiteralPath $dir -File -Force -ErrorAction Stop)) {
                    if ($f.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
                        throw 'reparse point in source tree; using copy fallback'
                    }
                    $link = Join-Path $dstAbs $f.FullName.Substring($srcAbs.Length).TrimStart('\')
                    $null = New-Item -ItemType HardLink -Path $link -Target $f.FullName -Force
                }
            }
            Write-Host "[offline] linked $src -> $dst (hard links, same volume)"
            return
        } catch {
            Write-Warning "[offline] hard-link pass failed ($($_.Exception.Message)); falling back to robocopy"
            if (Test-Path -LiteralPath $dst) { Remove-Item -LiteralPath $dst -Recurse -Force }
        }
    } else {
        Write-Host "[offline] $src and $dst on different volumes; copying"
    }
    & robocopy.exe $src $dst /MIR /NFL /NDL /NJH /NJS /NP /R:2 /W:1 | Out-Null
    if ($LASTEXITCODE -ge 8) { throw "robocopy failed ($LASTEXITCODE) copying $src -> $dst" }
}
if (-not $treeLayoutB) {
    # Layout A (portable zip): the trees sit unpacked next to this script.
    Sync-Dir (Join-Path $BundleDir 'node') (Join-Path $TargetRoot 'node')
    Sync-Dir (Join-Path $BundleDir 'dsh') (Join-Path $TargetRoot 'dsh')
    Write-Host "[offline] node + dsh tree -> $TargetRoot"
} else {
    # Layout B: one archive, one pass. Drop stale trees first so files removed
    # in a newer bundle do not linger (mirrors robocopy /MIR semantics).
    [System.IO.Directory]::CreateDirectory($TargetRoot) | Out-Null
    foreach ($rel in @('node', 'dsh', 'profile-web', 'wsl')) {
        $old = Join-Path $TargetRoot $rel
        if (Test-Path -LiteralPath $old) {
            try { Remove-Item -LiteralPath $old -Recurse -Force }
            catch { Write-Warning "[offline] could not remove stale $old ($($_.Exception.Message))" }
        }
    }
    $tar = Join-Path $env:SystemRoot 'System32\tar.exe'
    [System.IO.Directory]::CreateDirectory($TargetRoot) | Out-Null
    if (Test-Path -LiteralPath $tar -PathType Leaf) {
        & $tar -xf $payloadZip -C $TargetRoot
        if ($LASTEXITCODE -ne 0) { throw "payload extraction failed (tar exit $LASTEXITCODE): $payloadZip -> $TargetRoot" }
    } elseif (Get-Command Expand-Archive -ErrorAction SilentlyContinue) {
        # Very old Win10 without tar.exe: PowerShell zip fallback (slower).
        Expand-Archive -LiteralPath $payloadZip -DestinationPath $TargetRoot -Force
    } else {
        throw 'Neither System32\tar.exe nor Expand-Archive is available to unpack payload.zip.'
    }
    try { Remove-Item -LiteralPath $payloadZip -Force -ErrorAction SilentlyContinue } catch { }
    Write-Host "[offline] payload extracted (node+dsh+profile-web+wsl) -> $TargetRoot (single archive pass)"
}

# ---------- 2. dsh.cmd shim (absolute paths into the installed tree) ----------
$dshPkg = Get-Content -LiteralPath (Join-Path $TargetRoot 'dsh\@deepseek-ai\dsh\package.json') -Raw | ConvertFrom-Json
$bin = $dshPkg.bin
$entry = if ($bin -is [string]) { $bin } else { $bin.dsh }
if (-not $entry) { throw 'Could not resolve the dsh bin entry from package.json.' }
$binDir = Join-Path $TargetRoot 'bin'
[System.IO.Directory]::CreateDirectory($binDir) | Out-Null
$dshCmd = Join-Path $binDir 'dsh.cmd'
$nodeExe = Join-Path $TargetRoot 'node\node.exe'
$entryAbs = Join-Path (Join-Path $TargetRoot 'dsh\@deepseek-ai\dsh') $entry
$cmdBody = "@echo off`r`nsetlocal`r`n`"$nodeExe`" `"$entryAbs`" %*`r`n"
[System.IO.File]::WriteAllText($dshCmd, $cmdBody, (New-Object System.Text.ASCIIEncoding))
Write-Host "[offline] shim: $dshCmd -> node $entry"

# ---------- 3. User PATH (HKCU only; idempotent; type-preserving) ----------
if (-not $NoPath) {
    $envKey = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', $true)
    if ($envKey) {
        $kind = $envKey.GetValueKind('Path')
        $cur = [string]$envKey.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        $parts = @($cur -split ';' | Where-Object { $_ -ne '' })
        if ($parts -notcontains $binDir) {
            $envKey.SetValue('Path', ($parts + $binDir) -join ';', $kind)
            Write-Host "[offline] user PATH += $binDir (new terminals only)"
        } else {
            Write-Host '[offline] user PATH already contains the bundle bin dir'
        }
        $envKey.Close()
        # Broadcast so new processes started from Explorer pick it up.
        Add-Type -Namespace Win32 -Name Native -MemberDefinition '[DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Auto)] public static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint Msg, UIntPtr wParam, string lParam, uint fuFlags, uint uTimeout, out UIntPtr lpdwResult);'
        $result = [UIntPtr]::Zero
        [Win32.Native]::SendMessageTimeout([IntPtr]0xffff, 0x001A, [UIntPtr]::Zero, 'Environment', 2, 5000, [ref]$result) | Out-Null
    }
} else {
    Write-Host '[offline] -NoPath: PATH untouched (the manager still works via DshCommand)'
}

# ---------- 4. Pre-baked profile -> ~/.dsh (sandbox-aware) ----------
$profileSrc = if ($treeLayoutB) { Join-Path $TargetRoot 'profile-web' } else { Join-Path $BundleDir 'profile-web' }
if (Test-Path -LiteralPath $profileSrc) {
    # Sandbox testing (TESTING.md): never touch the real %USERPROFILE%\.dsh.
    $dshHome = if ($sandboxHome) { Join-Path $sandboxHome '.dsh' } else { Join-Path $env:USERPROFILE '.dsh' }
    if (-not (Test-Path -LiteralPath $dshHome)) {
        Copy-Item -LiteralPath $profileSrc -Destination $dshHome -Recurse
        Write-Host "[offline] profile installed -> $dshHome"
    } else {
        # Existing .dsh: fill gaps only — never clobber the user's profiles,
        # settings or credentials (API keys are entered in the WebUI).
        Get-ChildItem -LiteralPath $profileSrc -Recurse -File | ForEach-Object {
            $rel = $_.FullName.Substring($profileSrc.Length + 1)
            $dest = Join-Path $dshHome $rel
            if (-not (Test-Path -LiteralPath $dest)) {
                [System.IO.Directory]::CreateDirectory((Split-Path -Parent $dest)) | Out-Null
                Copy-Item -LiteralPath $_.FullName -Destination $dest
            }
        }
        Write-Host "[offline] existing $dshHome kept; missing files filled from the bundle"
    }
} else {
    Write-Warning '[offline] bundle has no profile-web\; first dsh start will initialize ~/.dsh itself'
}

# ---------- 5. Tray manager ----------
if (-not $SkipManager) {
    if ($sandboxHome) {
        # Testing layout (TESTING.md): mirror dist into the sandbox app dir, no
        # version downgrade, no real-machine shortcuts or config touched.
        $appRoot = Join-Path $sandboxHome 'AppData\Local\dsh-web-manager\app'
        $exe = Join-Path $appRoot 'dsh-web-manager.exe'
        $bundledExe = Join-Path $BundleDir 'dsh-web-manager\dsh-web-manager.exe'
        function Compare-Version([string]$a, [string]$b) {
            $pa = @($a -split '\.' | ForEach-Object { $n = 0; [void][int]::TryParse($_, [ref]$n); $n })
            $pb = @($b -split '\.' | ForEach-Object { $n = 0; [void][int]::TryParse($_, [ref]$n); $n })
            for ($i = 0; $i -lt [Math]::Max($pa.Count, $pb.Count); $i++) {
                $x = if ($i -lt $pa.Count) { $pa[$i] } else { 0 }
                $y = if ($i -lt $pb.Count) { $pb[$i] } else { 0 }
                if ($x -ne $y) { return if ($x -gt $y) { 1 } else { -1 } }
            }
            return 0
        }
        $installIt = $true
        if (Test-Path -LiteralPath $exe -PathType Leaf) {
            $oldV = (Get-Item -LiteralPath $exe).VersionInfo.FileVersion
            $newV = (Get-Item -LiteralPath $bundledExe).VersionInfo.FileVersion
            if ((Compare-Version $oldV $newV) -ge 0) { $installIt = $false; Write-Host "[offline] sandbox manager v$oldV kept (bundle v$newV not newer)" }
        }
        if ($installIt) {
            [System.IO.Directory]::CreateDirectory($appRoot) | Out-Null
            Copy-Item -Path (Join-Path $BundleDir 'dsh-web-manager\*') -Destination $appRoot -Recurse -Force
            Write-Host "[offline] sandbox manager -> $appRoot"
        }
    } else {
        $installer = Join-Path $BundleDir 'dsh-web-manager\Install.ps1'
        if (-not (Test-Path -LiteralPath $installer -PathType Leaf)) { throw "Manager installer missing: $installer" }
        # -SourceDir is REQUIRED here: Install.ps1 defaults its source to
        # <parent-of-its-dir>\dist (repo layout). In the bundle it lives INSIDE
        # the dist copy, so the default resolves to a nonexistent ...\dist\dist.
        $installArgs = @{ SkipLaunch = $true; SourceDir = (Join-Path $BundleDir 'dsh-web-manager') }
        if ($NoShortcut) { $installArgs.NoShortcut = $true }
        & $installer @installArgs
    }
}

# ---------- 6. Config wiring: DshCommand -> bundled shim ----------
# IMPORTANT: this runs BEFORE the WSL step so the Windows-side config is
# always written even when the WSL install fails (the WSL step is optional).
# If DshCommand were only set after the WSL step, a WSL failure with
# $ErrorActionPreference=Stop would leave the config without DshCommand,
# and the manager would not find the bundled dsh binary.
$sharedDir = if ($sandboxHome) { Join-Path $sandboxHome '.dsh-webui' } else { Join-Path $env:USERPROFILE '.dsh-webui' }
$configFile = Join-Path $sharedDir 'config.json'
[System.IO.Directory]::CreateDirectory($sharedDir) | Out-Null
$config = $null
if (Test-Path -LiteralPath $configFile -PathType Leaf) {
    $config = Get-Content -LiteralPath $configFile -Raw | ConvertFrom-Json
} else {
    $example = Join-Path $BundleDir 'dsh-web-manager\config.example.json'
    if (Test-Path -LiteralPath $example -PathType Leaf) {
        $config = Get-Content -LiteralPath $example -Raw | ConvertFrom-Json
    } else {
        $config = New-Object PSObject
    }
}
if (-not ($config.PSObject.Properties['DshCommand'])) {
    $config | Add-Member -MemberType NoteProperty -Name DshCommand -Value ''
}
# Only pin the bundled shim when unset, or when it already points into a
# dsh-bundle tree (upgrade); a deliberate user override wins.
$cur = [string]$config.DshCommand
if ($cur -eq '' -or $cur -like '*\dsh-bundle\*') { $config.DshCommand = $dshCmd }
if (-not ($config.PSObject.Properties['WindowBackend'])) {
	    $config | Add-Member -MemberType NoteProperty -Name WindowBackend -Value 'auto'
	}
	$config | ConvertTo-Json -Depth 8 | ForEach-Object { [System.IO.File]::WriteAllText($configFile, $_, (New-Object System.Text.UTF8Encoding($false))) }
Write-Host "[offline] config wired: DshCommand=$($config.DshCommand) WindowBackend=$($config.WindowBackend) ($configFile)"

# ---------- 5b. WSL side (optional; non-fatal) ----------
# Runs AFTER the Windows config wiring so a WSL failure never blocks the
# Windows-side config (DshCommand) from being written. The WSL step is
# best-effort: failures are warnings, not fatal errors.
$wslInstalledDistro = ''
$wslPayload = if ($treeLayoutB) { Join-Path $TargetRoot 'wsl' } else { Join-Path $BundleDir 'wsl' }
$wslWanted = $false
if ($SkipWsl) {
    Write-Host '[offline] -SkipWsl: WSL side untouched'
} elseif ($WithWsl -or (Test-Path -LiteralPath (Join-Path $wslPayload 'install-wsl.sh') -PathType Leaf)) {
    $wslWanted = $true
}
if ($wslWanted -and $sandboxHome) {
    Write-Host '[offline] sandbox mode: WSL side skipped (real distros only)'
    $wslWanted = $false
}
if ($wslWanted) {
    if (-not (Test-Path -LiteralPath (Join-Path $wslPayload 'install-wsl.sh') -PathType Leaf)) {
        Write-Warning '[offline] bundle has no wsl\ payload; WSL side skipped'
        $wslWanted = $false
    }
}
if ($wslWanted) {
    $wslExe = Join-Path $env:SystemRoot 'System32\wsl.exe'
    if (-not (Test-Path -LiteralPath $wslExe -PathType Leaf)) {
        if ($WithWsl) { Write-Warning '[offline] -WithWsl given but wsl.exe not found; WSL side skipped' }
        else { Write-Host '[offline] wsl.exe not found: WSL side skipped' }
        $wslWanted = $false
    }
}
if ($wslWanted) {
    function Convert-ToWslPath([string]$winPath) {
        $full = [System.IO.Path]::GetFullPath($winPath)
        $drive = $full.Substring(0, 1).ToLowerInvariant()
        return '/mnt/' + $drive + ($full.Substring(2) -replace '\\', '/')
    }
    function Get-WslLines([string[]]$wslArgs) {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $wslExe
        $psi.Arguments = ($wslArgs -join ' ')
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.RedirectStandardOutput = $true
        $psi.StandardOutputEncoding = [System.Text.Encoding]::Unicode
        $p = [System.Diagnostics.Process]::Start($psi)
        $out = $p.StandardOutput.ReadToEnd()
        $p.WaitForExit(10000) | Out-Null
        return (@($out -replace "`0", '' -split "`r?`n") | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
    }
    $helpers = @('docker-desktop', 'docker-desktop-data', 'rancher-desktop', 'podman-machine-default')
    $distro = $WslDistro
    if (-not $distro) {
        $running = @(Get-WslLines @('-l', '--running') | Select-Object -Skip 1 | Where-Object { $h = $_ -replace ' \(.+\)$', ''; $helpers -notcontains $h })
        $all     = @(Get-WslLines @('-l', '-q'))
        if ($running.Count -gt 0)      { $distro = ($running[0] -replace ' \(.+\)$', '') }
        elseif ($all.Count -gt 0)      { $distro = $all[0] }
    }
    if (-not $distro) {
        if ($WithWsl) { Write-Warning '[offline] -WithWsl given but no WSL distro found; WSL side skipped' }
        else { Write-Host '[offline] no WSL distro found: WSL side skipped' }
        $wslWanted = $false
    } else {
        Write-Host "[offline] WSL target distro: $distro"
        $srcWsl = Convert-ToWslPath $wslPayload
        $inner = 'cp "' + $srcWsl + '/install-wsl.sh" /tmp/install-wsl.sh && bash /tmp/install-wsl.sh --src "' + $srcWsl + '" --prefix "$HOME/.dsh-bundle"'
        try {
            & $wslExe -d $distro -- bash -c $inner
            if ($LASTEXITCODE -eq 0) {
                $wslInstalledDistro = $distro
                Write-Host "[offline] WSL side installed into '$distro' (~/.dsh-bundle + ~/.local/bin/dsh + profile + companion scripts)"
                # Remember the distro in config so the tray's WSL backend targets it.
                if (Test-Path -LiteralPath $configFile -PathType Leaf) {
                    try {
                        $cfg = Get-Content -LiteralPath $configFile -Raw | ConvertFrom-Json
                        if ($cfg.PSObject.Properties['WslDistro']) {
                            $curDistro = [string]$cfg.WslDistro
                            if ($curDistro -eq '' -or $curDistro -eq $wslInstalledDistro) {
                                $cfg.WslDistro = $wslInstalledDistro
                                $cfg | ConvertTo-Json -Depth 8 | ForEach-Object { [System.IO.File]::WriteAllText($configFile, $_, (New-Object System.Text.UTF8Encoding($false))) }
                            }
                        }
                    } catch { Write-Warning "[offline] could not update WslDistro in config: $($_.Exception.Message)" }
                }
            } else {
                Write-Warning "[offline] WSL-side install script exited $LASTEXITCODE (the 'Failed to start the systemd user session' notice is harmless); WSL side skipped"
            }
        } catch {
            Write-Warning "[offline] WSL-side install failed: $($_.Exception.Message); WSL side skipped"
        }
    }
}

# ---------- 7. Autostart (optional) ----------
if ($AutoStart -and -not $sandboxHome) {
    $runKey = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey('Software\Microsoft\Windows\CurrentVersion\Run')
    $runKey.SetValue('dsh-web-manager', '"' + (Join-Path $env:LOCALAPPDATA 'dsh-web-manager\app\dsh-web-manager.exe') + '" open')
    $runKey.Close()
    Write-Host '[offline] autostart enabled (HKCU Run)'
}

# ---------- 8. Verify + launch ----------
$nodeVer = & (Join-Path $TargetRoot 'node\node.exe') --version
Write-Host "[offline] verify: portable node $nodeVer"
$dshVersion = & $dshCmd --version 2>$null
if ($LASTEXITCODE -eq 0 -and $dshVersion) { Write-Host "[offline] verify: dsh $($dshVersion.Trim()) via $dshCmd" }
else { Write-Warning "[offline] dsh --version via shim failed (exit $LASTEXITCODE) — inspect $dshCmd" }

if (-not $SkipLaunch) {
    if ($sandboxHome) {
        Write-Host '[offline] sandbox mode: not auto-launching the tray (start it manually with DSH_WEB_MANAGER_HOME set)'
    } else {
        $exe = Join-Path $env:LOCALAPPDATA 'dsh-web-manager\app\dsh-web-manager.exe'
        if (Test-Path -LiteralPath $exe -PathType Leaf) {
            Start-Process -FilePath $exe -ArgumentList 'open' -WindowStyle Hidden
            Write-Host '[offline] tray manager started (look for the whale icon).'
        }
    }
}

Write-Host ''
Write-Host 'Offline install finished.'
Write-Host "  node/dsh tree : $TargetRoot"
Write-Host "  dsh shim      : $dshCmd"
$profileNote = if ($sandboxHome) { (Join-Path $sandboxHome '.dsh') } else { (Join-Path $env:USERPROFILE '.dsh') }
Write-Host "  profile       : $profileNote"
if (-not $sandboxHome) { Write-Host '  tray manager  : %LOCALAPPDATA%\dsh-web-manager\app (shortcuts on desktop/start menu)' }
