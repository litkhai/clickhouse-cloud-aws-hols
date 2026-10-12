-- B step 2b: classic mutation (rewrites the affected columns of every part that has matching rows).
ALTER TABLE mask_lab.users_b2
UPDATE DisplayName = concat(substringUTF8(DisplayName, 1, 1), '***'),
       AboutMe = NULL, WebsiteUrl = NULL, Location = NULL, is_masked = true
WHERE LastAccessDate < '2020-01-01'
SETTINGS mutations_sync = 2;
