-- Shared schema: one database, one column list, one masking rule.
-- Rule (stand-in for the customer's WHERE clause): LastAccessDate < '2020-01-01' (dormant accounts).
-- Sensitive columns: DisplayName (keep first character), AboutMe, WebsiteUrl, Location (NULL).
CREATE DATABASE IF NOT EXISTS mask_lab;

-- A: ClickPipes lands here. Null engine stores nothing; the MV below sees each insert block.
CREATE TABLE IF NOT EXISTS mask_lab.users_landing
(
    Id             Nullable(Int64),
    Reputation     Nullable(String),
    CreationDate   Nullable(DateTime64(3, 'UTC')),
    DisplayName    Nullable(String),
    LastAccessDate Nullable(DateTime64(3, 'UTC')),
    AboutMe        Nullable(String),
    Views          Nullable(Int64),
    UpVotes        Nullable(Int64),
    DownVotes      Nullable(Int64),
    WebsiteUrl     Nullable(String),
    Location       Nullable(String),
    AccountId      Nullable(Int64)
)
ENGINE = Null;

-- Target tables: same shape for A (ClickPipes + MV), B (load, then UPDATE) and C (INSERT ... SELECT FROM s3).
-- B needs the block number/offset columns for lightweight UPDATE.
CREATE TABLE IF NOT EXISTS mask_lab.users_a
(
    Id             Int64,
    Reputation     Nullable(String),
    CreationDate   Nullable(DateTime64(3, 'UTC')),
    DisplayName    Nullable(String),
    LastAccessDate Nullable(DateTime64(3, 'UTC')),
    AboutMe        Nullable(String),
    Views          Nullable(Int64),
    UpVotes        Nullable(Int64),
    DownVotes      Nullable(Int64),
    WebsiteUrl     Nullable(String),
    Location       Nullable(String),
    AccountId      Nullable(Int64),
    is_masked      Bool
)
ENGINE = MergeTree
ORDER BY Id;

CREATE TABLE IF NOT EXISTS mask_lab.users_b  AS mask_lab.users_a
ENGINE = MergeTree ORDER BY Id
SETTINGS enable_block_number_column = 1, enable_block_offset_column = 1;
CREATE TABLE IF NOT EXISTS mask_lab.users_b2 AS mask_lab.users_a ENGINE = MergeTree ORDER BY Id;
CREATE TABLE IF NOT EXISTS mask_lab.users_c  AS mask_lab.users_a ENGINE = MergeTree ORDER BY Id;

-- The masking SELECT. The MV (A) and the INSERT (C) use the same expressions.
-- if(cond, ...) follows WHERE semantics: a NULL condition means "not masked".
-- Wrap the rule in ifNull(..., true) if NULL must fail closed.
CREATE MATERIALIZED VIEW IF NOT EXISTS mask_lab.users_mask_mv TO mask_lab.users_a AS
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
FROM mask_lab.users_landing;
