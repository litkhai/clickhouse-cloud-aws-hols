-- app.{t:Identifier} = app.users_a | app.users_b. lab.expected is loaded from out/<name>/expected.tsv by run.sh.
SELECT {t:String} AS target,
       count() AS rows,
       countIf(mapSort(JSONExtract(toJSONString(u.properties), 'Map(String, String)'))
               = mapSort(JSONExtract(e.props, 'Map(String, String)'))) AS props_ok,
       countIf(u.email = e.email) AS email_ok,
       countIf(u.phone = e.phone) AS phone_ok
FROM app.{t:Identifier} AS u FINAL
JOIN lab.expected AS e USING user_id;
