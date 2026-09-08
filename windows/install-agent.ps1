# OPTiCS Agent Windows Installer
#
# Ask everything first, confirm, then act.
#   Phase 1  Ask      - collect settings only; the system is untouched.
#   Phase 2  Review   - show the collected values; any item can be revisited by number.
#   Phase 3  Execute  - real changes start here, Docker install included.
# Aborting at phase 2 leaves nothing changed.
#
# Unlike the Linux version there is no Web SSH step: standing up a host sshd does not
# port over to Windows. Hence 4 ask steps / 5 execute steps instead of 5 / 6.

$ErrorActionPreference = "Stop"

$INSTALLER_VERSION = "0.6.0"

$AGENT_REPO_BASE = "https://raw.githubusercontent.com/OPTiCS-Organization/OPTiCS-Agent"
# Resolved from the chosen version once it is known; see Resolve-RepoRef.
$AGENT_REPO_RAW = "$AGENT_REPO_BASE/main"
$INSTALL_DIR = if ($env:OPTICS_INSTALL_DIR) { $env:OPTICS_INSTALL_DIR } else { Join-Path $env:LOCALAPPDATA "OPTiCS\agent" }
# Kept separate from the install dir: that holds a couple of compose files, while build
# workspaces pile up here and can fill the drive.
$DATA_ROOT_DEFAULT = Join-Path $env:LOCALAPPDATA "OPTiCS\data"
$DATA_ROOT = if ($env:OPTICS_DATA_ROOT) { $env:OPTICS_DATA_ROOT } else { "" }

$composePath = Join-Path $INSTALL_DIR "docker-compose.yml"
$envPath = Join-Path $INSTALL_DIR ".env"

$AGENT_IMAGE = "ghcr.io/optics-organization/optics-agent"

# Phase 1 collects into these; nothing reads them until phase 3.
$PLAN_DATA_ROOT = ""
$PLAN_IMAGE_TAG = ""
$PLAN_AGENT_PORT = ""
$PLAN_DASHBOARD_PORT = ""
$PLAN_STOP_CONTAINERS = "no"
$PLAN_DOCKER = "present"
$PLAN_COMPOSE = "present"
$PLAN_COMPOSE_SUPPORTS_DATA_DIR = "no"
$COMPOSE_TMP = ""

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------
# Write-Output or a bare expression inside a value-returning function leaks into its
# return value, so everything user-visible goes through Write-Host.

# A per-line prefix eats width and buries the step structure; indent content instead.
function Say { param([string]$Message) Write-Host "  $Message" }
function Warn { param([string]$Message) Write-Host "  ! $Message" }
function Ask { param([string]$Prompt) Write-Host -NoNewline "  $Prompt" }

# PowerShell has no [ -t 0 ]: check host interactivity plus stdin/stdout redirection.
# On a console-less host the redirection probe itself can throw; assume nobody is there,
# since not blocking is always the safe side.
function Test-Interactive {
    try {
        if (-not [Environment]::UserInteractive) { return $false }
        if ([Console]::IsInputRedirected) { return $false }
        if ([Console]::IsOutputRedirected) { return $false }
        return $true
    }
    catch {
        return $false
    }
}

# With no one watching (pipe, CI) there is nobody to answer; fall through to defaults.
function Read-Answer {
    param([string]$Prompt)

    Ask $Prompt
    if (-not (Test-Interactive)) {
        Write-Host ""
        return ""
    }
    try {
        return [Console]::ReadLine()
    }
    catch {
        Write-Host ""
        return ""
    }
}

function Get-EnvNumber {
    param([string]$Name, [double]$Default)

    $raw = [Environment]::GetEnvironmentVariable($Name)
    if ([string]::IsNullOrWhiteSpace($raw)) { return $Default }
    $parsed = 0.0
    if ([double]::TryParse($raw, [ref]$parsed)) { return $parsed }
    return $Default
}

# Progress for phase 3 only. Script scope so the counter survives across calls.
$script:STEP_TOTAL = 5
$script:STEP_NUM = 0
function Step {
    param([string]$Title)

    $script:STEP_NUM = $script:STEP_NUM + 1
    Write-Host ""
    Write-Host "[$($script:STEP_NUM)/$($script:STEP_TOTAL)] $Title"
}

# Ask steps take a fixed number rather than incrementing: the review lets you jump back,
# and the number must match the review item so "changed 3" and "[3/4] Ports" agree.
$script:ASK_TOTAL = 4
function Ask-Step {
    param([int]$Number, [string]$Title)

    Write-Host ""
    Write-Host "[$Number/$($script:ASK_TOTAL)] $Title"
}

# Brief pause on a step with nothing to ask; otherwise the reason for skipping scrolls
# past between prompts.
function Pause-Skip {
    param([string]$Message)

    Say $Message
    if (Test-Interactive) {
        Start-Sleep -Seconds (Get-EnvNumber "OPTICS_SKIP_PAUSE" 1.5)
    }
}

# Last grace period before real changes; Ctrl+C here still leaves nothing modified.
function Start-Countdown {
    $from = [int](Get-EnvNumber "OPTICS_COUNTDOWN" 3)
    if ($from -le 0) { return }
    if (-not (Test-Interactive)) { return }

    Write-Host ""
    Write-Host -NoNewline "  Installation starts in "
    for ($i = $from; $i -gt 0; $i--) {
        Write-Host -NoNewline "$i"
        # One dot at a time so the seconds are visibly passing.
        for ($dot = 0; $dot -lt 5; $dot++) {
            Start-Sleep -Milliseconds 200
            Write-Host -NoNewline "."
        }
    }
    Write-Host ""
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function Get-FreeSpaceText {
    param([string]$Path)

    # Walk up to the nearest existing parent; only the drive letter matters.
    $probe = $Path
    while ($probe -and -not (Test-Path $probe)) {
        $parent = Split-Path $probe -Parent
        if (-not $parent -or $parent -eq $probe) { break }
        $probe = $parent
    }

    try {
        $qualifier = Split-Path -Qualifier (Resolve-Path $probe -ErrorAction Stop).Path
        $drive = Get-PSDrive -Name $qualifier.TrimEnd(':') -ErrorAction Stop
        $freeGB = [math]::Round($drive.Free / 1GB, 1)
        return "$freeGB GB free on $qualifier"
    }
    catch {
        return "free space unknown"
    }
}

# Create the data root and prove it is writable. Catching a disconnected network drive or
# a missing drive letter here lets the installer re-ask instead of compose failing later
# with an opaque error.
function Test-DataRoot {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        Warn "Enter a path."
        return $false
    }

    if (-not [System.IO.Path]::IsPathRooted($Path)) {
        Warn "Must be an absolute path: $Path"
        return $false
    }

    try {
        New-Item -ItemType Directory -Path (Join-Path $Path "agent") -Force -ErrorAction Stop | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $Path "build") -Force -ErrorAction Stop | Out-Null
    }
    catch {
        Warn "Cannot create: $Path"
        Say "Check that the drive is connected and writable."
        return $false
    }

    try {
        $probe = Join-Path $Path ".optics-write-test"
        [System.IO.File]::WriteAllText($probe, "ok")
        Remove-Item $probe -Force
    }
    catch {
        Warn "Not writable: $Path"
        return $false
    }

    return $true
}

function Get-OpticsFile {
    param([string]$Url, [string]$Destination)

    try {
        Invoke-WebRequest -Uri $Url -OutFile $Destination -UseBasicParsing
        return $true
    }
    catch {
        Warn "Failed to download: $Url"
        Say $_.Exception.Message
        return $false
    }
}

# Quiet variant: a missing tag is an expected outcome during the probe, not an error
# worth showing before the fallback has been tried.
function Get-OpticsFileQuiet {
    param([string]$Url, [string]$Destination)

    try {
        Invoke-WebRequest -Uri $Url -OutFile $Destination -UseBasicParsing
        return $true
    }
    catch {
        return $false
    }
}

# The compose file must come from the same version as the image, or the two can drift.
#
# "latest" resolves to main, not to whatever tag latest currently points at: GHCR's
# latest and GitHub's releases are maintained by different mechanisms and may disagree,
# and there is no `latest` git ref to fetch from anyway (raw.githubusercontent 404s).
function Resolve-RepoRef {
    if ($script:PLAN_IMAGE_TAG -eq "latest") { return "main" }
    return $script:PLAN_IMAGE_TAG
}

# Download the compose for the chosen version into a temp file and see whether it
# supports a custom data directory. Runs during phase 1, so it must not touch
# INSTALL_DIR -- a temp file keeps the "abort changes nothing" contract.
function Invoke-ProbeComposeFile {
    $script:PLAN_COMPOSE_SUPPORTS_DATA_DIR = "no"

    if (-not $script:COMPOSE_TMP) {
        $script:COMPOSE_TMP = Join-Path ([System.IO.Path]::GetTempPath()) ([System.IO.Path]::GetRandomFileName())
    }

    $ref = Resolve-RepoRef
    $script:AGENT_REPO_RAW = "$AGENT_REPO_BASE/$ref"

    # A GHCR tag does not guarantee a matching git tag, so fall back to main rather
    # than failing the install.
    if (-not (Get-OpticsFileQuiet "$script:AGENT_REPO_RAW/docker-compose.yml" $script:COMPOSE_TMP)) {
        if ($ref -ne "main") {
            Warn "No compose file at tag $ref; using main instead."
            $script:AGENT_REPO_RAW = "$AGENT_REPO_BASE/main"
            if (-not (Get-OpticsFileQuiet "$script:AGENT_REPO_RAW/docker-compose.yml" $script:COMPOSE_TMP)) { return }
        }
        else { return }
    }

    # Ask the fetched file directly rather than comparing versions, so a backport to an
    # older release is picked up correctly.
    if (Select-String -Path $script:COMPOSE_TMP -Pattern 'OPTICS_HOST_DATA_DIR|OPTICS_HOST_BUILD_DIR' -Quiet) {
        $script:PLAN_COMPOSE_SUPPORTS_DATA_DIR = "yes"
    }
}

# Split on the first = only: values may contain =.
function Get-EnvValue {
    param([string]$Key)

    if (-not (Test-Path $envPath)) { return "" }
    $line = Get-Content $envPath | Where-Object { $_ -match "^$([regex]::Escape($Key))=" } | Select-Object -Last 1
    if (-not $line) { return "" }
    return ($line -split '=', 2)[1]
}

function Set-AgentEnv {
    param([string]$Key, [string]$Value)

    $lines = @()
    if (Test-Path $envPath) {
        $lines = @(Get-Content $envPath)
    }

    $replaced = $false
    $result = foreach ($line in $lines) {
        if ($line -match "^$([regex]::Escape($Key))=") {
            $replaced = $true
            "$Key=$Value"
        }
        else {
            $line
        }
    }

    if (-not $replaced) {
        $result = @($result) + "$Key=$Value"
    }

    # compose reads .env byte for byte; a BOM corrupts the first key name.
    [System.IO.File]::WriteAllLines($envPath, [string[]]@($result), (New-Object System.Text.UTF8Encoding $false))
}

function Remove-AgentEnv {
    param([string]$Key)

    if (-not (Test-Path $envPath)) { return }
    $lines = @(Get-Content $envPath) | Where-Object { $_ -notmatch "^$([regex]::Escape($Key))=" }
    [System.IO.File]::WriteAllLines($envPath, [string[]]@($lines), (New-Object System.Text.UTF8Encoding $false))
}

# Config is written in step 3 but pull happens in step 4, so a failed pull would leave
# .env pointing at an image that does not exist and even a manual docker compose up would
# fail. Revert per key, not the whole file, so settings this installer never touched
# (the Hub address, say) are not dragged back to the step-3 state.
# The bare OPTICS_DATA_DIR/OPTICS_BUILD_DIR are the pre-0.6.0 names, kept here so an
# upgrade that removes them can still put them back if the pull fails.
$ENV_BACKUP_KEYS = @("OPTICS_HOST_DATA_DIR", "OPTICS_HOST_BUILD_DIR", "OPTICS_DATA_DIR", "OPTICS_BUILD_DIR", "AGENT_PORT", "DASHBOARD_PORT", "AGENT_IMAGE_TAG", "DASHBOARD_IMAGE_TAG")
$script:ENV_BACKUP = $null

function Backup-Env {
    if (-not (Test-Path $envPath)) { return }

    $snapshot = @{}
    foreach ($key in $ENV_BACKUP_KEYS) {
        $line = Get-Content $envPath | Where-Object { $_ -match "^$([regex]::Escape($key))=" } | Select-Object -Last 1
        # $null marks a key that was absent and must be deleted on restore.
        if ($line) {
            $snapshot[$key] = ($line -split '=', 2)[1]
        }
        else {
            $snapshot[$key] = $null
        }
    }
    $script:ENV_BACKUP = $snapshot
}

function Restore-Env {
    if ($null -eq $script:ENV_BACKUP) { return }
    if (-not (Test-Path $envPath)) { return }

    foreach ($key in $ENV_BACKUP_KEYS) {
        $value = $script:ENV_BACKUP[$key]
        if ($null -eq $value) {
            Remove-AgentEnv $key
        }
        else {
            Set-AgentEnv $key $value
        }
    }

    Say "Reverted .env to the previous settings."
}

# ---------------------------------------------------------------------------
# Docker
# ---------------------------------------------------------------------------

function Test-DockerPresent {
    return $null -ne (Get-Command docker -ErrorAction SilentlyContinue)
}

function Test-ComposePresent {
    if (-not (Test-DockerPresent)) { return $false }
    docker compose version *> $null
    return ($LASTEXITCODE -eq 0)
}

function Wait-DockerDaemon {
    param([int]$MaxWaitSeconds = 60)

    $elapsed = 0
    while ($elapsed -lt $MaxWaitSeconds) {
        # Judge by exit code: docker's wording changes between releases, so matching
        # its message breaks.
        docker ps *> $null
        if ($LASTEXITCODE -eq 0) { return $true }
        Start-Sleep -Seconds 1
        $elapsed += 1
    }
    return $false
}

# Execute phase only: the ask phase works fine without Docker, so nothing is installed
# before the user has confirmed.
function Install-DockerDesktop {
    Say "Installing Docker Desktop with winget..."
    winget install --id Docker.DockerDesktop --accept-package-agreements --accept-source-agreements
    if ($LASTEXITCODE -ne 0) {
        Warn "Docker Desktop installation failed. Install it manually and retry."
        exit 1
    }

    # Docker Desktop enables WSL2 and virtualization, so the daemon cannot start before a
    # reboot. Continuing would fail at pull; stop and have the user rerun.
    Write-Host ""
    Say "Docker Desktop was installed."
    Say "REBOOT YOUR SYSTEM to apply the changes,"
    Say "then run this script again to continue the installation."
    exit 0
}

function Initialize-Docker {
    if (-not (Test-DockerPresent)) {
        Install-DockerDesktop
    }

    $dockerVersion = (docker --version) 2>$null
    if ($dockerVersion) {
        Say ($dockerVersion -replace '^Docker version ', '')
    }

    # A sleeping daemon fails both pull and ps; wake Desktop and wait.
    docker ps *> $null
    if ($LASTEXITCODE -ne 0) {
        Say "Starting Docker Desktop..."
        # Docker Desktop is not on PATH; launch the exe by full path.
        $desktopExe = Join-Path $env:ProgramFiles "Docker\Docker\Docker Desktop.exe"
        if (Test-Path $desktopExe) {
            Start-Process $desktopExe -ErrorAction SilentlyContinue
        }
        if (-not (Wait-DockerDaemon 120)) {
            Warn "Docker daemon did not become ready."
            Say "Start Docker Desktop manually, then run this script again."
            exit 1
        }
    }

    # On Windows the Compose plugin ships with Docker Desktop; if it is missing, Desktop
    # is too old and the user must update it.
    docker compose version *> $null
    if ($LASTEXITCODE -ne 0) {
        Warn "Docker Compose plugin is not available."
        Say "Update Docker Desktop, then run this script again."
        exit 1
    }
}

# ---------------------------------------------------------------------------
# Version list
# ---------------------------------------------------------------------------
# A GHCR lookup is two round trips (token, then tags) and takes about 2s. It is timed out
# because falling back to latest beats stalling forever on an unresponsive network.

function Get-ImageTags {
    $timeout = [int](Get-EnvNumber "OPTICS_GHCR_TIMEOUT" 8)

    try {
        $tokenResponse = Invoke-RestMethod -Method Get -TimeoutSec $timeout -UseBasicParsing `
            -Uri "https://ghcr.io/token?scope=repository:optics-organization/optics-agent:pull&service=ghcr.io"
        $token = $tokenResponse.token
        if (-not $token) { return @() }

        $tagsResponse = Invoke-RestMethod -Method Get -TimeoutSec $timeout -UseBasicParsing `
            -Headers @{ Authorization = "Bearer $token" } `
            -Uri "https://ghcr.io/v2/optics-organization/optics-agent/tags/list"

        # Numeric tags only; latest and sha- are not selectable as versions.
        $numeric = @($tagsResponse.tags | Where-Object { $_ -match '^[0-9][0-9.]*$' })
        if ($numeric.Count -eq 0) { return @() }

        # String sort puts 0.10 before 0.9; compare as versions.
        return @($numeric | Sort-Object -Property { ConvertTo-VersionKey $_ } -Descending)
    }
    catch {
        return @()
    }
}

# Compare as [version]; single-component or malformed tags fall back to 0.0 so the sort
# stays stable.
function ConvertTo-VersionKey {
    param([string]$Tag)

    $parsed = $null
    $normalized = $Tag
    if (($normalized -split '\.').Count -lt 2) { $normalized = "$normalized.0" }
    if ([version]::TryParse($normalized, [ref]$parsed)) { return $parsed }
    return [version]"0.0"
}

# Prefetch the tag list while the data directory question is on screen, so the network
# wait overlaps user typing and the list is ready by the version step.
$script:TAGS_CACHE = $null
$script:TAGS_JOB = $null

function Start-TagPrefetch {
    try {
        $script:TAGS_JOB = Start-Job -ScriptBlock {
            param($timeout)
            try {
                $tokenResponse = Invoke-RestMethod -Method Get -TimeoutSec $timeout -UseBasicParsing `
                    -Uri "https://ghcr.io/token?scope=repository:optics-organization/optics-agent:pull&service=ghcr.io"
                $token = $tokenResponse.token
                if (-not $token) { return @() }
                $tagsResponse = Invoke-RestMethod -Method Get -TimeoutSec $timeout -UseBasicParsing `
                    -Headers @{ Authorization = "Bearer $token" } `
                    -Uri "https://ghcr.io/v2/optics-organization/optics-agent/tags/list"
                return @($tagsResponse.tags | Where-Object { $_ -match '^[0-9][0-9.]*$' })
            }
            catch {
                return @()
            }
        } -ArgumentList ([int](Get-EnvNumber "OPTICS_GHCR_TIMEOUT" 8))
    }
    catch {
        # Some hosts cannot start background jobs; fetch synchronously when needed.
        $script:TAGS_JOB = $null
    }
}

# Use the prefetched result; wait if still running, fetch now if it never started.
function Get-CachedImageTags {
    if ($null -ne $script:TAGS_CACHE) { return $script:TAGS_CACHE }

    if ($null -ne $script:TAGS_JOB) {
        try {
            $timeout = [int](Get-EnvNumber "OPTICS_GHCR_TIMEOUT" 8)
            $finished = Wait-Job -Job $script:TAGS_JOB -Timeout ($timeout + 4)
            $raw = @()
            if ($finished) { $raw = @(Receive-Job -Job $script:TAGS_JOB -ErrorAction SilentlyContinue) }
            Remove-Job -Job $script:TAGS_JOB -Force -ErrorAction SilentlyContinue
            $script:TAGS_JOB = $null
            if ($raw.Count -gt 0) {
                $script:TAGS_CACHE = @($raw | Sort-Object -Property { ConvertTo-VersionKey $_ } -Descending)
                return $script:TAGS_CACHE
            }
        }
        catch {
            $script:TAGS_JOB = $null
        }
    }

    $script:TAGS_CACHE = @(Get-ImageTags)
    return $script:TAGS_CACHE
}

function Get-InstalledAgentVersion {
    # No tag in .env means nothing was installed into this directory; a stray image left
    # on the host must not count as installed.
    $tag = Get-EnvValue "AGENT_IMAGE_TAG"
    if ([string]::IsNullOrWhiteSpace($tag)) { return "" }
    if (-not (Test-DockerPresent)) { return "" }

    $version = docker image inspect "${AGENT_IMAGE}:$tag" --format '{{index .Config.Labels "org.opencontainers.image.version"}}' 2>$null
    if ($LASTEXITCODE -ne 0) { $version = "" }
    if ($version) { $version = ([string]$version).Trim() }

    # Older images carry no label, so the tag itself is often the version. latest is not a
    # version, so treat it as unknown.
    if ([string]::IsNullOrWhiteSpace($version) -or $version -eq "<no value>") {
        if ($tag -eq "latest") { return "" }
        return $tag
    }
    return $version
}

function Test-Downgrade {
    param([string]$Target, [string]$Current)

    if ([string]::IsNullOrWhiteSpace($Target) -or [string]::IsNullOrWhiteSpace($Current)) { return $false }
    if ($Target -eq $Current) { return $false }
    if ($Target -eq "latest" -or $Current -eq "latest") { return $false }

    return ((ConvertTo-VersionKey $Target) -lt (ConvertTo-VersionKey $Current))
}

# ---------------------------------------------------------------------------
# Ports
# ---------------------------------------------------------------------------

function Test-PortInUse {
    param([int]$Port)

    # Test-NetConnection actually dials, which is slow and misreports behind a firewall.
    # Only whether this machine listens on the port matters.
    try {
        $listeners = Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue
        return $null -ne $listeners
    }
    catch {
        # No way to check: assume free. A real collision surfaces from compose.
        return $false
    }
}

# On reinstall the old container is torn down shortly after, so treating this install's
# own container as an occupant and asking for a different port would be wrong.
function Test-PortOwnedByAgent {
    param([int]$Port)

    if (-not (Test-Path $composePath)) { return $false }
    if (-not (Test-DockerPresent)) { return $false }

    Push-Location $INSTALL_DIR
    try {
        $ids = docker compose ps -q 2>$null
        if ($LASTEXITCODE -ne 0) { return $false }
        if (-not $ids) { return $false }

        foreach ($id in $ids) {
            if ([string]::IsNullOrWhiteSpace($id)) { continue }
            # Single-quote the pattern: inside double quotes $| and $) are read as
            # variables and break it.
            $pattern = '(^|:)' + [regex]::Escape($Port) + '(\s|$|->)'
            $published = docker port $id 2>$null
            if ($published -match $pattern) { return $true }
        }
    }
    catch {
        return $false
    }
    finally {
        Pop-Location
    }

    return $false
}

# Free, or already held by this install, is fine either way.
function Test-PortAvailable {
    param([int]$Port)

    if (-not (Test-PortInUse $Port)) { return $true }
    return (Test-PortOwnedByAgent $Port)
}

# stdout is the return value here, so all prompting goes through Write-Host.
function Read-AgentPort {
    param([string]$Label, [int]$Default, [string]$Preset)

    # Default to the port already in .env so an update does not reset a chosen port back
    # to 5230/5240.
    $port = $Default
    if ($Preset) {
        $parsedPreset = 0
        if ([int]::TryParse($Preset.Trim(), [ref]$parsedPreset) -and $parsedPreset -ge 1 -and $parsedPreset -le 65535) {
            $port = $parsedPreset
        }
    }

    while ($true) {
        $answer = Read-Answer "Port for $Label [$port]: "
        $candidate = $answer -replace '\s', ''
        if ([string]::IsNullOrEmpty($candidate)) { $candidate = "$port" }

        # Non-numeric or out of range would only fail once compose starts; reject here.
        $parsed = 0
        if (-not [int]::TryParse($candidate, [ref]$parsed) -or $parsed -lt 1 -or $parsed -gt 65535) {
            Warn "Enter a number between 1 and 65535."
            continue
        }

        if (-not (Test-PortAvailable $parsed)) {
            Warn "Port $parsed is in use."
            $port = $parsed
            continue
        }

        return $parsed
    }
}

# ---------------------------------------------------------------------------
# Phase 1: ask
# ---------------------------------------------------------------------------
# Functions here only decide values: no files written, no containers touched. The lone
# exception is creating the data directory, the only way to prove it is writable, and a
# leftover empty directory is harmless.

function Invoke-AskDataRoot {
    if ($DATA_ROOT) {
        Ask-Step 1 "Data directory"
        Pause-Skip "From OPTICS_DATA_ROOT: $DATA_ROOT"
        if (Test-DataRoot $DATA_ROOT) {
            $script:PLAN_DATA_ROOT = $DATA_ROOT
            return
        }
        Say "OPTICS_DATA_ROOT is unusable. Aborting..."
        exit 1
    }

    # Default to the value already in .env so an update does not re-ask for the drive.
    # Falls back to the pre-0.6.0 key so upgrading does not silently reset the drive.
    $default = $DATA_ROOT_DEFAULT
    $existing = Get-EnvValue "OPTICS_HOST_DATA_DIR"
    if (-not $existing) { $existing = Get-EnvValue "OPTICS_DATA_DIR" }
    if ($existing) {
        $parent = Split-Path ($existing -replace '/', '\') -Parent
        if ($parent) { $default = $parent }
    }

    Ask-Step 1 "Data directory"
    Say "Build workspace and local database live here, and this grows over time."
    Say "Default: $default ($(Get-FreeSpaceText $default))"

    while ($true) {
        $answer = Read-Answer "Data directory [$default]: "
        $candidate = if ([string]::IsNullOrWhiteSpace($answer)) { $default } else { $answer.Trim().Trim('"') }

        if (Test-DataRoot $candidate) {
            $script:PLAN_DATA_ROOT = $candidate
            return
        }
        Say "Please enter a different path."
    }
}

# Wraps the question so every path that settles on a version re-probes the compose,
# including the review's "change item 2" loop.
function Invoke-AskImageTag {
    Invoke-ChooseImageTag
    Invoke-ProbeComposeFile
}

function Invoke-ChooseImageTag {
    if ($env:OPTICS_AGENT_TAG) {
        Ask-Step 2 "Agent version"
        Pause-Skip "From OPTICS_AGENT_TAG: $($env:OPTICS_AGENT_TAG)"
        $script:PLAN_IMAGE_TAG = $env:OPTICS_AGENT_TAG
        return
    }

    $tags = @(Get-CachedImageTags)

    if ($tags.Count -eq 0) {
        # A failed lookup must not block the install; latest still works.
        Ask-Step 2 "Agent version"
        Pause-Skip "Could not fetch the version list. Using latest."
        $script:PLAN_IMAGE_TAG = "latest"
        return
    }

    $current = Get-InstalledAgentVersion

    Ask-Step 2 "Agent version"
    Say "Available Agent versions:"
    Write-Host "    latest (recommended)"
    # Mark the running version so an unintended downgrade is less likely.
    foreach ($tag in ($tags | Select-Object -First 8)) {
        if ($current -and $tag -eq $current) {
            Write-Host "    $tag  <- currently installed"
        }
        else {
            Write-Host "    $tag"
        }
    }

    while ($true) {
        $answer = Read-Answer "Agent version to install [latest]: "
        $choice = $answer -replace '\s', ''
        if ([string]::IsNullOrEmpty($choice)) { $choice = "latest" }

        if ($choice -eq "latest") {
            $script:PLAN_IMAGE_TAG = "latest"
            return
        }

        # An unlisted tag would only fail at pull; re-ask instead.
        if ($tags -notcontains $choice) {
            Say "Unknown version: $choice"
            continue
        }

        # A downgrade can leave the Agent unable to start against a newer DB schema, and
        # it is hard to undo; confirm once.
        if (Test-Downgrade $choice $current) {
            Write-Host ""
            Warn "$choice is older than the installed $current."
            Say "The local database was migrated by the newer version;"
            Say "the Agent may fail to start."
            $confirm = Read-Answer "Install $choice anyway? (y/N): "
            if ($confirm -notin @('Y', 'y')) { continue }
        }

        $script:PLAN_IMAGE_TAG = $choice
        return
    }
}

function Invoke-AskPorts {
    Ask-Step 3 "Ports"

    $script:PLAN_AGENT_PORT = Read-AgentPort "optics-agent" 5230 (Get-EnvValue "AGENT_PORT")
    $script:PLAN_DASHBOARD_PORT = Read-AgentPort "optics-agent-dashboard" 5240 (Get-EnvValue "DASHBOARD_PORT")
}

# Docker cannot be skipped: the Agent runs as a container, so this is a prerequisite,
# not a choice, and the prompt says so rather than pretending otherwise.
function Invoke-AskDocker {
    if ($PLAN_DOCKER -eq "present" -and $PLAN_COMPOSE -eq "present") {
        Ask-Step 4 "Install Docker"
        Pause-Skip "Docker and Compose are already installed"
        return
    }

    Ask-Step 4 "Install Docker"
    Say "Required: the Agent runs as a container."
    if ($PLAN_DOCKER -eq "install") {
        Say "Docker Desktop will be installed with winget."
        # The forced reboot is Windows-specific; warn up front.
        Say "The system must reboot before the installation can continue."
    }
    elseif ($PLAN_COMPOSE -eq "install") {
        Say "The Compose plugin comes with Docker Desktop; update it if missing."
    }
    Say "To use your own setup, abort and install Docker first."
}

# Detect only; the actual install happens in the execute phase after confirmation.
function Get-DockerState {
    if (Test-DockerPresent) { $script:PLAN_DOCKER = "present" } else { $script:PLAN_DOCKER = "install" }
    if (Test-ComposePresent) { $script:PLAN_COMPOSE = "present" } else { $script:PLAN_COMPOSE = "install" }
}

# Needed so the review can say what will be stopped.
function Get-RunningContainers {
    $script:PLAN_STOP_CONTAINERS = "no"
    if (-not (Test-DockerPresent)) { return }
    if (-not (Test-Path $composePath)) { return }

    Push-Location $INSTALL_DIR
    try {
        $ids = docker compose ps -q 2>$null
        if ($LASTEXITCODE -eq 0 -and $ids) { $script:PLAN_STOP_CONTAINERS = "yes" }
    }
    catch {
        $script:PLAN_STOP_CONTAINERS = "no"
    }
    finally {
        Pop-Location
    }
}

# ---------------------------------------------------------------------------
# Phase 2: review
# ---------------------------------------------------------------------------

function Show-Review {
    $versionLine = $PLAN_IMAGE_TAG
    $current = Get-InstalledAgentVersion
    # Append the current version only when it differs; otherwise it reads twice.
    if ($current -and $current -ne $PLAN_IMAGE_TAG) {
        $versionLine = "$PLAN_IMAGE_TAG  (currently $current)"
    }

    # Docker and Compose collapse into one line: to the user it is one question, and the
    # fix is the same whichever is missing.
    $dockerLine = "already installed"
    if ($PLAN_DOCKER -eq "install") {
        $dockerLine = "will install Docker Desktop (reboot required)"
    }
    elseif ($PLAN_COMPOSE -eq "install") {
        $dockerLine = "will need a Docker Desktop update"
    }

    # Older versions ship a compose without bind-mounted volumes, so the chosen
    # directory would be ignored. Say so here rather than letting it fail silently.
    if ($PLAN_COMPOSE_SUPPORTS_DATA_DIR -eq "yes") {
        $dataLine = "$PLAN_DATA_ROOT  ($(Get-FreeSpaceText $PLAN_DATA_ROOT))"
    }
    else {
        $dataLine = "not used by $PLAN_IMAGE_TAG  (data goes to Docker's default location)"
        $versionLine = "$versionLine  - no custom data directory"
    }

    Write-Host ""
    Write-Host "Review"
    Write-Host ""
    Write-Host "    1  Data directory   $dataLine"
    Write-Host "    2  Agent version    $versionLine"
    Write-Host "    3  Ports            agent $PLAN_AGENT_PORT, dashboard $PLAN_DASHBOARD_PORT"
    Write-Host "    4  Docker           $dockerLine"
    Write-Host ""
    Write-Host "    Install dir        $INSTALL_DIR"

    if ($PLAN_COMPOSE_SUPPORTS_DATA_DIR -ne "yes") {
        Write-Host "    Version $PLAN_IMAGE_TAG has no custom data directory support."
        # Suggesting "pick latest" is useless when latest is already the choice -- that
        # means no released version supports it yet.
        if ($PLAN_IMAGE_TAG -eq "latest") {
            Write-Host "      No released version supports it yet; $PLAN_DATA_ROOT stays unused."
        }
        else {
            Write-Host "      Choose 2 and pick latest to use $PLAN_DATA_ROOT"
        }
    }
    if ($PLAN_STOP_CONTAINERS -eq "yes") {
        Write-Host "    Running containers will restart after images are pulled"
    }
    Write-Host ""
}

# Show the review and let the user confirm or revisit an item. Answering no exits with
# nothing changed.
function Confirm-Plan {
    while ($true) {
        Show-Review
        $answer = Read-Answer "Proceed? (Y/n, or a number to change): "
        $answer = $answer -replace '\s', ''

        # switch is case-insensitive by default, so separate "Y" and "y" branches would
        # both match and run twice; keep one branch.
        switch ($answer) {
            "" { return }
            "y" { return }
            "n" { Say "Nothing was changed."; exit 0 }
            "1" { Invoke-AskDataRoot }
            "2" { Invoke-AskImageTag }
            "3" { Invoke-AskPorts }
            "4" { Invoke-AskDocker }
            default { Warn "Enter Y, n, or 1-4." }
        }
    }
}

# ---------------------------------------------------------------------------
# Phase 3: execute
# ---------------------------------------------------------------------------

function Invoke-Plan {
    if ($PLAN_DOCKER -eq "install" -or $PLAN_COMPOSE -eq "install") {
        Step "Installing Docker"
    }
    else {
        Step "Checking Docker"
    }
    Initialize-Docker

    Step "Preparing install files"
    New-Item -ItemType Directory -Path $INSTALL_DIR -Force | Out-Null

    # Already downloaded during phase 1 to probe it; reuse rather than fetching twice.
    if ($COMPOSE_TMP -and (Test-Path $COMPOSE_TMP)) {
        Copy-Item $COMPOSE_TMP $composePath -Force
        Say "Compose definition ready"
    }
    else {
        Say "Downloading compose definition..."
        if (-not (Get-OpticsFile "$AGENT_REPO_RAW/docker-compose.yml" $composePath)) { exit 1 }
    }

    # .env holds secrets and user settings; never overwrite an existing one, or a
    # reinstall would wipe things like the Hub address.
    if (Test-Path $envPath) {
        Say "Keeping existing .env"
    }
    else {
        if (-not (Get-OpticsFile "$AGENT_REPO_RAW/.env.example" $envPath)) { exit 1 }
        Say "Created .env from .env.example"
    }

    Step "Writing configuration"
    # .env changes start here; a failed pull rewinds to this point.
    Backup-Env
    # Docker Desktop accepts backslash bind paths, but forward slashes keep .env readable
    # by other tools that parse it directly.
    if ($PLAN_COMPOSE_SUPPORTS_DATA_DIR -eq "yes") {
        Set-AgentEnv "OPTICS_HOST_DATA_DIR" ((Join-Path $PLAN_DATA_ROOT "agent") -replace '\\', '/')
        Set-AgentEnv "OPTICS_HOST_BUILD_DIR" ((Join-Path $PLAN_DATA_ROOT "build") -replace '\\', '/')
    }
    else {
        # This compose ignores the paths, but the uninstaller would still read them and
        # offer to remove directories the Agent never used. Remove them instead.
        Remove-AgentEnv "OPTICS_HOST_DATA_DIR"
        Remove-AgentEnv "OPTICS_HOST_BUILD_DIR"
        Say "Data directory not applied ($PLAN_IMAGE_TAG does not support it)"
    }

    # Drop the pre-0.6.0 names. env_file hands every key to the container, and the Agent
    # reads OPTICS_BUILD_DIR as its build root -- leaving a host path there makes cleanup
    # target a path that does not exist inside the container, breaking the next deploy.
    Remove-AgentEnv "OPTICS_DATA_DIR"
    Remove-AgentEnv "OPTICS_BUILD_DIR"
    Set-AgentEnv "AGENT_PORT" $PLAN_AGENT_PORT
    Set-AgentEnv "DASHBOARD_PORT" $PLAN_DASHBOARD_PORT

    # The chosen version applies to the Agent only. Dashboard versions run on their own
    # scheme (to be merged into the Agent later), so reusing the tag would pull one that
    # does not exist. Always latest.
    Set-AgentEnv "DASHBOARD_IMAGE_TAG" "latest"
    # A previously pinned value would keep winning even when latest is chosen.
    Set-AgentEnv "AGENT_IMAGE_TAG" $PLAN_IMAGE_TAG
    Say "Saved to $envPath"

    # Docker's own storage lives in a WSL2 disk image managed by Docker Desktop. Moving it
    # from a script can lose every existing image, so leave it alone.

    Set-Location $INSTALL_DIR

    Step "Pulling images"
    # Pull before tearing anything down: it is slow and can fail (network, missing tag).
    # Doing it first narrows downtime to the container swap, and a failure leaves the
    # running service untouched.
    Say "From GHCR (tag: $PLAN_IMAGE_TAG)"
    docker compose pull
    if ($LASTEXITCODE -ne 0) {
        Warn "Pull failed. Check the network or the version and retry."
        Restore-Env
        Say "The running Agent was left untouched."
        exit 1
    }

    Step "Starting containers"
    # Down only after the images are local; this to up is the actual downtime.
    $running = docker compose ps -q 2>$null
    if ($LASTEXITCODE -eq 0 -and $running) {
        Say "Stopping current containers..."
        docker compose down
    }

    docker compose up -d
    if ($LASTEXITCODE -ne 0) {
        Warn "Failed to start. Check logs:"
        Write-Host "    cd $INSTALL_DIR; docker compose logs"
        exit 1
    }
}

# Read the real version off the running container: a latest install says nothing about
# which version that tag resolved to.
function Get-RunningVersion {
    param([string]$Name)

    $version = docker inspect $Name --format '{{index .Config.Labels "org.opencontainers.image.version"}}' 2>$null
    if ($LASTEXITCODE -ne 0) { return "" }
    if (-not $version) { return "" }
    $version = ([string]$version).Trim()
    if ($version -eq "<no value>") { return "" }
    return $version
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

# PowerShell has no trap EXIT; this fires on a normal end and on Ctrl+C, and a leftover
# temp file in %TEMP% is harmless if it does not.
$null = Register-EngineEvent PowerShell.Exiting -Action {
    if ($COMPOSE_TMP -and (Test-Path $COMPOSE_TMP)) { Remove-Item $COMPOSE_TMP -Force -ErrorAction SilentlyContinue }
}

Write-Host ""
Write-Host "OPTiCS Agent Installer v$INSTALLER_VERSION"
Say "Windows"
# Give the reader a moment; pointless when nobody is watching.
if (Test-Interactive) {
    Start-Sleep -Seconds (Get-EnvNumber "OPTICS_WELCOME_PAUSE" 2)
}

Get-DockerState

# The tag list is needed in step 2 but takes ~2s to fetch; starting it during step 1
# hides the wait behind user input.
Start-TagPrefetch

Invoke-AskDataRoot
Invoke-AskImageTag
Invoke-AskPorts
Invoke-AskDocker
Get-RunningContainers

Confirm-Plan
Start-Countdown
Invoke-Plan

Write-Host ""
Write-Host ""
Write-Host "Done."

$AGENT_VERSION = Get-RunningVersion "optics-agent-optics-agent-1"
$DASHBOARD_VERSION = Get-RunningVersion "optics-agent-optics-agent-dashboard-1"

$AGENT_LINE = if ($AGENT_VERSION) { $AGENT_VERSION } else { "unknown" }
# Show both when the pinned tag differs from the resolved version, as with latest.
if ($AGENT_VERSION -and $PLAN_IMAGE_TAG -ne $AGENT_VERSION) {
    $AGENT_LINE = "$AGENT_VERSION  (tag: $PLAN_IMAGE_TAG)"
}
$DASHBOARD_LINE = if ($DASHBOARD_VERSION) { $DASHBOARD_VERSION } else { "unknown" }

Write-Host ""
Write-Host "    Agent       : $AGENT_LINE"
Write-Host "    Dashboard   : $DASHBOARD_LINE"
Write-Host ""
Write-Host "    Console     : http://localhost:$PLAN_DASHBOARD_PORT/"
Write-Host "    Install dir : $INSTALL_DIR"
Write-Host "    Data dir    : $PLAN_DATA_ROOT"
Write-Host ""
# One cd instead of repeating the same long path three times.
Write-Host "    cd $INSTALL_DIR"
Write-Host "      update : docker compose pull; docker compose up -d"
Write-Host "      stop   : docker compose down"
Write-Host "      logs   : docker compose logs -f"
Write-Host ""

# No console (Task Scheduler, CI, redirection) means nobody to ask; the install is
# already done, so finish quietly.
if (Test-Interactive) {
    $answer = Read-Answer "Open a shell in the Agent container? (y/N): "
    if ($answer -in @('Y', 'y')) {
        $containerRunning = docker compose ps --status running | Select-String "optics-agent"
        if ($containerRunning) {
            docker compose exec optics-agent sh
        }
        else {
            Warn "Agent is not running. Check: docker compose logs optics-agent"
        }
    }
}

exit 0
