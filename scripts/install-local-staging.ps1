param([string]$ProjectPath='C:\Projects\gympro-api',[string]$StagingRoot='C:\Projects\gympro-staging')
$ErrorActionPreference='Stop'
$bin='C:\Program Files\PostgreSQL\18\bin'
$git='C:\Program Files\Git\cmd\git.exe'
$project=(Resolve-Path $ProjectPath).Path
$source=Join-Path $StagingRoot 'source';$cluster=Join-Path $StagingRoot 'pgdata'
$report=Join-Path $StagingRoot 'verification';$payload=Join-Path $StagingRoot 'installer'
$started=$false;$captured=$false;$success=$false;$savedEnv=@{};$originalDirectory=Get-Location
$utf8=New-Object Text.UTF8Encoding($false)
function Run([string]$Exe,[string[]]$Arguments,[string]$Step){
 Write-Host "CHECK: $Step" -ForegroundColor Cyan
 $old=$ErrorActionPreference
 try{$ErrorActionPreference='Continue';& $Exe @Arguments;$code=$LASTEXITCODE}finally{$ErrorActionPreference=$old}
 [IO.File]::WriteAllText((Join-Path $report ($Step+'.exit-code.txt')),[string]$code)
 if($null -eq $code -or $code -ne 0){throw "Step failed: $Step (exit $code)"}
}
function Hex-Secret(){ $bytes=New-Object byte[] 32;$rng=[Security.Cryptography.RandomNumberGenerator]::Create();try{$rng.GetBytes($bytes)}finally{$rng.Dispose()};return ([BitConverter]::ToString($bytes)).Replace('-','').ToLowerInvariant() }
function Protect([string]$Value){$secure=ConvertTo-SecureString -String $Value -AsPlainText -Force;try{return ConvertFrom-SecureString $secure}finally{$secure.Dispose()}}
function Owner-Password(){while($true){$s=Read-Host 'Choose a NEW persistent staging-owner password (12-200 characters)' -AsSecureString;$p=[Runtime.InteropServices.Marshal]::SecureStringToBSTR($s);try{$v=[Runtime.InteropServices.Marshal]::PtrToStringBSTR($p)}finally{[Runtime.InteropServices.Marshal]::ZeroFreeBSTR($p);$s.Dispose()};if($v.Length -ge 12 -and $v.Length -le 200 -and -not [string]::IsNullOrWhiteSpace($v)){return $v};$v=$null;Write-Host 'Use 12-200 characters; do not reuse a real account password.'}}
function Free-Port([int]$First,[int]$Last){foreach($candidate in $First..$Last){$listener=New-Object Net.Sockets.TcpListener([Net.IPAddress]::Parse('127.0.0.1'),$candidate);try{$listener.Start();return $candidate}catch{}finally{$listener.Stop()}};throw 'No isolated API verification port is free.'}
try{
 if(Test-Path -LiteralPath $StagingRoot){throw 'Staging destination already exists. Do not reinstall over it; send its result/error for inspection.'}
 if([IO.Path]::GetFullPath($StagingRoot).TrimEnd('\') -ne 'C:\Projects\gympro-staging'){throw 'This reviewed installer targets only C:\Projects\gympro-staging.'}
 foreach($port in @(3200,55440)){if(@(Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue).Count){throw "Required staging port $port is occupied."}}
 foreach($exe in @('initdb.exe','pg_ctl.exe','createdb.exe','psql.exe')){if(-not(Test-Path (Join-Path $bin $exe))){throw "PostgreSQL tool missing: $exe"}}
 $node=(Get-Command node.exe -ErrorAction Stop).Source;$npm=(Get-Command npm.cmd -ErrorAction Stop).Source;$npx=(Get-Command npx.cmd -ErrorAction Stop).Source
 $version=& $node -p 'process.versions.node';if($LASTEXITCODE -ne 0 -or [int]($version.Split('.')[0]) -ne 24){throw 'Node.js 24 is required.'}
 $pgVersion=& (Join-Path $bin 'pg_ctl.exe') --version;if($LASTEXITCODE -ne 0 -or $pgVersion -notmatch 'PostgreSQL\) 18\.'){throw 'PostgreSQL 18 is required.'}
 & $git -C $project merge-base --is-ancestor 2b7fcc9 HEAD
 if($LASTEXITCODE -ne 0){throw 'Required verified foundation checkpoint is not an ancestor.'}
 $head=& $git -C $project rev-parse HEAD;if($LASTEXITCODE -ne 0){throw 'Cannot identify committed source.'};$head=$head.Trim()
 New-Item -ItemType Directory $StagingRoot | Out-Null
 # Protect all staging files before writing secrets, data or logs.
 $acl=New-Object Security.AccessControl.DirectorySecurity
 $acl.SetAccessRuleProtection($true,$false)
 $sid=[Security.Principal.WindowsIdentity]::GetCurrent().User
 $inherit=[Security.AccessControl.InheritanceFlags]'ContainerInherit,ObjectInherit'
 foreach($identity in @($sid,([Security.Principal.SecurityIdentifier]::new('S-1-5-18')))){
  $rule=[Security.AccessControl.FileSystemAccessRule]::new($identity,[Security.AccessControl.FileSystemRights]::FullControl,$inherit,[Security.AccessControl.PropagationFlags]::None,[Security.AccessControl.AccessControlType]::Allow)
  $acl.AddAccessRule($rule)
 }
 $acl.SetOwner($sid);Set-Acl -LiteralPath $StagingRoot -AclObject $acl
 New-Item -ItemType Directory $report,$payload | Out-Null
 $ownerPassword=Owner-Password
 $adminPassword=Hex-Secret;$appPassword=Hex-Secret;$authPassword=Hex-Secret;$sessionPassword=Hex-Secret
 $secrets=[ordered]@{admin=(Protect $adminPassword);app=(Protect $appPassword);auth=(Protect $authPassword);session=(Protect $sessionPassword)}
 [IO.File]::WriteAllText((Join-Path $StagingRoot 'credentials.dpapi.json'),($secrets|ConvertTo-Json)+"`n",$utf8)
 $zip=Join-Path $payload 'tools.zip'
 [IO.File]::WriteAllBytes($zip,[Convert]::FromBase64String('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'))
 Expand-Archive -LiteralPath $zip -DestinationPath $payload
 foreach($scriptFile in @(Get-ChildItem -LiteralPath $payload -Filter '*.ps1' -File)){
  $tokens=$null;$parseErrors=$null
  $null=[System.Management.Automation.Language.Parser]::ParseFile($scriptFile.FullName,[ref]$tokens,[ref]$parseErrors)
  if($parseErrors.Count){throw ('Staging launcher syntax check failed: '+$scriptFile.Name)}
 }
 Run $node @('--check',(Join-Path $payload 'provision-staging.mjs')) 'node-helper-syntax'
 Run $git @('-C',$project,'archive','--format=zip',('--output='+(Join-Path $StagingRoot 'source.zip')),$head) 'archive-source'
 Expand-Archive -LiteralPath (Join-Path $StagingRoot 'source.zip') -DestinationPath $source
 $envFiles=@(Get-ChildItem $source -Recurse -File -Force | Where-Object{$_.Name -match '^\.env($|\.)' -and $_.Name -notmatch '\.(example|sample|template)$'})
 if($envFiles.Count){throw 'Committed environment configuration detected; inspect locally. No values printed.'}
 if((Test-Path (Join-Path $source 'node_modules')) -or (Test-Path (Join-Path $source 'dist'))){throw 'Archive contains dependency/build output.'}
 $schema=Join-Path $source 'sql\baseline-20261016\schema.sql'
 if((Get-FileHash $schema -Algorithm SHA256).Hash.ToLowerInvariant() -ne '24765f818899517aaaa79e39fe7269aae201bcaf774ea4faeff3a8948327ce06'){throw 'Baseline raw-byte checksum mismatch.'}
 foreach($item in @(Get-ChildItem Env:)){if($item.Name -match '^(GYMPRO_|PG|PRISMA_|.*DATABASE_URL$|NODE_ENV$|NODE_OPTIONS$|PORT$|NPM_CONFIG_IGNORE_SCRIPTS$|NPM_CONFIG_PRODUCTION$|NPM_CONFIG_OMIT$)'){$savedEnv[$item.Name]=$item.Value;[Environment]::SetEnvironmentVariable($item.Name,$null,'Process')}}
 $captured=$true
 $env:DATABASE_URL='postgresql://gympro_app@127.0.0.1:1/gympro_saas';$env:AUTH_DATABASE_URL='postgresql://gympro_auth@127.0.0.1:1/gympro_saas';$env:SESSION_DATABASE_URL='postgresql://gympro_session@127.0.0.1:1/gympro_saas';$env:PGSSLMODE='disable'
 Set-Location $source
 $lockHash=(Get-FileHash 'package-lock.json' -Algorithm SHA256).Hash
 Run $npm @('ci','--no-audit','--no-fund') 'npm-ci'
 if((Get-FileHash 'package-lock.json' -Algorithm SHA256).Hash -ne $lockHash){throw 'Dependency lockfile changed.'}
 Run $npx @('--no-install','prisma','generate') 'prisma-generate'
 Run $npm @('run','build') 'build'
 $stamp=(Get-Date -Format 'yyyyMMddHHmmss')+'_'+[guid]::NewGuid().ToString('N').Substring(0,6)
 $target='gympro_bootstrap_'+$stamp
 # Trust applies only during the isolated loopback bootstrap; scram replaces it before completion.
 Run (Join-Path $bin 'initdb.exe') @('-D',$cluster,'-U','postgres','-A','trust','--no-locale','-E','UTF8') 'initdb'
 $started=$true
 Run (Join-Path $bin 'pg_ctl.exe') @('-D',$cluster,'-l',(Join-Path $StagingRoot 'server.log'),'-o','-h 127.0.0.1 -p 55440','-w','start') 'start'
 Run (Join-Path $bin 'createdb.exe') @('-w','-h','127.0.0.1','-p','55440','-U','postgres','--template=template0',$target) 'createdb'
 $identity=& (Join-Path $bin 'psql.exe') -X -w -h 127.0.0.1 -p 55440 -U postgres -d postgres -At -v ON_ERROR_STOP=1 -c 'SELECT (pg_control_system()).system_identifier::text;'
 if($LASTEXITCODE -ne 0 -or ($identity -join '').Trim() -notmatch '^\d+$'){throw 'Cannot identify new staging cluster.'};$identity=($identity -join '').Trim()
 $meta=[ordered]@{sourceCommit=$head;databasePort=55440;apiPort=3200;systemIdentifier=$identity;postgresBin=$bin;nodeExe=$node;installedBySid=$sid.Value}
 [IO.File]::WriteAllText((Join-Path $StagingRoot 'installation.json'),($meta|ConvertTo-Json)+"`n",$utf8)
 $bootstrapFiles=Join-Path $source 'sql\bootstrap-prerequisites-20261016'
 $common=@('-X','-q','-w','-h','127.0.0.1','-p','55440','-U','postgres','-d',$target,'-v','ON_ERROR_STOP=1','-v',"target=$target")
 Run (Join-Path $bin 'psql.exe') ($common+@('-f',(Join-Path $bootstrapFiles '000-roles.sql'))) 'roles'
 Run (Join-Path $bin 'psql.exe') ($common+@('--single-transaction','-f',$schema)) 'schema'
 foreach($name in @('010-permissions.sql','verify-prerequisites.sql','verify-schema.sql')){Run (Join-Path $bin 'psql.exe') ($common+@('-f',(Join-Path $bootstrapFiles $name))) ([IO.Path]::GetFileNameWithoutExtension($name))}
 $harness=Join-Path $report 'verify-and-demo.mjs'
 Copy-Item (Join-Path $source 'tools\fresh-install\verify-and-demo.mjs') $harness
 Copy-Item (Join-Path $source 'tools\provisioning\provision.mjs') (Join-Path $report 'provision.mjs')
 $env:GYMPRO_1F_PASSWORD=Hex-Secret;$env:GYMPRO_FRESH_NO_BROWSER='1';$apiPort=Free-Port 3151 3181
 try{Run $node @($harness,$source,'55440',$target,"$apiPort",$report) 'full-suite-e2e-http'}finally{$env:GYMPRO_1F_PASSWORD=$null;$env:GYMPRO_FRESH_NO_BROWSER=$null}
 $unit=Get-Content (Join-Path $report 'full-suite-results.json') -Raw|ConvertFrom-Json
 $http=Get-Content (Join-Path $report 'provisioning-results.json') -Raw|ConvertFrom-Json
 if($unit.success -ne $true -or $unit.numPassedTests -lt 1567 -or $unit.numFailedTests -ne 0 -or $unit.numPendingTests -ne 0 -or $http.automaticChecksPassed -ne $true -or $http.automaticCheckCount -ne 46 -or $http.fixtureCleanupPassed -ne $true -or $http.ownApiStopped -ne $true){throw 'Full test/cleanup evidence incomplete.'}
 $env:GYMPRO_STAGE_OWNER_PASSWORD=$ownerPassword;$env:GYMPRO_STAGE_ADMIN_PASSWORD=$adminPassword;$env:GYMPRO_STAGE_APP_PASSWORD=$appPassword;$env:GYMPRO_STAGE_AUTH_PASSWORD=$authPassword;$env:GYMPRO_STAGE_SESSION_PASSWORD=$sessionPassword
 try{Run $node @((Join-Path $payload 'provision-staging.mjs'),$source,$StagingRoot) 'persistent-owner-and-db-passwords'}finally{foreach($key in @('GYMPRO_STAGE_ADMIN_PASSWORD','GYMPRO_STAGE_APP_PASSWORD','GYMPRO_STAGE_AUTH_PASSWORD','GYMPRO_STAGE_SESSION_PASSWORD')){[Environment]::SetEnvironmentVariable($key,$null,'Process')}}
 $hba=@'
# Local staging only. Generated credentials are encrypted for the installing Windows user.
host all all 127.0.0.1/32 scram-sha-256
host all all ::1/128 reject
'@
 [IO.File]::WriteAllText((Join-Path $cluster 'pg_hba.conf'),$hba+"`n",$utf8)
 Run (Join-Path $bin 'pg_ctl.exe') @('-D',$cluster,'-m','fast','-w','stop') 'secure-stop'
 $started=$false
 Copy-Item (Join-Path $payload 'Start-GymPro-Local-Staging.ps1') (Join-Path $StagingRoot 'Start-GymPro-Local-Staging.ps1')
 # Execute in this process so the secret is never a command-line argument.
 & (Join-Path $StagingRoot 'Start-GymPro-Local-Staging.ps1') -StagingRoot $StagingRoot -VerifyOnly
 if(-not(Test-Path (Join-Path $StagingRoot 'startup-verification.json'))){throw 'Secure startup verification evidence missing.'}
 $env:GYMPRO_STAGE_OWNER_PASSWORD=$null;$ownerPassword=$null
 $record=[ordered]@{sourceCommit=$head;fullSuitePassed=$true;passedTests=$unit.numPassedTests;rootE2ePassed=$true;httpDatabaseChecks=46;testFixturesRemoved=$true;persistentStagingOwnerCreated=$true;passwordProtectedDatabaseVerified=$true;credentialsEncryptedWithWindowsDpapi=$true;apiAndClusterStopped=$true;manualBrowserAcceptance='pending';workingDatabaseChanged=$false;stagingIsInternetHosted=$false;kbzPayDeferred=$true;createdAt=(Get-Date -Format o)}
 [IO.File]::WriteAllText((Join-Path $StagingRoot 'ready.json'),($record|ConvertTo-Json)+"`n",$utf8)
 $success=$true
}catch{Write-Host ('FAIL: '+$_.Exception.Message) -ForegroundColor Red;Write-Host "Keep staging folder for diagnosis: $StagingRoot";Write-Host 'Do not reinstall or delete it blindly.'}finally{
 if($started -and (Test-Path (Join-Path $cluster 'postmaster.pid'))){& (Join-Path $bin 'pg_ctl.exe') -D $cluster -m fast -w stop;if($LASTEXITCODE -ne 0){$success=$false;Write-Host 'FAIL: Owned staging cluster stop failed.'}}
 if($captured){foreach($item in @(Get-ChildItem Env:)){if($item.Name -match '^(GYMPRO_|PG|PRISMA_|.*DATABASE_URL$|NODE_ENV$|NODE_OPTIONS$|PORT$|NPM_CONFIG_IGNORE_SCRIPTS$|NPM_CONFIG_PRODUCTION$|NPM_CONFIG_OMIT$)'){[Environment]::SetEnvironmentVariable($item.Name,$null,'Process')}};foreach($key in $savedEnv.Keys){[Environment]::SetEnvironmentVariable($key,$savedEnv[$key],'Process')}}
 $ownerPassword=$null;$adminPassword=$null;$appPassword=$null;$authPassword=$null;$sessionPassword=$null
 Set-Location $originalDirectory
}
if(-not $success){exit 1}
Write-Host 'PASS: Local staging installed; full suite, root e2e, 46 checks and secure startup passed.' -ForegroundColor Green
Write-Host 'PASS: Test fixtures removed; persistent staging owner retained; staging API and cluster stopped.'
Write-Host 'PENDING: Browser acceptance. Finance/POS permissions require a separate explicit staging grant.'
Write-Host 'Start staging: powershell -NoProfile -ExecutionPolicy Bypass -File C:\Projects\gympro-staging\Start-GymPro-Local-Staging.ps1'
Write-Host "Private staging folder and reports: $StagingRoot"
Write-Host 'No working database/.env changes, Git commit, public deployment, real email or KBZPay operation.'
