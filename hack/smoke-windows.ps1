<#
.SYNOPSIS
    Windows smoke tests for ctx CLI — equivalent of Makefile "smoke" target.
.DESCRIPTION
    Builds ctx.exe, creates a temp directory, and runs core commands to verify
    the binary works on Windows. Exit code 0 = all passed.
.PARAMETER CtxBinary
    Path to a pre-built ctx.exe. If not provided, builds from source.
#>
param(
    [string]$CtxBinary
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Write-Host "Running Windows smoke tests..." -ForegroundColor Cyan

# Build if no binary provided
if (-not $CtxBinary) {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    Push-Location $repoRoot
    $version = (Get-Content VERSION -Raw).Trim()
    Write-Host "  Building ctx.exe (v$version)..."
    $env:CGO_ENABLED = "0"
    go build -ldflags="-s -w -X github.com/ActiveMemory/ctx/internal/bootstrap.version=$version" -o ctx.exe ./cmd/ctx
    if ($LASTEXITCODE -ne 0) { Write-Error "Build failed"; exit 1 }
    $CtxBinary = Join-Path $repoRoot "ctx.exe"
    Pop-Location
}

$CtxBinary = Resolve-Path $CtxBinary

# Create temp directory
$tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) "ctx-smoke-$(Get-Random)"
New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
Push-Location $tmpDir

$failed = 0
$tests = @(
    @{ Name = "ctx --help";                 Args = @("--help");                              Env = @{} },
    @{ Name = "ctx init";                   Args = @("init");                                Env = @{ CTX_SKIP_PATH_CHECK = "1" } },
    @{ Name = "ctx status";                 Args = @("status");                              Env = @{} },
    @{ Name = "ctx agent";                  Args = @("agent");                               Env = @{} },
    @{ Name = "ctx drift";                  Args = @("drift");                               Env = @{} },
    @{ Name = "ctx add task 'smoke test'";  Args = @("add", "task", "smoke test task");      Env = @{} },
    @{ Name = "ctx recall list";            Args = @("recall", "list");                      Env = @{} },
    @{ Name = "ctx why manifesto";          Args = @("why", "manifesto");                    Env = @{} }
)

foreach ($test in $tests) {
    Write-Host "  Testing: $($test.Name)" -NoNewline
    try {
        # Set env vars for this test
        foreach ($kv in $test.Env.GetEnumerator()) {
            [Environment]::SetEnvironmentVariable($kv.Key, $kv.Value, "Process")
        }
        $output = & $CtxBinary @($test.Args) 2>&1
        if ($LASTEXITCODE -ne 0 -and $test.Name -notlike "*drift*") {
            Write-Host " FAIL (exit $LASTEXITCODE)" -ForegroundColor Red
            $failed++
        } else {
            Write-Host " OK" -ForegroundColor Green
        }
        # Clear env vars
        foreach ($kv in $test.Env.GetEnumerator()) {
            [Environment]::SetEnvironmentVariable($kv.Key, $null, "Process")
        }
    } catch {
        Write-Host " FAIL ($_)" -ForegroundColor Red
        $failed++
    }
}

# Cleanup
Pop-Location
Remove-Item -Recurse -Force $tmpDir -ErrorAction SilentlyContinue

Write-Host ""
if ($failed -eq 0) {
    Write-Host "Smoke tests passed!" -ForegroundColor Green
    exit 0
} else {
    Write-Host "$failed test(s) failed!" -ForegroundColor Red
    exit 1
}
