-- C: mask while reading. One statement; raw values never reach a table.
-- Private bucket: s3('<url>', 'Parquet', extra_credentials(role_arn = '<role arn>'))
-- Retry = TRUNCATE TABLE mask_lab.users_c, then run again.
INSERT INTO mask_lab.users_c
WITH LastAccessDate < '2020-01-01' AS m
SELECT
    assumeNotNull(Id)                                             AS Id,
    Reputation,
    CreationDate,
    if(m, concat(substringUTF8(DisplayName, 1, 1), '***'), DisplayName) AS DisplayName,
    LastAccessDate,
    if(m, NULL, AboutMe)                                          AS AboutMe,
    Views,
    UpVotes,
    DownVotes,
    if(m, NULL, WebsiteUrl)                                       AS WebsiteUrl,
    if(m, NULL, Location)                                         AS Location,
    AccountId,
    m                                                             AS is_masked
FROM s3('https://datasets-documentation.s3.eu-west-3.amazonaws.com/stackoverflow/parquet/users.parquet', 'Parquet');
