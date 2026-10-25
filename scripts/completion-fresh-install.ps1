param(
 [string]$ProjectPath='C:\Projects\gympro-api',
 [string]$BackupRoot='C:\Projects\gympro-backups',
 [string]$PostgresBin='C:\Program Files\PostgreSQL\18\bin',
 [switch]$NoBrowser
)
$ErrorActionPreference='Stop'
$project=(Resolve-Path -LiteralPath $ProjectPath).Path
$git=(Get-Command git.exe -ErrorAction SilentlyContinue).Source
if(-not $git){$git='C:\Program Files\Git\cmd\git.exe'}
$bin=$PostgresBin
$stamp=(Get-Date -Format 'yyyyMMddHHmmss')+'_'+[guid]::NewGuid().ToString('N').Substring(0,6)
$report=Join-Path $BackupRoot ('fresh-install-'+$stamp);$clean=Join-Path $report 'source';$cluster=Join-Path $report 'pgdata'
$success=$false;$started=$false;$savedEnv=@{};$envCaptured=$false
function Run([string]$Exe,[string[]]$Arguments,[string]$Step){
 Write-Host "CHECK: $Step" -ForegroundColor Cyan
 $old=$ErrorActionPreference
 try{$ErrorActionPreference='Continue';& $Exe @Arguments;$code=$LASTEXITCODE}finally{$ErrorActionPreference=$old}
 [IO.File]::WriteAllText((Join-Path $report ($Step+'.exit-code.txt')),[string]$code)
 if($null -eq $code -or $code -ne 0){throw "Step failed: $Step (exit $code)"}
}
function Free-Port([int]$First,[int]$Last){foreach($candidate in $First..$Last){$listener=New-Object Net.Sockets.TcpListener([Net.IPAddress]::Parse('127.0.0.1'),$candidate);try{$listener.Start();return $candidate}catch{}finally{$listener.Stop()}};throw 'No free isolated port.'}
function Temporary-Password(){while($true){$secure=Read-Host 'Choose a separate temporary account password (12-200 characters)' -AsSecureString;$ptr=[Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure);try{$v=[Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)}finally{[Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr);$secure.Dispose()};if($v.Length -ge 12 -and $v.Length -le 200 -and -not [string]::IsNullOrWhiteSpace($v)){return $v};$v=$null;Write-Host 'Use 12 to 200 characters.'}}
try{
 foreach($exe in @('initdb.exe','pg_ctl.exe','createdb.exe','psql.exe')){if(-not(Test-Path (Join-Path $bin $exe))){throw "Missing PostgreSQL tool: $exe"}}
 $node=(Get-Command node.exe -ErrorAction Stop).Source;$npm=(Get-Command npm.cmd -ErrorAction Stop).Source;$npx=(Get-Command npx.cmd -ErrorAction Stop).Source
 $nodeVersion=& $node -p 'process.versions.node';if($LASTEXITCODE -ne 0 -or [int]($nodeVersion.Split('.')[0]) -ne 24){throw 'This rehearsal targets Node.js 24.'}
 $pgVersion=& (Join-Path $bin 'pg_ctl.exe') --version;if($LASTEXITCODE -ne 0 -or $pgVersion -notmatch 'PostgreSQL\) 18\.'){throw 'PostgreSQL 18 tools are required.'}
 New-Item -ItemType Directory -Path $report | Out-Null
 & $git -C $project merge-base --is-ancestor 68b9c76 HEAD
 if($LASTEXITCODE -ne 0){throw 'Required checkpoint 68b9c76 is not an ancestor.'}
 $head=& $git -C $project rev-parse HEAD;if($LASTEXITCODE -ne 0){throw 'Cannot determine committed source.'}
 $head.Trim() | Set-Content (Join-Path $report 'source-commit.txt') -Encoding ASCII
 $archive=Join-Path $report 'committed-source.zip'
 Run $git @('-C',$project,'archive','--format=zip',('--output='+$archive),$head.Trim()) 'archive-committed-source'
 Expand-Archive -LiteralPath $archive -DestinationPath $clean
 if((Test-Path (Join-Path $clean 'node_modules')) -or (Test-Path (Join-Path $clean 'dist'))){throw 'Archive unexpectedly contains dependencies or build output.'}
 $envFiles=@(Get-ChildItem -LiteralPath $clean -Recurse -File -Force | Where-Object {$_.Name -match '^\.env($|\.)' -and $_.Name -notmatch '\.(example|sample|template)$'})
 if($envFiles.Count){throw 'Committed environment file detected; inspect locally. No values printed.'}
 foreach($name in @('package-lock.json','prisma\schema.prisma','src\main.ts','tools\provisioning\provision.mjs','sql\migrations\manifest.json')){if(-not(Test-Path (Join-Path $clean $name))){throw "Committed input missing: $name"}}
 $schema=Join-Path $clean 'sql\baseline-20261016\schema.sql'
 if((Get-FileHash $schema -Algorithm SHA256).Hash.ToLowerInvariant() -ne '24765f818899517aaaa79e39fe7269aae201bcaf774ea4faeff3a8948327ce06'){throw 'Baseline raw-byte checksum mismatch.'}
 $bootstrapFiles=Join-Path $clean 'sql\bootstrap-prerequisites-20261016'
 $manifest=Get-Content (Join-Path $bootstrapFiles 'manifest.json') -Raw | ConvertFrom-Json
 foreach($entry in @($manifest.files.PSObject.Properties | Where-Object {$_.Name -ne 'README.md'})){if((Get-FileHash (Join-Path $bootstrapFiles $entry.Name) -Algorithm SHA256).Hash.ToLowerInvariant() -ne $entry.Value){throw "Bootstrap checksum mismatch: $($entry.Name)"}}
 $lockBefore=(Get-FileHash (Join-Path $clean 'package-lock.json') -Algorithm SHA256).Hash
 $envCaptured=$true
 foreach($item in @(Get-ChildItem Env:)){if($item.Name -match '^(GYMPRO_|PG|PRISMA_|.*DATABASE_URL$|NODE_ENV$|NODE_OPTIONS$|PORT$|NPM_CONFIG_IGNORE_SCRIPTS$|NPM_CONFIG_PRODUCTION$|NPM_CONFIG_OMIT$)'){$savedEnv[$item.Name]=$item.Value;[Environment]::SetEnvironmentVariable($item.Name,$null,'Process')}}
 $env:DATABASE_URL='postgresql://gympro_app@127.0.0.1:1/gympro_saas';$env:AUTH_DATABASE_URL='postgresql://gympro_auth@127.0.0.1:1/gympro_saas';$env:SESSION_DATABASE_URL='postgresql://gympro_session@127.0.0.1:1/gympro_saas';$env:PGSSLMODE='disable'
 $payload=Join-Path $report 'payload';$zip=Join-Path $report 'payload.zip'
 New-Item -ItemType Directory -Path $payload -Force | Out-Null
 $committedHarness = Join-Path $clean 'tools\fresh-install\verify-and-demo.mjs'
 if (-not (Test-Path -LiteralPath $committedHarness)) {
     throw 'Committed test harness is missing from the source archive.'
 }
 Copy-Item -LiteralPath $committedHarness -Destination (Join-Path $payload 'verify-and-demo.mjs')
 if ((Get-FileHash -LiteralPath $committedHarness -Algorithm SHA256).Hash -ne
     (Get-FileHash -LiteralPath (Join-Path $payload 'verify-and-demo.mjs') -Algorithm SHA256).Hash) {
     throw 'Committed harness copy checksum mismatch.'
 }
 Copy-Item (Join-Path $clean 'tools\provisioning\provision.mjs') (Join-Path $payload 'provision.mjs')
 Set-Location $clean
 Write-Host 'Installing locked dependencies into the NEW source folder. npm may download packages.'
 Run $npm @('ci','--no-audit','--no-fund') 'npm-ci'
 if((Get-FileHash (Join-Path $clean 'package-lock.json') -Algorithm SHA256).Hash -ne $lockBefore){throw 'Lockfile changed during install.'}
 Run $npx @('--no-install','prisma','generate') 'prisma-generate'
 Run $npm @('run','build') 'build'
 $port=Free-Port 55432 55462;$apiPort=Free-Port 3151 3181;$target='gympro_bootstrap_'+$stamp
 Run (Join-Path $bin 'initdb.exe') @('-D',$cluster,'-U','postgres','-A','trust','--no-locale','-E','UTF8') 'initdb'
 $started=$true
 Run (Join-Path $bin 'pg_ctl.exe') @('-D',$cluster,'-l',(Join-Path $report 'server.log'),'-o',"-h 127.0.0.1 -p $port",'-w','start') 'start'
 Run (Join-Path $bin 'createdb.exe') @('-w','-h','127.0.0.1','-p',"$port",'-U','postgres','--template=template0',$target) 'createdb'
 $common=@('-X','-q','-w','-h','127.0.0.1','-p',"$port",'-U','postgres','-d',$target,'-v','ON_ERROR_STOP=1','-v',"target=$target")
 Run (Join-Path $bin 'psql.exe') ($common+@('-f',(Join-Path $bootstrapFiles '000-roles.sql'))) 'roles'
 Run (Join-Path $bin 'psql.exe') ($common+@('--single-transaction','-f',$schema)) 'schema'
 foreach($name in @('010-permissions.sql','verify-prerequisites.sql','verify-schema.sql')){Run (Join-Path $bin 'psql.exe') ($common+@('-f',(Join-Path $bootstrapFiles $name))) ([IO.Path]::GetFileNameWithoutExtension($name))}
 if($NoBrowser){$env:GYMPRO_1F_PASSWORD=[guid]::NewGuid().ToString('N')+[guid]::NewGuid().ToString('N');$env:GYMPRO_FRESH_NO_BROWSER='1'}else{$env:GYMPRO_1F_PASSWORD=Temporary-Password}
 try{Run $node @((Join-Path $payload 'verify-and-demo.mjs'),$clean,"$port",$target,"$apiPort",$report) 'full-tests-e2e-and-http'}finally{$env:GYMPRO_1F_PASSWORD=$null;$env:GYMPRO_FRESH_NO_BROWSER=$null}
 $r=Get-Content (Join-Path $report 'provisioning-results.json') -Raw | ConvertFrom-Json
 $unit=Get-Content (Join-Path $report 'full-suite-results.json') -Raw | ConvertFrom-Json
 $e2e=Get-Content (Join-Path $report 'root-e2e-results.json') -Raw | ConvertFrom-Json
 if($r.automaticChecksPassed -ne $true -or $r.automaticCheckCount -ne 46 -or $r.fixtureCleanupPassed -ne $true -or $r.ownApiStopped -ne $true -or $unit.success -ne $true -or $unit.numPendingTests -ne 0 -or $e2e.success -ne $true){throw 'Test/cleanup evidence incomplete.'}
 $success=$true
}catch{Write-Host ('FAIL: '+$_.Exception.Message) -ForegroundColor Red}finally{
 $env:GYMPRO_1F_PASSWORD=$null;$env:GYMPRO_FRESH_NO_BROWSER=$null
 if($started -and (Test-Path (Join-Path $cluster 'postmaster.pid'))){try{Run (Join-Path $bin 'pg_ctl.exe') @('-D',$cluster,'-m','fast','-w','stop') 'stop'}catch{$success=$false;Write-Host ('FAIL: '+$_.Exception.Message) -ForegroundColor Red}}
 if($envCaptured){
 foreach($item in @(Get-ChildItem Env:)){if($item.Name -match '^(GYMPRO_|PG|PRISMA_|.*DATABASE_URL$|NODE_ENV$|NODE_OPTIONS$|PORT$|NPM_CONFIG_IGNORE_SCRIPTS$|NPM_CONFIG_PRODUCTION$|NPM_CONFIG_OMIT$)'){[Environment]::SetEnvironmentVariable($item.Name,$null,'Process')}}
 foreach($key in $savedEnv.Keys){[Environment]::SetEnvironmentVariable($key,$savedEnv[$key],'Process')}
 }
 Set-Location $project
}
if($success){try{
 $saved=Join-Path $project 'tools\fresh-install';New-Item -ItemType Directory $saved -Force | Out-Null
 # Keep the working harness unchanged; execute only the archived committed harness.
 $runnerDestination = Join-Path $project 'scripts\completion-fresh-install.ps1'
 if ([IO.Path]::GetFullPath($PSCommandPath) -ne [IO.Path]::GetFullPath($runnerDestination)) {
     Copy-Item -LiteralPath $PSCommandPath -Destination $runnerDestination -Force
 }
 [ordered]@{scope='Fresh committed-source installation on current Windows machine';sourceCommit=$head.Trim();gitArchiveUsed=$true;environmentFilesCopied=$false;oldDependenciesCopied=$false;lockfileUnchanged=$true;npmCiPassed=$true;prismaGenerationPassed=$true;buildPassed=$true;freshClusterBootstrapPassed=$true;fullSuitePassed=$true;passedTests=$unit.numPassedTests;skippedTests=$unit.numPendingTests;rootE2ePassed=$true;httpDatabaseChecks=46;fixturesRemoved=$true;ownApiStopped=$true;clusterStopped=$true;noBrowser=[bool]$NoBrowser;manualBrowserAcceptance='pending-user-confirmation';differentMachineVerified=$false;hostedCiVerified=$false;stagingDeploymentVerified=$false;workingDatabaseChanged=$false;productionAppSourceChanged=$false;productionFeaturesEnabled=$false;kbzPayDeferred=$true;reportFolder=$report;verifiedAt=(Get-Date -Format o)} | ConvertTo-Json | Set-Content (Join-Path $report 'fresh-install-summary.json') -Encoding UTF8
 Copy-Item (Join-Path $report 'fresh-install-summary.json') (Join-Path $project 'docs\completion\fresh-install-summary.json') -Force
 Write-Host 'PASS: New committed-source extraction, npm ci, Prisma generation, build, full tests, root e2e and 46 HTTP/database checks passed.' -ForegroundColor Green
 Write-Host 'PASS: Temporary fixtures removed; own API and new isolated PostgreSQL cluster stopped.'
 Write-Host 'PENDING: User browser acceptance, a genuinely different Windows machine, hosted CI and staging deployment.'
 Write-Host 'Reusable noninteractive entry: scripts\completion-fresh-install.ps1 -NoBrowser (requires Windows, Node 24 and PostgreSQL 18).'
}catch{$success=$false;Write-Host ('FAIL: '+$_.Exception.Message) -ForegroundColor Red}}
Write-Host "Reports and fresh source: $report"
Write-Host 'No working database/.env/authentication change, Git commit, hosted CI claim or KBZPay operation.'
if(-not $success){exit 1}
