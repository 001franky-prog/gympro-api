# C10 development recovery checkpoint

Verified on 2026-10-15.

Application commit: c836215
Recovery folder: C:\Projects\gympro-backups\c10-recovery-20261015-211046

Passed:
- Complete committed-source Git bundle verified.
- Database archive and password-free PostgreSQL roles exported.
- Archive restored into a separate temporary database.
- Forced RLS and runtime access restrictions verified.
- Core functions and C7/C8/C9 functions verified.
- Demo records verified; temporary restore database removed.
- C8 browser lookup returned the correct no-card message.
- Direct C8 API lookup returned {"card":null}.

Subsequent local configuration:
- Demo administrator received gym.cards.read for BR001 only.
- This permission assignment occurred after the recovery backup.
- Card issuance and other permissions were not granted by that change.

Limitations:
- Restore verification reused existing PostgreSQL cluster roles.
- Fresh-server role provisioning was not tested.
- Source bundle contains committed files; local environment secrets
  must be configured separately.
