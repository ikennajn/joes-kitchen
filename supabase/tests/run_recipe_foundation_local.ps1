$ErrorActionPreference = 'Stop'

$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$testRoot = Join-Path $repositoryRoot '.local-migration-test'
$testSupabase = Join-Path $testRoot 'supabase'
$testMigrations = Join-Path $testSupabase 'migrations'
$dockerDirectory = Join-Path $repositoryRoot '.tools'
$dockerExecutable = Join-Path $dockerDirectory 'docker.exe'
$supabaseExecutable = (Get-Command supabase -ErrorAction Stop).Source

$env:PATH = "$dockerDirectory;$env:PATH"
$env:DO_NOT_TRACK = '1'

if (-not (Test-Path $dockerExecutable)) {
  throw 'Expected the disposable Docker CLI at .tools\docker.exe.'
}

$originalErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$dockerServerVersion = & $dockerExecutable version --format '{{.Server.Version}}' 2>$null
$dockerVersionExitCode = $LASTEXITCODE
$ErrorActionPreference = $originalErrorActionPreference
if ($dockerVersionExitCode -ne 0 -or -not $dockerServerVersion) {
  throw 'Docker Desktop Linux engine is not running. Open Docker Desktop, select Linux containers, and wait for Engine running before retrying.'
}
Write-Host "Docker engine ready: $dockerServerVersion"

if (Test-Path $testRoot) {
  $resolvedTestRoot = (Resolve-Path -LiteralPath $testRoot).Path
  if (
    (Split-Path $resolvedTestRoot -Leaf) -ne '.local-migration-test' -or
    (Split-Path $resolvedTestRoot -Parent) -ne $repositoryRoot
  ) {
    throw "Refusing to remove unexpected test path: $resolvedTestRoot"
  }
  Write-Host "Removing stale disposable test state at $resolvedTestRoot"
  Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force
}

New-Item -ItemType Directory -Force -Path $testRoot | Out-Null
& $supabaseExecutable init --workdir $testRoot
New-Item -ItemType Directory -Force -Path $testMigrations | Out-Null

Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'legacy_schema_fixture.sql') `
  -Destination (Join-Path $testMigrations '20260816000000_legacy_schema_fixture.sql')

Get-ChildItem -LiteralPath (Join-Path $repositoryRoot 'supabase\migrations') -Filter '*.sql' |
  Sort-Object Name |
  ForEach-Object {
    Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $testMigrations $_.Name)
  }

Write-Host 'Starting disposable Supabase stack and applying migrations...'
& $supabaseExecutable start --workdir $testRoot `
  --exclude gotrue,realtime,storage-api,imgproxy,kong,mailpit,postgrest,postgres-meta,studio,edge-runtime,logflare,vector,supavisor

if ($LASTEXITCODE -ne 0) {
  throw 'Supabase start or migration replay failed.'
}

$projectIdLine = Select-String -LiteralPath (Join-Path $testSupabase 'config.toml') `
  -Pattern '^project_id\s*=\s*"([^"]+)"' | Select-Object -First 1
if (-not $projectIdLine) {
  throw 'Could not determine the disposable Supabase project ID.'
}
$containerName = 'supabase_db_' + $projectIdLine.Matches[0].Groups[1].Value
$verificationPath = Join-Path $PSScriptRoot 'recipe_foundation_verification.sql'

Write-Host 'Running read-only Recipe Builder verification queries...'
Get-Content -Raw -LiteralPath $verificationPath |
  & $dockerExecutable exec -i $containerName `
    psql -v ON_ERROR_STOP=1 -U postgres -d postgres

if ($LASTEXITCODE -ne 0) {
  throw 'Recipe Builder verification queries failed.'
}

Write-Host 'Local Recipe Builder migration test passed.'
Write-Host "Disposable stack remains at $testRoot for inspection."
