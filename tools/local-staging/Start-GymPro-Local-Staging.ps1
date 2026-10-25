param([string]$StagingRoot='C:\Projects\gympro-staging',[switch]$VerifyOnly)
$ErrorActionPreference='Stop'
$started=$false;$api=$null;$savedEnv=@{}
$meta=Get-Content (Join-Path $StagingRoot 'installation.json') -Raw | ConvertFrom-Json
if($meta.installedBySid -ne [Security.Principal.WindowsIdentity]::GetCurrent().User.Value){throw 'Start staging using the Windows account that installed it.'}
$ready=Join-Path $StagingRoot 'ready.json'
if(-not $VerifyOnly -and -not(Test-Path $ready)){throw 'Staging installation is incomplete; do not start it manually.'}
$cluster=Join-Path $StagingRoot 'pgdata';$source=Join-Path $StagingRoot 'source'
if($meta.databasePort -ne 55440 -or $meta.apiPort -ne 3200 -or $meta.sourceCommit -notmatch '^[a-f0-9]{40}$'){throw 'Unexpected staging configuration.'}
$bin=$meta.postgresBin;$node=$meta.nodeExe
function Reveal([string]$Cipher){$s=ConvertTo-SecureString $Cipher;$p=[Runtime.InteropServices.Marshal]::SecureStringToBSTR($s);try{return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($p)}finally{[Runtime.InteropServices.Marshal]::ZeroFreeBSTR($p);$s.Dispose()}}
function Call-Stage([string]$Path,[string]$Method='GET',$Body=$null,[string]$Token=''){
 $headers=@{};if($Token){$headers.Authorization='Bearer '+$Token}
 $requestParams=@{Uri=('http://127.0.0.1:3200'+$Path);Method=$Method;Headers=$headers;UseBasicParsing=$true;TimeoutSec=10;ErrorAction='Stop'}
 if($null -ne $Body){$requestParams.ContentType='application/json';$requestParams.Body=($Body|ConvertTo-Json -Compress)}
 try{$r=Invoke-WebRequest @requestParams;return @{status=[int]$r.StatusCode;body=$r.Content}}catch{if($_.Exception.Response){return @{status=[int]$_.Exception.Response.StatusCode;body=''}};throw}
}
try{
 foreach($item in @(Get-ChildItem Env:)){if($item.Name -match '^(GYMPRO_|PG|PRISMA_|.*DATABASE_URL$|NODE_ENV$|NODE_OPTIONS$|PORT$)'){$savedEnv[$item.Name]=$item.Value;[Environment]::SetEnvironmentVariable($item.Name,$null,'Process')}}
 if(@(Get-NetTCPConnection -LocalPort 3200 -State Listen -ErrorAction SilentlyContinue).Count){throw 'Staging API port 3200 is already occupied.'}
 if(@(Get-NetTCPConnection -LocalPort 55440 -State Listen -ErrorAction SilentlyContinue).Count){throw 'Staging database port 55440 is already occupied. Stop its existing staging window first.'}
 $credentials=Get-Content (Join-Path $StagingRoot 'credentials.dpapi.json') -Raw | ConvertFrom-Json
 $started=$true
 & (Join-Path $bin 'pg_ctl.exe') -D $cluster -l (Join-Path $StagingRoot 'server.log') -o '-h 127.0.0.1 -p 55440' -w start
 if($LASTEXITCODE -ne 0){throw 'Owned staging cluster failed to start.'}
 $env:PGPASSWORD=Reveal $credentials.admin
 $identity=& (Join-Path $bin 'psql.exe') -X -w -h 127.0.0.1 -p 55440 -U postgres -d postgres -At -v ON_ERROR_STOP=1 -c 'SELECT (pg_control_system()).system_identifier::text;'
 if($LASTEXITCODE -ne 0 -or ($identity -join '').Trim() -ne $meta.systemIdentifier){throw 'Staging cluster identity/password verification failed.'}
 $env:PGPASSWORD=$null
 $env:NODE_ENV='production';$env:GYMPRO_SESSION_MODE='persistent';$env:PORT='3200';$env:PGSSLMODE='disable'
 $env:DATABASE_URL='postgresql://gympro_app:'+(Reveal $credentials.app)+'@127.0.0.1:55440/gympro_saas'
 $env:AUTH_DATABASE_URL='postgresql://gympro_auth:'+(Reveal $credentials.auth)+'@127.0.0.1:55440/gympro_saas'
 $env:SESSION_DATABASE_URL='postgresql://gympro_session:'+(Reveal $credentials.session)+'@127.0.0.1:55440/gympro_saas'
 $entry=@('dist\src\main.js','dist\main.js') | ForEach-Object{Join-Path $source $_} | Where-Object{Test-Path $_} | Select-Object -First 1
 if(-not $entry){throw 'Built staging entry is missing.'}
 $api=Start-Process -FilePath $node -ArgumentList @('"'+$entry+'"') -WorkingDirectory $source -RedirectStandardOutput (Join-Path $StagingRoot 'api.log') -RedirectStandardError (Join-Path $StagingRoot 'api-errors.log') -PassThru
 $listening=$false
 for($i=0;$i -lt 60;$i++){
  if($api.HasExited){throw 'Staging API stopped during startup. Inspect its private api-errors.log.'}
  try{if((Call-Stage '/auth/me').status -eq 401){$listening=$true;break}}catch{}
  Start-Sleep -Milliseconds 500
 }
 if(-not $listening){throw 'Staging API readiness timed out.'}
 $listeners=@(Get-NetTCPConnection -LocalPort 3200 -State Listen -ErrorAction Stop)
 if($listeners.Count -ne 1 -or $listeners[0].LocalAddress -ne '127.0.0.1' -or $listeners[0].OwningProcess -ne $api.Id){throw 'Staging API listener ownership/binding mismatch.'}
 $owner=Get-Content (Join-Path $StagingRoot 'owner.json') -Raw | ConvertFrom-Json
 if($VerifyOnly){
  $checks=@()
  foreach($route in @('/operator','/payments','/inventory','/pos','/account/sessions')){
   if((Call-Stage $route).status -ne 200){throw "Staging UI asset failed: $route"};$checks+=$route
  }
  $password=$savedEnv['GYMPRO_STAGE_OWNER_PASSWORD'];if(-not $password){throw 'Installer password missing for staging login verification.'}
  $login=Call-Stage '/auth/login' 'POST' @{tenantId=$owner.tenantId;email=$owner.email;password=$password}
  if($login.status -ne 200){throw "Staging owner login failed: HTTP $($login.status)"}
  $token=($login.body|ConvertFrom-Json).accessToken
  if(-not $token -or (Call-Stage '/auth/me' 'GET' $null $token).status -ne 200){throw 'Staging owner identity check failed.'}
  $lookup='/tenants/'+$owner.tenantId+'/branches/'+$owner.branchId+'/members/lookup?q=demo'
  if((Call-Stage $lookup 'GET' $null $token).status -ne 200){throw 'Staging owner branch lookup failed.'}
  if((Call-Stage '/auth/logout' 'POST' $null $token).status -ne 204){throw 'Staging logout failed.'}
  if((Call-Stage '/auth/me' 'GET' $null $token).status -ne 401){throw 'Staging logout revocation failed.'}
  $token=$null;$password=$null
  [ordered]@{restrictedCredentialStartupPassed=$true;loopbackApiBindingPassed=$true;ownerLoginPassed=$true;ownerLookupPassed=$true;logoutRevocationPassed=$true;uiRoutes=$checks;manualBrowserAcceptance='pending'}|ConvertTo-Json -Depth 5|Set-Content (Join-Path $StagingRoot 'startup-verification.json') -Encoding UTF8
  Write-Host 'PASS: Password-protected staging startup, UI assets, owner login, lookup and logout verified.'
 }else{
  Write-Host "`nLOCAL STAGING: http://127.0.0.1:3200/operator" -ForegroundColor Cyan
  Write-Host "Tenant ID: $($owner.tenantId)"
  Write-Host "Branch ID: $($owner.branchId)"
  Write-Host "Email: $($owner.email)"
  Write-Host 'Password: the separate staging-owner password you chose during installation.'
  Write-Host 'Initial owner has eight basic permissions. Finance/POS rights are not implicitly assigned.'
  Write-Host 'Keep this terminal open. Staging records persist after stopping.'
  Read-Host 'Press Enter when finished to stop this staging API and cluster' | Out-Null
 }
}finally{
 try{
 if($api -and -not $api.HasExited){Stop-Process -Id $api.Id -ErrorAction SilentlyContinue;Start-Sleep -Milliseconds 500;if(-not $api.HasExited){throw 'Owned staging API did not stop.'}}
 if($started -and (Test-Path (Join-Path $cluster 'postmaster.pid'))){& (Join-Path $bin 'pg_ctl.exe') -D $cluster -m fast -w stop;if($LASTEXITCODE -ne 0){throw 'Owned staging cluster did not stop.'}}
 }finally{
 foreach($item in @(Get-ChildItem Env:)){if($item.Name -match '^(GYMPRO_|PG|PRISMA_|.*DATABASE_URL$|NODE_ENV$|NODE_OPTIONS$|PORT$)'){[Environment]::SetEnvironmentVariable($item.Name,$null,'Process')}}
 foreach($key in $savedEnv.Keys){[Environment]::SetEnvironmentVariable($key,$savedEnv[$key],'Process')}
 }
}
Write-Host 'PASS: Staging API and cluster stopped; staging records preserved.'
