# Joe's Kitchen production schema baseline

Baseline captured read-only from Supabase project `tcpblqxybtcpkfsultxd` on 2026-08-17.

## Existing public tables

| Table | Rows before Phase 1 | Purpose |
| --- | ---: | --- |
| `inventory` | 91 | Canonical-ish item records and mutable on-hand quantity |
| `shopping_sessions` | 6 | Shopping runs plus legacy driver/mileage data |
| `purchase_log` | 58 | Historical purchase snapshots |
| `receipt_aliases` | 28 | Store receipt text mapped to inventory items |
| `session_receipts` | 8 | Receipt totals and raw OCR payloads |
| `session_notes` | 6 | Notes captured during runs |
| `shop_quantities` | 4 | Desired quantities for a run |
| `meals` | 1 | Meal costing/planning definitions |
| `meal_ingredients` | 0 | Meal-to-inventory join rows |
| `rider_payments` | 0 | Legacy driver compensation records |

## Existing relationships

- `meal_ingredients.meal_id -> meals.id` (`ON DELETE CASCADE`)
- `meal_ingredients.item_id -> inventory.id` (`ON DELETE CASCADE`)
- `receipt_aliases.inventory_id -> inventory.id` (`ON DELETE SET NULL`)
- `session_notes.session_id -> shopping_sessions.id` (`ON DELETE CASCADE`)
- `session_receipts.session_id -> shopping_sessions.id` (`ON DELETE CASCADE`)
- `shop_quantities.session_id -> shopping_sessions.id` (`ON DELETE CASCADE`)
- `shop_quantities.item_id -> inventory.id` (`ON DELETE CASCADE`)

`purchase_log.session_id`, `purchase_log.item_id`, and `inventory.session_id` were not protected by foreign keys in the baseline.

## Baseline integrity notes

- Two case-insensitive duplicate-name groups: `Spinach` and `Salmon Rub`.
- One orphaned purchase references a removed `Spice Adobo Seasoning` inventory row.
- Twenty-eight purchase rows have no shopping session.
- Eight receipt rows exist, but both storage buckets contain zero objects.
- No Supabase Auth users or recorded database migrations existed.

## Phase 1 compatibility strategy

The first migration adds ownership to every table without renaming or deleting legacy columns. Existing rows are assigned to a singleton Joe's Kitchen household. The first authenticated account becomes that household's owner. Existing application tables remain available through the Data API, but only to authenticated household members through RLS.
