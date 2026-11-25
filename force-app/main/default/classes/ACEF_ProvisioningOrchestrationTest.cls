@IsTest
private class ACEF_ProvisioningOrchestrationTest {
    private static ACEF_PGA_Application__c readyPackage() {
        ACEF_Form_7300_Request__c req = new ACEF_Form_7300_Request__c(
            ACEF_Status__c = 'Section 4 Complete',
            ACEF_BI_Disposition__c = 'Favorable'
        );
        insert req;
        ACEF_PGA_Application__c pkg = new ACEF_PGA_Application__c(
            ACEF_Form_7300_Request__c = req.Id,
            ACEF_Form001_User_Complete__c = true,
            ACEF_Form001_Supervisor_Complete__c = true,
            ACEF_Form002_Complete__c = true,
            ACEF_NDA_Uploaded__c = true,
            ACEF_Access_Area__c = 'ACE Portal'
        );
        insert pkg;
        req.ACEF_PGA_Application__c = pkg.Id;
        update req;
        return pkg;
    }

    @IsTest
    static void routeProvisioningSetsHashAndStatus() {
        ACEF_PGA_Application__c pkg = readyPackage();
        pkg.ACEF_Readiness_Status__c = 'Approved';
        update pkg;

        Test.startTest();
        ACEF_ProvisioningOrchestration.routeForProvisioning(pkg.Id, 'ACE Portal');
        Test.stopTest();

        pkg = [
            SELECT ACEF_Package_Status__c, ACEF_Provisioning_Status__c, ACEF_Hash_Id__c
            FROM ACEF_PGA_Application__c
            WHERE Id = :pkg.Id
        ];
        System.assertEquals('Provisioning', pkg.ACEF_Package_Status__c);
        System.assertEquals('Requested', pkg.ACEF_Provisioning_Status__c);
        System.assert(String.isNotBlank(pkg.ACEF_Hash_Id__c));
    }

    @IsTest
    static void unfavorableBiClosesPackage() {
        ACEF_PGA_Application__c pkg = readyPackage();
        ACEF_Form_7300_Request__c req = [
            SELECT Id
            FROM ACEF_Form_7300_Request__c
            WHERE Id = :pkg.ACEF_Form_7300_Request__c
        ];

        Test.startTest();
        ACEF_ProvisioningOrchestration.applyBiDisposition(req.Id, 'Unfavorable', 'Failed check');
        Test.stopTest();

        pkg = [SELECT ACEF_Package_Status__c, ACEF_Status__c, ACEF_Ready_For_Readiness__c FROM ACEF_PGA_Application__c WHERE Id = :pkg.Id];
        System.assertEquals('Closed', pkg.ACEF_Package_Status__c);
        System.assertEquals('Unfavorable BI Determination', pkg.ACEF_Status__c);
        System.assertEquals(false, pkg.ACEF_Ready_For_Readiness__c);
    }

    /** CBPPGA-88 took Start Readiness Vetting, Route and Mark Complete off the layout; the code is kept and still works. */
    @IsTest
    static void keptReadinessRouteAndCompleteActionsStillWork() {
        ACEF_PGA_Application__c pkg = readyPackage();
        ACEF_PGA_Application__c rejected = readyPackage();
        ACEF_PGA_Application__c held = readyPackage();

        Test.startTest();
        ACEF_ProvisioningUiActions.applyReadinessDecision(pkg.Id, 'Approve', 'ok');
        ACEF_ProvisioningUiActions.applyReadinessDecision(rejected.Id, 'Reject', 'no');
        ACEF_ProvisioningUiActions.applyReadinessDecision(held.Id, 'Hold', 'wait');
        ACEF_ProvisioningUiActions.routeForProvisioning(pkg.Id, 'ACE Portal');
        ACEF_ProvisioningUiActions.markProvisioningComplete(pkg.Id, 'done');
        Test.stopTest();

        System.assertEquals(
            'Complete',
            [SELECT ACEF_Provisioning_Status__c FROM ACEF_PGA_Application__c WHERE Id = :pkg.Id].ACEF_Provisioning_Status__c
        );
        System.assertEquals(
            'Rejected',
            [SELECT ACEF_Readiness_Status__c FROM ACEF_PGA_Application__c WHERE Id = :rejected.Id].ACEF_Readiness_Status__c
        );
        System.assertEquals(
            'On Hold',
            [SELECT ACEF_Readiness_Status__c FROM ACEF_PGA_Application__c WHERE Id = :held.Id].ACEF_Readiness_Status__c
        );
    }

    /** Kurt's package after-update hook (not wired to the trigger): Package Complete and the ATS flag. */
    @IsTest
    static void afterPackageUpdateMarksPackageCompleteAndNotifiesAts() {
        ACEF_PGA_Application__c pkg = readyPackage();
        update new ACEF_PGA_Application__c(
            Id = pkg.Id,
            ACEF_Package_Status__c = 'Provisioning',
            ACEF_Roles_Requested__c = 'AES filer'
        );
        ACEF_PGA_Application__c prior = new ACEF_PGA_Application__c(Id = pkg.Id, ACEF_Package_Status__c = 'NDA Upload Pending');
        ACEF_PGA_Application__c row = [
            SELECT Id, ACEF_Package_Status__c, ACEF_Ready_For_Readiness__c, ACEF_Roles_Requested__c
            FROM ACEF_PGA_Application__c
            WHERE Id = :pkg.Id
        ];

        Test.startTest();
        ACEF_ProvisioningOrchestration.afterPgaApplicationUpdate(
            new List<ACEF_PGA_Application__c>{ row },
            new Map<Id, ACEF_PGA_Application__c>{ pkg.Id => prior }
        );
        row.ACEF_Package_Status__c = 'Draft';
        ACEF_ProvisioningOrchestration.afterPgaApplicationUpdate(
            new List<ACEF_PGA_Application__c>{ row },
            new Map<Id, ACEF_PGA_Application__c>{ pkg.Id => prior }
        );
        ACEF_ProvisioningOrchestration.syncPackageFlags(new List<Id>{ pkg.Id });
        ACEF_ProvisioningOrchestration.syncPackageFlags(null);
        Test.stopTest();

        row = [SELECT ACEF_Package_Status__c, ACEF_ATS_Notified__c FROM ACEF_PGA_Application__c WHERE Id = :pkg.Id];
        System.assertEquals(true, row.ACEF_ATS_Notified__c, 'Routed to Provisioning with AES roles');
        System.assertEquals('Package Complete', row.ACEF_Package_Status__c);
    }

    @IsTest
    static void verifyAceSecurityRequiresProvisioningComplete() {
        ACEF_PGA_Application__c pkg = readyPackage();
        Boolean threw = false;
        try {
            ACEF_ProvisioningOrchestration.verifyAceSecurity(pkg.Id, null);
        } catch (Exception ex) {
            threw = true;
        }
        System.assertEquals(true, threw);
    }
}