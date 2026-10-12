-- B: where the old values still are. Run after 31 (lightweight UPDATE) and again after APPLY PATCHES.
-- 1) Base parts without patches applied: any user with SELECT can add this setting.
SELECT countIf(LastAccessDate < '2020-01-01' AND DisplayName NOT LIKE '%***') AS raw_names_readable
FROM mask_lab.users_b
SETTINGS apply_patch_parts = 0, select_sequential_consistency = 1;

-- 2) Parts replaced by a mutation or APPLY PATCHES stay on disk (active = 0) for old_parts_lifetime.
SELECT table, active, startsWith(name, 'patch') AS patch, count() AS parts, sum(rows) AS rows
FROM system.parts
WHERE database = 'mask_lab' AND table IN ('users_b', 'users_b2')
GROUP BY table, active, patch
ORDER BY table, active, patch;
