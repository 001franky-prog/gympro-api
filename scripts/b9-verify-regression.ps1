param([string]$ProjectPath='C:\Projects\gympro-api',[string]$BackupRoot='C:\Projects\gympro-backups',[string]$PostgresBin='C:\Program Files\PostgreSQL\18\bin')
$ErrorActionPreference='Stop'
$gymProApiProcess=$null
$gymProExitCode=1
$gymProOriginalPgPassword=$env:PGPASSWORD
function Invoke-GymProCommand([string]$Command,[string[]]$Arguments) {
    & $Command @Arguments
    if($LASTEXITCODE -ne 0){throw "Command failed ($LASTEXITCODE): $Command"}
}
try {
    Set-Location -LiteralPath $ProjectPath
    if(-not (Test-Path .\node_modules\pg)){throw 'Project dependencies are missing. Run npm.cmd ci first.'}
    if(Get-NetTCPConnection -LocalPort 3000 -State Listen -ErrorAction SilentlyContinue){throw 'Port 3000 is occupied. Press Ctrl+C in your existing API window, then rerun this command.'}
    if(-not(Test-Path .\scripts\b8-verify-complete-api.mjs)){throw 'Verified B8 HTTP script is missing.'}
    if(-not(Test-Path .\vitest.config.e2e.ts)){throw 'End-to-end test configuration is missing.'}
    $gymProTimestamp=Get-Date -Format 'yyyyMMdd-HHmmss'
    $gymProRunDirectory=Join-Path $BackupRoot "b9-verification-$gymProTimestamp"
    New-Item -ItemType Directory -Path $gymProRunDirectory -Force | Out-Null
    Start-Transcript -Path (Join-Path $gymProRunDirectory 'runner-report.txt') | Out-Null
    Write-Progress -Activity 'Gym Pro B9 verification' -Status 'Preflight complete' -PercentComplete 10
    $gymProSecret=Read-Host 'Local PostgreSQL postgres password' -AsSecureString
    $gymProCredential=[System.Management.Automation.PSCredential]::new('postgres',$gymProSecret)
    $env:PGPASSWORD=$gymProCredential.GetNetworkCredential().Password
    $env:GYMPRO_B8_DB_PASSWORD=$env:PGPASSWORD
    Invoke-GymProCommand (Join-Path $PostgresBin 'pg_dump.exe') @('-h','127.0.0.1','-p','5432','-U','postgres','-w','-d','gympro_saas','-Fc','-f',(Join-Path $gymProRunDirectory 'before-b9.dump'))
    Invoke-GymProCommand (Join-Path $PostgresBin 'pg_restore.exe') @('--list',(Join-Path $gymProRunDirectory 'before-b9.dump')) | Out-Null
    Remove-Item Env:\PGPASSWORD,Env:\GYMPRO_B8_DB_PASSWORD -ErrorAction SilentlyContinue
    Write-Progress -Activity 'Gym Pro B9 verification' -Status 'Building and running full regression' -PercentComplete 25
    Invoke-GymProCommand 'npm.cmd' @('run','build')
    Invoke-GymProCommand 'npx.cmd' @('--no-install','vitest','run','--reporter=default','--reporter=json',('--outputFile='+ (Join-Path $gymProRunDirectory 'unit-results.json')))
    Invoke-GymProCommand 'npx.cmd' @('--no-install','vitest','run','--config','vitest.config.e2e.ts','--reporter=default','--reporter=json',('--outputFile='+ (Join-Path $gymProRunDirectory 'e2e-results.json')))
    foreach($gymProReport in @('unit-results.json','e2e-results.json')){
        $gymProResults=Get-Content (Join-Path $gymProRunDirectory $gymProReport) -Raw | ConvertFrom-Json
        if($gymProResults.numTotalTests -lt 1 -or $gymProResults.numFailedTests -ne 0 -or $gymProResults.success -ne $true){throw "Invalid or unsuccessful test report: $gymProReport"}
    }
    $gymProApiEntry=@('dist\src\main.js','dist\main.js') | Where-Object {Test-Path -LiteralPath $_} | Select-Object -First 1
    if(-not $gymProApiEntry){throw 'Compiled API entry point was not found.'}
    $env:NODE_ENV='development'
    $env:GYMPRO_DEV_SESSION_WRITES='enabled'
    $env:GYMPRO_DEV_SESSION_CONFIRM='I_UNDERSTAND_THE_RISK'
    # The API child does not need the administrator password.
    Remove-Item Env:\PGPASSWORD -ErrorAction SilentlyContinue
    Remove-Item Env:\GYMPRO_B8_DB_PASSWORD -ErrorAction SilentlyContinue
    $gymProApiProcess=Start-Process -FilePath (Get-Command node.exe).Source -ArgumentList $gymProApiEntry -WorkingDirectory $ProjectPath -RedirectStandardOutput (Join-Path $gymProRunDirectory 'api-output.txt') -RedirectStandardError (Join-Path $gymProRunDirectory 'api-error.txt') -PassThru
    $gymProReady=$false
    for($gymProAttempt=0;$gymProAttempt -lt 45;$gymProAttempt++){
        if($gymProApiProcess.HasExited){throw "API exited during startup. Review $gymProRunDirectory\api-error.txt"}
        try {Invoke-WebRequest -Uri 'http://127.0.0.1:3000/' -UseBasicParsing -TimeoutSec 2 | Out-Null;$gymProReady=$true;break}catch{Start-Sleep -Milliseconds 1000}
    }
    if(-not $gymProReady){throw 'API did not become ready within 45 seconds.'}
    Write-Progress -Activity 'Gym Pro B9 verification' -Status 'Running combined branch HTTP verification' -PercentComplete 70
    $env:GYMPRO_B8_DB_PASSWORD=$gymProCredential.GetNetworkCredential().Password
    $env:GYMPRO_B8_BASE_URL='http://127.0.0.1:3000'
    Invoke-GymProCommand 'node.exe' @((Join-Path $ProjectPath 'scripts\b8-verify-complete-api.mjs'))
    $gymProGit='C:\Program Files\Git\cmd\git.exe'
    $gymProCommit=$null
    if(Test-Path -LiteralPath $gymProGit){
        $gymProCommit= & $gymProGit rev-parse HEAD
        if($LASTEXITCODE -ne 0){throw 'Could not record Git checkpoint.'}
    }
    [ordered]@{
        checkpoint='B9 regression batch'
        completedAt=(Get-Date).ToUniversalTime().ToString('o')
        commit=$gymProCommit
        buildPassed=$true
        fullTestSuitePassed=$true
        e2eSuitePassed=$true
        branchHttpVerificationPassed=$true
        limitations='Concurrency, performance, and fresh-server restore are not verified by this batch.'
    } | ConvertTo-Json | Set-Content (Join-Path $gymProRunDirectory 'b9-summary.json') -Encoding UTF8
    $gymProExitCode=0
    Write-Progress -Activity 'Gym Pro B9 verification' -Status 'Completed' -PercentComplete 100
    Write-Host 'PASS: B9 regression batch completed: build, full test suite, end-to-end suite, and live branch HTTP verification.' -ForegroundColor Green
    Write-Host "Backup and report folder: $gymProRunDirectory"
    Write-Host 'No application source edits, SQL installation, Git commit or external publication was performed.'
}catch{
    Write-Host "FAIL: $($_.Exception.Message)" -ForegroundColor Red
    if($gymProRunDirectory){Write-Host "Keep this backup/report folder for recovery: $gymProRunDirectory"}
    Write-Host 'Verification stopped at the first failure. Review the report folder; no application code or SQL installation was performed.'
}finally{
    if($gymProApiProcess -and -not $gymProApiProcess.HasExited){Stop-Process -Id $gymProApiProcess.Id -ErrorAction SilentlyContinue}
    Remove-Item Env:\GYMPRO_B8_DB_PASSWORD,Env:\GYMPRO_B8_BASE_URL,Env:\GYMPRO_DEV_SESSION_WRITES,Env:\GYMPRO_DEV_SESSION_CONFIRM -ErrorAction SilentlyContinue
    if($null -eq $gymProOriginalPgPassword){Remove-Item Env:\PGPASSWORD -ErrorAction SilentlyContinue}else{$env:PGPASSWORD=$gymProOriginalPgPassword}
    $gymProCredential=$null;$gymProSecret=$null
    Write-Progress -Activity 'Gym Pro B9 verification' -Completed
    try{Stop-Transcript | Out-Null}catch{}
}
exit $gymProExitCode
