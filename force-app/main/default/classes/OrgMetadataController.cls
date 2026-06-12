public with sharing class OrgMetadataController {

    public class ObjectInfo {
        @AuraEnabled public String apiName;
        @AuraEnabled public String label;
        @AuraEnabled public String labelPlural;
    }

    public class FieldInfo {
        @AuraEnabled public String apiName;
        @AuraEnabled public String label;
        @AuraEnabled public String type;
        @AuraEnabled public Boolean nillable;
        @AuraEnabled public Boolean updateable;
        @AuraEnabled public Boolean externalId;
        @AuraEnabled public Integer length;
        @AuraEnabled public String referenceTo;
    }

    @AuraEnabled(cacheable=true)
    public static List<ObjectInfo> getObjects() {
        Map<String, Schema.SObjectType> globalDescribe = Schema.getGlobalDescribe();
        List<String> sortedNames = new List<String>(globalDescribe.keySet());
        sortedNames.sort();

        List<ObjectInfo> objects = new List<ObjectInfo>();
        for (String objectName : sortedNames) {
            Schema.DescribeSObjectResult d = globalDescribe.get(objectName).getDescribe();
            if (!d.isQueryable() || d.isCustomSetting()) continue;
            ObjectInfo obj = new ObjectInfo();
            obj.apiName = d.getName();
            obj.label = d.getLabel();
            obj.labelPlural = d.getLabelPlural();
            objects.add(obj);
        }
        return objects;
    }

    @AuraEnabled(cacheable=true)
    public static List<FieldInfo> getFields(String objectApiName) {
        List<FieldInfo> fields = new List<FieldInfo>();
        Schema.SObjectType sObjectType = Schema.getGlobalDescribe().get(objectApiName);
        if (sObjectType == null) return fields;
        if (!sObjectType.getDescribe().isAccessible()) return fields;

        Map<String, Schema.SObjectField> fieldMap = sObjectType.getDescribe().fields.getMap();
        List<String> sortedFieldNames = new List<String>(fieldMap.keySet());
        sortedFieldNames.sort();

        for (String fieldName : sortedFieldNames) {
            Schema.DescribeFieldResult d = fieldMap.get(fieldName).getDescribe();
            if (!d.isAccessible()) continue;
            FieldInfo f = new FieldInfo();
            f.apiName = d.getName();
            f.label = d.getLabel();
            f.type = String.valueOf(d.getType());
            f.nillable = d.isNillable();
            f.updateable = d.isUpdateable();
            f.externalId = d.isExternalID();
            f.length = d.getLength();
            List<Schema.SObjectType> refs = d.getReferenceTo();
            f.referenceTo = refs.isEmpty() ? '' : refs[0].getDescribe().getName();
            fields.add(f);
        }
        return fields;
    }

    @AuraEnabled(cacheable=true)
    public static Map<String, Object> getOrgLimits() {
        Map<String, Object> limitsMap = new Map<String, Object>();
        for (System.OrgLimit lim : OrgLimits.getAll()) {
            limitsMap.put(lim.getName(), new Map<String, Object>{
                'used' => lim.getValue(),
                'max'  => lim.getLimit()
            });
        }
        return limitsMap;
    }

    @AuraEnabled(cacheable=true)
    public static List<String> getPicklistValues(String objectApiName, String fieldApiName) {
        List<String> values = new List<String>();
        Schema.SObjectType sot = Schema.getGlobalDescribe().get(objectApiName);
        if (sot == null) return values;
        Schema.SObjectField fld = sot.getDescribe().fields.getMap().get(fieldApiName.toLowerCase());
        if (fld == null) return values;
        for (Schema.PicklistEntry pe : fld.getDescribe().getPicklistValues()) {
            if (pe.isActive()) values.add(pe.getValue());
        }
        return values;
    }

    @AuraEnabled
    public static String updateRecord(String recordId, String updatesJson) {
        try {
            Id sfId = Id.valueOf(recordId.trim());
            Schema.DescribeSObjectResult sod = sfId.getSObjectType().getDescribe();
            if (!sod.isUpdateable()) {
                return 'Insufficient permissions to update ' + sod.getName() + ' records.';
            }
            String objectType = sod.getName();
            Map<String, Schema.SObjectField> fieldMap =
                Schema.getGlobalDescribe().get(objectType).getDescribe().fields.getMap();

            Map<String, Object> updates = (Map<String, Object>) JSON.deserializeUntyped(updatesJson);
            SObject obj = Schema.getGlobalDescribe().get(objectType).newSObject();
            obj.put('Id', sfId);

            for (String fieldName : updates.keySet()) {
                String fLower = fieldName.toLowerCase();
                if (!fieldMap.containsKey(fLower)) continue;
                Schema.DescribeFieldResult fd = fieldMap.get(fLower).getDescribe();
                if (!fd.isUpdateable()) continue;
                Object rawVal = updates.get(fieldName);
                if (rawVal == null || String.valueOf(rawVal).trim() == '') {
                    obj.put(fd.getName(), null);
                } else {
                    obj.put(fd.getName(), castFieldValue(fd.getType(), rawVal));
                }
            }
            update obj;
            return 'success';
        } catch (DmlException e) {
            return e.getDmlMessage(0);
        } catch (Exception e) {
            return 'An error occurred. Please verify the record ID and field values.';
        }
    }

    private static Object castFieldValue(Schema.DisplayType t, Object value) {
        String str = String.valueOf(value).trim();
        switch on t {
            when INTEGER                       { return Integer.valueOf(str); }
            when DOUBLE, CURRENCY, PERCENT     { return Decimal.valueOf(str); }
            when BOOLEAN                       { return Boolean.valueOf(str); }
            when DATE                          { return Date.valueOf(str); }
            when DATETIME                      { return Datetime.valueOf(str); }
            when else                          { return str; }
        }
    }

    @AuraEnabled
    public static Map<String, Object> getRecord(String recordId) {
        Map<String, Object> result = new Map<String, Object>();
        try {
            Id sfId = Id.valueOf(recordId.trim());
            Schema.DescribeSObjectResult sod = sfId.getSObjectType().getDescribe();
            if (!sod.isAccessible()) {
                result.put('error', 'Insufficient permissions to access ' + sod.getName() + ' records.');
                return result;
            }
            String objectType = sod.getName();

            Map<String, Schema.SObjectField> fieldMap =
                Schema.getGlobalDescribe().get(objectType).getDescribe().fields.getMap();

            List<String> accessibleFields = new List<String>();
            for (String fn : fieldMap.keySet()) {
                if (fieldMap.get(fn).getDescribe().isAccessible()) {
                    accessibleFields.add(fieldMap.get(fn).getDescribe().getName());
                }
            }

            String soql = 'SELECT ' + String.join(accessibleFields, ',')
                + ' FROM ' + objectType
                + ' WHERE Id = \'' + String.escapeSingleQuotes(recordId.trim()) + '\''
                + ' LIMIT 1';

            List<SObject> records = Database.query(soql);
            if (!records.isEmpty()) {
                result = new Map<String, Object>(records[0].getPopulatedFieldsAsMap());
                result.put('__objectType__', objectType);
            } else {
                result.put('error', 'Record not found');
            }
        } catch (Exception e) {
            result.put('error', e.getMessage());
        }
        return result;
    }
}
