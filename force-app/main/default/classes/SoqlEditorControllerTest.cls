@isTest
private class SoqlEditorControllerTest {

    @TestSetup
    static void makeData() {
        Account a = new Account(Name = 'Test Account');
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

    // ── executeQuery ────────────────────────────────────────────

    @isTest
    static void testExecuteQuery_success() {
        SoqlEditorController.QueryResult r =
            SoqlEditorController.executeQuery('SELECT Id, Name FROM Account LIMIT 1');
        Assert.isNull(r.error, 'Valid SELECT should not return an error');
        Assert.isTrue(r.totalRows >= 0);
        Assert.isTrue(r.columns.contains('Id'));
    }

    @isTest
    static void testExecuteQuery_nonSelectBlocked() {
        SoqlEditorController.QueryResult r =
            SoqlEditorController.executeQuery('FIND {Test} IN ALL FIELDS RETURNING Account');
        Assert.isNotNull(r.error, 'Non-SELECT query should return an error');
        Assert.isTrue(r.error.contains('Only SELECT'));
    }

    @isTest
    static void testExecuteQuery_invalidSyntax() {
        SoqlEditorController.QueryResult r =
            SoqlEditorController.executeQuery('SELECT FROM');
        Assert.isNotNull(r.error, 'Invalid SOQL syntax should produce an error');
    }

    @isTest
    static void testExecuteQuery_emptyResult() {
        SoqlEditorController.QueryResult r =
            SoqlEditorController.executeQuery('SELECT Id FROM Account WHERE Name = \'NoSuchRecord_XYZ\'');
        Assert.isNull(r.error);
        Assert.areEqual(0, r.totalRows);
        Assert.isTrue(r.rows.isEmpty());
    }

    @isTest
    static void testExecuteQuery_fieldsStandard() {
        SoqlEditorController.QueryResult r =
            SoqlEditorController.executeQuery('SELECT FIELDS(STANDARD) FROM Account LIMIT 1');
        Assert.isNull(r.error, 'FIELDS(STANDARD) should expand and execute without error');
        Assert.isTrue(r.columns.contains('Id'), 'Expanded query should include Id column');
    }

    @isTest
    static void testExecuteQuery_fieldsCustom() {
        SoqlEditorController.QueryResult r =
            SoqlEditorController.executeQuery('SELECT FIELDS(CUSTOM) FROM Account LIMIT 1');
        Assert.isNull(r.error, 'FIELDS(CUSTOM) should expand and execute without error');
    }

    @isTest
    static void testExecuteQuery_allColumnsFromAllRecords() {
        SoqlEditorController.QueryResult r =
            SoqlEditorController.executeQuery('SELECT Id, Name FROM Account');
        Assert.isNull(r.error);
        Assert.isTrue(r.columns.contains('Id'));
        Assert.isTrue(r.columns.contains('Name'));
    }

    // ── executeQueryAll ─────────────────────────────────────────

    @isTest
    static void testExecuteQueryAll_success() {
        SoqlEditorController.QueryResult r =
            SoqlEditorController.executeQueryAll('SELECT Id FROM Account');
        Assert.isNull(r.error);
        Assert.isTrue(r.totalRows >= 0);
    }

    @isTest
    static void testExecuteQueryAll_alreadyContainsAllRows() {
        SoqlEditorController.QueryResult r =
            SoqlEditorController.executeQueryAll('SELECT Id FROM Account ALL ROWS');
        Assert.isNull(r.error);
    }

    @isTest
    static void testExecuteQueryAll_nonSelectBlocked() {
        SoqlEditorController.QueryResult r =
            SoqlEditorController.executeQueryAll('FIND {Test} IN ALL FIELDS RETURNING Account');
        Assert.isNotNull(r.error);
        Assert.isTrue(r.error.contains('Only SELECT'));
    }

    // ── executeToolingQuery ─────────────────────────────────────

    private class ToolingSuccessMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);
            res.setBody('{"totalSize":1,"records":[{"Id":"01p000000000001AAA","Name":"MyClass"}]}');
            return res;
        }
    }

    private class ToolingErrorMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(400);
            res.setBody('{"errorCode":"INVALID_QUERY","message":"unexpected token: INVALID"}');
            return res;
        }
    }

    @isTest
    static void testExecuteToolingQuery_success() {
        Test.setMock(HttpCalloutMock.class, new ToolingSuccessMock());
        Test.startTest();
        SoqlEditorController.QueryResult r =
            SoqlEditorController.executeToolingQuery('SELECT Id, Name FROM ApexClass LIMIT 1');
        Test.stopTest();
        Assert.isNull(r.error);
        Assert.areEqual(1, r.totalRows);
        Assert.isTrue(r.columns.contains('Id'));
    }

    @isTest
    static void testExecuteToolingQuery_apiError() {
        Test.setMock(HttpCalloutMock.class, new ToolingErrorMock());
        Test.startTest();
        SoqlEditorController.QueryResult r =
            SoqlEditorController.executeToolingQuery('SELECT INVALID FROM ApexClass');
        Test.stopTest();
        Assert.isNotNull(r.error);
    }

    // ── importRecords ───────────────────────────────────────────

    // Returns a RecordTypeId field fragment when the org requires one on Account.
    private static String rtFragment() {
        List<RecordType> rts = [
            SELECT Id FROM RecordType
            WHERE SObjectType = 'Account' AND IsActive = true
            LIMIT 1
        ];
        return rts.isEmpty() ? '' : ',"RecordTypeId":"' + rts[0].Id + '"';
    }

    @isTest
    static void testImportRecords_insertSuccess() {
        String payload = '[{"Name":"Imported Account"' + rtFragment() + '}]';
        Test.startTest();
        SoqlEditorController.ImportResult r = SoqlEditorController.importRecords(
            'Account', 'insert', null, payload
        );
        Test.stopTest();
        Assert.areEqual(1, r.successCount);
        Assert.areEqual(0, r.errorCount);
    }

    @isTest
    static void testImportRecords_updateSuccess() {
        Account a = [SELECT Id FROM Account LIMIT 1];
        String payload = '[{"Id":"' + a.Id + '","Name":"Updated Name"}]';
        Test.startTest();
        SoqlEditorController.ImportResult r =
            SoqlEditorController.importRecords('Account', 'update', null, payload);
        Test.stopTest();
        Assert.areEqual(1, r.successCount);
        Assert.areEqual(0, r.errorCount);
    }

    @isTest
    static void testImportRecords_upsertNoExternalId() {
        String payload = '[{"Name":"Upserted Account"' + rtFragment() + '}]';
        Test.startTest();
        SoqlEditorController.ImportResult r = SoqlEditorController.importRecords(
            'Account', 'upsert', null, payload
        );
        Test.stopTest();
        Assert.areEqual(0, r.errorCount);
    }

    @isTest
    static void testImportRecords_upsertWithUnknownExternalIdField() {
        String payload = '[{"Name":"Upserted Account 2"' + rtFragment() + '}]';
        Test.startTest();
        SoqlEditorController.ImportResult r = SoqlEditorController.importRecords(
            'Account', 'upsert', 'FakeExternalId__c', payload
        );
        Test.stopTest();
        // Falls back to standard upsert when the external ID field is not found
        Assert.areEqual(0, r.errorCount);
    }

    @isTest
    static void testImportRecords_unknownObject() {
        Test.startTest();
        SoqlEditorController.ImportResult r = SoqlEditorController.importRecords(
            'FakeObject__c', 'insert', null, '[{"Name":"Test"}]'
        );
        Test.stopTest();
        Assert.isTrue(r.errorCount > 0);
        Assert.isTrue(r.errors[0].contains('Unknown object'));
    }

    @isTest
    static void testImportRecords_batchSizeExceeded() {
        List<Map<String, Object>> records = new List<Map<String, Object>>();
        for (Integer i = 0; i < 201; i++) {
            records.add(new Map<String, Object>{ 'Name' => 'Batch Account ' + i });
        }
        Test.startTest();
        SoqlEditorController.ImportResult r = SoqlEditorController.importRecords(
            'Account', 'insert', null, JSON.serialize(records)
        );
        Test.stopTest();
        Assert.isTrue(r.errorCount > 0, 'Should reject batches over 200 records');
        Assert.isTrue(r.errors[0].contains('200'));
    }
}
