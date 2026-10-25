param([string]$ProjectPath='C:\Projects\gympro-api',[string]$BackupRoot='C:\Projects\gympro-backups')
$ErrorActionPreference='Stop'
$code=0;$verified=$false;$initialized=$false;$stopped=$false
$vars=@('GYMPRO_1F_PASSWORD','PGPASSWORD','PGOPTIONS','PGSERVICE','PGSERVICEFILE','PGHOST','PGPORT','PGDATABASE','PGUSER','PGPASSFILE','PGSSLMODE')
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
 $destination=Join-Path $ProjectPath 'tools\provisioning'
 $runnerTarget=Join-Path $ProjectPath 'scripts\completion-batch1f-provisioning.ps1'
 if((Test-Path $destination) -or (Test-Path $runnerTarget)){throw 'Batch 1F destination already exists; stop to inspect previous results.'}
 $port=$null
 foreach($candidate in 55432..55462){
  $listener=New-Object Net.Sockets.TcpListener([Net.IPAddress]::Parse('127.0.0.1'),$candidate)
  try{$listener.Start();$port=$candidate;break}catch{}finally{$listener.Stop()}
 }
 if(-not $port){throw 'No unused rehearsal port available between 55432 and 55462.'}
 $suffix=(Get-Date -Format 'yyyyMMddHHmmss')+'_'+[guid]::NewGuid().ToString('N').Substring(0,6)
 $target='gympro_bootstrap_'+$suffix
 $report=Join-Path $BackupRoot ('completion-batch1f-'+$suffix)
 New-Item -ItemType Directory -Path $report -Force | Out-Null
 $cluster=Join-Path $report 'pgdata'
 $payload=Join-Path $report 'payload'
 $zip=Join-Path $report 'payload.zip'
 [IO.File]::WriteAllBytes($zip,[Convert]::FromBase64String('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'))
 Expand-Archive -LiteralPath $zip -DestinationPath $payload
 $manifest=Get-Content (Join-Path $payload 'payload-manifest.json') -Raw | ConvertFrom-Json
 foreach($entry in $manifest.files.PSObject.Properties){if((Get-FileHash (Join-Path $payload $entry.Name) -Algorithm SHA256).Hash.ToLowerInvariant() -cne $entry.Value){throw "Payload checksum mismatch: $($entry.Name)"}}

 $node=(Get-Command node.exe -ErrorAction Stop).Source
 $npm=(Get-Command npm.cmd -ErrorAction Stop).Source
 foreach($package in @('pg','argon2')){if(-not(Test-Path (Join-Path $ProjectPath ('node_modules\'+$package+'\package.json')))){throw "Required installed package missing: $package"}}
 $bootstrap=Join-Path $ProjectPath 'sql\bootstrap-prerequisites-20261016'
 $sourceManifest=Get-Content (Join-Path $bootstrap 'manifest.json') -Raw | ConvertFrom-Json
 foreach($entry in $sourceManifest.files.PSObject.Properties){if((Get-FileHash (Join-Path $bootstrap $entry.Name) -Algorithm SHA256).Hash.ToLowerInvariant() -cne $entry.Value){throw "Bootstrap source changed: $($entry.Name)"}}
 foreach($name in @('000-roles.sql','010-permissions.sql','verify-prerequisites.sql','verify-schema.sql')){Copy-Item (Join-Path $bootstrap $name) $payload}
 $approvedPath=Join-Path $ProjectPath 'sql\migrations\manifest.json'
 $approved=Get-Content $approvedPath -Raw | ConvertFrom-Json
 if($approved.version -ne 1 -or $approved.migrations.Count -ne 0){throw 'Expected verified 1E manifest with no later migration; stop to inspect current source.'}
 if(-not(Test-Path (Join-Path $ProjectPath 'tools\migrations\migrate.mjs'))){throw 'Verified 1E migration tool missing.'}
 $migrationPath=Join-Path $ProjectPath 'sql\migrations\0002_tenant_provisioning.sql'
 if(Test-Path $migrationPath){throw 'Provisioning migration already exists; stop rather than overwrite.'}
 Copy-Item $approvedPath (Join-Path $report 'manifest.before.json')
 New-Item -ItemType Directory -Path $destination -Force | Out-Null
 foreach($name in @('provision.mjs','provision.test.mjs','verify-and-demo.mjs','README.md','payload-manifest.json')){Copy-Item (Join-Path $payload $name) $destination}
 Copy-Item (Join-Path $payload '0002_tenant_provisioning.sql') $migrationPath
 $approved.migrations=@([ordered]@{position=2;id='0002_tenant_provisioning';file='sql/migrations/0002_tenant_provisioning.sql';sha256=(Get-FileHash $migrationPath -Algorithm SHA256).Hash.ToLowerInvariant()})
 [IO.File]::WriteAllText($approvedPath,($approved | ConvertTo-Json -Depth 10),(New-Object Text.UTF8Encoding($false)))
 Write-Host 'CHECK: Seven provisioning validation tests' -ForegroundColor Cyan
 Run-Native $node @('--test',(Join-Path $payload 'provision.test.mjs')) (Join-Path $report 'unit')
 Write-Host 'CHECK: Build existing API (no UI source changes)' -ForegroundColor Cyan
 Push-Location $ProjectPath
 try{Run-Native $npm @('run','build') (Join-Path $report 'build')}finally{Pop-Location}
 $apiPort=$null
 foreach($candidate in 3151..3181){
  $apiListener=New-Object Net.Sockets.TcpListener([Net.IPAddress]::Parse('127.0.0.1'),$candidate)
  try{$apiListener.Start();$apiPort=$candidate;break}catch{}finally{$apiListener.Stop()}
 }
 if(-not $apiPort){throw 'No unused isolated API port available.'}
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
 Write-Host 'CHECK: Provisioning, real API login and isolated browser demonstration' -ForegroundColor Cyan
 while($true){
  $secure=Read-Host 'Choose a NEW rehearsal password (12 to 256 characters)' -AsSecureString
  $ptr=[Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
  try{$plain=[Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)}finally{[Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr);$secure.Dispose()}
  $count=[regex]::Matches($plain,'[\uD800-\uDBFF][\uDC00-\uDFFF]|[\s\S]').Count
  if($plain.Length -ge 12 -and $plain.Length -le 256 -and $count -ge 12 -and -not [string]::IsNullOrWhiteSpace($plain)){
   [Environment]::SetEnvironmentVariable('GYMPRO_1F_PASSWORD',$plain,'Process');$plain=$null;break
  }
  $plain=$null
  Write-Host 'Password must contain 12 to 256 characters. Please enter another separate rehearsal password.' -ForegroundColor Yellow
 }
 try{Run-Native $node @((Join-Path $payload 'verify-and-demo.mjs'),$ProjectPath,"$port",$target,"$apiPort",$report) (Join-Path $report 'provisioning-demo')}finally{[Environment]::SetEnvironmentVariable('GYMPRO_1F_PASSWORD',$null,'Process')}
 $results=Get-Content (Join-Path $report 'provisioning-results.json') -Raw | ConvertFrom-Json
 if($results.automaticChecksPassed -ne $true -or $results.automaticCheckCount -ne 17 -or $results.fixtureCleanupPassed -ne $true -or $results.ownApiStopped -ne $true){throw 'Provisioning verification or cleanup summary incomplete.'}
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
  New-Item -ItemType Directory -Path (Split-Path $runnerTarget) -Force | Out-Null
  Copy-Item -LiteralPath $PSCommandPath -Destination $runnerTarget
  $summary=[ordered]@{batch='1F isolated tenant/admin provisioning';localTestsPassed=7;databaseAndHttpChecksPassed=17;atomicProvisioningVerified=$true;idempotentReceiptVerified=$true;passwordHashVerified=$true;duplicateRollbackVerified=$true;restrictedInitialPermissionsVerified=$true;concurrentRetryVerified=$true;newOwnerHttpLoginVerified=$true;logoutRevocationVerified=$true;migration0002AppliedInRehearsal=$true;fixtureCleanupPassed=$true;ownApiStopped=$true;rehearsalClusterStopped=$true;manualBrowserAcceptance='pending-user-confirmation';workingDatabaseChanged=$false;productionAuthenticationChanged=$false;cleanMachineApplicationInstallVerified=$false;kbzPayDeferred=$true;verifiedAt=(Get-Date -Format o)}
  $summary | ConvertTo-Json | Set-Content (Join-Path $report 'batch1f-summary.json') -Encoding UTF8
  $docs=Join-Path $ProjectPath 'docs\completion'
  New-Item -ItemType Directory -Path $docs -Force | Out-Null
  Copy-Item (Join-Path $report 'batch1f-summary.json') (Join-Path $docs 'batch1f-summary.json')
  Write-Host 'PASS: Batch 1F provisioning: 7 local tests and 17 database/HTTP checks passed; fixture cleanup completed.' -ForegroundColor Green
  Write-Host 'PASS: Own temporary PostgreSQL cluster stopped; normal cluster/database/roles unchanged.'
  Write-Host 'PENDING: Browser acceptance confirmation, controlled real-environment provisioning, clean application installation and production authentication.'
  Write-Host 'Existing operator UI was used against the isolated API; no UI source changes or Git commit. KBZPay deferred.'
  Write-Host "Reports and stopped rehearsal cluster: $report"
 }catch{$code=1;Write-Host ('FAIL: Checkpoint file preservation: '+$_.Exception.Message) -ForegroundColor Red;Write-Host "Keep reports: $report"}
}
exit $code
