-- One load chunk. 10-ch-setup.sh runs this once per chunk with
--   --param_base=<unix seconds, 30 days before the load> --param_off=<first number> --param_n=<rows>
-- Every column is a hash of the row number, so a re-load produces the same data.
INSERT INTO cachelab.events
SELECT
    toDateTime({base:UInt32} + cityHash64(number, 1) % 2592000)                      AS ts,
    toUInt32(cityHash64(number, 2) % 1000000)                                         AS user_id,
    toUInt16(cityHash64(number, 3) % 1000)                                            AS campaign_id,
    ['KR','US','JP','CN','TW','SG','VN','TH','ID','MY','PH','IN','AU','GB','DE','FR','CA','BR','MX','ES'][1 + cityHash64(number, 4) % 20] AS country,
    ['mobile','desktop','tablet'][1 + cityHash64(number, 5) % 3]                      AS device,
    ['impression','click','view','add_to_cart','purchase'][1 + cityHash64(number, 6) % 5] AS event_type,
    (cityHash64(number, 7) % 10000) / 100                                             AS revenue
FROM numbers({off:UInt64}, {n:UInt64});
