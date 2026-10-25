# Local staging recovery verification

The staging database archive was restored into a separate temporary database in
its existing staging PostgreSQL cluster. Comparison verified schema, ownership,
row-level security, grants, security functions, all table-content fingerprints
and sequence values. Unknown-session and private session-verifier boundaries
passed. The original staging snapshot remained unchanged. The temporary database
was removed and the staging cluster stopped.

An initial comparator incorrectly treated a NULL object ACL as empty. The
corrected verifier expands NULL ACLs with PostgreSQL acldefault, using the actual
object type and owner. Explicit empty ACLs remain empty; zero-cardinality arrays
are handled before aclexplode. Seven database-backed regression checks preserve
PUBLIC/runtime grant differences, owner differences and forced-RLS differences.
The original raw snapshot is checked before legacy evidence is normalized.

Reusable recovery command (staging stopped first):

    powershell -NoProfile -ExecutionPolicy Bypass -File scripts\verify-local-staging-recovery.ps1

The comparison correction passed against the retained restore. The corrected
full runner was preserved and syntax-checked, but its complete dump/restore path
has not been rerun; the earlier dump/restore succeeded before comparison stopped.

Only tools and acceptance metadata are committed. Dumps, role backups,
fingerprint files, logs and encrypted credentials remain in private local folders.
The role backup deliberately excludes login passwords. This verification does
not establish fresh-cluster role restoration, Windows DPAPI recovery on another
machine, off-machine backup storage, or controlled application update/rollback.
Those remain separate tasks. KBZPay and production recovery/MFA/audit rollout
remain deferred/pending as recorded in the project acceptance register.
