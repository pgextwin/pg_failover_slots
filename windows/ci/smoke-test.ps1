[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$PgRoot,
    [Parameter(Mandatory = $true)][int]$PgPort,
    [Parameter(Mandatory = $true)][int]$PostgreSqlMajor
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$data = Join-Path $env:RUNNER_TEMP "pg_failover_slots-$PostgreSqlMajor-data"
$log = Join-Path $env:RUNNER_TEMP "pg_failover_slots-$PostgreSqlMajor.log"

& "$PgRoot/bin/initdb.exe" -D $data -U postgres -A trust --encoding=UTF8 --no-locale
if ($LASTEXITCODE -ne 0) { throw 'initdb failed' }

$started = $false
try {
    & "$PgRoot/bin/pg_ctl.exe" -D $data -l $log -o "-p $PgPort -c listen_addresses=127.0.0.1 -c shared_preload_libraries=pg_failover_slots" start
    if ($LASTEXITCODE -ne 0) { throw 'Preload startup failed' }
    $started = $true

    # The worker registers at consistent state and then sleeps on a
    # standalone primary (no primary connection is attempted unless the
    # server is in recovery). Poll pg_stat_activity until it appears.
    $workerSeen = $false
    for ($i = 0; $i -lt 30; $i++) {
        $count = (& "$PgRoot/bin/psql.exe" -h 127.0.0.1 -p $PgPort -U postgres -d postgres -X -t -A -v ON_ERROR_STOP=1 `
            -c "SELECT count(*) FROM pg_stat_activity WHERE backend_type = 'pg_failover_slots worker'").Trim()
        if ($LASTEXITCODE -ne 0) { throw 'pg_stat_activity query failed' }
        if ([int]$count -ge 1) { $workerSeen = $true; break }
        Start-Sleep -Seconds 1
    }
    if (-not $workerSeen) { throw 'pg_failover_slots worker did not appear in pg_stat_activity' }

    $version = (& "$PgRoot/bin/psql.exe" -h 127.0.0.1 -p $PgPort -U postgres -d postgres -X -t -A -v ON_ERROR_STOP=1 `
        -c "SELECT setting FROM pg_settings WHERE name = 'pg_failover_slots.version'").Trim()
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($version)) { throw 'pg_failover_slots.version GUC not visible' }
    Write-Host "pg_failover_slots.version GUC reports: $version"
    Write-Host "Note: upstream in-code version macro is 1.2.0 while the release is 1.2.1."

    $syncNames = (& "$PgRoot/bin/psql.exe" -h 127.0.0.1 -p $PgPort -U postgres -d postgres -X -t -A -v ON_ERROR_STOP=1 `
        -c "SELECT setting FROM pg_settings WHERE name = 'pg_failover_slots.synchronize_slot_names'").Trim()
    if ($LASTEXITCODE -ne 0 -or $syncNames -ne 'name_like:%') { throw "Unexpected synchronize_slot_names default: $syncNames" }

    & "$PgRoot/bin/psql.exe" -h 127.0.0.1 -p $PgPort -U postgres -d postgres -X -v ON_ERROR_STOP=1 `
        -c 'SET statement_timeout = 30000' `
        -c 'SELECT 1 AS server_alive'
    if ($LASTEXITCODE -ne 0) { throw 'pg_failover_slots SQL smoke failed' }

    $logText = Get-Content $log -Raw
    if ($logText -notmatch 'starting pg_failover_slots replica worker') {
        throw 'Server log is missing the pg_failover_slots worker start line'
    }
    Write-Host "PASS: pg_failover_slots PG$PostgreSqlMajor functional smoke test"
} finally {
    if (Test-Path $log) { Get-Content $log -Tail 80 }
    if ($started) { & "$PgRoot/bin/pg_ctl.exe" -D $data -m immediate stop }
}
