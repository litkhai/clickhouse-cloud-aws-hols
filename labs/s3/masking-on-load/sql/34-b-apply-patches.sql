-- B step 3 (lightweight UPDATE only): rewrite the base parts so the old values leave the active parts.
ALTER TABLE mask_lab.users_b APPLY PATCHES SETTINGS mutations_sync = 2;
