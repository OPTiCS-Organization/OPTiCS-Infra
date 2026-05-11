Write-Host "Welcome to OPTiCS Windows Installer v0.2.0"

Start-Sleep 1
$installAgree = Read-Host "[OPTiCS Installer] Are you sure want to install OPTiCS Agent on your PC? (y/N)"
if (-not ($installAgree -in @('Y', 'y'))) {
    Write-Host "[OPTiCS Installer] Installation process Terminated"
    exit
}

Start-Sleep 1

$needRestartFlag = 0

Write-Host "[OPTiCS Installer] Checking Git version..."
if (Get-Command git -ErrorAction SilentlyContinue) {
    $gitVersion = git --version
    Write-Host "[OPTiCS Installer] Detected: $gitVersion"
}
else {
    Write-Host "[OPTiCS Installer] Git not detected."
    $installGitAgree = Read-Host "[OPTiCS Installer] Do you want to install Git? (y/N)"
    if (-not ($installGitAgree -in @('Y', 'y'))) {
        Write-Host "[OPTiCS Installer] Installation process Terminated."
        exit
    }
    winget install Git.Git
    Write-Host "[OPTiCS Installer] Git installation finished."
}
Start-Sleep 1

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
        exit
    }
    $needRestartFlag = 1
    winget install Docker.DockerDesktop
    Write-Host "[OPTiCS Installer] Docker installation finished."
}

if ($needRestartFlag) {
    Write-Host "Please REBOOT YOUR SYSTEM to apply changes.

TO CONTINUE INSTALL, re-run this script again AFTER REBOOT."
    exit
}

function Wait-DockerDaemon {
    param($maxWaitSeconds = 60)
    
    $elapsed = 0
    while ($elapsed -lt $maxWaitSeconds) {
        try {
            $output = docker ps 2>&1
            if ($output -notmatch "error|denied|failed") {
                Write-Host "[OPTiCS Installer] Docker daemon is ready."
                return $true
            }
        }
        catch {
            # Stand by...
        }
        $elapsed += 1
    }
    return $false
}

Write-Host "[OPTiCS Installer] Starting Docker Desktop..."
Write-Host "[OPTiCS Installer] Waiting for Docker daemon... (max 1 min)"
Start-Process "docker" -ErrorAction SilentlyContinue
Start-Sleep 5

if (-not (Wait-DockerDaemon 120)) {
    Write-Host "[OPTiCS Installer] Docker daemon failed to initialize."
    exit
}

Start-Sleep 1

$INSTALL_DIR = "$HOME/optics-build"

Write-Host "[OPTiCS Installer] Starting clone from github..."
Push-Location $HOME
git clone https://github.com/OPTiCS-Organization/OPTiCS-Agent OPTiCS-Agent
git clone https://github.com/OPTiCS-Organization/OPTiCS-Agent-Dashboard OPTiCS-Agent-Dashboard

Write-Host "[OPTiCS Installer] Creating directory 'optics-build'..."
New-Item -ItemType Directory -Path "$INSTALL_DIR" -Force | Out-Null

Write-Host "[OPTiCS Installer] Copying files..."
Copy-Item -Path "./OPTiCS-Agent" -Destination "$INSTALL_DIR" -Recurse -Force
Copy-Item -Path "./OPTiCS-Agent-Dashboard" -Destination "$INSTALL_DIR" -Recurse -Force

Write-Host "[OPTiCS Installer] Cleaning up..."
Remove-Item -Path "./OPTiCS-Agent" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -Path "./OPTiCS-Agent-Dashboard" -Recurse -Force -ErrorAction SilentlyContinue
Pop-Location

Write-Host "[OPTiCS Installer] Repository clone successful."
Start-Sleep 1
Write-Host "[OPTiCS Installer] Docker-compose phase start in 3..."
Start-Sleep 1
Write-Host "[OPTiCS Installer] Docker-compose phase start in 2..."
Start-Sleep 1
Write-Host "[OPTiCS Installer] Docker-compose phase start in 1..."
Start-Sleep 1

Write-Host "[OPTiCS Installer] Checking ports..."

$AGENT_PORT = 5230
$portInUse = $true
while ($portInUse) {
    $connection = Test-NetConnection -ComputerName localhost -Port $AGENT_PORT -WarningAction SilentlyContinue
    if ($connection.TcpTestSucceeded) {
        Write-Host "[OPTiCS Installer] Port $AGENT_PORT is already in use (optics-agent)."
        do {
            $input = Read-Host "[OPTiCS Installer] Enter a different port for optics-agent"
            $parsed = 0
            if ([int]::TryParse($input, [ref]$parsed) -and $parsed -ge 1 -and $parsed -le 65535) {
                $AGENT_PORT = $parsed
                break
            }
            Write-Host "[OPTiCS Installer] Invalid port. Please enter a number between 1 and 65535."
        } while ($true)
    } else {
        $portInUse = $false
    }
}

$DASHBOARD_PORT = 5240
$portInUse = $true
while ($portInUse) {
    $connection = Test-NetConnection -ComputerName localhost -Port $DASHBOARD_PORT -WarningAction SilentlyContinue
    if ($connection.TcpTestSucceeded) {
        Write-Host "[OPTiCS Installer] Port $DASHBOARD_PORT is already in use (optics-agent-dashboard)."
        do {
            $input = Read-Host "[OPTiCS Installer] Enter a different port for optics-agent-dashboard"
            $parsed = 0
            if ([int]::TryParse($input, [ref]$parsed) -and $parsed -ge 1 -and $parsed -le 65535) {
                $DASHBOARD_PORT = $parsed
                break
            }
            Write-Host "[OPTiCS Installer] Invalid port. Please enter a number between 1 and 65535."
        } while ($true)
    } else {
        $portInUse = $false
    }
}

Write-Host "[OPTiCS Installer] Using ports: agent=$AGENT_PORT, dashboard=$DASHBOARD_PORT"

Write-Host "[OPTiCS Installer] Building agent client and dashboard..."
Set-Location "$INSTALL_DIR/OPTiCS-Agent"
@"
AGENT_PORT=$AGENT_PORT
DASHBOARD_PORT=$DASHBOARD_PORT
"@ | Out-File -FilePath ".env.ports" -Encoding ASCII

$env:AGENT_PORT = $AGENT_PORT
$env:DASHBOARD_PORT = $DASHBOARD_PORT
docker compose --env-file .env.ports up --build -d
Remove-Item -Path ".env.ports" -Force

Write-Host "[OPTiCS Installer] OPTiCS Agent installment finished."
$answer = Read-Host "[OPTiCS Installer] Do you want to enter Agent console after finish? (y/N)"
if ($answer -in @('Y', 'y')) {
    $containerRunning = docker compose ps | Select-String "optics-agent"
    if ($containerRunning) {
        docker compose exec optics-agent sh
    } else {
        Write-Host "[OPTiCS Installer] Agent container is not running. Check logs with: docker compose logs optics-agent"
    }
}

$answer = Read-Host "[OPTiCS Installer] Do you want to remove 'optics-build' folder? (Y/n)"
if ([string]::IsNullOrEmpty($answer) -or $answer -in @('Y', 'y')) {
    Set-Location $HOME
    Remove-Item -Path "$INSTALL_DIR" -Recurse -Force
}

Write-Host "[OPTiCS Installer] Installation complete."
Write-Host "
    To enter dashboard: http://localhost:$DASHBOARD_PORT
"
exit 0
