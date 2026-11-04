-- How the views stored properties: one String path per key, or inferred types (dates)?
SELECT {t:String} AS target, arrayJoin(distinctJSONPathsAndTypes(properties)) AS path_types FROM app.{t:Identifier};
