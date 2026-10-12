-- B step 1: load as is (any loader — ClickPipes or s3() — lands the same raw rows).
INSERT INTO mask_lab.users_b
SELECT assumeNotNull(Id), Reputation, CreationDate, DisplayName, LastAccessDate, AboutMe,
       Views, UpVotes, DownVotes, WebsiteUrl, Location, AccountId, false
FROM s3('https://datasets-documentation.s3.eu-west-3.amazonaws.com/stackoverflow/parquet/users.parquet', 'Parquet');
-- Same raw rows for the ALTER TABLE ... UPDATE variant.
INSERT INTO mask_lab.users_b2 SELECT * FROM mask_lab.users_b;
