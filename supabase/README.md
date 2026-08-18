# Supabase migrations

Project reference: `tcpblqxybtcpkfsultxd`.

The production project pre-dates repository-managed migrations. The security foundation is split into two releases so the existing application remains usable while the authenticated frontend is deployed:

1. `20260817000100_auth_security_foundation.sql` adds authentication ownership, backfills a singleton household, adds authenticated RLS policies, and preserves the legacy anonymous policies and public buckets temporarily.
2. `20260817000200_enforce_authenticated_access.sql` refuses to run until an owner exists, then removes anonymous table access, enforces household ownership, and makes receipt/item-photo storage private.

Follow [cutover-checklist.md](cutover-checklist.md). Do not run the second migration until the authenticated production frontend is deployed and the first owner can read and update inventory.
