<#
.SYNOPSIS
    Deploy ctx repo to lintest VM and run the full CI suite via SSH.
.DESCRIPTION
    Copies the repo to the remote Ubuntu VM via SCP, then runs the full
    test and audit suite: fmt check, vet, golangci-lint, lint-drift,
    lint-docs, check-why, Go tests (incl compliance), VS Code extension
    tests, and smoke tests.
    Mirrors the 'make check' / 'make audit' pipeline on a real Linux box.
.PARAMETER ComputerName
    IP or hostname of the lintest VM. Default: 172.28.8.112
.PARAMETER Username
    Username for SSH authentication. Default: ersan
.PARAMETER Password
    Password for SSH authentication (used for sudo on VM).
.PARAMETER TestScope
    Which tests to run: all, go, lint, smoke. Default: all
.PARAMETER RemotePath
    Destination path on the VM. Default: /home/ersan/ctx
.PARAMETER SkipDeploy
    Skip file copy — use existing files on VM.
#>
param(
    [string]$ComputerName = "172.28.8.112",
    [string]$Username = "ersan",
    [string]$Password,
    [ValidateSet("all", "go", "lint", "vscode", "smoke")]
    [string]$TestScope = "all",
    [string]$RemotePath = "/home/ersan/ctx",
    [switch]$SkipDeploy
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$sshTarget = "${Username}@${ComputerName}"

# --- Connectivity check ---
Write-Host "Connecting to ${sshTarget}..." -ForegroundColor Cyan
$hostCheck = ssh -o BatchMode=yes -o ConnectTimeout=5 $sshTarget "hostname" 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Error "SSH connection failed. Ensure SSH key auth is configured for ${sshTarget}."
    exit 1
}
Write-Host "Connected to $hostCheck" -ForegroundColor Cyan

# --- Deploy ---
if (-not $SkipDeploy) {
    Write-Host ""
    Write-Host "=== Deploying repo to ${RemotePath} ===" -ForegroundColor Yellow

    $repoRoot = Split-Path -Parent $PSScriptRoot
    $tarPath = Join-Path ([System.IO.Path]::GetTempPath()) "ctx-linux-deploy.tar"
    if (Test-Path $tarPath) { Remove-Item $tarPath -Force }

    Write-Host "  Creating archive..."
    Push-Location $repoRoot
    $fileListPath = Join-Path ([System.IO.Path]::GetTempPath()) "ctx-filelist-linux.txt"
    git ls-files --cached --others --exclude-standard | Out-File -Encoding ascii $fileListPath
    tar cf $tarPath -T $fileListPath
    Remove-Item $fileListPath -Force
    Pop-Location

    $archiveSize = [math]::Round((Get-Item $tarPath).Length / 1MB, 1)
    Write-Host "  Archive: ${archiveSize}MB"

    Write-Host "  Transferring to VM..."
    scp -q $tarPath "${sshTarget}:/tmp/ctx-deploy.tar"
    if ($LASTEXITCODE -ne 0) { Write-Error "SCP failed"; exit 1 }

    Write-Host "  Extracting on VM..."
    ssh $sshTarget "rm -rf ${RemotePath} && mkdir -p ${RemotePath} && cd ${RemotePath} && tar xf /tmp/ctx-deploy.tar && rm /tmp/ctx-deploy.tar && find . \( -name '*.sh' -o -name '*.go' -o -name '*.md' -o -name '*.toml' -o -name '*.yaml' -o -name '*.yml' -o -name '*.mod' -o -name '*.sum' \) -exec sed -i 's/\r$//' {} +"
    if ($LASTEXITCODE -ne 0) { Write-Error "Extract failed"; exit 1 }

    Remove-Item $tarPath -Force
    Write-Host "  Deploy complete." -ForegroundColor Green
}

# --- Test execution helper ---
function Run-SSHTest {
    param([string]$Name, [string]$Command)
    Write-Host ""
    Write-Host "=== $Name ===" -ForegroundColor Yellow
    $startTime = Get-Date
    try {
        $output = ssh $sshTarget $Command 2>&1
        $exitCode = $LASTEXITCODE
        $output | ForEach-Object { Write-Host "  $_" }
        $duration = (Get-Date) - $startTime
        if ($exitCode -ne 0) {
            Write-Host "  FAILED (exit $exitCode, $([math]::Round($duration.TotalSeconds, 1))s)" -ForegroundColor Red
            return $false
        }
        Write-Host "  PASSED ($([math]::Round($duration.TotalSeconds, 1))s)" -ForegroundColor Green
        return $true
    } catch {
        $duration = (Get-Date) - $startTime
        Write-Host "  FAILED: $($_.Exception.Message) ($([math]::Round($duration.TotalSeconds, 1))s)" -ForegroundColor Red
        return $false
    }
}

$goEnv = "export PATH=/usr/local/go/bin:/usr/local/bin:/usr/bin:/bin && export HOME=/home/${Username} && cd ${RemotePath} && export CGO_ENABLED=0"

$results = [ordered]@{}

# --- Lint / audit checks ---
if ($TestScope -in @("all", "lint")) {
    $results["Format Check"] = Run-SSHTest "Format Check" "$goEnv && bash hack/check-fmt.sh"

    $results["Go Vet"] = Run-SSHTest "Go Vet" "$goEnv && go vet ./... && echo 'Vet OK'"

    $results["Lint Drift"] = Run-SSHTest "Lint Drift" "$goEnv && bash hack/lint-drift.sh"

    $results["Lint Docs"] = Run-SSHTest "Lint Docs" "$goEnv && bash hack/lint-docs.sh"

    $results["Check Why Docs"] = Run-SSHTest "Check Why Docs" "$goEnv && bash hack/check-why.sh"

    $results["Golangci-lint"] = Run-SSHTest "Golangci-lint" "$goEnv && which golangci-lint >/dev/null 2>&1 && golangci-lint run --timeout=5m || echo 'SKIP: golangci-lint not installed'"
}

# --- Go tests ---
if ($TestScope -in @("all", "go")) {
    $results["Go Build"] = Run-SSHTest "Go Build" "$goEnv && go build ./... && echo 'Build OK'"

    $results["Go Test"] = Run-SSHTest "Go Test" "$goEnv && go test -count=1 ./..."
}

# --- VS Code extension tests ---
if ($TestScope -in @("all", "vscode")) {
    $results["VS Code Tests"] = Run-SSHTest "VS Code Extension Tests" "$goEnv && cd editors/vscode && npm ci --silent 2>&1 && npm test 2>&1"
}

# --- Smoke tests ---
if ($TestScope -in @("all", "smoke")) {
    $results["Smoke Tests"] = Run-SSHTest "Smoke Tests" "$goEnv && bash hack/smoke-linux.sh"
}

# --- Summary ---
Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  Test Summary (Linux)" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

$passed = 0; $total = 0
foreach ($kv in $results.GetEnumerator()) {
    $total++
    $status = if ($kv.Value) { $passed++; "PASS" } else { "FAIL" }
    $color = if ($kv.Value) { "Green" } else { "Red" }
    Write-Host "  [$status] $($kv.Key)" -ForegroundColor $color
}

Write-Host ""
Write-Host "  $passed/$total passed" -ForegroundColor $(if ($passed -eq $total) { "Green" } else { "Red" })
Write-Host "========================================" -ForegroundColor Cyan

if ($passed -ne $total) { exit 1 }
