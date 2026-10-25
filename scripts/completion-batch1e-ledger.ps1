param([string]$ProjectPath='C:\Projects\gympro-api',[string]$BackupRoot='C:\Projects\gympro-backups')
$ErrorActionPreference='Stop'
$code=0;$verified=$false;$initialized=$false;$stopped=$false
$vars=@('PGPASSWORD','PGOPTIONS','PGSERVICE','PGSERVICEFILE','PGHOST','PGPORT','PGDATABASE','PGUSER','PGPASSFILE','PGSSLMODE')
$saved=@{};foreach($name in $vars){$saved[$name]=[Environment]::GetEnvironmentVariable($name,'Process')}
function Run-Native {
 param([string]$Executable,[string[]]$Arguments,[string]$LogName)
 # Invoke native tools directly: no descendant-tree wait and no inherited output pipes.
 $previousPreference=$ErrorActionPreference
 try {
  $ErrorActionPreference='Continue'
  & $Executable @Arguments
  $nativeExitCode=$LASTEXITCODE
 } finally {$ErrorActionPreference=$previousPreference}
 [IO.File]::WriteAllText(($LogName+'.exit-code.txt'),[string]$nativeExitCode)
 if($null -eq $nativeExitCode -or $nativeExitCode -ne 0){throw ('Command failed with exit '+$nativeExitCode+': '+[IO.Path]::GetFileName($Executable))}
}
try {
 $bin='C:\Program Files\PostgreSQL\18\bin'
 foreach($exe in @('initdb.exe','pg_ctl.exe','createdb.exe','psql.exe')){if(-not(Test-Path (Join-Path $bin $exe))){throw "Required PostgreSQL executable missing: $exe"}}
 $schema=Join-Path $ProjectPath 'sql\baseline-20261016\schema.sql'
 if(-not(Test-Path $schema)){throw 'Verified 1C schema baseline not found.'}
 if((Get-FileHash $schema -Algorithm SHA256).Hash.ToLowerInvariant() -cne '24765f818899517aaaa79e39fe7269aae201bcaf774ea4faeff3a8948327ce06'){throw 'Verified baseline checksum mismatch.'}
 $destination=Join-Path $ProjectPath 'tools\migrations'
 $runnerTarget=Join-Path $ProjectPath 'scripts\completion-batch1e-ledger.ps1'
 if((Test-Path $destination) -or (Test-Path $runnerTarget)){throw 'Batch 1E destination already exists; stop to inspect previous results.'}
 $port=$null
 foreach($candidate in 55432..55462){
  $listener=New-Object Net.Sockets.TcpListener([Net.IPAddress]::Parse('127.0.0.1'),$candidate)
  try{$listener.Start();$port=$candidate;break}catch{}finally{$listener.Stop()}
 }
 if(-not $port){throw 'No unused rehearsal port available between 55432 and 55462.'}
 $suffix=(Get-Date -Format 'yyyyMMddHHmmss')+'_'+[guid]::NewGuid().ToString('N').Substring(0,6)
 $target='gympro_bootstrap_'+$suffix
 $report=Join-Path $BackupRoot ('completion-batch1e-'+$suffix)
 New-Item -ItemType Directory -Path $report -Force | Out-Null
 $cluster=Join-Path $report 'pgdata'
 $payload=Join-Path $report 'payload'
 $zip=Join-Path $report 'payload.zip'
 [IO.File]::WriteAllBytes($zip,[Convert]::FromBase64String('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'))
 Expand-Archive -LiteralPath $zip -DestinationPath $payload
 $manifest=Get-Content (Join-Path $payload 'tool-manifest.json') -Raw | ConvertFrom-Json
 foreach($entry in $manifest.files.PSObject.Properties){if((Get-FileHash (Join-Path $payload $entry.Name) -Algorithm SHA256).Hash.ToLowerInvariant() -cne $entry.Value){throw "Payload checksum mismatch: $($entry.Name)"}}

 $bootstrap=Join-Path $ProjectPath 'sql\bootstrap-prerequisites-20261016'
 $sourceManifest=Get-Content (Join-Path $bootstrap 'manifest.json') -Raw | ConvertFrom-Json
 foreach($entry in $sourceManifest.files.PSObject.Properties){if((Get-FileHash (Join-Path $bootstrap $entry.Name) -Algorithm SHA256).Hash.ToLowerInvariant() -cne $entry.Value){throw "Bootstrap source changed: $($entry.Name)"}}
 foreach($name in @('000-roles.sql','010-permissions.sql','verify-prerequisites.sql','verify-schema.sql')){Copy-Item (Join-Path $bootstrap $name) $payload}
 $node=(Get-Command node.exe -ErrorAction Stop).Source
 if(-not(Test-Path (Join-Path $ProjectPath 'node_modules\pg\package.json'))){throw 'Existing pg package not found.'}
 $approved=[ordered]@{version=1;baseline=[ordered]@{position=1;id='0001_recovered_schema_and_permissions';sources=@()};migrations=@()}
 foreach($relative in @('sql/baseline-20261016/schema.sql','sql/bootstrap-prerequisites-20261016/000-roles.sql','sql/bootstrap-prerequisites-20261016/010-permissions.sql')){
  $approved.baseline.sources+=@{file=$relative;sha256=(Get-FileHash (Join-Path $ProjectPath $relative) -Algorithm SHA256).Hash.ToLowerInvariant()}
 }
 $approved | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $report 'approved-manifest.json') -Encoding UTF8
 # Node JSON parsing expects no BOM.
 [IO.File]::WriteAllText((Join-Path $report 'approved-manifest.json'),($approved | ConvertTo-Json -Depth 8),(New-Object Text.UTF8Encoding($false)))
 $migrationDirectory=Join-Path $ProjectPath 'sql\migrations'
 if(Test-Path $migrationDirectory){throw 'Migration directory already exists; inspect before installing.'}
 foreach($directory in @((Split-Path $schema),$bootstrap)){
  if(Test-Path (Join-Path $directory '.gitattributes')){throw 'Existing SQL byte-preservation attributes require review.'}
 }
 Write-Host 'CHECK: Seven local migration-tool tests' -ForegroundColor Cyan
 Run-Native $node @('--test',(Join-Path $payload 'migrate.test.mjs')) (Join-Path $report 'unit')
 foreach($name in $vars){[Environment]::SetEnvironmentVariable($name,$null,'Process')}
 $env:PGSSLMODE='disable'
 Write-Host 'CHECK: Initialize separate credential-free PostgreSQL cluster' -ForegroundColor Cyan
 Write-Host "Only loopback 127.0.0.1:$port will be used; normal PostgreSQL service is untouched."
 Run-Native (Join-Path $bin 'initdb.exe') @('-D',$cluster,'-U','postgres','-A','trust','--no-locale','-E','UTF8') (Join-Path $report 'initdb')
 $initialized=$true
 Run-Native (Join-Path $bin 'pg_ctl.exe') @('-D',$cluster,'-l',(Join-Path $report 'server.log'),'-o',"-h 127.0.0.1 -p $port",'-w','start') (Join-Path $report 'start')
 Run-Native (Join-Path $bin 'createdb.exe') @('-w','-h','127.0.0.1','-p',"$port",'-U','postgres','--template=template0',$target) (Join-Path $report 'createdb')
 $common=@('-X','-q','-w','-h','127.0.0.1','-p',"$port",'-U','postgres','-d',$target,'-v','ON_ERROR_STOP=1','-v',"target=$target")
 Write-Host 'CHECK: Create 20 roles, reconstruct baseline and seed 39 permissions' -ForegroundColor Cyan
 Run-Native (Join-Path $bin 'psql.exe') ($common+@('-f',(Join-Path $payload '000-roles.sql'))) (Join-Path $report 'roles')
 Run-Native (Join-Path $bin 'psql.exe') ($common+@('--single-transaction','-f',$schema)) (Join-Path $report 'schema')
 Run-Native (Join-Path $bin 'psql.exe') ($common+@('-f',(Join-Path $payload '010-permissions.sql'))) (Join-Path $report 'seed')
 Write-Host 'CHECK: Seed retry and exact role/permission assertions' -ForegroundColor Cyan
 Run-Native (Join-Path $bin 'psql.exe') ($common+@('-f',(Join-Path $payload '010-permissions.sql'))) (Join-Path $report 'seed-retry')
 Run-Native (Join-Path $bin 'psql.exe') ($common+@('-f',(Join-Path $payload 'verify-prerequisites.sql'))) (Join-Path $report 'verify-prerequisites')
 Write-Host 'CHECK: Schema privileges and runtime/auth role boundaries' -ForegroundColor Cyan
 Run-Native (Join-Path $bin 'psql.exe') ($common+@('-f',(Join-Path $payload 'verify-schema.sql'))) (Join-Path $report 'verify-schema')
 Write-Host 'CHECK: Ten isolated migration ledger, rollback and concurrency tests' -ForegroundColor Cyan
 Run-Native $node @((Join-Path $payload 'verify-db.mjs'),$ProjectPath,"$port",$target,$report) (Join-Path $report 'migration-tests')
 $results=Get-Content (Join-Path $report 'migration-results.json') -Raw | ConvertFrom-Json
 if($results.passed -ne $true -or $results.checks.Count -ne 10){throw 'Migration test summary incomplete.'}
 $verified=$true
} catch {
 $code=1
 Write-Host ('FAIL: '+$_.Exception.Message) -ForegroundColor Red
 if($report){Write-Host "Keep reports: $report"}
} finally {
 if($initialized){
  try {
   if(Test-Path (Join-Path $cluster 'postmaster.pid')){Run-Native (Join-Path $bin 'pg_ctl.exe') @('-D',$cluster,'-m','fast','-w','stop') (Join-Path $report 'stop')}
   $stopped=-not(Test-Path (Join-Path $cluster 'postmaster.pid'))
   if(-not $stopped){throw 'Own rehearsal cluster did not stop.'}
  }catch{$code=1;Write-Host ('FAIL: Rehearsal cleanup: '+$_.Exception.Message) -ForegroundColor Red}
 }
 foreach($name in $vars){[Environment]::SetEnvironmentVariable($name,$saved[$name],'Process')}
}
if($code -eq 0 -and $verified -and $stopped){
 try {
  New-Item -ItemType Directory -Path $destination -Force | Out-Null
  foreach($name in @('migrate.mjs','migrate.test.mjs','verify-db.mjs','run.mjs','README.md','tool-manifest.json')){Copy-Item (Join-Path $payload $name) $destination}
  New-Item -ItemType Directory -Path $migrationDirectory -Force | Out-Null
  Copy-Item (Join-Path $report 'approved-manifest.json') (Join-Path $migrationDirectory 'manifest.json')
  [IO.File]::WriteAllText((Join-Path $migrationDirectory '.gitattributes'),"*.sql -text`n",(New-Object Text.UTF8Encoding($false)))
  foreach($directory in @((Split-Path $schema),$bootstrap)){[IO.File]::WriteAllText((Join-Path $directory '.gitattributes'),"*.sql -text`n",(New-Object Text.UTF8Encoding($false)))}
  New-Item -ItemType Directory -Path (Split-Path $runnerTarget) -Force | Out-Null
  Copy-Item -LiteralPath $PSCommandPath -Destination $runnerTarget
  $summary=[ordered]@{batch='1E isolated migration ledger';localTestsPassed=7;databaseChecksPassed=10;baselineRegistrationVerified=$true;immutableRetryVerified=$true;checksumAndHistoryRejectionVerified=$true;failedMigrationRollbackVerified=$true;concurrentApplyOnceVerified=$true;runtimeLedgerAccessDenied=$true;freshBootstrapReverified=$true;rehearsalClusterStopped=$true;workingDatabaseLedgerInstalled=$false;workingDatabaseChanged=$false;productionReady=$false;kbzPayDeferred=$true;verifiedAt=(Get-Date -Format o)}
  $summary | ConvertTo-Json | Set-Content (Join-Path $report 'batch1e-summary.json') -Encoding UTF8
  $docs=Join-Path $ProjectPath 'docs\completion'
  New-Item -ItemType Directory -Path $docs -Force | Out-Null
  Copy-Item (Join-Path $report 'batch1e-summary.json') (Join-Path $docs 'batch1e-summary.json')
  Write-Host 'PASS: Batch 1E migration ledger verified: 7 local tests and 10 database checks passed.' -ForegroundColor Green
  Write-Host 'PASS: Own temporary PostgreSQL cluster stopped; normal cluster/database/roles unchanged.'
  Write-Host 'PENDING: Controlled live baseline adoption, tenant/admin provisioning, clean application installation and production authentication.'
  Write-Host 'No UI change or Git commit. KBZPay deferred.'
  Write-Host "Reports and stopped rehearsal cluster: $report"
 }catch{$code=1;Write-Host ('FAIL: Checkpoint file preservation: '+$_.Exception.Message) -ForegroundColor Red;Write-Host "Keep reports: $report"}
}
exit $code
