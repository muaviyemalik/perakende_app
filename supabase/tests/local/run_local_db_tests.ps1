# Runs the migration chain and SQL tests against a throwaway local PostgreSQL.
# Requires portable PostgreSQL binaries (default: %LOCALAPPDATA%\Programs\pgsql).
# Usage:  powershell -File supabase\tests\local\run_local_db_tests.ps1
param(
  [string]$PgBin = "$env:LOCALAPPDATA\Programs\pgsql\bin",
  [int]$Port = 54329
)

$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path "$PSScriptRoot\..\..\..").Path
$mig = Join-Path $repo 'supabase\migrations'
$tests = Join-Path $repo 'supabase\tests\database'
$stub = Join-Path $PSScriptRoot 'supabase_stub.sql'
$data = Join-Path $env:TEMP "perakende_pg_$Port"

# NOTICE messages go to stderr; with 'Stop' PowerShell would treat them as
# fatal. Rely on psql's exit code (ON_ERROR_STOP) instead.
$env:PGOPTIONS = '-c client_min_messages=warning'

function Invoke-Psql([string]$db, [string]$file, [switch]$SingleTransaction) {
  $ErrorActionPreference = 'Continue'
  # Supabase CLI applies each migration inside one transaction; mirror that.
  $psqlArgs = @('-X', '-q', '-p', "$Port", '-U', 'postgres', '-d', $db, '-v', 'ON_ERROR_STOP=1')
  if ($SingleTransaction) { $psqlArgs += '--single-transaction' }
  $psqlArgs += @('-f', $file)
  $out = & "$PgBin\psql.exe" $psqlArgs 2>&1 | ForEach-Object { "$_" }
  if ($LASTEXITCODE -ne 0) {
    $err = ($out | Where-Object { $_ -match 'ERROR|DETAIL|HINT|CONTEXT' }) -join "`n"
    throw "FAILED: $(Split-Path $file -Leaf)`n$err"
  }
  $out
}

if (Test-Path $data) { Remove-Item -Recurse -Force $data }
& "$PgBin\initdb.exe" -D $data -U postgres -A trust -E UTF8 --locale=C | Out-Null
# pg_ctl shares its output handles with the server on Windows; if its output is
# piped it never returns. Start it detached and poll until ready instead.
Start-Process -FilePath "$PgBin\pg_ctl.exe" -WindowStyle Hidden `
  -ArgumentList @('-D', "`"$data`"", '-o', "`"-p $Port -c wal_level=logical`"", '-l', "`"$data\server.log`"", 'start')
$ready = $false
for ($i = 0; $i -lt 60 -and -not $ready; $i++) {
  & "$PgBin\pg_isready.exe" -q -p $Port -U postgres
  $ready = ($LASTEXITCODE -eq 0)
  if (-not $ready) { Start-Sleep -Milliseconds 500 }
}
if (-not $ready) { throw 'PostgreSQL did not start.' }

$results = @()
try {
  # Chain A: forward migrations + tests 00, 01, 03.
  # Chain B: baseline + P0 + emergency rollback + test 02.
  $chains = @(
    @{ Name = 'forward';  Migrations = Get-ChildItem $mig -Filter *.sql | Sort-Object Name;
       Tests = @('00_complete_sale.test.sql', '01_p0_authorization.test.sql', '03_password_flag_guard.test.sql') },
    @{ Name = 'rollback'; Migrations = @(
         Get-ChildItem $mig -Filter *.sql | Where-Object { $_.Name -lt '20260822' } | Sort-Object Name
         Get-ChildItem (Join-Path $repo 'supabase\emergency_migrations') -Filter *.sql | Sort-Object Name);
       Tests = @('02_p0_emergency_rollback.test.sql') }
  )

  foreach ($chain in $chains) {
   try {
    $db = "chain_$($chain.Name)"
    & "$PgBin\createdb.exe" -p $Port -U postgres $db
    Invoke-Psql $db $stub | Out-Null
    foreach ($m in $chain.Migrations) {
      $out = Invoke-Psql $db $m.FullName -SingleTransaction
      $version, $name = $m.BaseName -split '_', 2
      & "$PgBin\psql.exe" -X -q -p $Port -U postgres -d $db -c `
        "INSERT INTO supabase_migrations.schema_migrations (version, name) VALUES ('$version', '$name') ON CONFLICT DO NOTHING" | Out-Null
      Write-Host "  [$($chain.Name)] migration OK: $($m.Name)"
    }
    foreach ($t in $chain.Tests) {
      $path = Join-Path $tests $t
      # pgTAP (plan/ok/...) is not shipped with plain PostgreSQL binaries.
      if (Select-String -Path $path -Pattern '\bplan\(' -Quiet) {
        $results += "SKIP  $t (pgTAP gerekli)"
        continue
      }
      try {
        Invoke-Psql $db $path | Out-Null
        $results += "PASS  $t"
      } catch {
        $results += "FAIL  $t"
        $results += ($_.Exception.Message -split "`n" | Select-Object -Skip 1 -First 5 |
          ForEach-Object { "      $_" })
      }
    }
   } catch {
    # A migration in this chain failed: report it and continue with the next chain.
    $results += "FAIL  [$($chain.Name)] $($_.Exception.Message -split "`n" | Select-Object -First 2)"
   }
  }
} finally {
  Start-Process -FilePath "$PgBin\pg_ctl.exe" -WindowStyle Hidden -Wait `
    -ArgumentList @('-D', "`"$data`"", '-m', 'fast', 'stop')
}

$results | ForEach-Object { Write-Host $_ }
if ($results -match '^FAIL') { exit 1 }
