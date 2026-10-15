param([string]$ProjectPath='C:\Projects\gympro-api',[string]$BackupRoot='C:\Projects\gympro-backups',[switch]$CleanupOnly,[string]$DemoFolder)
$ErrorActionPreference='Stop';$apiProcess=$null;$admin=$null;$manager=$null;$folder=$null;$exitCode=0;$cleanupNeeded=$false
$names=@('NODE_ENV','PORT','PGPASSWORD','GYMPRO_DEV_SESSION_WRITES','GYMPRO_DEV_SESSION_CONFIRM','GYMPRO_D8_PROJECT','GYMPRO_D8_DEMO_FOLDER','GYMPRO_D8_DEMO_PASSWORD','GYMPRO_B8_DB_PASSWORD');$previous=@{};foreach($name in $names){$previous[$name]=[Environment]::GetEnvironmentVariable($name,'Process')}
try{
 Set-Location $ProjectPath;$node=(Get-Command node.exe).Source
 if(-not $CleanupOnly){$listener=[System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback,3000);try{$listener.Start()}catch{throw 'Stop the existing Nest/operator server with Ctrl+C before starting this demo.'}finally{$listener.Stop()}}
 $admin=[System.Management.Automation.PSCredential]::new('postgres',(Read-Host 'Local PostgreSQL postgres password' -AsSecureString))
 if($CleanupOnly){if(-not $DemoFolder){throw 'Provide -DemoFolder from the earlier demo output.'};$folder=(Resolve-Path $DemoFolder).Path}else{$folder=Join-Path $BackupRoot ('d8-inventory-demo-'+(Get-Date -Format 'yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N').Substring(0,6));New-Item -ItemType Directory -Path $folder -Force | Out-Null}
 $env:GYMPRO_D8_PROJECT=$ProjectPath;$env:GYMPRO_D8_DEMO_FOLDER=$folder;$env:PGPASSWORD=$admin.GetNetworkCredential().Password;$cleanupNeeded=$true
 if(-not $CleanupOnly){
  $manager=[System.Management.Automation.PSCredential]::new('inventory manager',(Read-Host 'Choose temporary inventory manager password (at least 10 characters)' -AsSecureString));$env:GYMPRO_D8_DEMO_PASSWORD=$manager.GetNetworkCredential().Password
  & $node .\scripts\d8-ui-fixture.mjs setup;if($LASTEXITCODE -ne 0){throw 'Temporary POS fixture setup failed.'}
  Remove-Item Env:\PGPASSWORD,Env:\GYMPRO_D8_DEMO_PASSWORD,Env:\GYMPRO_B8_DB_PASSWORD -ErrorAction SilentlyContinue;$manager=$null
  $env:NODE_ENV='development';$env:PORT='3000';$env:GYMPRO_DEV_SESSION_WRITES='enabled';$env:GYMPRO_DEV_SESSION_CONFIRM='I_UNDERSTAND_THE_RISK'
  $entry=@('dist\src\main.js','dist\main.js')|Where-Object{Test-Path $_}|Select-Object -First 1;if(-not $entry){throw 'Build the API first.'};$entry=(Resolve-Path $entry).Path
  $apiProcess=Start-Process -FilePath $node -ArgumentList ('"'+$entry+'"') -WorkingDirectory $ProjectPath -RedirectStandardOutput (Join-Path $folder 'api-output.txt') -RedirectStandardError (Join-Path $folder 'api-error.txt') -PassThru
  $ready=$false;for($i=0;$i -lt 45;$i++){if($apiProcess.HasExited){throw "API startup failed. Review $folder\api-error.txt"};try{Invoke-WebRequest 'http://127.0.0.1:3000/inventory' -UseBasicParsing -TimeoutSec 2 | Out-Null;$ready=$true;break}catch{Start-Sleep -Milliseconds 1000}};if(-not $ready){throw 'API startup timed out.'}
  $fixture=Get-Content (Join-Path $folder 'fixture.json') -Raw|ConvertFrom-Json
  Write-Host "`nManager email: $($fixture.email)" -ForegroundColor Cyan
  Write-Host ('Open: http://127.0.0.1:3000/inventory?tenant='+$fixture.tenant+'&branch='+$fixture.branch+'&email='+$fixture.email+'&skuPrefix='+$fixture.tag+'_') -ForegroundColor Cyan
  Write-Host 'Use the inventory manager password you just chose. Create a draft product, activate it, receive 10 units, then remove 2 units with a reason.'
  Write-Host "Demo folder: $folder"
  Read-Host 'Keep this window open. Press Enter AFTER finishing the browser test to stop the API and remove test records' | Out-Null
 }
}catch{$exitCode=1;Write-Host ('FAIL: '+$_.Exception.Message) -ForegroundColor Red}
finally{
 if($apiProcess -and -not $apiProcess.HasExited){Stop-Process -Id $apiProcess.Id -Force -ErrorAction SilentlyContinue}
 if($cleanupNeeded -and $admin){try{$env:PGPASSWORD=$admin.GetNetworkCredential().Password;& $node .\scripts\d8-ui-fixture.mjs cleanup;if($LASTEXITCODE -ne 0){throw 'Fixture cleanup failed.'}}catch{$exitCode=1;Write-Host "Cleanup incomplete. Retain demo folder: $folder" -ForegroundColor Red;Write-Host $_.Exception.Message}}
 foreach($name in $names){[Environment]::SetEnvironmentVariable($name,$previous[$name],'Process')};$admin=$null;$manager=$null
}
exit $exitCode
