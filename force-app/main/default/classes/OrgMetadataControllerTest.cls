@isTest
private class OrgMetadataControllerTest {

    @TestSetup
    static void makeData() {
        Account a = new Account(Name = 'Test Record', AccountSource = 'Web');
        List<RecordType> rts = [
            SELECT Id FROM RecordType
            WHERE SObjectType = 'Account' AND IsActive = true
            LIMIT 1
        ];
        if (!rts.isEmpty()) {
            a.RecordTypeId = rts[0].Id;
        }
        insert a;
    }

    // ── getObjects ──────────────────────────────────────────────

    @isTest
    static void testGetObjects_returnsQueryableObjects() {
        List<OrgMetadataController.ObjectInfo> objs = OrgMetadataController.getObjects();
        Assert.isTrue(objs.size() > 0);
        Boolean hasAccount = false;
        for (OrgMetadataController.ObjectInfo o : objs) {
            if (o.apiName == 'Account') { hasAccount = true; break; }
        }
        Assert.isTrue(hasAccount, 'Account should be in the queryable object list');
    }

    // ── getFields ───────────────────────────────────────────────

    @isTest
    static void testGetFields_validObject() {
        List<OrgMetadataController.FieldInfo> fields = OrgMetadataController.getFields('Account');
        Assert.isTrue(fields.size() > 0);
        Boolean hasName = false;
        for (OrgMetadataController.FieldInfo f : fields) {
            if (f.apiName == 'Name') { hasName = true; break; }
        }
        Assert.isTrue(hasName, 'Name field should be present on Account');
    }

    @isTest
    static void testGetFields_invalidObject() {
        List<OrgMetadataController.FieldInfo> fields = OrgMetadataController.getFields('FakeObject__c');
        Assert.areEqual(0, fields.size(), 'Unknown object should return empty list');
    }

    // ── getOrgLimits ────────────────────────────────────────────

    @isTest
    static void testGetOrgLimits_returnsData() {
        Map<String, Object> limits = OrgMetadataController.getOrgLimits();
        Assert.isNotNull(limits);
        Assert.isTrue(limits.size() > 0, 'Should return at least one org limit');
    }

    // ── getPicklistValues ───────────────────────────────────────

    @isTest
    static void testGetPicklistValues_validField() {
        List<String> values = OrgMetadataController.getPicklistValues('Account', 'AccountSource');
        Assert.isNotNull(values);
    }

    @isTest
    static void testGetPicklistValues_invalidObject() {
        List<String> values = OrgMetadataController.getPicklistValues('FakeObject__c', 'Status');
        Assert.areEqual(0, values.size());
    }

    @isTest
    static void testGetPicklistValues_invalidField() {
        List<String> values = OrgMetadataController.getPicklistValues('Account', 'FakeField__c');
        Assert.areEqual(0, values.size());
    }

    // ── getRecord ───────────────────────────────────────────────

    @isTest
    static void testGetRecord_validId() {
        Account a = [SELECT Id FROM Account LIMIT 1];
        Map<String, Object> result = OrgMetadataController.getRecord(a.Id);
        Assert.isFalse(result.containsKey('error'), 'Valid ID should not produce an error');
        Assert.areEqual('Account', result.get('__objectType__'));
    }

    @isTest
    static void testGetRecord_invalidId() {
        Map<String, Object> result = OrgMetadataController.getRecord('notAnId');
        Assert.isTrue(result.containsKey('error'), 'Invalid ID should return an error');
    }

    @isTest
    static void testGetRecord_notFound() {
        // Valid-format but non-existent ID
        Map<String, Object> result = OrgMetadataController.getRecord('001000000000000AAA');
        Assert.isTrue(result.containsKey('error'), 'Non-existent record should return an error');
    }

    // ── updateRecord ────────────────────────────────────────────

    @isTest
    static void testUpdateRecord_success() {
        Account a = [SELECT Id FROM Account LIMIT 1];
        String updatesJson = '{"Name":"Updated by Test"}';
        Test.startTest();
        String result = OrgMetadataController.updateRecord(a.Id, updatesJson);
        Test.stopTest();
        Assert.areEqual('success', result);
        Account updated = [SELECT Name FROM Account WHERE Id = :a.Id];
        Assert.areEqual('Updated by Test', updated.Name);
    }

    @isTest
    static void testUpdateRecord_invalidId() {
        String result = OrgMetadataController.updateRecord('notAnId', '{}');
        Assert.areNotEqual('success', result, 'Invalid ID should not return success');
    }

    @isTest
    static void testUpdateRecord_nonUpdateableFieldSkipped() {
        Account a = [SELECT Id FROM Account LIMIT 1];
        // IsDeleted is never updateable; the controller should silently skip it and still succeed
        String updatesJson = '{"IsDeleted":"true","Name":"After Skip Test"}';
        Test.startTest();
        String result = OrgMetadataController.updateRecord(a.Id, updatesJson);
        Test.stopTest();
        Assert.areEqual('success', result);
    }

    @isTest
    static void testUpdateRecord_emptyUpdates() {
        Account a = [SELECT Id FROM Account LIMIT 1];
        Test.startTest();
        String result = OrgMetadataController.updateRecord(a.Id, '{}');
        Test.stopTest();
        Assert.areEqual('success', result);
    }

    // ── getCurrentUser ──────────────────────────────────────────

    @isTest
    static void testGetCurrentUser_returnsCurrentUser() {
        Test.startTest();
        Map<String, Object> u = OrgMetadataController.getCurrentUser();
        Test.stopTest();
        Assert.isNotNull(u.get('Id'),       'Should return current user Id');
        Assert.isNotNull(u.get('Name'),     'Should return current user Name');
        Assert.isNotNull(u.get('Username'), 'Should return current user Username');
        Assert.areEqual(UserInfo.getUserId(), u.get('Id'), 'Id should match running user');
    }

    // ── searchUsers ─────────────────────────────────────────────

    @isTest
    static void testSearchUsers_blank() {
        Test.startTest();
        List<Map<String, Object>> results = OrgMetadataController.searchUsers('');
        Test.stopTest();
        Assert.areEqual(0, results.size(), 'Blank search term should return empty list');
    }

    @isTest
    static void testSearchUsers_found() {
        String name = UserInfo.getName();
        Test.startTest();
        List<Map<String, Object>> results =
            OrgMetadataController.searchUsers(name.substring(0, Math.min(3, name.length())));
        Test.stopTest();
        Assert.isNotNull(results, 'Should return a non-null list');
    }

    @isTest
    static void testSearchUsers_noMatch() {
        Test.startTest();
        List<Map<String, Object>> results =
            OrgMetadataController.searchUsers('XYZXYZ_NoMatch_99999');
        Test.stopTest();
        Assert.areEqual(0, results.size(), 'No-match search should return empty list');
    }
}
