[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$PgRoot,
    [Parameter(Mandatory = $true)][string]$UpstreamDir
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$source = (Resolve-Path $UpstreamDir).Path
$manifest = Get-Content (Join-Path $PSScriptRoot '../../config/extension.json') -Raw | ConvertFrom-Json
$actual = (& git -C $source rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0 -or $actual -cne $manifest.upstream.commit) {
    throw 'Upstream identity mismatch'
}

# pg_failover_slots.c unconditionally includes four POSIX headers
# (dirent.h, sys/file.h, sys/stat.h, unistd.h) that do not exist in MSVC.
# Nothing from them is used anywhere in the file (verified by grep:
# no dirent/flock/stat/sleep/usleep/access/unlink/getpid/fork calls,
# no struct stat / DIR / pid_t / mode_t uses), so guard the block out
# on Windows only. The pinned commit itself is not changed.
$sourceFile = Join-Path $source 'pg_failover_slots.c'
$lines = @(Get-Content -Path $sourceFile)
$idx = [Array]::IndexOf($lines, '#include <dirent.h>')
if ($idx -lt 0 -or $lines[$idx + 1] -ne '#include <sys/file.h>' -or
    $lines[$idx + 2] -ne '#include <sys/stat.h>' -or
    $lines[$idx + 3] -ne '#include <unistd.h>') {
    throw 'POSIX include block not found at expected position in pg_failover_slots.c'
}
$newLines = @()
if ($idx -gt 0) { $newLines += $lines[0..($idx - 1)] }
$newLines += '#ifndef WIN32'
$newLines += $lines[$idx..($idx + 3)]
$newLines += '#endif'
$newLines += $lines[($idx + 4)..($lines.Count - 1)]
Set-Content -Path $sourceFile -Value $newLines -Encoding utf8
Write-Host 'Guarded POSIX includes with #ifndef WIN32'

$vswhere = Join-Path ([Environment]::GetFolderPath('ProgramFilesX86')) 'Microsoft Visual Studio/Installer/vswhere.exe'
if (-not (Test-Path $vswhere)) { throw 'MSVC discovery tool missing' }
$vs = @(& $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath |
    Select-Object -First 1)
if (-not $vs -or -not $vs[0].Trim()) { throw 'MSVC x64 toolchain missing' }
$devCmd = Join-Path $vs[0].Trim() 'Common7/Tools/VsDevCmd.bat'
if (-not (Test-Path $devCmd)) { throw 'VsDevCmd unavailable' }

# _PG_init has no explicit export and pg_failover_slots_main must be
# visible to the background-worker loader on every major, including
# PG15 (same export-list pattern as the pg_wait_sampling PG15 fix).
@(
    'LIBRARY pg_failover_slots'
    'EXPORTS'
    '    _PG_init'
    '    pg_failover_slots_main'
) |
    Set-Content -Path (Join-Path $source 'pg_failover_slots.def') -Encoding ascii

$buildCmd = Join-Path $env:RUNNER_TEMP 'pg-failover-slots-build.cmd'
@"
@echo off
call "$devCmd" -arch=x64 -host_arch=x64 >nul
if errorlevel 1 exit /b %errorlevel%
pushd "$source"
if errorlevel 1 exit /b %errorlevel%
cl /nologo /O2 /MD /DWIN32 /DWIN32_NO_STATUS /D_CRT_SECURE_NO_WARNINGS ^
 /I"$PgRoot\include\server\port\win32_msvc" ^
 /I"$PgRoot\include\server\port\win32" ^
 /I"$PgRoot\include\server" /I"$PgRoot\include" ^
 /c pg_failover_slots.c
if errorlevel 1 exit /b %errorlevel%
link /nologo /DLL /OUT:pg_failover_slots.dll /DEF:pg_failover_slots.def ^
 pg_failover_slots.obj "$PgRoot\lib\postgres.lib" "$PgRoot\lib\libpq.lib"
if errorlevel 1 exit /b %errorlevel%
dumpbin /nologo /exports pg_failover_slots.dll
"@ | Set-Content -Path $buildCmd -Encoding ascii

$buildLog = @(& cmd.exe /d /c $buildCmd 2>&1)
$buildLog | ForEach-Object { Write-Host "$_" }
if ($LASTEXITCODE -ne 0 -or -not (Test-Path (Join-Path $source 'pg_failover_slots.dll'))) {
    throw 'Pinned native MSVC DLL compile/link failed'
}
