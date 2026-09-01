# Windows equivalent of build_app.sh: release build + deployable layout.
#
# This is NOT a straight port of build_app.sh. macOS ships one relocatable
# unit (a code-signed .app bundle) because Gatekeeper/TCC require it; Windows
# has no bundle format and no equivalent of TCC privacy grants tied to a
# signing identity, so this script's job is simpler and different in kind:
# produce a folder containing the .exe plus every DLL it needs to run WITHOUT
# the Swift toolchain on PATH, because that is the actual constraint Claude
# Desktop imposes (it spawns the MCP server with its own environment, not this
# shell's PATH).
$ErrorActionPreference = "Stop"

function Fail($message) {
    Write-Error $message
    exit 1
}

# ---------------------------------------------------------------------------
# 1. Locate the Swift toolchain, runtime, Windows platform SDK, and MSVC
#    environment. Same discovery strategy as swiftenv.ps1 (newest-versioned
#    subdirectory under each of Toolchains/Runtimes/Platforms), but every
#    lookup fails with an actionable message instead of throwing a bare
#    "path not found" -- this script is meant to also work on a machine
#    that has never been set up for this project before.
# ---------------------------------------------------------------------------
$swiftRoot = "$env:LOCALAPPDATA\Programs\Swift"
if (-not (Test-Path $swiftRoot)) {
    Fail "Swift toolchain not found at $swiftRoot. Install the Swift for Windows toolchain (swift.org/install) before running this script."
}

$toolchainDir = Get-ChildItem "$swiftRoot\Toolchains" -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1
if (-not $toolchainDir) {
    Fail "No Swift toolchain found under $swiftRoot\Toolchains. Install the Swift for Windows toolchain (swift.org/install)."
}
$toolchain = $toolchainDir.FullName

$runtimeDir = Get-ChildItem "$swiftRoot\Runtimes" -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1
if (-not $runtimeDir) {
    Fail "No Swift Runtimes directory found under $swiftRoot\Runtimes. Install (or repair) the Swift for Windows runtime component."
}
$runtimeVer = $runtimeDir.Name
$runtimeBin = "$swiftRoot\Runtimes\$runtimeVer\usr\bin"
if (-not (Test-Path $runtimeBin)) {
    Fail "Swift runtime bin directory not found at $runtimeBin. Reinstall the Swift for Windows runtime component."
}

$platformDir = Get-ChildItem "$swiftRoot\Platforms" -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1
if (-not $platformDir) {
    Fail "No Windows platform SDK found under $swiftRoot\Platforms. Install the Swift for Windows platform SDK component."
}
$platformVer = $platformDir.Name
$env:SDKROOT = "$swiftRoot\Platforms\$platformVer\Windows.platform\Developer\SDKs\Windows.sdk"
if (-not (Test-Path $env:SDKROOT)) {
    Fail "Windows SDK not found at $env:SDKROOT. Reinstall the Swift for Windows platform SDK component."
}

$env:PATH = "$toolchain\usr\bin;$runtimeBin;$env:PATH"

# Import the MSVC environment (link.exe, cl.exe headers/libs) from
# vcvars64.bat, located via vswhere. This is required for swift build to
# link on Windows; without it the build fails with missing link.exe / CRT
# headers rather than anything Swift-specific.
$vswhere = "C:\Program Files (x86)\Microsoft Visual Studio\Installer\vswhere.exe"
if (-not (Test-Path $vswhere)) {
    Fail "vswhere.exe not found at $vswhere. Install Visual Studio 2022 Build Tools with the 'Desktop development with C++' workload."
}

$vsPath = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if (-not $vsPath) {
    Fail "No Visual Studio installation with the VC.Tools.x86.x64 component was found. Install Visual Studio 2022 Build Tools with the 'Desktop development with C++' workload (and the Windows 10/11 SDK)."
}

$vcvars = "$vsPath\VC\Auxiliary\Build\vcvars64.bat"
if (-not (Test-Path $vcvars)) {
    Fail "vcvars64.bat not found at $vcvars. Repair the Visual Studio 2022 Build Tools installation (VC++ workload)."
}

cmd /c "`"$vcvars`" >nul 2>&1 && set" | ForEach-Object {
    if ($_ -match '^([^=]+)=(.*)$') {
        $name = $matches[1]
        $value = $matches[2]
        if ($name -ne "PATH") {
            Set-Item -Path "env:$name" -Value $value -ErrorAction SilentlyContinue
        } else {
            $env:PATH = "$toolchain\usr\bin;$runtimeBin;$value"
        }
    }
}
if (-not $env:VCToolsInstallDir) {
    Fail "vcvars64.bat ran but did not populate the MSVC environment (VCToolsInstallDir unset). Repair the Visual Studio 2022 Build Tools installation."
}

Write-Output "Swift toolchain: $toolchain"
Write-Output "Swift runtime:   $runtimeBin"
Write-Output "SDKROOT:         $env:SDKROOT"
Write-Output "VS install:      $vsPath"

# ---------------------------------------------------------------------------
# 2. Release build.
# ---------------------------------------------------------------------------
Write-Output "Building AI Chalkboard release binary..."
swift build -c release
if ($LASTEXITCODE -ne 0) {
    Fail "swift build -c release failed (exit $LASTEXITCODE)."
}

$repoRoot = (Get-Location).Path

# NOT ".build\release\AIChalkboard.exe": that path is a convenience symlink
# SwiftPM creates alongside the real, triple-qualified output directory
# (".build\<triple>\release"), and creating it needs either Windows
# Developer Mode or an elevated process -- verified failing here with
# "unable to create symbolic link ... I/O error (code: 512)" even though the
# actual release build succeeded. `--show-bin-path` is SwiftPM's own
# documented way to ask where a build's output actually landed, so it works
# whether or not that symlink got created.
$buildExe = (swift build -c release --show-bin-path 2>$null | Select-Object -Last 1).Trim()
$buildExe = Join-Path $buildExe "AIChalkboard.exe"
if (-not (Test-Path $buildExe)) {
    Fail "Release build reported success but $buildExe does not exist."
}

# ---------------------------------------------------------------------------
# 3. Build identifier. Mirrors build_app.sh: git short SHA, '-dirty' suffix
#    when the tree has staged, unstaged, or untracked changes, 'source'
#    fallback when Git is unavailable or the identifier is otherwise unusable.
#    Windows has no Info.plist to embed this in (see step 5's comment on
#    BuildMetadata.swift), so this is reported alongside the exe path instead.
# ---------------------------------------------------------------------------
$buildIdentifier = $env:AI_CHALKBOARD_BUILD_IDENTIFIER
if (-not $buildIdentifier) {
    $gitSha = $null
    try {
        $gitSha = (git rev-parse --short=12 HEAD 2>$null)
        if ($LASTEXITCODE -ne 0) { $gitSha = $null }
    } catch {
        $gitSha = $null
    }
    $buildIdentifier = if ($gitSha) { $gitSha.Trim() } else { "source" }

    if ($gitSha) {
        $isRepo = $false
        try {
            git rev-parse --is-inside-work-tree *> $null
            $isRepo = ($LASTEXITCODE -eq 0)
        } catch { $isRepo = $false }

        if ($isRepo) {
            $dirty = $false
            git diff --quiet 2>$null
            if ($LASTEXITCODE -ne 0) { $dirty = $true }
            git diff --cached --quiet 2>$null
            if ($LASTEXITCODE -ne 0) { $dirty = $true }
            $untracked = git ls-files --others --exclude-standard 2>$null
            if ($untracked) { $dirty = $true }
            if ($dirty) { $buildIdentifier = "$buildIdentifier-dirty" }
        }
    }
}
if ($buildIdentifier -notmatch '^[A-Za-z0-9._-]{1,128}$') {
    Write-Warning "Invalid AI_CHALKBOARD_BUILD_IDENTIFIER; using source fallback."
    $buildIdentifier = "source"
}

# CFBundleShortVersionString's Windows counterpart: read productVersion from
# the same single source of truth build_app.sh uses, for the same reason
# (drift between a hardcoded copy and BuildMetadata.swift). Fail loudly
# rather than silently reporting an empty/malformed version.
$buildMetadataPath = Join-Path $repoRoot "Sources\Support\BuildMetadata.swift"
$productVersion = $null
if (Test-Path $buildMetadataPath) {
    $match = Select-String -Path $buildMetadataPath -Pattern '^\s*static let productVersion = "([^"]*)"' | Select-Object -First 1
    if ($match) { $productVersion = $match.Matches[0].Groups[1].Value }
}
if (-not $productVersion -or $productVersion -notmatch '^[0-9]+(\.[0-9]+){1,3}$') {
    Fail "Could not determine a valid productVersion from Sources\Support\BuildMetadata.swift (got: '$productVersion'). Expected a line there like: static let productVersion = `"2.1.0`""
}

Write-Output "Build identifier: $buildIdentifier"
Write-Output "Product version:  $productVersion"

# ---------------------------------------------------------------------------
# 4. Assemble the deployable layout: dist\AIChalkboard\AIChalkboard.exe plus
#    every Swift/C++ runtime DLL it transitively needs, so Claude Desktop can
#    launch it without the Swift toolchain on PATH. Verified: running the
#    bare .build\release\AIChalkboard.exe from a shell with a minimal PATH
#    fails immediately with STATUS_DLL_NOT_FOUND (0xC0000135).
#
#    Method for determining the needed DLL set: read the PE import table
#    with the Swift toolchain's own llvm-objdump.exe (`-p`, "DLL Name:"
#    lines under the import table) starting from AIChalkboard.exe, and walk
#    the dependency graph transitively -- for every imported DLL that exists
#    in the Swift Runtimes usr\bin directory, copy it and recurse into ITS
#    imports too (a Swift DLL can depend on other Swift/C++ redistributable
#    DLLs, e.g. swiftCore.dll -> swiftCRT.dll -> vcruntime140.dll). Anything
#    NOT found in that runtime directory (kernel32.dll, ntdll.dll, user32.dll,
#    gdi32.dll, ole32.dll, oleaut32.dll, shell32.dll, shcore.dll, dwmapi.dll,
#    gdiplus.dll, windowscodecs.dll, advapi32.dll, ws2_32.dll, bcrypt.dll,
#    api-ms-win-*.dll, etc.) is assumed to be a base Windows component
#    present on any target machine and is deliberately left uncopied -- this
#    app already links those directly (see Package.swift's linkerSettings
#    and CChalkboardWin), and they ship with Windows itself, not with Swift.
#    This is a closure over actual PE imports, not a guessed/hardcoded list,
#    so it stays correct if a future Swift toolchain version changes which
#    DLLs exist or depend on which others.
# ---------------------------------------------------------------------------
$objdump = "$toolchain\usr\bin\llvm-objdump.exe"
if (-not (Test-Path $objdump)) {
    Fail "llvm-objdump.exe not found at $objdump (expected inside the Swift toolchain)."
}

function Get-ImportedDlls([string]$binaryPath) {
    $output = & $objdump -p $binaryPath 2>$null
    $names = @()
    foreach ($line in $output) {
        if ($line -match '^\s*DLL Name:\s*(\S+)\s*$') {
            $names += $matches[1]
        }
    }
    return $names
}

$runtimeDllIndex = @{}
Get-ChildItem $runtimeBin -Filter "*.dll" | ForEach-Object {
    $runtimeDllIndex[$_.Name.ToLowerInvariant()] = $_.FullName
}

$needed = New-Object System.Collections.Generic.HashSet[string]
$queue = New-Object System.Collections.Generic.Queue[string]
$queue.Enqueue($buildExe)
$visitedBinaries = New-Object System.Collections.Generic.HashSet[string]

while ($queue.Count -gt 0) {
    $current = $queue.Dequeue()
    $currentKey = $current.ToLowerInvariant()
    if ($visitedBinaries.Contains($currentKey)) { continue }
    [void]$visitedBinaries.Add($currentKey)

    foreach ($dllName in (Get-ImportedDlls $current)) {
        $key = $dllName.ToLowerInvariant()
        if ($runtimeDllIndex.ContainsKey($key) -and -not $needed.Contains($key)) {
            [void]$needed.Add($key)
            $queue.Enqueue($runtimeDllIndex[$key])
        }
    }
}

if ($needed.Count -eq 0) {
    Fail "Dependency scan found zero Swift runtime DLLs required by AIChalkboard.exe -- llvm-objdump likely failed silently; investigate before shipping a dist that will STATUS_DLL_NOT_FOUND on launch."
}

# ---------------------------------------------------------------------------
# 3b. Lock-tolerant replacement of a single deployed file.
#
#    Claude Desktop runs the PREVIOUS build's AIChalkboard.exe as a
#    long-lived MCP server child process, and Windows locks a RUNNING
#    executable's image file -- and every Swift runtime DLL it has loaded --
#    against deletion. This is the normal case on every rebuild while the
#    connector is installed, not an edge case: the observed failure is
#    "Remove-Item : ... Access to the path 'AIChalkboard.exe' is denied.",
#    and it reproduces identically in an elevated Administrator shell,
#    because an image lock is not a permissions problem -- elevation cannot
#    override it.
#
#    What Windows DOES still allow against a locked file is RENAMING it -- a
#    directory-entry operation -- even though it forbids deleting,
#    truncating, or overwriting it. This is the same technique Windows
#    self-updaters use: rename the locked file aside so the already-running
#    process keeps using its already-mapped old image, then write a fresh
#    file at the original path. So instead of one blunt
#    `Remove-Item -Recurse -Force $appDir` (which dies the instant it
#    reaches whichever locked file it enumerates first, mid-directory, and
#    used to take out the entire dist folder with it), every file this
#    script deploys is replaced individually: plain delete first, and only
#    on failure, rename aside.
# ---------------------------------------------------------------------------
$script:anyRenamedAside = $false

function Get-LockHolderReport([string]$path) {
    # Best-effort diagnostic for the Fail() message below, not a guarantee of
    # completeness -- this only enumerates AIChalkboard.exe processes, which
    # covers the actual observed cause (Claude Desktop's MCP server child),
    # not every conceivable handle holder on $path.
    $holders = @(Get-CimInstance Win32_Process -Filter "Name='AIChalkboard.exe'" -ErrorAction SilentlyContinue)
    if ($holders.Count -eq 0) {
        return "  (no AIChalkboard.exe process is currently running -- some other program has '$path' open)"
    }
    $lines = foreach ($proc in $holders) {
        $parentName = "unknown"
        $parent = Get-CimInstance Win32_Process -Filter "ProcessId=$($proc.ParentProcessId)" -ErrorAction SilentlyContinue
        if ($parent) { $parentName = $parent.Name }
        "  PID $($proc.ProcessId), parent: $parentName (PID $($proc.ParentProcessId))"
    }
    return ($lines -join "`n")
}

function Remove-OrRenameAside([string]$path) {
    if (-not (Test-Path $path)) { return }
    try {
        Remove-Item -Force $path -ErrorAction Stop
        return
    } catch {
        # Fall through to the rename-aside path below. Not every possible
        # delete failure is a lock, but a rename attempt is a cheap,
        # harmless next step either way -- and if the real cause is
        # something else, the rename below fails too and reports it.
    }

    $directory = Split-Path $path -Parent
    $leaf = Split-Path $path -Leaf
    $maxAttempts = 1000
    for ($counter = 1; $counter -le $maxAttempts; $counter++) {
        $candidateName = "$leaf.old-$counter"
        if (Test-Path (Join-Path $directory $candidateName)) { continue }
        try {
            Rename-Item -Path $path -NewName $candidateName -ErrorAction Stop
            $script:anyRenamedAside = $true
            return
        } catch {
            Fail (
                "Cannot update '$path' -- it is locked and could not be deleted or renamed aside.`n" +
                "Likely holding process(es):`n$(Get-LockHolderReport $path)`n`n" +
                "Fully quit Claude Desktop (it keeps AIChalkboard.exe running as a long-lived MCP server child process) and re-run this script."
            )
        }
    }
    Fail "Could not find a free '$leaf.old-N' name aside for '$path' after $maxAttempts attempts -- clean up '$directory' by hand and re-run this script."
}

$distDir = Join-Path $repoRoot "dist"
$appDir = Join-Path $distDir "AIChalkboard"
Write-Output "Creating deployable layout at $appDir..."

# Best-effort cleanup of *.old-* files renamed aside by a PREVIOUS run (see
# Remove-OrRenameAside above). Once the process that held the lock has
# exited, these are ordinary deletable files -- but this is purely cosmetic
# housekeeping (nothing reads a *.old-* file, and Remove-OrRenameAside picks
# a name that avoids colliding with one anyway), so a failure here must
# NEVER fail the build; a leftover just waits for the next run to try again.
if (Test-Path $appDir) {
    Get-ChildItem $appDir -Filter "*.old-*" -File -ErrorAction SilentlyContinue | ForEach-Object {
        Remove-Item -Force $_.FullName -ErrorAction SilentlyContinue
    }
}

if (-not (Test-Path $appDir)) {
    New-Item -ItemType Directory -Path $appDir | Out-Null
}

# Note this no longer wipes $appDir wholesale: only the exact files this
# build deploys (the exe, and this toolchain's current DLL closure) are
# touched. On the common path -- app not running -- Remove-OrRenameAside's
# plain-delete branch makes this behave exactly like the old
# delete-directory-then-recopy did, with no leftovers.
$exeDest = Join-Path $appDir "AIChalkboard.exe"
Remove-OrRenameAside $exeDest
Copy-Item $buildExe $exeDest

foreach ($key in $needed) {
    $dllDest = Join-Path $appDir (Split-Path $runtimeDllIndex[$key] -Leaf)
    Remove-OrRenameAside $dllDest
    Copy-Item $runtimeDllIndex[$key] $dllDest
}
Write-Output "Copied $($needed.Count) Swift runtime DLL(s): $($needed -join ', ')"

# ---------------------------------------------------------------------------
# 4b. Build-identifier sidecar file: the Windows analogue of macOS's
#    Info.plist embedding (see build_app.sh, and Sources\Support\BuildMetadata.swift's
#    "buildIdentifier" doc comment). A bare .exe has no bundle to embed
#    metadata into, so BuildMetadata reads this small file back out of the
#    directory containing the RUNNING executable instead. Plain
#    [System.IO.File]::WriteAllText with an explicit no-BOM UTF8Encoding,
#    not `Out-File -Encoding utf8` / `Set-Content` -- both of those emit a
#    UTF-8 BOM in Windows PowerShell 5.1, and a BOM has already silently
#    broken this project once (the Claude Desktop config file). The name
#    here must match BuildMetadata.windowsSidecarFileName exactly.
# ---------------------------------------------------------------------------
$sidecarPath = Join-Path $appDir "build-identifier.txt"
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($sidecarPath, $buildIdentifier, $utf8NoBom)
Write-Output "Wrote build identifier sidecar: $sidecarPath"

# ---------------------------------------------------------------------------
# 5. No code-signing step here, deliberately.
#
#    build_app.sh signs the macOS bundle with a pinned local identity so
#    macOS TCC treats every local rebuild as an update of the SAME app,
#    keeping Screen Recording / Accessibility grants stable instead of
#    re-prompting (or silently losing the grant) on every rebuild. Windows
#    has no equivalent per-app privacy-grant system keyed off a code-signing
#    identity -- there is nothing here for signing to stabilize. (A real
#    Authenticode certificate would still be worth having for
#    SmartScreen/AV reputation before wide distribution, but that is an
#    unrelated concern from TCC grant stability and out of scope for this
#    dev-build script.)
# ---------------------------------------------------------------------------

$exePath = Join-Path $appDir "AIChalkboard.exe"
Write-Output ""
Write-Output "Deployable layout created successfully at $appDir"
Write-Output "Build identifier: $buildIdentifier | Product version: $productVersion"
Write-Output ""
Write-Output "Paste into claude_desktop_config.json as the MCP server 'command':"
Write-Output "  `"$exePath`""
Write-Output "  (as a JSON string, i.e. with backslashes escaped: `"$($exePath -replace '\\','\\')`")"

if ($script:anyRenamedAside) {
    Write-Output ""
    Write-Output "NOTE: $appDir had one or more files locked by an already-running AIChalkboard.exe."
    Write-Output "Those files were renamed aside (*.old-N) rather than overwritten -- the new build above is complete and on disk,"
    Write-Output "but the ALREADY-RUNNING connector process is still executing its OLD image from before this rename, so it is NOT running this build."
    Write-Output "Fully quit Claude Desktop and relaunch it to pick up this build."
}
