#Requires -Version 5.1
[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
$projectRoot = Split-Path -Parent $PSScriptRoot

dotnet test (Join-Path $projectRoot "tests\CodexOneClick.Core.Tests\CodexOneClick.Core.Tests.csproj") --filter "FullyQualifiedName~DomainTests"
exit $LASTEXITCODE
