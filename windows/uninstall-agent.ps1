# OPTiCS Agent Windows Uninstaller
#
# Since 0.6.0 an install *is* the compose file in the install directory. Tearing down with
# compose from that directory, rather than removing containers by name, also cleans up the
# network and volumes.
#
# Same shape as the installer: ask everything first, confirm, then act.
#   Phase 1  Ask      - choose what to remove; nothing is removed.
#   Phase 2  Review   - show what goes and what stays; any item can be revisited by number.
#   Phase 3  Execute  - removal starts here.
# Removal is irreversible, so aborting at phase 2 loses nothing.
#
# Unlike Linux there is no SSH item: the Windows installer never touches authorized_keys,
# so there is nothing to undo. Hence 3 ask steps instead of 4.

# Stop would abort the script on every failing docker command. "Already gone" is the normal
# case when removing things, so errors are judged inline instead.
$ErrorActionPreference = "Continue"

$UNINSTALLER_VERSION = "0.6.0"

$INSTALL_DIR = if ($env:OPTICS_INSTALL_DIR) { $env:OPTICS_INSTALL_DIR } else { Join-Path $env:LOCALAPPDATA "OPTiCS\agent" }
$AGENT_IMAGE = "ghcr.io/optics-organization/optics-agent"
$DASHBOARD_IMAGE = "ghcr.io/optics-organization/optics-agent-dashboard"

# Phase 1 collects into these; nothing is removed until phase 3.
$PLAN_CONTAINERS = $false
$PLAN_IMAGES = $false
$PLAN_DATA = $false
$PLAN_INSTALL_DIR = $false

# Current state discovered during the ask phase, used to spell out what disappears.
$CONTAINERS_FOUND = $false
$CONTAINER_NOTE = ""
$IMAGES_FOUND = @()
$DATA_DIR = ""
$BUILD_DIR = ""
$COMPOSE_OK = $false

# What phase 3 actually removed, for the closing summary.
$DONE_CONTAINERS = "kept"
$DONE_IMAGES = "kept"
$DONE_DATA = "kept"
$DONE_INSTALL_DIR = "kept"

# Progress for phase 3 only.
$STEP_TOTAL = 4
$script:STEP_NUM = 0

function Write-Step {
    param([string]$Title)

    $script:STEP_NUM += 1
    Write-Host ""
    Write-Host "[$($script:STEP_NUM)/$STEP_TOTAL] $Title"
}

# Ask steps take a fixed number rather than incrementing: the review lets you jump back,
# and the number must match the review item so "changed 3" and "[3/3] Agent data" agree.
$ASK_TOTAL = 3

function Write-AskStep {
    param([int]$Number, [string]$Title)

    Write-Host ""
    Write-Host "[$Number/$ASK_TOTAL] $Title"
}

# A per-line prefix eats width and buries the step structure; indent content instead.
# A function's stdout is its return value, so user-visible text goes through Write-Host.
function Say {
    param([string]$Message)
    Write-Host "  $Message"
}

function Warn {
    param([string]$Message)
    Write-Host "  ! $Message"
}

# Nothing to wait for when console input is redirected.
function Test-Interactive {
    try {
        return -not [Console]::IsInputRedirected
    }
    catch {
        return $false
    }
}

# Brief pause on a step with nothing to ask; otherwise the reason for skipping scrolls
# past between prompts.
$SKIP_PAUSE = if ($env:OPTICS_SKIP_PAUSE) { [double]$env:OPTICS_SKIP_PAUSE } else { 1.5 }

function Wait-Skip {
    param([string]$Message)

    Say $Message
    if ((Test-Interactive) -and $SKIP_PAUSE -gt 0) {
        Start-Sleep -Seconds $SKIP_PAUSE
    }
}

# Last grace period before deletion; Ctrl+C here still loses nothing.
$COUNTDOWN_FROM = if ($env:OPTICS_COUNTDOWN) { [int]$env:OPTICS_COUNTDOWN } else { 3 }

function Start-Countdown {
    if (-not (Test-Interactive) -or $COUNTDOWN_FROM -le 0) {
        return
    }

    Write-Host ""
    Write-Host -NoNewline "  Removal starts in "
    for ($i = $COUNTDOWN_FROM; $i -gt 0; $i--) {
        Write-Host -NoNewline "$i"
        # One dot at a time so the seconds are visibly passing.
        for ($dot = 1; $dot -le 5; $dot++) {
            Start-Sleep -Milliseconds 200
            Write-Host -NoNewline "."
        }
    }
    Write-Host ""
}

# One-line y/N. The default is always the safe side: keep.
function Read-YesNo {
    param([string]$Prompt)

    # $input is an automatic variable in a PowerShell function; do not shadow it.
    $answer = Read-Host "  $Prompt (y/N)"
    return ($answer -in @('Y', 'y'))
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function Test-DockerPresent {
    return [bool](Get-Command docker -ErrorAction SilentlyContinue)
}

function Test-ComposePresent {
    if (-not (Test-DockerPresent)) { return $false }

    # Judge by exit code: docker's wording changes between releases.
    docker compose version *> $null
    return ($LASTEXITCODE -eq 0)
}

function Get-EnvValue {
    param([string]$Key)

    $envPath = Join-Path $INSTALL_DIR ".env"
    if (-not (Test-Path $envPath)) { return "" }

    $line = Select-String -Path $envPath -Pattern "^$Key=" -ErrorAction SilentlyContinue |
        Select-Object -Last 1
    if (-not $line) { return "" }

    return $line.Line.Substring($line.Line.IndexOf('=') + 1).Trim()
}

# Last guard before Remove-Item: refuse empty, relative, or drive-root paths even when
# they came from .env, so one typo cannot wipe a whole drive.
function Test-SafeToRemove {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    if (-not [System.IO.Path]::IsPathRooted($Path)) { return $false }

    try {
        $full = [System.IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
    }
    catch {
        return $false
    }

    # Reject paths that reduce to a drive root such as "C:" or "C:\".
    if ($full.Length -le 2) { return $false }
    $qualifier = [System.IO.Path]::GetPathRoot($full).TrimEnd('\', '/')
    if ($full -eq $qualifier) { return $false }

    return $true
}

# Read-only. The review needs to know what will be stopped, so this runs in the ask
# phase.
function Find-Containers {
    $script:CONTAINERS_FOUND = $false
    $script:CONTAINER_NOTE = ""

    if (-not (Test-DockerPresent)) {
        $script:CONTAINER_NOTE = "Docker is not installed"
        return
    }

    # The compose project name is pinned to optics-agent in the compose file, so the same
    # containers are findable by label even without that file.
    $names = @(docker ps -a --filter "label=com.docker.compose.project=optics-agent" --format "{{.Names}}" 2>$null |
        Where-Object { $_ } | Sort-Object)

    if ($names.Count -eq 0) {
        $names = @(docker ps -a --format "{{.Names}}" 2>$null |
            Where-Object { $_ -match '^optics-agent-optics-agent(-dashboard)?-1$' } | Sort-Object)
    }

    if ($names.Count -gt 0) {
        $script:CONTAINERS_FOUND = $true
        $script:CONTAINER_NOTE = ($names -join " ")
    }
}

function Find-Images {
    $script:IMAGES_FOUND = @()
    if (-not (Test-DockerPresent)) { return }

    # Match on image name, since tags may have been pinned.
    $script:IMAGES_FOUND = @(docker images --format "{{.Repository}}:{{.Tag}}" 2>$null |
        Where-Object { $_ -like "$AGENT_IMAGE`:*" -or $_ -like "$DASHBOARD_IMAGE`:*" } | Sort-Object)
}

# Since 0.7.0 both volumes bind mount host directories named in .env, so removing the
# volumes alone drops the shell and leaves the data. Read those paths first in order to
# ask about them.
function Find-DataDirs {
    # Falls back to the pre-0.6.0 key names. Uninstall is exactly when stale state shows
    # up, and without the fallback the paths read as unknown -- so data the user believed
    # was removed would silently survive.
    $script:DATA_DIR = Get-EnvValue "OPTICS_HOST_DATA_DIR"
    if (-not $script:DATA_DIR) { $script:DATA_DIR = Get-EnvValue "OPTICS_DATA_DIR" }

    $script:BUILD_DIR = Get-EnvValue "OPTICS_HOST_BUILD_DIR"
    if (-not $script:BUILD_DIR) { $script:BUILD_DIR = Get-EnvValue "OPTICS_BUILD_DIR" }
}

# ---------------------------------------------------------------------------
# Phase 1: ask
# ---------------------------------------------------------------------------
# Functions here only decide values: no containers stopped, no files removed.

function Ask-Containers {
    Write-AskStep 1 "Containers"

    if (-not $CONTAINERS_FOUND) {
        $script:PLAN_CONTAINERS = $false
        $note = if ($CONTAINER_NOTE) { " ($CONTAINER_NOTE)" } else { "" }
        Wait-Skip "No OPTiCS containers found$note"
        return
    }

    Say "Found: $CONTAINER_NOTE"
    Say "Stops and removes them along with the compose network."
    # Keeping containers pins the images and data too, so this is the one item that
    # defaults to yes.
    $answer = Read-Host "  Stop and remove containers? (Y/n)"
    $script:PLAN_CONTAINERS = -not ($answer -in @('N', 'n'))
}

function Ask-Images {
    Write-AskStep 2 "Images"

    if ($IMAGES_FOUND.Count -eq 0) {
        $script:PLAN_IMAGES = $false
        Wait-Skip "No OPTiCS images found"
        return
    }

    Say "Downloaded Agent and Dashboard images:"
    foreach ($image in $IMAGES_FOUND) {
        Write-Host "    $image"
    }
    Say "Reinstalling later will download them again."

    $script:PLAN_IMAGES = Read-YesNo "Remove downloaded images?"
}

function Ask-Data {
    Write-AskStep 3 "Agent data"

    # The local DB holds this Agent's UUID and signing secret. Removing it makes a
    # reinstall register as a brand-new Agent, orphaning the old one and its services.
    Say "Removing this unregisters the machine from OPTiCS Hub."
    Say "Reinstalling registers a new Agent; services on the old one stay orphaned."

    if ($DATA_DIR -or $BUILD_DIR) {
        $dataText = if ($DATA_DIR) { $DATA_DIR } else { "unknown" }
        $buildText = if ($BUILD_DIR) { $BUILD_DIR } else { "unknown" }
        Say "Data : $dataText"
        Say "Build: $buildText"
    }
    else {
        # Without .env the targets are unknown, and guessing a path could destroy someone
        # else's directory; say so instead.
        Warn ".env not found, so the data directories are unknown."
        Say "Docker volumes can still be removed; host directories cannot."
    }

    $script:PLAN_DATA = Read-YesNo "Remove Agent data?"
}

# Not a review item but a tail question: the compose file is the install, so removing it
# takes away the means to stop anything left behind.
function Ask-InstallDir {
    $script:PLAN_INSTALL_DIR = $false
    if (-not (Test-Path $INSTALL_DIR)) { return }

    $script:PLAN_INSTALL_DIR = Read-YesNo "Also remove the install directory ($INSTALL_DIR)?"
}

# ---------------------------------------------------------------------------
# Phase 2: review
# ---------------------------------------------------------------------------

function Show-Review {
    if ($PLAN_CONTAINERS) {
        $containersLine = "remove  ($CONTAINER_NOTE)"
    }
    elseif ($CONTAINERS_FOUND) {
        $containersLine = "keep    (still running: $CONTAINER_NOTE)"
    }
    else {
        $containersLine = "none found"
    }

    if ($PLAN_IMAGES) {
        $imagesLine = "remove  ($($IMAGES_FOUND.Count) image(s))"
    }
    elseif ($IMAGES_FOUND.Count -gt 0) {
        $imagesLine = "keep    ($($IMAGES_FOUND.Count) image(s))"
    }
    else {
        $imagesLine = "none found"
    }

    if ($PLAN_DATA) {
        $dataLine = "remove  (unregisters this machine from OPTiCS Hub)"
    }
    else {
        $dataLine = "keep"
    }

    Write-Host ""
    Write-Host "Review"
    Write-Host ""
    Write-Host "    1  Containers   $containersLine"
    Write-Host "    2  Images       $imagesLine"
    Write-Host "    3  Agent data   $dataLine"
    Write-Host ""
    Write-Host "    Install dir    $INSTALL_DIR"

    # Repeat the literal paths right before confirmation; deletion targets deserve one
    # last read.
    if ($PLAN_DATA) {
        if ($DATA_DIR -or $BUILD_DIR) {
            if ($DATA_DIR) { Write-Host "    Will delete    $DATA_DIR" }
            if ($BUILD_DIR) { Write-Host "    Will delete    $BUILD_DIR" }
        }
        else {
            Write-Host "    Data directories are unknown (.env missing); only volumes are removed"
        }
    }
    elseif ($DATA_DIR -or $BUILD_DIR) {
        $dataText = if ($DATA_DIR) { $DATA_DIR } else { "?" }
        $buildText = if ($BUILD_DIR) { $BUILD_DIR } else { "?" }
        Write-Host "    Data kept at   $dataText , $buildText"
    }

    if ($PLAN_CONTAINERS) {
        Write-Host "    The Agent stops serving this host once containers are removed"
    }
    Write-Host ""
}

# Show the review and let the user confirm or revisit an item. Answering no exits with
# nothing removed.
function Confirm-Plan {
    while ($true) {
        Show-Review
        $answer = Read-Host "  Proceed? (Y/n, or a number to change)"
        $answer = if ($null -eq $answer) { "" } else { $answer.Trim() }

        switch ($answer) {
            { $_ -in @('', 'Y', 'y') } { return }
            { $_ -in @('N', 'n') } {
                Say "Nothing was changed."
                exit 0
            }
            '1' { Ask-Containers }
            '2' { Ask-Images }
            '3' { Ask-Data }
            default { Warn "Enter Y, n, or 1-3." }
        }
    }
}

# ---------------------------------------------------------------------------
# Phase 3: execute
# ---------------------------------------------------------------------------

function Invoke-RemoveContainers {
    Write-Step "Removing containers"

    if (-not $PLAN_CONTAINERS) {
        Wait-Skip "Skipped"
        return
    }

    $composePath = Join-Path $INSTALL_DIR "docker-compose.yml"
    if ((Test-Path $composePath) -and $COMPOSE_OK) {
        Say "Stopping via compose in $INSTALL_DIR..."
        Push-Location $INSTALL_DIR
        docker compose down --remove-orphans
        Pop-Location
    }
    else {
        # Without the compose file or command, remove by container name: the project name
        # is pinned to optics-agent, so the names are predictable.
        Say "Compose definition not found. Falling back to container names..."
        docker rm -f optics-agent-optics-agent-dashboard-1 *> $null
        docker rm -f optics-agent-optics-agent-1 *> $null
        docker network rm optics-agent_service-network *> $null
    }

    $script:DONE_CONTAINERS = "removed"
    Say "Containers removed."
}

function Invoke-RemoveImages {
    Write-Step "Removing images"

    if (-not $PLAN_IMAGES) {
        Wait-Skip "Skipped"
        return
    }

    foreach ($image in $IMAGES_FOUND) {
        docker rmi $image *> $null
    }

    $script:DONE_IMAGES = "removed"
    Say "Images removed."
}

function Invoke-RemoveData {
    Write-Step "Removing Agent data"

    if (-not $PLAN_DATA) {
        Wait-Skip "Skipped"
        return
    }

    docker volume rm optics-agent_optics-data *> $null
    docker volume rm optics-build *> $null
    Say "Docker volumes removed."

    # Only paths read from .env, and only if absolute and not a drive root.
    $removedAny = $false
    foreach ($dir in @($DATA_DIR, $BUILD_DIR)) {
        if ([string]::IsNullOrWhiteSpace($dir)) { continue }

        if (-not (Test-SafeToRemove $dir)) {
            Warn "Refusing to remove an unsafe path: $dir"
            continue
        }

        if (Test-Path $dir) {
            Say "Removing $dir"
            Remove-Item -Path $dir -Recurse -Force -ErrorAction SilentlyContinue
            $removedAny = $true
        }
    }

    if (-not $DATA_DIR -and -not $BUILD_DIR) {
        Warn "Data directories are unknown (.env not found)."
        Say "Remove them manually if you know where they are."
        $script:DONE_DATA = "volumes only"
    }
    elseif ($removedAny) {
        $script:DONE_DATA = "removed"
    }
    else {
        $script:DONE_DATA = "volumes only"
    }

    Say "Agent data removed. This machine is no longer registered with OPTiCS Hub."
}

function Invoke-RemoveInstallDir {
    Write-Step "Removing install directory"

    if (-not $PLAN_INSTALL_DIR) {
        Wait-Skip "Kept at $INSTALL_DIR"
        return
    }

    if (-not (Test-SafeToRemove $INSTALL_DIR)) {
        Warn "Refusing to remove an unsafe path: $INSTALL_DIR"
        return
    }

    Remove-Item -Path $INSTALL_DIR -Recurse -Force -ErrorAction SilentlyContinue
    $script:DONE_INSTALL_DIR = "removed"
    Say "Install directory removed."
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

Write-Host ""
Write-Host "OPTiCS Agent Uninstaller v$UNINSTALLER_VERSION"
Say "Install dir: $INSTALL_DIR"
# Give the reader a moment; pointless when nobody is watching.
$WELCOME_PAUSE = if ($env:OPTICS_WELCOME_PAUSE) { [double]$env:OPTICS_WELCOME_PAUSE } else { 2 }
if ((Test-Interactive) -and $WELCOME_PAUSE -gt 0) {
    Start-Sleep -Seconds $WELCOME_PAUSE
}

$COMPOSE_OK = Test-ComposePresent

# Read-only discovery: what exists determines what can be asked about.
Find-Containers
Find-Images
Find-DataDirs

Ask-Containers
Ask-Images
Ask-Data

Confirm-Plan
# Asked after the review: losing the compose file loses the means to undo anything, so it
# is decided last, once everything else is settled.
Write-Host ""
Ask-InstallDir

Start-Countdown

Invoke-RemoveContainers
Invoke-RemoveImages
Invoke-RemoveData
Invoke-RemoveInstallDir

Write-Host ""
Write-Host ""
Write-Host "Done."
Write-Host ""

# Gather what went and what stayed in one place; the operation is irreversible, so nobody
# should have to go hunting afterwards for what happened to their data.
Write-Host "    Containers   $DONE_CONTAINERS"
Write-Host "    Images       $DONE_IMAGES"
Write-Host "    Agent data   $DONE_DATA"
Write-Host "    Install dir  $DONE_INSTALL_DIR"
Write-Host ""

if (-not $PLAN_DATA -and ($DATA_DIR -or $BUILD_DIR)) {
    Write-Host "    Agent data is still at:"
    if ($DATA_DIR) { Write-Host "      $DATA_DIR" }
    if ($BUILD_DIR) { Write-Host "      $BUILD_DIR" }
    Write-Host ""
}

if (-not $PLAN_INSTALL_DIR -and (Test-Path $INSTALL_DIR)) {
    Write-Host "    Reinstall or restart from: $INSTALL_DIR"
    Write-Host ""
}

exit 0
