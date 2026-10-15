param([string]$ProjectPath='C:\Projects\gympro-api')
$ErrorActionPreference='Stop'
Set-Location -LiteralPath $ProjectPath
if(Get-NetTCPConnection -LocalPort 3000 -State Listen -ErrorAction SilentlyContinue){throw 'Port 3000 is occupied. Stop the existing API first.'}
$gymProPriorPgPassword=$env:PGPASSWORD
try {
 Remove-Item Env:\PGPASSWORD -ErrorAction SilentlyContinue
 $env:NODE_ENV='development'
 $env:GYMPRO_DEV_SESSION_WRITES='enabled'
 $env:GYMPRO_DEV_SESSION_CONFIRM='I_UNDERSTAND_THE_RISK'
 Write-Host 'Open http://127.0.0.1:3000/operator after Nest starts.' -ForegroundColor Cyan
 Write-Host 'Press Ctrl+C to stop the local development API.'
 npm.cmd run start:dev
 if($LASTEXITCODE -ne 0){throw 'Development API stopped with an error.'}
} finally {
 Remove-Item Env:\GYMPRO_DEV_SESSION_WRITES,Env:\GYMPRO_DEV_SESSION_CONFIRM -ErrorAction SilentlyContinue
 if($null -eq $gymProPriorPgPassword){Remove-Item Env:\PGPASSWORD -ErrorAction SilentlyContinue}else{$env:PGPASSWORD=$gymProPriorPgPassword}
}
