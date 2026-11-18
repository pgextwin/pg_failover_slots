[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$UpstreamDir,

    [Parameter(Mandatory = $true)]
    [string]$UpstreamRepository,

    [Parameter(Mandatory = $true)]
    [string]$UpstreamRef,

    [Parameter(Mandatory = $true)]
    [string]$UpstreamVersion,

    [Parameter(Mandatory = $true)]
    [int]$PostgreSqlMajor,

    [Parameter(Mandatory = $true)]
    [string]$PostgreSqlMinor,

    [string]$DistDir = "dist"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$manifest = Get-Content (Join-Path $PSScriptRoot "../../config/extension.json") -Raw | ConvertFrom-Json
$upstreamSha = (& git -C $UpstreamDir rev-parse HEAD).Trim().ToLowerInvariant()
if ($LASTEXITCODE -ne 0 -or
    $upstreamSha -cne ([string]$manifest.upstream.commit).ToLowerInvariant() -or
    $UpstreamRepository -cne [string]$manifest.upstream.repository -or
    $UpstreamRef -cne [string]$manifest.upstream.ref -or
    $UpstreamVersion -cne [string]$manifest.upstream.version -or
    $PostgreSqlMajor -notin @(15, 16, 17, 18)) {
    throw "Package identity mismatch for pg_failover_slots."
}

$assetName = "pg_failover_slots-$UpstreamRef-pg$PostgreSqlMajor-windows-x64"
$stage = Join-Path $DistDir $assetName
$zipPath = Join-Path $DistDir "$assetName.zip"

if (Test-Path $stage) {
    Remove-Item $stage -Recurse -Force
}
if (Test-Path $zipPath) {
    Remove-Item $zipPath -Force
}

New-Item -ItemType Directory -Force -Path (Join-Path $stage "lib") | Out-Null
Copy-Item (Join-Path $UpstreamDir "pg_failover_slots.dll") (Join-Path $stage "lib/pg_failover_slots.dll") -Force
# Windows Git checkout may use CRLF; distribute the exact pinned LICENSE blob.
& git -C $UpstreamDir -c core.autocrlf=false checkout-index --force -- LICENSE
if ($LASTEXITCODE -ne 0) { throw "Could not restore exact upstream LICENSE bytes." }
Copy-Item (Join-Path $UpstreamDir "LICENSE") (Join-Path $stage "LICENSE") -Force
if (Test-Path (Join-Path $UpstreamDir "README.md")) {
    Copy-Item (Join-Path $UpstreamDir "README.md") (Join-Path $stage "UPSTREAM-README.md") -Force
}

@"
pg_failover_slots Windows package
=================================

Upstream repository: $UpstreamRepository
Upstream ref:        $UpstreamRef
Upstream commit:     $upstreamSha
pg_failover_slots version: $UpstreamVersion
PostgreSQL major:    $PostgreSqlMajor
PostgreSQL tested:   $PostgreSqlMinor
Architecture:        Windows x64
Compiler:            MSVC x64
License:             PostgreSQL; see LICENSE

This is an unofficial pgextwin Windows package built from the official pg_failover_slots source.
Shared-preload library only (no CREATE EXTENSION, no SQL files).
Requires shared_preload_libraries=pg_failover_slots.
"@ | Set-Content -Path (Join-Path $stage "PACKAGE-INFO.txt") -Encoding utf8

Compress-Archive -Path (Join-Path $stage "*") -DestinationPath $zipPath -CompressionLevel Optimal
if (-not (Test-Path $zipPath)) {
    throw "Expected package was not produced: $zipPath"
}

Add-Type -AssemblyName System.IO.Compression.FileSystem
$archive = [System.IO.Compression.ZipFile]::OpenRead((Resolve-Path $zipPath).Path)
try {
    $items = @($archive.Entries | ForEach-Object { $_.FullName.Replace('\', '/') })
    foreach ($required in @("lib/pg_failover_slots.dll", "LICENSE", "PACKAGE-INFO.txt")) {
        if ($items -cnotcontains $required) {
            throw "ZIP entry missing: $required"
        }
    }
}
finally {
    $archive.Dispose()
}
