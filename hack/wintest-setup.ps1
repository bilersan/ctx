#Requires -RunAsAdministrator
<#
.SYNOPSIS
    One-time setup script for wintest Hyper-V VM.
    Run this INSIDE the VM via Hyper-V Manager console.

.DESCRIPTION
    Configures WinRM, firewall, and installs required dev tools
    so the host can deploy and run tests remotely.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Write-Host "=== wintest VM Setup ===" -ForegroundColor Cyan
Write-Host ""

# Step 1: Set a password on the current user (required for WinRM)
$currentUser = $env:USERNAME
Write-Host "[1/6] Setting password for '$currentUser'..." -ForegroundColor Yellow
Write-Host "  WinRM requires a non-blank password." -ForegroundColor Gray
$securePass = Read-Host -Prompt "  Enter new password for $currentUser" -AsSecureString
$bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePass)
$plainPass = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
[System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
net user $currentUser $plainPass | Out-Null
Write-Host "  Password set." -ForegroundColor Green

# Step 2: Enable WinRM
Write-Host "[2/6] Enabling WinRM..." -ForegroundColor Yellow
Enable-PSRemoting -Force -SkipNetworkProfileCheck
# Allow unencrypted for internal Hyper-V network (not exposed externally)
Set-Item WSMan:\localhost\Service\AllowUnencrypted -Value $true
Set-Item WSMan:\localhost\Service\Auth\Basic -Value $true
Write-Host "  WinRM enabled." -ForegroundColor Green

# Step 3: Firewall — allow WinRM and ICMP from host
Write-Host "[3/6] Configuring firewall..." -ForegroundColor Yellow
# WinRM should already be allowed by Enable-PSRemoting, but ensure it
Enable-NetFirewallRule -DisplayGroup "Windows Remote Management" -ErrorAction SilentlyContinue
# Allow ICMP (ping) for connectivity testing
New-NetFirewallRule -DisplayName "Allow ICMPv4" -Protocol ICMPv4 -IcmpType 8 -Action Allow -Direction Inbound -ErrorAction SilentlyContinue | Out-Null
Write-Host "  Firewall configured." -ForegroundColor Green

# Step 4: Install dev tools via direct download (winget not always available on Win10)
Write-Host "[4/6] Installing development tools..." -ForegroundColor Yellow

# Disable progress bar — PowerShell 5.1 Invoke-WebRequest is extremely slow with it enabled
$ProgressPreference = 'SilentlyContinue'

$downloadDir = "$env:TEMP\wintest-installers"
if (!(Test-Path $downloadDir)) { New-Item -ItemType Directory -Path $downloadDir -Force | Out-Null }

# Go
if (Get-Command go -ErrorAction SilentlyContinue) {
    Write-Host "  Go already installed: $(go version)" -ForegroundColor Gray
} else {
    Write-Host "  Downloading Go 1.25.0..." -ForegroundColor Gray
    $goMsi = "$downloadDir\go-install.msi"
    Invoke-WebRequest -Uri "https://go.dev/dl/go1.25.0.windows-amd64.msi" -OutFile $goMsi -UseBasicParsing
    Write-Host "  Installing Go..." -ForegroundColor Gray
    Start-Process msiexec.exe -ArgumentList "/i","$goMsi","/quiet","/norestart" -Wait
    Write-Host "  Go installed." -ForegroundColor Green
}

# Node.js LTS
if (Get-Command node -ErrorAction SilentlyContinue) {
    Write-Host "  Node.js already installed: $(node --version)" -ForegroundColor Gray
} else {
    Write-Host "  Downloading Node.js 22 LTS..." -ForegroundColor Gray
    $nodeMsi = "$downloadDir\node-install.msi"
    Invoke-WebRequest -Uri "https://nodejs.org/dist/v22.14.0/node-v22.14.0-x64.msi" -OutFile $nodeMsi -UseBasicParsing
    Write-Host "  Installing Node.js..." -ForegroundColor Gray
    Start-Process msiexec.exe -ArgumentList "/i","$nodeMsi","/quiet","/norestart" -Wait
    Write-Host "  Node.js installed." -ForegroundColor Green
}

# Git
if (Get-Command git -ErrorAction SilentlyContinue) {
    Write-Host "  Git already installed: $(git --version)" -ForegroundColor Gray
} else {
    Write-Host "  Downloading Git..." -ForegroundColor Gray
    $gitExe = "$downloadDir\git-install.exe"
    Invoke-WebRequest -Uri "https://github.com/git-for-windows/git/releases/download/v2.48.1.windows.1/Git-2.48.1-64-bit.exe" -OutFile $gitExe -UseBasicParsing
    Write-Host "  Installing Git..." -ForegroundColor Gray
    Start-Process $gitExe -ArgumentList "/VERYSILENT","/NORESTART","/NOCANCEL","/SP-","/CLOSEAPPLICATIONS","/RESTARTAPPLICATIONS" -Wait
    Write-Host "  Git installed." -ForegroundColor Green
}

# Step 5: Refresh PATH for current session
Write-Host "[5/6] Refreshing PATH..." -ForegroundColor Yellow
$machinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
$userPath = [Environment]::GetEnvironmentVariable("Path", "User")
$env:Path = "$machinePath;$userPath"

# Step 6: Verify installations
Write-Host "[6/6] Verifying installations..." -ForegroundColor Yellow
Write-Host ""

$checks = @(
    @{ Cmd = "go version";   Name = "Go" },
    @{ Cmd = "node --version"; Name = "Node.js" },
    @{ Cmd = "npm --version";  Name = "npm" },
    @{ Cmd = "git --version";  Name = "Git" }
)

$allOk = $true
foreach ($check in $checks) {
    try {
        $result = Invoke-Expression $check.Cmd 2>&1
        Write-Host "  $($check.Name): $result" -ForegroundColor Green
    } catch {
        Write-Host "  $($check.Name): NOT FOUND (restart terminal and retry)" -ForegroundColor Red
        $allOk = $false
    }
}

Write-Host ""
if ($allOk) {
    Write-Host "=== Setup complete! ===" -ForegroundColor Green
    Write-Host ""
    Write-Host "VM IP address:" -ForegroundColor Cyan
    Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.InterfaceAlias -notlike "*Loopback*" } | ForEach-Object {
        Write-Host "  $($_.InterfaceAlias): $($_.IPAddress)" -ForegroundColor White
    }
    Write-Host ""
    Write-Host "From the HOST, test with:" -ForegroundColor Cyan
    Write-Host '  $cred = Get-Credential' -ForegroundColor White
    Write-Host '  Invoke-Command -ComputerName <VM-IP> -Credential $cred -ScriptBlock { hostname }' -ForegroundColor White
} else {
    Write-Host "=== Some tools need a terminal restart ===" -ForegroundColor Yellow
    Write-Host "Close and reopen PowerShell, then run the verification commands manually." -ForegroundColor Gray
}
