[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$PgRoot,

    [Parameter(Mandatory = $true)]
    [string]$UpstreamDir
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# pg_failover_slots is a shared-preload library: no .control file, no SQL
# files. Only the DLL is installed.
$dll = Join-Path $UpstreamDir "pg_failover_slots.dll"
if (-not (Test-Path $dll -PathType Leaf)) {
    throw "Required pg_failover_slots file was not found: $dll"
}

Copy-Item $dll (Join-Path $PgRoot "lib/pg_failover_slots.dll") -Force
Write-Host "Installed native pg_failover_slots DLL into $PgRoot\lib"
