public with sharing class SoqlEditorController {

    private static final Integer MAX_IMPORT_BATCH = 200;

    public class QueryResult {
        @AuraEnabled public List<String> columns;
        @AuraEnabled public List<Map<String, Object>> rows;
        @AuraEnabled public Integer totalRows;
        @AuraEnabled public String error;

        public QueryResult() {
            this.columns = new List<String>();
            this.rows = new List<Map<String, Object>>();
            this.totalRows = 0;
        }
    }

    public class ImportResult {
        @AuraEnabled public Integer successCount;
        @AuraEnabled public Integer errorCount;
        @AuraEnabled public List<String> errors;

        public ImportResult() {
            this.successCount = 0;
            this.errorCount = 0;
            this.errors = new List<String>();
        }
    }

    private class ExpandResult {
        String query;
        List<String> fields; // non-null only when FIELDS() was expanded
        ExpandResult(String q, List<String> f) { this.query = q; this.fields = f; }
    }

    // Expands FIELDS(ALL|STANDARD|CUSTOM) into an explicit field list so
    // Database.query() can execute it. Also returns the field list so callers
    // can build columns without getPopulatedFieldsAsMap() dropping null fields.
    private static ExpandResult expandFieldsFunction(String q) {
        if (!q.toLowerCase().contains('fields(')) return new ExpandResult(q, null);
        Pattern fp = Pattern.compile('(?i)\\bFIELDS\\s*\\(\\s*(ALL|STANDARD|CUSTOM)\\s*\\)');
        Matcher fm = fp.matcher(q);
        if (!fm.find()) return new ExpandResult(q, null);
        String kind = fm.group(1).toUpperCase();
        Pattern op = Pattern.compile('(?i)\\bFROM\\s+(\\w+)');
        Matcher om = op.matcher(q);
        if (!om.find()) return new ExpandResult(q, null);
        Schema.SObjectType sot = Schema.getGlobalDescribe().get(om.group(1));
        if (sot == null) return new ExpandResult(q, null);
        List<String> names = new List<String>();
        for (Schema.SObjectField sf : sot.getDescribe().fields.getMap().values()) {
            Schema.DescribeFieldResult dfr = sf.getDescribe();
            if (!dfr.isAccessible()) continue;
            if (kind == 'STANDARD' && dfr.isCustom()) continue;
            if (kind == 'CUSTOM'   && !dfr.isCustom()) continue;
            // Skip compound wrapper fields (ADDRESS, LOCATION) — their scalar
            // components are already present in the field map and will be included.
            String typeName = dfr.getType().name();
            if (typeName == 'ADDRESS' || typeName == 'LOCATION') continue;
            names.add(dfr.getName());
        }
        if (names.isEmpty()) return new ExpandResult(q, null);
        return new ExpandResult(fm.replaceFirst(String.join(names, ', ')), names);
    }

    // Parses the SELECT clause to extract simple field/relationship names.
    // Returns null for aggregate or complex queries so the caller can fall back.
    private static List<String> parseSelectColumns(String soql) {
        try {
            String s = soql.trim();
            if (!s.toUpperCase().startsWith('SELECT')) return null;
            // Find the first FROM at parenthesis depth 0
            Integer depth = 0, fromIdx = -1;
            for (Integer i = 6; i <= s.length() - 4; i++) {
                String c = s.substring(i, i + 1);
                if (c == '(') { depth++; continue; }
                if (c == ')') { depth--; continue; }
                if (depth == 0 && s.substring(i, i + 4).toUpperCase() == 'FROM') {
                    String prev = i > 0 ? s.substring(i - 1, i) : ' ';
                    String next = i + 4 < s.length() ? s.substring(i + 4, i + 5) : ' ';
                    Boolean preOk  = prev == ' ' || prev == '\n' || prev == '\t' || prev == '\r';
                    Boolean postOk = next == ' ' || next == '\n' || next == '\t' || next == '\r';
                    if (preOk && postOk) { fromIdx = i; break; }
                }
            }
            if (fromIdx < 0) return null;
            String clause = s.substring(6, fromIdx).trim();
            // Split by comma at depth 0; skip any token containing ( (aggregates/subqueries)
            List<String> cols = new List<String>();
            depth = 0;
            Integer start = 0;
            for (Integer i = 0; i < clause.length(); i++) {
                String c = clause.substring(i, i + 1);
                if (c == '(') depth++;
                else if (c == ')') depth--;
                else if (c == ',' && depth == 0) {
                    String col = clause.substring(start, i).trim();
                    if (String.isNotBlank(col) && !col.contains('(')) cols.add(col);
                    start = i + 1;
                }
            }
            String last = clause.substring(start).trim();
            if (String.isNotBlank(last) && !last.contains('(')) cols.add(last);
            return cols.isEmpty() ? null : cols;
        } catch (Exception ex) {
            return null;
        }
    }

    // Resolves a dotted relationship path (e.g. "Account.Name") from a record.
    private static Object resolveFieldValue(SObject record, String path) {
        try {
            if (!path.contains('.')) return record.get(path);
            List<String> parts = path.split('\\.');
            SObject current = record;
            for (Integer i = 0; i < parts.size() - 1; i++) {
                current = current.getSObject(parts[i]);
                if (current == null) return null;
            }
            return current.get(parts[parts.size() - 1]);
        } catch (Exception ex) {
            return null;
        }
    }

    // Only SELECT queries are permitted through this controller.
    private static Boolean isSelectQuery(String query) {
        return query.trim().toLowerCase().startsWith('select');
    }

    @AuraEnabled
    public static QueryResult executeQuery(String query) {
        QueryResult result = new QueryResult();
        try {
            if (!isSelectQuery(query)) {
                result.error = 'Only SELECT queries are permitted.';
                return result;
            }
            ExpandResult expanded = expandFieldsFunction(query.trim());
            List<SObject> records = Database.query(expanded.query);
            if (!records.isEmpty()) {
                List<Map<String, Object>> flatRows = new List<Map<String, Object>>();
                // Prefer an explicit column list so null-valued fields are included.
                // FIELDS() queries use the expanded list; regular queries parse SELECT.
                List<String> cols = expanded.fields != null
                    ? expanded.fields
                    : parseSelectColumns(query.trim());
                if (cols != null) {
                    List<String> displayCols = new List<String>(cols);
                    if (expanded.fields != null) displayCols.sort(); // sort FIELDS() results
                    result.columns = displayCols;
                    for (SObject record : records) {
                        Map<String, Object> row = new Map<String, Object>();
                        for (String col : cols) {
                            row.put(col, resolveFieldValue(record, col));
                        }
                        flatRows.add(row);
                    }
                } else {
                    // Fallback for aggregate/complex queries
                    Set<String> colSet = new Set<String>();
                    for (SObject record : records) {
                        Map<String, Object> flat = flattenRecord(record);
                        colSet.addAll(flat.keySet());
                        flatRows.add(flat);
                    }
                    result.columns = new List<String>(colSet);
                    result.columns.sort();
                }
                result.rows = flatRows;
            }
            result.totalRows = records.size();
        } catch (Exception e) {
            result.error = e.getMessage();
        }
        return result;
    }

    @AuraEnabled
    public static QueryResult executeQueryAll(String query) {
        QueryResult result = new QueryResult();
        try {
            if (!isSelectQuery(query)) {
                result.error = 'Only SELECT queries are permitted.';
                return result;
            }
            ExpandResult expanded = expandFieldsFunction(query.trim());
            String q = expanded.query;
            if (!q.toLowerCase().contains('all rows')) q += ' ALL ROWS';
            List<SObject> records = Database.query(q);
            if (!records.isEmpty()) {
                List<Map<String, Object>> flatRows = new List<Map<String, Object>>();
                List<String> cols = expanded.fields != null
                    ? expanded.fields
                    : parseSelectColumns(query.trim());
                if (cols != null) {
                    List<String> displayCols = new List<String>(cols);
                    if (expanded.fields != null) displayCols.sort();
                    result.columns = displayCols;
                    for (SObject record : records) {
                        Map<String, Object> row = new Map<String, Object>();
                        for (String col : cols) {
                            row.put(col, resolveFieldValue(record, col));
                        }
                        flatRows.add(row);
                    }
                } else {
                    Set<String> colSet = new Set<String>();
                    for (SObject record : records) {
                        Map<String, Object> flat = flattenRecord(record);
                        colSet.addAll(flat.keySet());
                        flatRows.add(flat);
                    }
                    result.columns = new List<String>(colSet);
                    result.columns.sort();
                }
                result.rows = flatRows;
            }
            result.totalRows = records.size();
        } catch (Exception e) {
            result.error = e.getMessage();
        }
        return result;
    }

    @AuraEnabled
    public static QueryResult executeToolingQuery(String query) {
        QueryResult result = new QueryResult();
        try {
            String instanceUrl = System.Url.getOrgDomainUrl().toExternalForm();
            String endpoint    = instanceUrl + '/services/data/v63.0/tooling/query?q='
                + EncodingUtil.urlEncode(query.trim(), 'UTF-8');
            HttpRequest req = new HttpRequest();
            req.setEndpoint(endpoint);
            req.setMethod('GET');
            req.setHeader('Authorization', 'Bearer ' + UserInfo.getSessionId());
            req.setTimeout(30000);
            Map<String, Object> parsed = (Map<String, Object>) JSON.deserializeUntyped(new Http().send(req).getBody());
            if (parsed.containsKey('errorCode')) { result.error = String.valueOf(parsed.get('message')); return result; }
            result.totalRows = parsed.get('totalSize') != null ? Integer.valueOf(String.valueOf(parsed.get('totalSize'))) : 0;
            List<Object> records = parsed.get('records') != null ? (List<Object>) parsed.get('records') : new List<Object>();
            if (!records.isEmpty()) {
                Map<String, Object> first = new Map<String, Object>((Map<String, Object>) records[0]);
                first.remove('attributes');
                List<String> cols = new List<String>(first.keySet());
                cols.sort();
                result.columns = cols;
                for (Object rec : records) {
                    Map<String, Object> row = new Map<String, Object>((Map<String, Object>) rec);
                    row.remove('attributes');
                    result.rows.add(row);
                }
            }
        } catch (Exception e) {
            result.error = e.getMessage() + ' (Ensure org domain is in Remote Site Settings)';
        }
        return result;
    }

    @AuraEnabled
    public static ImportResult importRecords(
        String objectApiName,
        String operation,
        String externalIdField,
        String recordsJson
    ) {
        ImportResult result = new ImportResult();
        try {
            List<Object> rawList = (List<Object>) JSON.deserializeUntyped(recordsJson);

            if (rawList.size() > MAX_IMPORT_BATCH) {
                result.errors.add('Batch size exceeds the maximum of ' + MAX_IMPORT_BATCH + ' records per operation.');
                result.errorCount = 1;
                return result;
            }

            Schema.SObjectType sObjectType = Schema.getGlobalDescribe().get(objectApiName);
            if (sObjectType == null) {
                result.errors.add('Unknown object: ' + objectApiName);
                result.errorCount = 1;
                return result;
            }

            Schema.DescribeSObjectResult sod = sObjectType.getDescribe();
            if (operation == 'insert' && !sod.isCreateable()) {
                result.errors.add('Insufficient permissions to create ' + objectApiName + ' records.');
                result.errorCount = 1;
                return result;
            }
            if ((operation == 'update' || operation == 'upsert') && !sod.isUpdateable()) {
                result.errors.add('Insufficient permissions to update ' + objectApiName + ' records.');
                result.errorCount = 1;
                return result;
            }

            Map<String, Schema.SObjectField> fieldMap = sObjectType.getDescribe().fields.getMap();
            List<SObject> sObjects = new List<SObject>();

            for (Object rawRecord : rawList) {
                Map<String, Object> recordMap = (Map<String, Object>) rawRecord;
                SObject sObj = sObjectType.newSObject();
                for (String fieldName : recordMap.keySet()) {
                    String fieldLower = fieldName.toLowerCase();
                    if (!fieldMap.containsKey(fieldLower)) continue;
                    Object value = recordMap.get(fieldName);
                    if (value == null || String.valueOf(value) == '') continue;
                    try {
                        Schema.DisplayType fType = fieldMap.get(fieldLower).getDescribe().getType();
                        sObj.put(fieldMap.get(fieldLower).getDescribe().getName(), castValue(fType, value));
                    } catch (Exception ex) {
                        // Skip fields that cannot be set
                    }
                }
                sObjects.add(sObj);
            }

            if (operation == 'insert') {
                for (Database.SaveResult sr : Database.insert(sObjects, false)) {
                    if (sr.isSuccess()) result.successCount++;
                    else { result.errorCount++; result.errors.add(sr.getErrors()[0].getMessage()); }
                }
            } else if (operation == 'update') {
                for (Database.SaveResult sr : Database.update(sObjects, false)) {
                    if (sr.isSuccess()) result.successCount++;
                    else { result.errorCount++; result.errors.add(sr.getErrors()[0].getMessage()); }
                }
            } else if (operation == 'upsert') {
                if (String.isNotBlank(externalIdField)) {
                    Schema.SObjectField extIdField = fieldMap.get(externalIdField.toLowerCase());
                    if (extIdField != null) {
                        for (Database.UpsertResult ur : Database.upsert(sObjects, extIdField, false)) {
                            if (ur.isSuccess()) result.successCount++;
                            else { result.errorCount++; result.errors.add(ur.getErrors()[0].getMessage()); }
                        }
                    } else {
                        for (Database.UpsertResult ur : Database.upsert(sObjects, false)) {
                            if (ur.isSuccess()) result.successCount++;
                            else { result.errorCount++; result.errors.add(ur.getErrors()[0].getMessage()); }
                        }
                    }
                } else {
                    for (Database.UpsertResult ur : Database.upsert(sObjects, false)) {
                        if (ur.isSuccess()) result.successCount++;
                        else { result.errorCount++; result.errors.add(ur.getErrors()[0].getMessage()); }
                    }
                }
            }
        } catch (Exception e) {
            result.errorCount++;
            result.errors.add(e.getMessage());
        }
        return result;
    }

    private static Map<String, Object> flattenRecord(SObject record) {
        Map<String, Object> result = new Map<String, Object>();
        Map<String, Object> fields = record.getPopulatedFieldsAsMap();
        for (String fieldName : fields.keySet()) {
            Object value = fields.get(fieldName);
            if (value instanceof SObject) {
                Map<String, Object> nested = flattenRecord((SObject) value);
                for (String nestedKey : nested.keySet()) {
                    result.put(fieldName + '.' + nestedKey, nested.get(nestedKey));
                }
            } else {
                result.put(fieldName, value);
            }
        }
        return result;
    }

    private static Object castValue(Schema.DisplayType fieldType, Object value) {
        String str = String.valueOf(value);
        switch on fieldType {
            when INTEGER    { return Integer.valueOf(str); }
            when DOUBLE, CURRENCY, PERCENT { return Decimal.valueOf(str); }
            when BOOLEAN    { return Boolean.valueOf(str); }
            when DATE       { return Date.valueOf(str); }
            when DATETIME   { return Datetime.valueOf(str); }
            when else       { return str; }
        }
    }
}
