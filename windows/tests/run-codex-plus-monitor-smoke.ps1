#Requires -Version 5.1
[CmdletBinding(DefaultParameterSetName = 'Fixture')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Fixture')]
    [string] $FixtureRoot,

    [Parameter(Mandatory, ParameterSetName = 'Candidate')]
    [string] $CodexPlusPlusExe,

    [Parameter(Mandatory, ParameterSetName = 'Candidate')]
    [string] $CodexPackageFamily,

    [Parameter(Mandatory, ParameterSetName = 'Candidate')]
    [string] $IsolatedHome,

    [Parameter(Mandatory)]
    [string] $ReportPath,

    [string] $NodePath = 'node',

    [ValidateRange(0, 65535)]
    [int] $DebugPort = 0
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$WindowsRoot = Split-Path -Parent $PSScriptRoot
$RepositoryRoot = Split-Path -Parent $WindowsRoot
$Runner = Join-Path $PSScriptRoot 'fixtures/monitor-smoke/smoke-runner.mjs'
$PlaywrightModule = Join-Path $RepositoryRoot `
    'tests/script-runtime/node_modules/playwright/index.mjs'
$ScriptMarketRoot = Join-Path $RepositoryRoot 'Resources/script-market-sources'

function Resolve-PathFromCurrent([string] $Path) {
    if ([IO.Path]::IsPathRooted($Path)) {
        return [IO.Path]::GetFullPath($Path)
    }
    return [IO.Path]::GetFullPath((Join-Path (Get-Location).Path $Path))
}

function Assert-File([string] $Path, [string] $Description) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "monitor-smoke: missing $Description at $Path"
    }
}

function Invoke-SmokeNode([string[]] $Arguments) {
    & $NodePath $Runner @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "monitor-smoke: node runner failed with exit code $LASTEXITCODE"
    }
}

function Assert-Report([string] $Path) {
    Assert-File $Path 'report'
    $report = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    if ($report.status -ne 'pass' -or
        $report.runtime.status -ne 'pass' -or
        $report.persistence.status -ne 'pass') {
        throw 'monitor-smoke: runtime or persistence did not pass'
    }
    foreach ($manual in @($report.manualRequired)) {
        if ($manual.status -ne 'manualRequired') {
            throw 'monitor-smoke: login and UAC may only be manualRequired'
        }
    }
}

Assert-File $Runner 'node runner'
Assert-File $PlaywrightModule 'Playwright module'
$ResolvedReport = Resolve-PathFromCurrent $ReportPath
$reportParent = Split-Path -Parent $ResolvedReport
if ($reportParent) {
    [IO.Directory]::CreateDirectory($reportParent) | Out-Null
}

if ($PSCmdlet.ParameterSetName -eq 'Fixture') {
    $ResolvedFixture = Resolve-PathFromCurrent $FixtureRoot
    $FixtureConfig = Join-Path $ResolvedFixture 'fixture.json'
    Assert-File $FixtureConfig 'fixture config'
    Invoke-SmokeNode @(
        '--mode', 'fixture',
        '--fixture-root', $ResolvedFixture,
        '--report', $ResolvedReport,
        '--playwright-module', $PlaywrightModule,
        '--script-market-root', $ScriptMarketRoot
    )
    Assert-Report $ResolvedReport
    $secret = (Get-Content -LiteralPath $FixtureConfig -Raw |
        ConvertFrom-Json).fixtureSecret
    $reportText = Get-Content -LiteralPath $ResolvedReport -Raw
    if ($secret -and $reportText.Contains([string] $secret)) {
        throw 'monitor-smoke: fixture secret leaked into report'
    }
    Write-Output 'monitor-smoke: PASS'
    exit 0
}

if ($env:OS -ne 'Windows_NT') {
    throw 'monitor-smoke: candidate CDP execution is CI-only on Windows'
}

$ResolvedExe = Resolve-PathFromCurrent $CodexPlusPlusExe
$ResolvedHome = Resolve-PathFromCurrent $IsolatedHome
Assert-File $ResolvedExe 'Codex++ candidate'
[IO.Directory]::CreateDirectory($ResolvedHome) | Out-Null
$ProfileRoot = Join-Path $ResolvedHome 'renderer-profile'
[IO.Directory]::CreateDirectory($ProfileRoot) | Out-Null

function Test-DebugPortAvailable([int] $Port) {
    $listener = $null
    try {
        $listener = [Net.Sockets.TcpListener]::new(
            [Net.IPAddress]::Loopback,
            $Port)
        $listener.Start()
        return $true
    } catch {
        return $false
    } finally {
        if ($null -ne $listener) {
            try { $listener.Stop() } catch { }
        }
    }
}

function Get-IsolatedDebugPort() {
    $listener = [Net.Sockets.TcpListener]::new(
        [Net.IPAddress]::Loopback,
        0)
    try {
        $listener.Start()
        return ([Net.IPEndPoint] $listener.LocalEndpoint).Port
    } finally {
        $listener.Stop()
    }
}

if ($DebugPort -eq 0) {
    $DebugPort = Get-IsolatedDebugPort
}
if (-not (Test-DebugPortAvailable $DebugPort)) {
    throw "monitor-smoke: debug port is already in use: $DebugPort"
}
$CdpUrl = "http://127.0.0.1:$DebugPort"

function Quote-ProcessArgument([string] $Value) {
    return '"' + $Value.Replace('"', '\"') + '"'
}

function Start-Candidate() {
    if (-not (Test-DebugPortAvailable $DebugPort)) {
        throw "monitor-smoke: refusing to reuse occupied CDP port $DebugPort"
    }
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = $ResolvedExe
    $start.UseShellExecute = $false
    $quotedArguments = @(
        "--remote-debugging-port=$DebugPort",
        "--user-data-dir=$ProfileRoot",
        "--codex-package-family=$CodexPackageFamily"
    ) | ForEach-Object { Quote-ProcessArgument $_ }
    $start.Arguments = [string]::Join(' ', $quotedArguments)
    $start.EnvironmentVariables['HOME'] = $ResolvedHome
    $start.EnvironmentVariables['USERPROFILE'] = $ResolvedHome
    $start.EnvironmentVariables['APPDATA'] = Join-Path $ResolvedHome 'AppData/Roaming'
    $start.EnvironmentVariables['LOCALAPPDATA'] = Join-Path $ResolvedHome 'AppData/Local'
    $start.EnvironmentVariables['CODEX_PACKAGE_FAMILY'] = $CodexPackageFamily
    $process = [Diagnostics.Process]::Start($start)
    if ($null -eq $process) {
        throw 'monitor-smoke: Codex++ candidate did not start'
    }
    Start-Sleep -Milliseconds 250
    if ($process.HasExited) {
        $exitCode = $process.ExitCode
        $process.Dispose()
        throw "monitor-smoke: Codex++ candidate exited before CDP attach: $exitCode"
    }
    return $process
}

function Stop-Candidate([Diagnostics.Process] $Process) {
    if ($null -eq $Process) { return }
    try {
        if (-not $Process.HasExited) {
            & taskkill.exe /PID $Process.Id /T /F | Out-Null
            $taskkillExit = $LASTEXITCODE
            if ($taskkillExit -ne 0 -and -not $Process.HasExited) {
                $Process.Kill()
            }
            if (-not $Process.WaitForExit(10000)) {
                try { $Process.Kill() } catch { }
                if (-not $Process.WaitForExit(5000)) {
                    throw 'monitor-smoke: Codex++ candidate did not exit'
                }
            }
        }
    } finally {
        $Process.Dispose()
    }
    if (-not (Test-DebugPortAvailable $DebugPort)) {
        throw "monitor-smoke: CDP port remained occupied after candidate exit: $DebugPort"
    }
}

$candidate = $null
try {
    $candidate = Start-Candidate
    Invoke-SmokeNode @(
        '--mode', 'candidate',
        '--phase', 'initial',
        '--cdp-url', $CdpUrl,
        '--codex-package-family', $CodexPackageFamily,
        '--report', $ResolvedReport,
        '--playwright-module', $PlaywrightModule,
        '--script-market-root', $ScriptMarketRoot
    )
    if ($candidate.HasExited) {
        throw 'monitor-smoke: Codex++ candidate exited during initial smoke'
    }
} finally {
    Stop-Candidate $candidate
}

$candidate = $null
try {
    $candidate = Start-Candidate
    Invoke-SmokeNode @(
        '--mode', 'candidate',
        '--phase', 'restart',
        '--cdp-url', $CdpUrl,
        '--codex-package-family', $CodexPackageFamily,
        '--report', $ResolvedReport,
        '--playwright-module', $PlaywrightModule,
        '--script-market-root', $ScriptMarketRoot
    )
    if ($candidate.HasExited) {
        throw 'monitor-smoke: Codex++ candidate exited during restart smoke'
    }
} finally {
    Stop-Candidate $candidate
}

Assert-Report $ResolvedReport
Write-Output 'monitor-smoke: PASS'
