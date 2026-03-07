<#
.SYNOPSIS
    Deploy ctx repo to wintest VM and run the full CI suite via WinRM.
.DESCRIPTION
    Copies the repo to the remote Windows VM via WinRM, then runs the full
    test and audit suite: fmt check, vet, golangci-lint, lint-drift,
    lint-docs, check-why, Go tests, VS Code tests, and smoke tests.
    Mirrors the 'make check' / 'make audit' pipeline on a real Windows box.
.PARAMETER ComputerName
    IP or hostname of the wintest VM. Default: 172.28.6.106
.PARAMETER Username
    Username for WinRM authentication. Default: ersan
.PARAMETER Password
    Password for WinRM authentication.
.PARAMETER TestScope
    Which tests to run: all, go, lint, vscode, smoke. Default: all
.PARAMETER RemotePath
    Destination path on the VM. Default: C:\ctx
.PARAMETER SkipDeploy
    Skip file copy — use existing files on VM.
#>
param(
    [string]$ComputerName = "172.28.6.106",
    [string]$Username = "ersan",
    [string]$Password,
    [ValidateSet("all", "go", "lint", "vscode", "smoke")]
    [string]$TestScope = "all",
    [string]$RemotePath = "C:\ctx",
    [switch]$SkipDeploy
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# --- Credential setup ---
if (-not $Password) {
    $cred = Get-Credential -UserName $Username -Message "wintest VM password"
} else {
    $secPass = ConvertTo-SecureString $Password -AsPlainText -Force
    $cred = New-Object System.Management.Automation.PSCredential($Username, $secPass)
}

$session = New-PSSession -ComputerName $ComputerName -Credential $cred
Write-Host "Connected to $(Invoke-Command -Session $session -ScriptBlock { hostname })" -ForegroundColor Cyan

# --- Deploy ---
if (-not $SkipDeploy) {
    Write-Host ""
    Write-Host "=== Deploying repo to ${RemotePath} ===" -ForegroundColor Yellow

    $repoRoot = Split-Path -Parent $PSScriptRoot
    $tarPath = Join-Path ([System.IO.Path]::GetTempPath()) "ctx-deploy.tar"
    if (Test-Path $tarPath) { Remove-Item $tarPath -Force }

    # Use git archive for fast, clean export (respects .gitignore)
    Write-Host "  Creating archive..."
    Push-Location $repoRoot
    # Include both committed and uncommitted files: use tar with git ls-files
    $tarExe = (Get-Command tar -ErrorAction SilentlyContinue).Source
    if (-not $tarExe) { $tarExe = "tar" }
    # Get all tracked + untracked (un-ignored) files
    $fileList = git ls-files --cached --others --exclude-standard
    $fileListPath = Join-Path ([System.IO.Path]::GetTempPath()) "ctx-filelist.txt"
    # Write without BOM — tar chokes on UTF-8 BOM
    [System.IO.File]::WriteAllLines($fileListPath, $fileList)
    & $tarExe cf $tarPath -T $fileListPath
    Remove-Item $fileListPath -Force
    Pop-Location

    $archiveSize = [math]::Round((Get-Item $tarPath).Length / 1MB, 1)
    Write-Host "  Archive: ${archiveSize}MB"

    # Copy tar to VM
    Write-Host "  Transferring to VM..."
    Copy-Item -Path $tarPath -Destination "C:\temp\ctx-deploy.tar" -ToSession $session -Force

    # Extract on VM and strip CRLF from text files (gofmt expects LF)
    Write-Host "  Extracting on VM..."
    Invoke-Command -Session $session -ScriptBlock {
        param($p)
        if (Test-Path $p) { Remove-Item -Recurse -Force $p }
        New-Item -ItemType Directory -Path $p -Force | Out-Null
        Set-Location $p
        tar xf "C:\temp\ctx-deploy.tar"
        Remove-Item "C:\temp\ctx-deploy.tar" -Force
        # Convert CRLF to LF for text files (gofmt, bash scripts need LF)
        Get-ChildItem -Recurse -Include *.go,*.sh,*.md,*.toml,*.yaml,*.yml,*.mod,*.sum -File | ForEach-Object {
            $bytes = [System.IO.File]::ReadAllBytes($_.FullName)
            $text = [System.Text.Encoding]::UTF8.GetString($bytes) -replace "`r`n", "`n"
            [System.IO.File]::WriteAllBytes($_.FullName, [System.Text.Encoding]::UTF8.GetBytes($text))
        }
    } -ArgumentList $RemotePath

    Remove-Item $tarPath -Force
    Write-Host "  Deploy complete." -ForegroundColor Green
}

# --- Test execution helper ---
function Run-RemoteTest {
    param([string]$Name, [scriptblock]$Block)
    Write-Host ""
    Write-Host "=== $Name ===" -ForegroundColor Yellow
    $startTime = Get-Date
    try {
        $output = Invoke-Command -Session $session -ScriptBlock $Block -ArgumentList $RemotePath
        $output | ForEach-Object { Write-Host "  $_" }
        $duration = (Get-Date) - $startTime
        Write-Host "  PASSED ($([math]::Round($duration.TotalSeconds, 1))s)" -ForegroundColor Green
        return $true
    } catch {
        $duration = (Get-Date) - $startTime
        Write-Host "  FAILED: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "  ($([math]::Round($duration.TotalSeconds, 1))s)" -ForegroundColor Red
        return $false
    }
}

$results = [ordered]@{}

# --- Lint / audit checks ---
if ($TestScope -in @("all", "lint")) {
    $results["Format Check"] = Run-RemoteTest "Format Check" {
        param($p)
        $ErrorActionPreference = 'Continue'
        $env:Path = [Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [Environment]::GetEnvironmentVariable("Path","User")
        Set-Location $p
        $env:CGO_ENABLED = "0"
        $bad = cmd /c "gofmt -l . 2>&1" | Where-Object { $_ -and $_ -notmatch '^vendor/' }
        if ($bad) { throw "Files need formatting:`n$($bad -join "`n")" }
        "Format OK"
    }

    $results["Go Vet"] = Run-RemoteTest "Go Vet" {
        param($p)
        $ErrorActionPreference = 'Continue'
        $env:Path = [Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [Environment]::GetEnvironmentVariable("Path","User")
        Set-Location $p
        $env:CGO_ENABLED = "0"
        cmd /c "go vet ./... 2>&1"
        if ($LASTEXITCODE -ne 0) { throw "go vet failed" }
        "Vet OK"
    }

    $results["Lint Drift"] = Run-RemoteTest "Lint Drift" {
        param($p)
        $ErrorActionPreference = 'Continue'
        $env:Path = [Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [Environment]::GetEnvironmentVariable("Path","User")
        Set-Location $p
        $bash = Join-Path (Split-Path (Split-Path (Get-Command git).Source -Parent) -Parent) "bin\bash.exe"
        $result = cmd /c "`"$bash`" -c `"cd /c/ctx && bash hack/lint-drift.sh`" 2>&1"
        $result | ForEach-Object { $_ }
        if ($LASTEXITCODE -ne 0) { throw "lint-drift failed" }
    }

    $results["Lint Docs"] = Run-RemoteTest "Lint Docs" {
        param($p)
        $ErrorActionPreference = 'Continue'
        $env:Path = [Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [Environment]::GetEnvironmentVariable("Path","User")
        Set-Location $p
        $bash = Join-Path (Split-Path (Split-Path (Get-Command git).Source -Parent) -Parent) "bin\bash.exe"
        $result = cmd /c "`"$bash`" -c `"cd /c/ctx && bash hack/lint-docs.sh`" 2>&1"
        $result | ForEach-Object { $_ }
        if ($LASTEXITCODE -ne 0) { throw "lint-docs failed" }
    }

    $results["Check Why Docs"] = Run-RemoteTest "Check Why Docs" {
        param($p)
        $ErrorActionPreference = 'Continue'
        $env:Path = [Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [Environment]::GetEnvironmentVariable("Path","User")
        Set-Location $p
        $bash = Join-Path (Split-Path (Split-Path (Get-Command git).Source -Parent) -Parent) "bin\bash.exe"
        $result = cmd /c "`"$bash`" -c `"cd /c/ctx && bash hack/check-why.sh`" 2>&1"
        $result | ForEach-Object { $_ }
        if ($LASTEXITCODE -ne 0) { throw "check-why failed" }
    }

    $results["Golangci-lint"] = Run-RemoteTest "Golangci-lint" {
        param($p)
        $ErrorActionPreference = 'Continue'
        $env:Path = [Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [Environment]::GetEnvironmentVariable("Path","User")
        Set-Location $p
        $env:CGO_ENABLED = "0"
        $gcl = Get-Command golangci-lint -ErrorAction SilentlyContinue
        if (-not $gcl) { "SKIP: golangci-lint not installed"; return }
        cmd /c "golangci-lint run --timeout=5m 2>&1"
        if ($LASTEXITCODE -ne 0) { throw "golangci-lint failed" }
    }
}

# --- Go tests ---
if ($TestScope -in @("all", "go")) {
    $results["Go Build"] = Run-RemoteTest "Go Build" {
        param($p)
        $ErrorActionPreference = 'Continue'
        $env:Path = [Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [Environment]::GetEnvironmentVariable("Path","User")
        Set-Location $p
        $env:CGO_ENABLED = "0"
        cmd /c "go build ./... 2>&1"
        if ($LASTEXITCODE -ne 0) { throw "go build failed" }
        "Build OK"
    }

    $results["Go Test"] = Run-RemoteTest "Go Test" {
        param($p)
        $ErrorActionPreference = 'Continue'
        $env:Path = [Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [Environment]::GetEnvironmentVariable("Path","User")
        Set-Location $p
        $env:CGO_ENABLED = "0"
        $env:CTX_SKIP_PATH_CHECK = "1"
        cmd /c "go test -v ./... 2>&1"
        if ($LASTEXITCODE -ne 0) { throw "go test failed" }
    }
}

# --- VS Code extension tests ---
if ($TestScope -in @("all", "vscode")) {
    $results["VS Code Tests"] = Run-RemoteTest "VS Code Extension Tests" {
        param($p)
        $ErrorActionPreference = 'Continue'
        $env:Path = [Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [Environment]::GetEnvironmentVariable("Path","User")
        Set-Location (Join-Path $p "editors\vscode")
        cmd /c "npm ci 2>&1"
        if ($LASTEXITCODE -ne 0) { throw "npm ci failed" }
        cmd /c "npm test 2>&1"
        if ($LASTEXITCODE -ne 0) { throw "npm test failed" }
    }
}

# --- Smoke tests ---
if ($TestScope -in @("all", "smoke")) {
    $results["Smoke Tests"] = Run-RemoteTest "Smoke Tests" {
        param($p)
        $ErrorActionPreference = 'Continue'
        $env:Path = [Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [Environment]::GetEnvironmentVariable("Path","User")
        Set-Location $p
        $env:CGO_ENABLED = "0"
        cmd /c "powershell -ExecutionPolicy Bypass -File hack\smoke-windows.ps1 2>&1"
        if ($LASTEXITCODE -ne 0) { throw "smoke tests failed" }
    }
}

# --- Summary ---
Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  Test Summary (Windows)" -ForegroundColor Cyan
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

# Cleanup
Remove-PSSession -Session $session

if ($passed -ne $total) { exit 1 }
