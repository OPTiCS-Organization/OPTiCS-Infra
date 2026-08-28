# OPTiCS Agent Windows Installer
#
# 0.6.0부터 Agent와 Dashboard는 소스를 빌드하지 않고 GHCR에 게시된 이미지를 받아 씁니다.
# 그래서 이 스크립트가 내려받는 것은 docker-compose.yml과 .env.example 두 개뿐이고,
# Git도 Node.js도 필요하지 않습니다.
#
# 설치 디렉터리는 지워지지 않고 남습니다. compose 파일이 곧 이 설치의 실체이므로,
# 지우면 이후에 컨테이너를 멈추거나 업데이트할 방법이 사라집니다.

$ErrorActionPreference = "Stop"

$INSTALLER_VERSION = "0.4.0"
Write-Host "Welcome to OPTiCS Windows Installer v$INSTALLER_VERSION"

$AGENT_REPO_RAW = "https://raw.githubusercontent.com/OPTiCS-Organization/OPTiCS-Agent/main"
$INSTALL_DIR = if ($env:OPTICS_INSTALL_DIR) { $env:OPTICS_INSTALL_DIR } else { Join-Path $env:LOCALAPPDATA "OPTiCS\agent" }

Start-Sleep 1
$installAgree = Read-Host "[OPTiCS Installer] Are you sure want to install OPTiCS Agent on your PC? (y/N)"
if (-not ($installAgree -in @('Y', 'y'))) {
    Write-Host "[OPTiCS Installer] Installation process Terminated"
    exit 1
}

Start-Sleep 1

# ---------------------------------------------------------------------------
# Docker
# ---------------------------------------------------------------------------

$needRestartFlag = 0

Write-Host "[OPTiCS Installer] Checking Docker version..."
if (Get-Command docker -ErrorAction SilentlyContinue) {
    $dockerVersion = docker --version
    Write-Host "[OPTiCS Installer] Detected Docker version: $dockerVersion"
}
else {
    Write-Host "[OPTiCS Installer] Docker not detected."
    $installDockerAgree = Read-Host "[OPTiCS Installer] Do you want to install docker? (y/N)"
    if (-not ($installDockerAgree -in @('Y', 'y'))) {
        Write-Host "[OPTiCS Installer] Installation process Terminated."
        exit 1
    }
    $needRestartFlag = 1
    winget install Docker.DockerDesktop
    Write-Host "[OPTiCS Installer] Docker installation finished."
}

if ($needRestartFlag) {
    Write-Host "Please REBOOT YOUR SYSTEM to apply changes.

TO CONTINUE INSTALL, re-run this script again AFTER REBOOT."
    exit 0
}

function Wait-DockerDaemon {
    param($maxWaitSeconds = 60)

    $elapsed = 0
    while ($elapsed -lt $maxWaitSeconds) {
        # docker ps는 데몬이 뜨기 전엔 0이 아닌 종료 코드로 끝난다.
        # 문자열 매칭은 도커 판올림마다 문구가 달라져 깨지므로 종료 코드로 판단한다.
        docker ps *> $null
        if ($LASTEXITCODE -eq 0) {
            Write-Host "[OPTiCS Installer] Docker daemon is ready."
            return $true
        }
        Start-Sleep 1
        $elapsed += 1
    }
    return $false
}

Write-Host "[OPTiCS Installer] Starting Docker Desktop..."
Write-Host "[OPTiCS Installer] Waiting for Docker daemon... (max 2 min)"
Start-Process "docker" -ErrorAction SilentlyContinue
Start-Sleep 5

if (-not (Wait-DockerDaemon 120)) {
    Write-Host "[OPTiCS Installer] Docker daemon failed to initialize."
    Write-Host "[OPTiCS Installer] Start Docker Desktop manually and run this script again."
    exit 1
}

Write-Host "[OPTiCS Installer] Checking Docker Compose version..."
docker compose version *> $null
if ($LASTEXITCODE -ne 0) {
    Write-Host "[OPTiCS Installer] Docker Compose plugin is not available."
    Write-Host "[OPTiCS Installer] Update Docker Desktop, then run this script again."
    exit 1
}
Write-Host "[OPTiCS Installer] docker compose (plugin) detected: $(docker compose version)"

Start-Sleep 1

# ---------------------------------------------------------------------------
# 설치 파일 준비
# ---------------------------------------------------------------------------

Write-Host "[OPTiCS Installer] Install directory: $INSTALL_DIR"
New-Item -ItemType Directory -Path $INSTALL_DIR -Force | Out-Null

$composePath = Join-Path $INSTALL_DIR "docker-compose.yml"
$envPath = Join-Path $INSTALL_DIR ".env"

# 기존 설치 위에 덮어쓰는 경우, 먼저 컨테이너를 멈춰야 이미지 교체가 안전하다.
if (Test-Path $composePath) {
    Write-Host "[OPTiCS Installer] Existing installation found. Checking for running containers..."
    Push-Location $INSTALL_DIR
    $running = docker compose ps -q
    if ($running) {
        Write-Host "[OPTiCS Installer] Stopping existing OPTiCS Agent containers..."
        docker compose down
    }
    Pop-Location
}

function Get-OpticsFile {
    param($Url, $Destination)

    try {
        Invoke-WebRequest -Uri $Url -OutFile $Destination -UseBasicParsing
        return $true
    }
    catch {
        Write-Host "[OPTiCS Installer] Failed to download: $Url"
        Write-Host "[OPTiCS Installer] $($_.Exception.Message)"
        return $false
    }
}

Write-Host "[OPTiCS Installer] Downloading compose definition..."
if (-not (Get-OpticsFile "$AGENT_REPO_RAW/docker-compose.yml" $composePath)) { exit 1 }

# .env는 비밀값과 사용자 설정을 담으므로 이미 있으면 덮어쓰지 않는다.
# 재설치할 때마다 초기화되면 Hub 주소 같은 설정이 매번 날아간다.
if (Test-Path $envPath) {
    Write-Host "[OPTiCS Installer] Existing .env found. Keeping it."
}
else {
    Write-Host "[OPTiCS Installer] Downloading .env.example..."
    if (-not (Get-OpticsFile "$AGENT_REPO_RAW/.env.example" $envPath)) { exit 1 }
    Write-Host "[OPTiCS Installer] Created .env from .env.example."
}

Start-Sleep 1

# ---------------------------------------------------------------------------
# 포트
# ---------------------------------------------------------------------------

function Test-PortInUse {
    param($Port)

    # Test-NetConnection은 연결을 시도하느라 느리고, 방화벽에 걸리면 오탐한다.
    # 실제로 이 PC가 그 포트를 듣고 있는지만 보면 된다.
    $listeners = Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue
    return $null -ne $listeners
}

function Read-Port {
    param($Label, $Default)

    $port = $Default
    while (Test-PortInUse $port) {
        Write-Host "[OPTiCS Installer] Port $port is already in use ($Label)."
        do {
            $answer = Read-Host "[OPTiCS Installer] Enter a different port for $Label"
            $parsed = 0
            if ([int]::TryParse($answer, [ref]$parsed) -and $parsed -ge 1 -and $parsed -le 65535) {
                $port = $parsed
                break
            }
            Write-Host "[OPTiCS Installer] Invalid port. Please enter a number between 1 and 65535."
        } while ($true)
    }
    return $port
}

Write-Host "[OPTiCS Installer] Checking ports..."
$AGENT_PORT = Read-Port "optics-agent" 5230
$DASHBOARD_PORT = Read-Port "optics-agent-dashboard" 5240
Write-Host "[OPTiCS Installer] Using ports: agent=$AGENT_PORT, dashboard=$DASHBOARD_PORT"

function Set-AgentEnv {
    param($Key, $Value)

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

    # compose는 .env를 바이트 그대로 읽는다. BOM이 붙으면 첫 줄의 키 이름이 깨진다.
    [System.IO.File]::WriteAllLines($envPath, [string[]]@($result), (New-Object System.Text.UTF8Encoding $false))
}

# 포트를 .env에 적어 둔다. compose가 프로젝트 디렉터리의 .env를 자동으로 읽으므로,
# 나중에 사용자가 그냥 `docker compose up -d`만 해도 같은 설정으로 뜬다.
Set-AgentEnv "AGENT_PORT" $AGENT_PORT
Set-AgentEnv "DASHBOARD_PORT" $DASHBOARD_PORT

# ---------------------------------------------------------------------------
# 이미지 수신 및 기동
# ---------------------------------------------------------------------------

Set-Location $INSTALL_DIR

# AGENT_IMAGE_TAG를 지정하지 않으면 compose가 latest를 쓴다.
# latest는 릴리스 워크플로가 정식 릴리스(prerelease 아님)에만 붙이므로 최신 안정판을 가리킨다.
$IMAGE_TAG = if ($env:OPTICS_AGENT_TAG) { $env:OPTICS_AGENT_TAG } else { "latest" }
if ($IMAGE_TAG -ne "latest") {
    Set-AgentEnv "AGENT_IMAGE_TAG" $IMAGE_TAG
    Set-AgentEnv "DASHBOARD_IMAGE_TAG" $IMAGE_TAG
    Write-Host "[OPTiCS Installer] Pinned image tag: $IMAGE_TAG"
}

Write-Host "[OPTiCS Installer] Pulling images from GHCR (tag: $IMAGE_TAG)..."
docker compose pull
if ($LASTEXITCODE -ne 0) {
    Write-Host "[OPTiCS Installer] Failed to pull images from GHCR."
    Write-Host "[OPTiCS Installer] Check your network connection and try again."
    exit 1
}

Write-Host "[OPTiCS Installer] Starting containers..."
docker compose up -d
if ($LASTEXITCODE -ne 0) {
    Write-Host "[OPTiCS Installer] Failed to start containers. Check logs with:"
    Write-Host "    cd $INSTALL_DIR; docker compose logs"
    exit 1
}

Write-Host "[OPTiCS Installer] OPTiCS Agent installment finished."
Write-Host "
    Dashboard   : http://localhost:$DASHBOARD_PORT/
    Install dir : $INSTALL_DIR

    Update      : cd $INSTALL_DIR; docker compose pull; docker compose up -d
    Stop        : cd $INSTALL_DIR; docker compose down
    Logs        : cd $INSTALL_DIR; docker compose logs -f
"

$answer = Read-Host "[OPTiCS Installer] Do you want to enter Agent console after finish? (y/N)"
if ($answer -in @('Y', 'y')) {
    $containerRunning = docker compose ps --status running | Select-String "optics-agent"
    if ($containerRunning) {
        docker compose exec optics-agent sh
    }
    else {
        Write-Host "[OPTiCS Installer] Agent container is not running. Check logs with: docker compose logs optics-agent"
    }
}

Write-Host "[OPTiCS Installer] Installation complete."
exit 0