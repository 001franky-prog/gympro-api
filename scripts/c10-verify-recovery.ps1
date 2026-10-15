param(
    [string]$ProjectPath='C:\Projects\gympro-api',
    [string]$BackupRoot='C:\Projects\gympro-backups',
    [string]$PostgresBin='C:\Program Files\PostgreSQL\18\bin',
    [string]$GitPath='C:\Program Files\Git\cmd\git.exe'
)
$ErrorActionPreference='Stop'
$gymProExitCode=1
$gymProOriginalPgPassword=$env:PGPASSWORD
$gymProTestCreated=$false
$gymProTestRemoved=$false
function Invoke-GymProNative([string]$Command,[string[]]$Arguments){
    & $Command @Arguments
    if($LASTEXITCODE -ne 0){throw "Command failed ($LASTEXITCODE): $Command"}
}
try {
    Set-Location -LiteralPath $ProjectPath
    foreach($exe in @($GitPath,(Join-Path $PostgresBin 'pg_dump.exe'),(Join-Path $PostgresBin 'pg_dumpall.exe'),(Join-Path $PostgresBin 'pg_restore.exe'),(Join-Path $PostgresBin 'psql.exe'),(Join-Path $PostgresBin 'createdb.exe'),(Join-Path $PostgresBin 'dropdb.exe'))){
        if(-not(Test-Path -LiteralPath $exe)){throw "Required executable missing: $exe"}
    }
    $gymProCommit=& $GitPath rev-parse HEAD
    if($LASTEXITCODE -ne 0){throw 'Git checkpoint lookup failed.'}
    $gymProCommitSubject=& $GitPath log -1 --format=%s
    if($LASTEXITCODE -ne 0){throw 'Git checkpoint title lookup failed.'}
    # Capture the committed checkpoint without silently omitting changes to current feature sources.
    $gymProTrackedChanges=@(& $GitPath status --porcelain --untracked-files=no)
    if($LASTEXITCODE -ne 0){throw 'Git status check failed.'}
    if($gymProTrackedChanges.Count -gt 0){$gymProTrackedChanges | ForEach-Object {Write-Host $_};throw 'Tracked changes remain. Commit or inspect them before creating the recovery checkpoint.'}
    foreach($required in @('src/attendance/attendance-read.service.ts','src/cards/member-card.service.ts','src/member-lookup/member-lookup.service.ts','sql/c9-install-attendance-summary.sql','web/operator/app.js')){
        & $GitPath ls-files --error-unmatch -- $required | Out-Null
        if($LASTEXITCODE -ne 0){throw "Required C9 checkpoint file is not tracked: $required"}
    }
    $gymProStamp=Get-Date -Format 'yyyyMMdd-HHmmss'
    $gymProRun=Join-Path $BackupRoot "c10-recovery-$gymProStamp"
    New-Item -ItemType Directory -Path $gymProRun | Out-Null
    Start-Transcript -Path (Join-Path $gymProRun 'recovery-report.txt') | Out-Null
    Write-Progress -Activity 'Gym Pro C10 recovery checkpoint' -Status 'Backing up committed source' -PercentComplete 10
    $gymProBundle=Join-Path $gymProRun 'gympro-source.bundle'
    Invoke-GymProNative $GitPath @('bundle','create',$gymProBundle,'--all')
    Invoke-GymProNative $GitPath @('bundle','verify',$gymProBundle)
    $gymProSecret=Read-Host 'Local PostgreSQL postgres password' -AsSecureString
    $gymProCredential=[System.Management.Automation.PSCredential]::new('postgres',$gymProSecret)
    $env:PGPASSWORD=$gymProCredential.GetNetworkCredential().Password
    $gymProDump=Join-Path $gymProRun 'gympro_saas.dump'
    $gymProRoles=Join-Path $gymProRun 'roles-without-passwords.sql'
    Write-Progress -Activity 'Gym Pro C10 recovery checkpoint' -Status 'Creating database and role backups' -PercentComplete 30
    Invoke-GymProNative (Join-Path $PostgresBin 'pg_dump.exe') @('-w','-h','127.0.0.1','-p','5432','-U','postgres','-d','gympro_saas','-Fc','-f',$gymProDump)
    $gymProArchive=& (Join-Path $PostgresBin 'pg_restore.exe') --list $gymProDump
    if($LASTEXITCODE -ne 0){throw 'Database archive listing failed.'}
    $gymProArchive | Set-Content -LiteralPath (Join-Path $gymProRun 'archive-list.txt') -Encoding UTF8
    Invoke-GymProNative (Join-Path $PostgresBin 'pg_dumpall.exe') @('-w','-h','127.0.0.1','-p','5432','-U','postgres','-l','gympro_saas','--roles-only','--no-role-passwords','-f',$gymProRoles)
    $gymProTestDb='gympro_restore_c10_'+(Get-Date -Format 'yyyyMMdd_HHmmss')+'_'+([guid]::NewGuid().ToString('N').Substring(0,6))
    Write-Host "Temporary restore database: $gymProTestDb"
    Write-Progress -Activity 'Gym Pro C10 recovery checkpoint' -Status 'Restoring into an isolated test database' -PercentComplete 50
    Invoke-GymProNative (Join-Path $PostgresBin 'createdb.exe') @('-w','-h','127.0.0.1','-p','5432','-U','postgres','--template=template0',$gymProTestDb)
    $gymProTestCreated=$true
    Invoke-GymProNative (Join-Path $PostgresBin 'pg_restore.exe') @('-w','-h','127.0.0.1','-p','5432','-U','postgres','--exit-on-error','--single-transaction','-d',$gymProTestDb,$gymProDump)
    $gymProSql=@'
\set ON_ERROR_STOP on
\pset pager off
BEGIN READ ONLY;
DO $$
DECLARE v_table text;v_function text;v_owner record;
BEGIN
 IF current_database()='gympro_saas' OR left(current_database(),19)<>'gympro_restore_c10_' THEN
  RAISE EXCEPTION 'Verification must run only in the temporary restore database';
 END IF;
 FOREACH v_table IN ARRAY ARRAY[
  'app.members','app.membership_plans','app.plan_prices','app.member_subscriptions',
  'app.subscription_renewals','app.subscription_suspensions','app.subscription_expirations',
  'app.member_blacklist_events','app.subscription_foc_grants','app.membership_promotions',
  'app.membership_discounts','app.attendance_visits','app.attendance_checkouts',
  'app.member_cards','app.member_card_events','app.card_scan_receipts'
 ] LOOP
  IF NOT EXISTS(SELECT 1 FROM pg_class WHERE oid=to_regclass(v_table) AND relrowsecurity AND relforcerowsecurity) THEN
   RAISE EXCEPTION 'Missing restored table or forced RLS: %',v_table;
  END IF;
  IF has_table_privilege('gympro_app',v_table,'SELECT,INSERT,UPDATE,DELETE') THEN
   RAISE EXCEPTION 'Unexpected direct runtime access: %',v_table;
  END IF;
 END LOOP;
 RAISE NOTICE 'PASS: Membership, attendance and card tables restored with forced RLS and no direct runtime CRUD.';
 FOREACH v_function IN ARRAY ARRAY[
  'security.register_member(bytea,uuid,uuid,text,text,text)',
  'security.check_in_member(bytea,uuid,uuid,uuid,uuid)',
  'security.check_out_member(bytea,uuid,uuid,uuid,uuid)',
  'security.read_branch_attendance(bytea,uuid,uuid,boolean,date,date,integer,timestamptz,uuid)',
  'security.change_member_card(bytea,uuid,uuid,uuid,text,uuid,text)',
  'security.read_member_card(bytea,uuid,uuid,uuid)',
  'security.scan_member_card(bytea,uuid,uuid,uuid,uuid)',
  'security.search_branch_members(bytea,uuid,uuid,text,integer,uuid)',
  'security.find_member_card(bytea,uuid,uuid,uuid)',
  'security.summarize_branch_attendance(bytea,uuid,uuid,date)'
 ] LOOP
  SELECT r.* INTO v_owner FROM pg_proc p JOIN pg_roles r ON r.oid=p.proowner
   WHERE p.oid=to_regprocedure(v_function) AND p.prosecdef;
  IF NOT FOUND THEN RAISE EXCEPTION 'Missing restored security-definer function: %',v_function;END IF;
  IF v_owner.rolcanlogin OR v_owner.rolsuper OR v_owner.rolbypassrls OR v_owner.rolcreatedb OR v_owner.rolcreaterole OR v_owner.rolinherit THEN
   RAISE EXCEPTION 'Unsafe restored function owner: %',v_function;
  END IF;
  IF NOT has_function_privilege('gympro_app',v_function,'EXECUTE') THEN RAISE EXCEPTION 'Runtime function access missing: %',v_function;END IF;
  IF EXISTS(SELECT 1 FROM pg_proc p CROSS JOIN LATERAL aclexplode(coalesce(p.proacl,acldefault('f',p.proowner))) a WHERE p.oid=to_regprocedure(v_function) AND a.grantee=0 AND a.privilege_type='EXECUTE') THEN
   RAISE EXCEPTION 'Unexpected public execution: %',v_function;
  END IF;
 END LOOP;
 RAISE NOTICE 'PASS: Core functions and C7/C8/C9 functions restored with restricted owners and runtime execution.';
 IF (SELECT count(*) FROM app.members WHERE tenant_id='d0d732f6-a08d-4c68-bb8c-20ad3f98ab0b' AND id IN('3113ab9f-8edd-41f4-afe6-c8f03e291f89','41f45bd6-114c-4241-9be0-0a949dc5f2b6'))<>2 THEN
  RAISE EXCEPTION 'Expected demo members missing from restore';
 END IF;
 IF NOT EXISTS(SELECT 1 FROM app.member_subscriptions WHERE tenant_id='d0d732f6-a08d-4c68-bb8c-20ad3f98ab0b' AND id='8a28fa97-e41f-4053-be61-8162ff3d387d') THEN RAISE EXCEPTION 'Demo subscription missing';END IF;
 IF EXISTS(SELECT 1 FROM app.members WHERE id='6c600001-1111-4444-8888-000000000001') THEN RAISE EXCEPTION 'Temporary C6 camera fixture remains';END IF;
 RAISE NOTICE 'PASS: Demo members and subscription restored; C6 camera fixture absent.';
END $$;
SET LOCAL ROLE gympro_app;
DO $$ BEGIN
 BEGIN PERFORM * FROM security.search_branch_members(NULL,NULL,NULL,NULL,NULL,NULL);RAISE EXCEPTION 'Restored search accepted invalid session';EXCEPTION WHEN SQLSTATE '28000' THEN RAISE NOTICE 'PASS: Restored member search rejects invalid session';END;
 BEGIN PERFORM * FROM security.find_member_card(NULL,NULL,NULL,NULL);RAISE EXCEPTION 'Restored card lookup accepted invalid session';EXCEPTION WHEN SQLSTATE '28000' THEN RAISE NOTICE 'PASS: Restored card lookup rejects invalid session';END;
 BEGIN PERFORM * FROM security.summarize_branch_attendance(NULL,NULL,NULL,NULL);RAISE EXCEPTION 'Restored summary accepted invalid session';EXCEPTION WHEN SQLSTATE '28000' THEN RAISE NOTICE 'PASS: Restored summary rejects invalid session';END;
END $$;
RESET ROLE;
ROLLBACK;
'@
    $gymProCheckPath=Join-Path $gymProRun 'verify-restored-checkpoint.sql'
    [IO.File]::WriteAllText($gymProCheckPath,$gymProSql,[Text.UTF8Encoding]::new($false))
    Write-Progress -Activity 'Gym Pro C10 recovery checkpoint' -Status 'Verifying restored security and demo records' -PercentComplete 75
    Invoke-GymProNative (Join-Path $PostgresBin 'psql.exe') @('-X','-w','-h','127.0.0.1','-p','5432','-U','postgres','-d',$gymProTestDb,'-v','ON_ERROR_STOP=1','-f',$gymProCheckPath)
    if(-not $gymProTestDb.StartsWith('gympro_restore_c10_')){throw 'Unexpected temporary database name. Cleanup refused.'}
    Invoke-GymProNative (Join-Path $PostgresBin 'dropdb.exe') @('-w','-h','127.0.0.1','-p','5432','-U','postgres',$gymProTestDb)
    $gymProTestRemoved=$true
    [ordered]@{
        checkpoint='C10 recovery through C9'
        createdAt=(Get-Date).ToString('o')
        gitCommit="$gymProCommit"
        gitSubject="$gymProCommitSubject"
        sourceBundleVerified=$true
        databaseRestoreVerified=$true
        restoreSecurityChecksPassed=$true
        temporaryDatabaseRemoved=$true
        testedUsingExistingClusterRoles=$true
        roleRestoreOnFreshClusterTested=$false
        rolesIncludePasswords=$false
        c8BrowserCardLookupResult='pending'
        liveDatabase='gympro_saas'
        sourceBundleSha256=(Get-FileHash $gymProBundle -Algorithm SHA256).Hash
        databaseSha256=(Get-FileHash $gymProDump -Algorithm SHA256).Hash
        rolesSha256=(Get-FileHash $gymProRoles -Algorithm SHA256).Hash
    } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $gymProRun 'checkpoint.json') -Encoding UTF8
    $gymProExitCode=0
    Write-Progress -Activity 'Gym Pro C10 recovery checkpoint' -Status 'Completed' -PercentComplete 100
    Write-Host 'PASS: Committed source bundle, database archive and password-free role backup created.' -ForegroundColor Green
    Write-Host 'PASS: Database restored; forced RLS, core functions, C7/C8/C9 functions and demo records verified.' -ForegroundColor Green
    Write-Host 'PASS: Temporary restore database removed. Working database unchanged by this runner.' -ForegroundColor Green
    Write-Host "Recovery folder: $gymProRun"
    Write-Host 'C8 browser lookup result remains pending. No application files, Git commits or published services changed.'
}catch{
    Write-Host "FAIL: $($_.Exception.Message)" -ForegroundColor Red
    if($gymProRun){Write-Host "Keep recovery reports: $gymProRun"}
    if($gymProTestCreated -and -not $gymProTestRemoved){Write-Host "Temporary test database retained for diagnosis: $gymProTestDb"}
}finally{
    if($null -eq $gymProOriginalPgPassword){Remove-Item Env:\PGPASSWORD -ErrorAction SilentlyContinue}else{$env:PGPASSWORD=$gymProOriginalPgPassword}
    $gymProCredential=$null;$gymProSecret=$null
    Write-Progress -Activity 'Gym Pro C10 recovery checkpoint' -Completed
    try{Stop-Transcript | Out-Null}catch{}
}
exit $gymProExitCode
