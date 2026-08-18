# Authentication cutover checklist

This rollout intentionally keeps the compatibility window short. During that
window, the legacy anonymous policies remain active, so the app keeps working
but the original security exposure still exists.

## Stage 1: additive compatibility migration

1. Apply `20260817000100_auth_security_foundation.sql`.
2. Verify all ten legacy tables have a nullable, backfilled `household_id`.
3. Verify the existing anonymous policies and public buckets still exist.
4. Verify the authenticated household policies and storage policies exist.
5. Run the security and performance advisors.

## Stage 2: frontend deployment

1. Merge the authenticated frontend and API changes.
2. Wait for the production deployment to complete.
3. Create the first owner account through the production app.
4. Verify the owner has one `household_members` row with role `owner`.
5. Smoke-test inventory read, create, update, and delete operations.
6. Upload and retrieve a test image using a household-prefixed storage path.
7. Verify an unauthenticated OCR request returns HTTP 401.

Do not continue if any smoke test fails. Because Stage 1 remains backward
compatible, the frontend can be rolled back without reverting the database.

## Stage 3: security enforcement

1. Apply `20260817000200_enforce_authenticated_access.sql`.
2. Verify `anon` has no privileges on the application tables.
3. Verify only the household-scoped policies remain on application tables.
4. Verify `receipts` and `item-photos` are private.
5. Repeat the authenticated CRUD, storage, and OCR smoke tests.
6. Run security and performance advisors again.

If Stage 3 fails, stop writes and diagnose before changing policies manually.
The migration is transactional, so a SQL error rolls back the entire cutover.
