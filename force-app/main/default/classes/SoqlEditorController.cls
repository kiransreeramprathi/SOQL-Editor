public with sharing class SoqlEditorController {

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

    @AuraEnabled
    public static QueryResult executeQuery(String query) {
        QueryResult result = new QueryResult();
        try {
            List<SObject> records = Database.query(query.trim());
            if (!records.isEmpty()) {
                Map<String, Object> firstFlat = flattenRecord(records[0]);
                result.columns = new List<String>(firstFlat.keySet());
                result.columns.sort();
                for (SObject record : records) {
                    result.rows.add(flattenRecord(record));
                }
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
            String q = query.trim();
            if (!q.toLowerCase().contains('all rows')) q += ' ALL ROWS';
            List<SObject> records = Database.query(q);
            if (!records.isEmpty()) {
                Map<String, Object> firstFlat = flattenRecord(records[0]);
                result.columns = new List<String>(firstFlat.keySet());
                result.columns.sort();
                for (SObject record : records) result.rows.add(flattenRecord(record));
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
            Schema.SObjectType sObjectType = Schema.getGlobalDescribe().get(objectApiName);
            if (sObjectType == null) {
                result.errors.add('Unknown object: ' + objectApiName);
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
