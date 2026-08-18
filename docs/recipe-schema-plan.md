# Recipe Builder schema and migration plan

Status: Recipe foundation applied to production on 2026-08-18 as Supabase migration `20260818193427_recipe_foundation`.

## Goals

- Replace the user-facing Meals feature with Recipes without deleting or renaming legacy tables.
- Preserve a recipe's identity while publishing immutable versions over time.
- Support parallel cooking processes, ordered steps, repeated ingredient additions, and multiple timers.
- Preserve raw cooking-session evidence independently from the cleaned recipe.
- Link recipe ingredients to canonical inventory items when possible without blocking unmatched ingredients.
- Keep recipe costing and future inventory/Shopify integration possible without implementing automatic depletion now.
- Enforce the existing authenticated household boundary on every new table.

## Important boundaries

- Recipes do not directly change inventory in the first implementation.
- A cooking session records actual usage, but inventory deductions remain disabled until a separately approved ledger integration exists.
- Shopify sales will eventually estimate theoretical recipe consumption. They cannot directly prove waste.
- Voice transcripts and AI interpretations are supporting evidence. Only user-confirmed structured events become authoritative recipe data.
- Unit conversion is allowed only between compatible measurement dimensions and only when a verified ingredient/package conversion exists.

## Proposed entities

All primary keys use UUIDs with `gen_random_uuid()` to remain consistent with the existing application. Every table includes:

- `id uuid primary key default gen_random_uuid()` unless a composite key is explicitly noted
- `household_id uuid not null default public.current_household_id()`
- `created_at timestamptz not null default now()`
- `updated_at timestamptz not null default now()` where records are editable

All parent relationships use household-consistent foreign keys so a row cannot reference an object belonging to another household.

### `recipes`

Stable identity for a recipe across all versions.

| Column | Type | Notes |
| --- | --- | --- |
| `name` | text | Required |
| `description` | text | Nullable |
| `status` | text | `draft`, `published`, or `archived` |
| `current_version_id` | uuid | Nullable until the first version is published |
| `legacy_meal_id` | uuid | Nullable, unique per household; preserves migration provenance |

Index/constraint requirements:

- Case-insensitive household/name lookup index.
- Unique `(household_id, id)` for composite tenant foreign keys.
- Unique `(household_id, legacy_meal_id)` where `legacy_meal_id is not null`.

### `recipe_versions`

Immutable published snapshot of a recipe. Draft versions may be edited until publication.

| Column | Type | Notes |
| --- | --- | --- |
| `recipe_id` | uuid | Required |
| `version_number` | integer | Starts at 1; unique within a recipe |
| `status` | text | `draft`, `published`, or `superseded` |
| `yield_quantity` | numeric | Positive when supplied |
| `yield_unit` | text | Examples: `servings`, `batches`, `pans` |
| `serving_size_quantity` | numeric | Nullable |
| `serving_size_unit` | text | Nullable |
| `description` | text | Version-specific introduction |
| `notes` | text | Version-specific notes |
| `published_at` | timestamptz | Nullable until published |
| `source_session_id` | uuid | Nullable cooking session that produced this version |

Constraints:

- Unique `(household_id, recipe_id, version_number)`.
- Positive yield and serving quantities.
- A published version must have `published_at`.

### `recipe_processes`

A parallel workstream inside one recipe version, such as Sauce, Rice, Goat Meat, or Final Assembly.

| Column | Type | Notes |
| --- | --- | --- |
| `recipe_version_id` | uuid | Required |
| `name` | text | Required |
| `position` | integer | Non-negative display order |
| `notes` | text | Nullable |

Unique `(household_id, recipe_version_id, position)`.

### `recipe_steps`

An ordered instruction inside a process.

| Column | Type | Notes |
| --- | --- | --- |
| `recipe_version_id` | uuid | Required for efficient version loading |
| `process_id` | uuid | Required |
| `position` | integer | Non-negative order within the process |
| `instruction` | text | Required |
| `expected_duration_seconds` | integer | Nullable, non-negative |
| `temperature_value` | numeric | Nullable |
| `temperature_unit` | text | `f`, `c`, or null |
| `notes` | text | Nullable |

Unique `(household_id, process_id, position)`.

### `recipe_ingredients`

The consolidated ingredient requirement for a recipe version.

| Column | Type | Notes |
| --- | --- | --- |
| `recipe_version_id` | uuid | Required |
| `inventory_item_id` | uuid | Nullable; unmatched ingredients remain valid |
| `ingredient_name` | text | Required snapshot name |
| `quantity` | numeric | Positive |
| `unit` | text | Required |
| `measurement_dimension` | text | `weight`, `volume`, `count`, or `other` |
| `preparation_note` | text | Examples: diced, divided, room temperature |
| `position` | integer | Non-negative display order |

An inventory link uses `ON DELETE SET NULL` so recipe history survives inventory cleanup or item merging.

### `recipe_step_ingredients`

Allocates part of a consolidated ingredient to a particular step. This preserves distinctions such as adding thyme twice while still calculating a three-tablespoon recipe total.

| Column | Type | Notes |
| --- | --- | --- |
| `recipe_version_id` | uuid | Required; prevents allocations across recipe versions |
| `recipe_step_id` | uuid | Required |
| `recipe_ingredient_id` | uuid | Required |
| `quantity` | numeric | Positive |
| `unit` | text | Required; must be compatible with the ingredient dimension |
| `position` | integer | Non-negative order within the step |
| `note` | text | Nullable |

### `cooking_sessions`

One actual build or cook attempt.

| Column | Type | Notes |
| --- | --- | --- |
| `recipe_id` | uuid | Nullable for an untitled Build Mode session |
| `recipe_version_id` | uuid | Nullable in Build Mode; required when Cook Mode begins from a version |
| `mode` | text | `build` or `cook` |
| `status` | text | `active`, `paused`, `review`, `completed`, or `abandoned` |
| `started_at` | timestamptz | Required |
| `completed_at` | timestamptz | Nullable |
| `yield_quantity` | numeric | Actual session yield, nullable |
| `yield_unit` | text | Nullable |
| `notes` | text | Nullable |

Active-session queries use a composite `(household_id, status, started_at desc)` index.

### `cooking_events`

Append-oriented chronological evidence captured during a session.

| Column | Type | Notes |
| --- | --- | --- |
| `cooking_session_id` | uuid | Required |
| `event_sequence` | bigint identity | Stable ordering for events sharing a timestamp |
| `occurred_at` | timestamptz | Required, defaults to now |
| `event_type` | text | Constrained event vocabulary |
| `process_id` | uuid | Nullable |
| `recipe_step_id` | uuid | Nullable |
| `inventory_item_id` | uuid | Nullable |
| `ingredient_name` | text | Nullable snapshot |
| `quantity` | numeric | Nullable |
| `unit` | text | Nullable |
| `duration_seconds` | integer | Nullable, non-negative |
| `temperature_value` | numeric | Nullable |
| `temperature_unit` | text | Nullable |
| `raw_transcript` | text | Nullable; retained as evidence |
| `structured_data` | jsonb | Nullable provider-independent metadata |
| `supersedes_event_id` | uuid | Nullable correction link |
| `confirmed_at` | timestamptz | Nullable until user-confirmed |

Initial event types:

- `session_started`
- `ingredient_added`
- `ingredient_adjusted`
- `timer_started`
- `timer_paused`
- `timer_resumed`
- `timer_stopped`
- `step_started`
- `step_completed`
- `note`
- `observation`
- `correction`

Index `(household_id, cooking_session_id, occurred_at, event_sequence)` supports timeline reads.

### `cooking_timers`

Current timer state plus final measured duration. Timer lifecycle events are also written to `cooking_events`.

| Column | Type | Notes |
| --- | --- | --- |
| `cooking_session_id` | uuid | Required |
| `process_id` | uuid | Nullable |
| `recipe_step_id` | uuid | Nullable |
| `name` | text | Required |
| `status` | text | `running`, `paused`, `stopped`, or `cancelled` |
| `started_at` | timestamptz | Required |
| `paused_at` | timestamptz | Nullable |
| `stopped_at` | timestamptz | Nullable |
| `paused_duration_seconds` | integer | Non-negative, defaults to 0 |
| `target_duration_seconds` | integer | Nullable, non-negative |
| `final_duration_seconds` | integer | Nullable, non-negative |

Partial index on active timers: `(household_id, cooking_session_id)` where status is `running` or `paused`.

### `session_ingredient_usage`

User-confirmed actual ingredient usage for a cooking session. This is separate from inventory transactions.

| Column | Type | Notes |
| --- | --- | --- |
| `cooking_session_id` | uuid | Required |
| `recipe_ingredient_id` | uuid | Nullable for newly discovered ingredients |
| `inventory_item_id` | uuid | Nullable |
| `ingredient_name` | text | Required snapshot |
| `quantity` | numeric | Positive |
| `unit` | text | Required |
| `measurement_dimension` | text | Required |
| `confirmed_at` | timestamptz | Required |

This table becomes the future bridge to inventory usage, costing, and Shopify-derived theoretical consumption.

### `recipe_deviations`

Review decisions comparing a cooking session with its source recipe version.

| Column | Type | Notes |
| --- | --- | --- |
| `cooking_session_id` | uuid | Required |
| `recipe_version_id` | uuid | Required baseline |
| `deviation_type` | text | Ingredient, duration, temperature, sequence, technique, step, or other |
| `entity_id` | uuid | Nullable related ingredient/step/process |
| `before_data` | jsonb | Required snapshot |
| `after_data` | jsonb | Required snapshot |
| `decision` | text | `pending`, `session_only`, or `promote` |
| `promoted_version_id` | uuid | Nullable new version created from the decision |
| `reviewed_at` | timestamptz | Nullable |

## Security model

Every new table will:

1. Enable RLS before frontend access is granted.
2. Receive one household-scoped policy for authenticated CRUD:
   - `USING (household_id = public.current_household_id())`
   - `WITH CHECK (household_id = public.current_household_id())`
3. Revoke all access from `anon` and `PUBLIC`.
4. Grant only `select`, `insert`, `update`, and `delete` to `authenticated` where the UI needs them.
5. Index `household_id` and every foreign-key column.
6. Use composite household/parent foreign keys to prevent cross-household references.

No new `SECURITY DEFINER` function is required for the foundation. Coordinated publishing may later use a database function, but it must live in `private`, verify `auth.uid()`, use a fixed empty search path, and have direct execution revoked unless explicitly required.

## Legacy Meals compatibility

The production database currently contains zero `meals` rows and zero `meal_ingredients` rows. The migration remains data-preserving:

1. Do not rename or drop `meals` or `meal_ingredients`.
2. Add the new recipe tables alongside them.
3. For each legacy meal present at migration time:
   - Create one `recipes` row with `legacy_meal_id`.
   - Create version 1 using `portions` as `yield_quantity` and `servings` as `yield_unit`.
   - Convert each `meal_ingredients` row to a `recipe_ingredients` row linked to the same inventory item.
   - Publish version 1 only after ingredient counts match.
4. Keep legacy tables readable during a compatibility release.
5. Switch the frontend to Recipes after validation.
6. Consider removing legacy writes only in a later approved migration. Do not drop the tables during the Recipe Builder rollout.

## Migration phases

### Phase R1 — Additive recipe foundation

- Create `recipes`, `recipe_versions`, `recipe_processes`, `recipe_steps`, `recipe_ingredients`, and `recipe_step_ingredients`.
- Add constraints, indexes, grants, and RLS in the same transaction.
- Add legacy backfill logic guarded by `ON CONFLICT`/provenance keys.
- Do not change the existing frontend yet.

### Phase R2 — Cooking-session capture

- Create `cooking_sessions`, `cooking_events`, `cooking_timers`, and `session_ingredient_usage`.
- Implement manual Build Mode and multiple timers.
- Keep voice disabled and retain manual fallback controls.

### Phase R3 — Review, deviations, and version promotion

- Create `recipe_deviations`.
- Implement end-of-cook review.
- Publish a new immutable version only after explicit user confirmation.
- Perform multi-table version publication in one transaction.

### Phase R4 — Voice adapter

- Add private `recipe-audio` storage only if raw audio retention is approved.
- Use household-prefixed private object paths and short-lived signed URLs.
- Store provider-independent transcripts/events; do not place provider API keys in the browser.
- Add strict server-side cost and duration limits.

### Phase R5 — Costing, shopping, and inventory bridge

- Calculate recipe costs from confirmed price observations.
- Add recipe/batch demand to the shopping planner.
- Introduce inventory usage transactions only after the inventory ledger is live.
- Keep theoretical usage, physical counts, recorded waste, and unexplained variance separate.

## Verification required before each production phase

- Migration runs successfully in a disposable/local database.
- Every new public table has RLS enabled.
- `anon` has no table privileges.
- An authenticated household owner can CRUD only their household rows.
- A simulated second household cannot read or reference the first household's data.
- Every foreign-key column has a supporting index.
- Recipe version and process/step ordering constraints reject duplicates.
- Invalid negative quantities, durations, and positions are rejected.
- Legacy meal and ingredient row counts reconcile before and after backfill.
- Deleting an inventory item sets recipe links to null without deleting recipe history.
- Deleting a recipe cascades only through its owned recipe/version structure.
- Supabase security and performance advisors contain no new warnings caused by the migration.

## Approval boundary

Approval of this document authorizes creation of a migration file for review. It does not authorize applying that migration to production. Production execution remains a separate explicit approval step after the SQL, rollback considerations, and verification queries are reviewed.
