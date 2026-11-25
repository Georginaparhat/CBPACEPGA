/**
 * CBPPGA-88. ACE PGA provisioning lifecycle: Draft ─► Pending BI Review ─► Ready for Provisioning
 * ─► Provisioned ─► ACE Security Review ─► Complete, and Unfavorable BI Determination.
 * The AES / GCMC recipients come from the ACEF_System_Notification__mdt records (AES, GCMC).
 */
@IsTest
private class ACEF_PackageLifecycleServiceTest {
  /** Form 7300 past Security / PSO (7300 Pending BI Determination), with ACE Portal access, linked both ways. */
  private static ACEF_PGA_Application__c newPackage(Boolean formsComplete, String systems) {
    ACEF_Form_7300_Request__c req = new ACEF_Form_7300_Request__c(
      ACEF_Status__c = 'With 7300 Processing',
      ACEF_ACE_Access_Requested__c = true
    );
    insert req;
    ACEF_PGA_Application__c pkg = new ACEF_PGA_Application__c(
      ACEF_Form_7300_Request__c = req.Id,
      ACEF_Form001_User_Complete__c = formsComplete,
      ACEF_Form001_Supervisor_Complete__c = formsComplete,
      ACEF_Form002_Complete__c = formsComplete,
      ACEF_NDA_Uploaded__c = formsComplete,
      ACEF_Requested_Systems__c = systems,
      ACEF_Form001_Applicant_Name__c = 'Pat Applicant',
      ACEF_Work_Email__c = 'pat@agency.example.gov'
    );
    insert pkg;
    update new ACEF_Form_7300_Request__c(Id = req.Id, ACEF_PGA_Application__c = pkg.Id);
    return pkg;
  }

  private static ACEF_PGA_Application__c reload(Id packageId) {
    return [
      SELECT
        ACEF_Status__c,
        ACEF_Submitted_At__c,
        ACEF_Submitted_By__c,
        ACEF_Hash_Id__c,
        ACEF_Provisioning_Status__c,
        ACEF_AES_Notified_At__c,
        ACEF_GCMC_Notified_At__c,
        ACEF_System_Notification_Log__c,
        ACEF_ACE_Security_Verified__c,
        ACEF_Form_7300_Request__c
      FROM ACEF_PGA_Application__c
      WHERE Id = :packageId
    ];
  }

  private static void setStatus(Id packageId, String status) {
    update new ACEF_PGA_Application__c(Id = packageId, ACEF_Status__c = status);
  }

  @IsTest
  static void newPackageStartsInDraftAndCannotSubmitUntilFullPackageIsIn() {
    ACEF_PGA_Application__c pkg = newPackage(false, null);
    System.assertEquals('Draft', reload(pkg.Id).ACEF_Status__c);

    ACEF_PackageLifecycleService.ActionContext ctx = ACEF_PackageLifecycleService.getActionContext(pkg.Id, 'submit');
    System.assert(!ctx.allowed);
    System.assertEquals(5, ctx.checklist.size(), '7300, application (applicant and supervisor), Rules, NDA');
    System.assert(ctx.checklist[0].passed, '7300 is through Security / PSO');
    System.assert(!ctx.checklist[1].passed);
    try {
      ACEF_PackageLifecycleService.submitRequest(pkg.Id);
      System.assert(false, 'Submit needs the full package');
    } catch (AuraHandledException e) {
      System.assert(true);
    }
    System.assertEquals('Draft', reload(pkg.Id).ACEF_Status__c);
  }

  @IsTest
  static void fullPackageIsSubmittedAutomatically() {
    ACEF_PGA_Application__c pkg = newPackage(false, null);
    Test.startTest();
    update new ACEF_PGA_Application__c(
      Id = pkg.Id,
      ACEF_Form001_User_Complete__c = true,
      ACEF_Form001_Supervisor_Complete__c = true,
      ACEF_Form002_Complete__c = true,
      ACEF_NDA_Uploaded__c = true
    );
    Test.stopTest();
    pkg = reload(pkg.Id);
    System.assertEquals('Pending BI Review', pkg.ACEF_Status__c, 'No separate Submitted status');
    System.assertNotEquals(null, pkg.ACEF_Submitted_At__c);
    System.assertEquals(ACEF_PackageLifecycleService.AUTO_SUBMITTER, pkg.ACEF_Submitted_By__c);
    System.assert(!ACEF_PackageLifecycleService.getActionContext(pkg.Id, 'submit').allowed, 'Already submitted');
  }

  @IsTest
  static void submitRequestMovesDraftToPendingBiReview() {
    ACEF_PackageLifecycleService.autoSubmitDisabled = true;
    ACEF_PGA_Application__c pkg = newPackage(true, null);
    System.assertEquals('Draft', reload(pkg.Id).ACEF_Status__c);
    ACEF_PackageLifecycleService.autoSubmitDisabled = false;

    ACEF_PackageLifecycleService.ActionContext ctx = ACEF_PackageLifecycleService.getActionContext(pkg.Id, 'submit');
    System.assert(ctx.allowed, ctx.message);
    Test.startTest();
    ACEF_PackageLifecycleService.submitRequest(pkg.Id);
    Test.stopTest();
    pkg = reload(pkg.Id);
    System.assertEquals('Pending BI Review', pkg.ACEF_Status__c);
    System.assertEquals(UserInfo.getName(), pkg.ACEF_Submitted_By__c);
  }

  @IsTest
  static void biAdjudicationWaitsForPendingBiReviewThenFavorableIsReadyForProvisioning() {
    ACEF_PGA_Application__c pkg = newPackage(false, null);
    Id requestId = pkg.ACEF_Form_7300_Request__c;
    System.assertNotEquals(null, ACEF_PackageLifecycleService.biBlockReason(requestId), 'Draft: BI waits');
    try {
      ACEF_ProvisioningUiActions.recordBiDisposition(requestId, 'Favorable', null);
      System.assert(false, 'BI waits for Pending BI Review');
    } catch (AuraHandledException e) {
      System.assert(true);
    }

    Test.startTest();
    update new ACEF_PGA_Application__c(
      Id = pkg.Id,
      ACEF_Form001_User_Complete__c = true,
      ACEF_Form001_Supervisor_Complete__c = true,
      ACEF_Form002_Complete__c = true,
      ACEF_NDA_Uploaded__c = true
    );
    System.assertEquals(null, ACEF_PackageLifecycleService.biBlockReason(requestId));
    ACEF_PortalWorkflowService.recordVetting(requestId, 'Favorable', null);
    Test.stopTest();
    System.assertEquals('Ready for Provisioning', reload(pkg.Id).ACEF_Status__c);
    System.assert(ACEF_PackageLifecycleService.biBlockReason(requestId).contains('Ready for Provisioning'));
  }

  @IsTest
  static void unfavorableBiStopsProcessing() {
    ACEF_PGA_Application__c pkg = newPackage(true, null);
    System.assertEquals('Pending BI Review', reload(pkg.Id).ACEF_Status__c);
    Test.startTest();
    ACEF_PortalWorkflowService.recordVetting(pkg.ACEF_Form_7300_Request__c, 'Unfavorable', 'Not cleared.');
    Test.stopTest();
    System.assertEquals('Unfavorable BI Determination', reload(pkg.Id).ACEF_Status__c);
    System.assert(!ACEF_PackageLifecycleService.getActionContext(pkg.Id, 'provision').allowed);
  }

  @IsTest
  static void provisionEmailsAesAndGcmcTeamsWhenRequested() {
    ACEF_PGA_Application__c pkg = newPackage(true, 'ACE_Reports;AES;GCMC');
    setStatus(pkg.Id, 'Ready for Provisioning');

    ACEF_PackageLifecycleService.ActionContext ctx = ACEF_PackageLifecycleService.getActionContext(pkg.Id, 'provision');
    System.assert(ctx.allowed, ctx.message);
    System.assertEquals(2, ctx.notifyTeams.size(), 'AES and GCMC teams: ' + ctx.notifyTeams);

    Test.startTest();
    ACEF_PackageLifecycleService.provision(pkg.Id, 'Provisioned in ACE');
    Integer emailCalls = Limits.getEmailInvocations();
    Test.stopTest();

    System.assertEquals(1, emailCalls, 'One send with both team emails');
    pkg = reload(pkg.Id);
    System.assertEquals('ACE Security Review', pkg.ACEF_Status__c, 'Provisioned, then on to ACE Security Review');
    System.assertEquals('Complete', pkg.ACEF_Provisioning_Status__c);
    System.assert(String.isNotBlank(pkg.ACEF_Hash_Id__c));
    System.assertNotEquals(null, pkg.ACEF_AES_Notified_At__c);
    System.assertNotEquals(null, pkg.ACEF_GCMC_Notified_At__c);
    System.assert(pkg.ACEF_System_Notification_Log__c.contains('aes-team@example.com'), pkg.ACEF_System_Notification_Log__c);
  }

  @IsTest
  static void provisionWithoutAesOrGcmcSendsNoEmail() {
    ACEF_PGA_Application__c pkg = newPackage(true, 'ACE_Reports');
    update new ACEF_PGA_Application__c(Id = pkg.Id, ACEF_Systems_Remove__c = 'AES', ACEF_Status__c = 'Ready for Provisioning');
    System.assert(ACEF_PackageLifecycleService.getActionContext(pkg.Id, 'provision').notifyTeams.isEmpty(), 'Remove is not a request');

    Test.startTest();
    ACEF_PackageLifecycleService.provision(pkg.Id, null);
    Integer emailCalls = Limits.getEmailInvocations();
    Test.stopTest();

    System.assertEquals(0, emailCalls);
    pkg = reload(pkg.Id);
    System.assertEquals('ACE Security Review', pkg.ACEF_Status__c);
    System.assertEquals(null, pkg.ACEF_AES_Notified_At__c);
    System.assert(pkg.ACEF_System_Notification_Log__c.contains('not requested'));
  }

  @IsTest
  static void actionsAreOnlyAvailableInTheirStatus() {
    ACEF_PGA_Application__c pkg = newPackage(true, 'AES');
    System.assertEquals('Pending BI Review', reload(pkg.Id).ACEF_Status__c);
    try {
      ACEF_PackageLifecycleService.provision(pkg.Id, null);
      System.assert(false, 'Provision needs Ready for Provisioning');
    } catch (AuraHandledException e) {
      System.assert(true);
    }
    try {
      ACEF_ProvisioningUiActions.verifyAceSecurity(pkg.Id, null);
      System.assert(false, 'Complete Security Review needs ACE Security Review');
    } catch (AuraHandledException e) {
      System.assert(true);
    }
    System.assert(!ACEF_PackageLifecycleService.getActionContext(pkg.Id, 'security').allowed);
    try {
      ACEF_PackageLifecycleService.getActionContext(pkg.Id, 'unknown');
      System.assert(false, 'Unknown action');
    } catch (AuraHandledException e) {
      System.assert(true);
    }
  }

  @IsTest
  static void completeSecurityReviewMovesToComplete() {
    ACEF_PGA_Application__c pkg = newPackage(true, null);
    setStatus(pkg.Id, 'Ready for Provisioning');
    ACEF_PackageLifecycleService.provision(pkg.Id, null);
    System.assert(ACEF_PackageLifecycleService.getActionContext(pkg.Id, 'security').allowed);

    Test.startTest();
    ACEF_ProvisioningUiActions.verifyAceSecurity(pkg.Id, 'Reviewed');
    Test.stopTest();

    pkg = reload(pkg.Id);
    System.assertEquals('Complete', pkg.ACEF_Status__c);
    System.assert(pkg.ACEF_ACE_Security_Verified__c);
  }
}