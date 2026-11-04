-- Who can reach a key? Run as the admin user; analyst checks are run by run.sh as that user.
-- 1. Did any plaintext key reach the query log? (positive control: run.sh first runs one query with a literal key)
SELECT count() AS keys_checked,
       countIf(hits > 0) AS keys_in_query_log,
       max(hits) AS max_hits
FROM (
  SELECT k.key_hex, countIf(position(lower(l.query), lower(k.key_hex)) > 0) AS hits
  FROM keys.plain_keys AS k
  CROSS JOIN (SELECT query FROM clusterAllReplicas(default, system.query_log) WHERE event_date >= today() - 1) AS l
  GROUP BY k.key_hex);
-- 2. What the catalog shows about the key sources
SELECT name, origin, create_query = '' AS no_create_query FROM system.functions WHERE name IN ('kms_unwrap', 'dec_val');
SELECT database, name, source, status, element_count FROM system.dictionaries WHERE name = 'plain_key_dict';
