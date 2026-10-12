-- B step 2a: lightweight UPDATE (writes patch parts; base parts keep the old values until patches are applied).
UPDATE mask_lab.users_b
SET DisplayName = concat(substringUTF8(DisplayName, 1, 1), '***'),
    AboutMe = NULL, WebsiteUrl = NULL, Location = NULL, is_masked = true
WHERE LastAccessDate < '2020-01-01'
SETTINGS enable_lightweight_update = 1;
