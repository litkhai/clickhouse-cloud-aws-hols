-- After CDC: the decrypted table (FINAL hides _peerdb_is_deleted rows) against lab.expected_r FINAL.
SELECT {t:String} AS target,
       (SELECT count() FROM lab.expected_r FINAL WHERE deleted = 0) AS expected_live,
       count() AS rows,
       countIf(e.user_id = '') AS unexpected_rows,
       countIf(e.deleted = 1) AS deleted_still_visible,
       countIf(e.user_id != '' AND mapSort(JSONExtract(toJSONString(u.properties), 'Map(String, String)'))
               = mapSort(JSONExtract(e.props, 'Map(String, String)')) AND u.email = e.email AND u.phone = e.phone) AS all_fields_ok
FROM app.{t:Identifier} AS u FINAL
LEFT JOIN (SELECT * FROM lab.expected_r FINAL) AS e USING user_id
SETTINGS join_use_nulls = 0;
