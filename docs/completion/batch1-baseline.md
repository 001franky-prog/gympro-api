# Batch 1A foundation baseline

Run from the project root:

    powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\completion-batch1-baseline.ps1

The runner installs or checks only its own files, runs a redacted configuration preflight, Nest build, all unit tests and root e2e. Reports go outside the repository. It does not install dependencies, apply SQL, modify authentication policy, change operator styling, start a server, commit or publish.

Prerequisites: existing working project and node_modules; Node 24+; npm.cmd/npx.cmd; three restricted database URLs available in .env or the process environment. No administrator PostgreSQL password is requested. Tests may use configured application database connections according to their existing implementation; this is not a read-only database audit or proof that all test code is side-effect free.

Stop an existing watch build before running so two compilers do not modify dist simultaneously. The runner never stops another process.

A successful run is Batch 1A baseline verification only. Clean-install, migration-ledger and production authentication work remain pending. Keep detailed logs locally; share the first failing check, not credential values.
