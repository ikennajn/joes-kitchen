# Supabase migrations

Project reference: `tcpblqxybtcpkfsultxd`.

The production project pre-dates repository-managed migrations. `20260817000100_auth_security_foundation.sql` is the first reproducible migration and is intentionally additive for application data. It introduces authentication ownership, backfills a singleton household, replaces blanket public policies, and makes receipt/item-photo storage private.

Do not apply this migration to production before deploying the matching authenticated frontend. Validate it on a Supabase branch first, run security and performance advisors, then deploy the frontend and database change as one coordinated release.
