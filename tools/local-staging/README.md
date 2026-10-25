# Local Windows staging

This tooling installs a committed source snapshot into C:\Projects\gympro-staging,
with a separate PostgreSQL 18 cluster on 127.0.0.1:55440 and API on 127.0.0.1:3200.
It does not use the development database or copy development environment files.

Install once: powershell -NoProfile -ExecutionPolicy Bypass -File scripts\install-local-staging.ps1
Start the installed environment: powershell -NoProfile -ExecutionPolicy Bypass -File C:\Projects\gympro-staging\Start-GymPro-Local-Staging.ps1

Keep its terminal open. Sign out in the browser, then press Enter in that terminal
to stop the owned API and database cluster. Staging records persist.
The separate staging-owner password is chosen at installation and is not saved.
Generated database credentials are encrypted with Windows DPAPI for the installing
Windows account. Use that same account to start staging.

The initial owner has eight basic permissions; finance/POS rights are not implied.
The installer refuses an existing destination. Do not reinstall over retained data.
The installed source snapshot does not change automatically when master advances.

Never add pgdata, credentials.dpapi.json, environment files, database backups,
application logs, or the entire staging directory to Git.

Basic browser acceptance and automated checks are recorded under docs/completion.
Separate-machine validation, staging backup/restore, controlled upgrade/rollback,
broader business UI acceptance and production recovery/MFA/audit rollout remain open.
KBZPay remains deferred. Local staging is not an internet production deployment.
