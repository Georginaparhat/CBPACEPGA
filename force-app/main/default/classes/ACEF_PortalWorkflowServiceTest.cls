@isTest
private class ACEF_PortalWorkflowServiceTest {
  private static ACEF_Form_7300_Request__c newRequest() {
    ACEF_Form_7300_Request__c request = new ACEF_Form_7300_Request__c(ACEF_Status__c = 'Draft');
    insert request;
    return request;
  }

  /** Submits Form 7300 Test 2 for the request; withCbp adds a CBP supervisor (section 3). */
  private static void submitForm7300(Id requestId, Boolean withCbp) {
    ACEF_CBP_Form_7300__c form = ACEF_Form7300TestData.insertPending();
    if (withCbp) {
      update new ACEF_CBP_Form_7300__c(
        Id = form.Id,
        ACEF_CBP_Supervisor_Applies__c = true,
        ACEF_CBP_Supervisor_Email__c = 'casey.cbp@cbp.example.gov'
      );
    }
    String confirmation = [SELECT Name FROM ACEF_CBP_Form_7300__c WHERE Id = :form.Id].Name;
    ACEF_PortalCbpForm7300Service.linkSubmittedForm(requestId, confirmation);
  }

  private static ACEF_Form_7300_Request__c reload(Id requestId) {
    return [
      SELECT ACEF_Status__c, ACEF_BI_Disposition__c, ACEF_PGA_Application__c, ACEF_ACE_Access_Requested__c,
        ACEF_Sec2_Decision__c, ACEF_Section2_Signed_By__c, ACEF_Next_Agency_Supervisor_Email__c
      FROM ACEF_Form_7300_Request__c
      WHERE Id = :requestId
    ];
  }

  private static Boolean inQueue(String lane, String key) {
    for (ACEF_PortalWorkflowService.QueueItem item : ACEF_PortalWorkflowService.listQueue(lane)) {
      if (item.key == key) {
        return true;
      }
    }
    return false;
  }

  private static ACEF_PortalWorkflowService.QueueItem findItem(String lane, String key) {
    for (ACEF_PortalWorkflowService.QueueItem item : ACEF_PortalWorkflowService.listQueue(lane)) {
      if (item.key == key) {
        return item;
      }
    }
    return null;
  }

  @isTest
  static void yesPathFollowsKurtsSequenceToProvisioning() {
    ACEF_Form_7300_Request__c request = newRequest();
    System.assertEquals(
      'Answer: are you requesting ACE Portal access?',
      ACEF_PortalWorkflowService.getProgress(request.Id).stage
    );

    ACEF_ApplicationService.PortalInitResult init = ACEF_PortalWorkflowService.setAccessAnswer(request.Id, 'Yes');
    System.assert(init.aceAccessInScope);
    System.assertNotEquals(null, init.packageRecordId, 'Yes creates the PGA package');
    Id packageId = init.packageRecordId;
    System.assertEquals('Complete and submit the CBP Form 7300', ACEF_PortalWorkflowService.getProgress(request.Id).stage);

    Test.startTest();
    submitForm7300(request.Id, true);
    ACEF_Form_7300_Request__c row = reload(request.Id);
    System.assertEquals('Section 2 Pending', row.ACEF_Status__c, 'Routed to the agency supervisor');
    System.assertEquals('grace@agency.gov', row.ACEF_Next_Agency_Supervisor_Email__c);
    System.assert(inQueue('supervisor', 'form7300' + request.Id));
    ACEF_PortalWorkflowService.Progress progress = ACEF_PortalWorkflowService.getProgress(request.Id);
    System.assertEquals('grace@agency.gov', progress.waitingOn);
    System.assertEquals(3, progress.openForms.size(), 'Application, Rules and NDA still open');

    ACEF_PortalWorkflowService.decide7300Section(request.Id, '2', 'Approved', 'Grace Supervisor', null);
    System.assertEquals('Section 3 Pending', reload(request.Id).ACEF_Status__c, 'CBP supervisor next');
    System.assert(inQueue('cbpSupervisor', 'form7300' + request.Id));

    ACEF_PortalWorkflowService.decide7300Section(request.Id, '3', 'Approved', 'Casey CBP', null);
    System.assertEquals('Section 4 Pending', reload(request.Id).ACEF_Status__c, 'Security / PSO next');
    System.assert(inQueue('security', 'form7300' + request.Id));

    ACEF_PortalWorkflowService.decide7300Section(request.Id, '4', 'Approved', 'Alan PSO', null);
    System.assertEquals('With 7300 Processing', reload(request.Id).ACEF_Status__c, 'Vetting next');
    System.assert(inQueue('vetting', 'form7300' + request.Id));
    // CBPPGA-88: BI adjudication waits for the full package (Pending BI Review), so the requester is told to finish it.
    System.assertEquals('Complete your PGA access application', ACEF_PortalWorkflowService.getProgress(request.Id).stage);
    System.assertEquals('You', ACEF_PortalWorkflowService.getProgress(request.Id).waitingOn);
    System.assertEquals('Draft', lifecycleStatus(packageId));
    try {
      ACEF_PortalWorkflowService.recordVetting(request.Id, 'Favorable', null);
      System.assert(false, 'BI waits for the submitted package');
    } catch (AuraHandledException e) {
      System.assert(e.getMessage().contains('not been submitted'), e.getMessage());
    }

    // Requester completes the package. The Rules / NDA steps overwrite the package status,
    // so the supervisor sign-off must still be found by its flags (regression).
    update new ACEF_PGA_Application__c(
      Id = packageId,
      ACEF_Form001_User_Complete__c = true,
      ACEF_Package_Status__c = 'NDA Upload Pending'
    );
    System.assert(inQueue('supervisor', 'form001' + packageId), 'Sign-off still waiting for the supervisor');
    System.assertEquals('Draft', lifecycleStatus(packageId), 'Not the full package yet');
    update new ACEF_PGA_Application__c(
      Id = packageId,
      ACEF_Form001_Supervisor_Complete__c = true,
      ACEF_Form002_Complete__c = true,
      ACEF_NDA_Uploaded__c = true,
      ACEF_Access_Area__c = 'ACE Portal',
      ACEF_Package_Status__c = 'With PGA Processing'
    );
    System.assert(!inQueue('supervisor', 'form001' + packageId), 'Signed: leaves the supervisor lane');
    System.assertEquals('Pending BI Review', lifecycleStatus(packageId), 'Full package in: submitted automatically');
    progress = ACEF_PortalWorkflowService.getProgress(request.Id);
    System.assertEquals('Vetting: OIT background investigation (BI)', progress.stage);
    System.assertEquals('CBP vetting team', progress.waitingOn);

    ACEF_PortalWorkflowService.recordVetting(request.Id, 'Favorable', null);
    row = reload(request.Id);
    System.assertEquals('OIT BI Review', row.ACEF_Status__c);
    System.assertEquals('Favorable', row.ACEF_BI_Disposition__c);
    System.assert(!inQueue('vetting', 'form7300' + request.Id));
    System.assertEquals('Ready for Provisioning', lifecycleStatus(packageId));
    ACEF_PortalWorkflowService.QueueItem readyItem = findItem('provisioning', 'package' + packageId);
    System.assert(readyItem.ready, 'Ready once the package checks pass: ' + readyItem.waitingOn);
    System.assert(ACEF_PortalWorkflowService.getGates(packageId).readyForReadiness);
    System.assertEquals(null, ACEF_PortalWorkflowService.getGates(null));
    Test.stopTest();

    ACEF_PackageLifecycleService.provision(packageId, 'done');
    System.assertEquals('ACE Security Review', lifecycleStatus(packageId));
    System.assert(inQueue('aceSecurity', 'package' + packageId));
    System.assertEquals('ACE Security verification', ACEF_PortalWorkflowService.getProgress(request.Id).stage);

    ACEF_ProvisioningUiActions.verifyAceSecurity(packageId, 'verified');
    System.assertEquals('Complete', lifecycleStatus(packageId));
    progress = ACEF_PortalWorkflowService.getProgress(request.Id);
    System.assert(progress.closed);
    System.assert(progress.favorable);
  }

  private static String lifecycleStatus(Id packageId) {
    return [SELECT ACEF_Status__c FROM ACEF_PGA_Application__c WHERE Id = :packageId].ACEF_Status__c;
  }

  /** Signs every package item so the package is submitted (Pending BI Review). */
  private static void completePackage(Id packageId) {
    update new ACEF_PGA_Application__c(
      Id = packageId,
      ACEF_Form001_User_Complete__c = true,
      ACEF_Form001_Supervisor_Complete__c = true,
      ACEF_Form002_Complete__c = true,
      ACEF_NDA_Uploaded__c = true
    );
  }

  @isTest
  static void noPathIsForm7300OnlyAndEndsAfterFavorableVetting() {
    ACEF_Form_7300_Request__c request = newRequest();
    ACEF_ApplicationService.PortalInitResult init = ACEF_PortalWorkflowService.setAccessAnswer(request.Id, 'No');
    System.assert(!init.aceAccessInScope);
    System.assertEquals(null, init.packageRecordId, 'No creates no PGA package');

    Test.startTest();
    submitForm7300(request.Id, false);
    System.assertEquals('Section 2 Pending', reload(request.Id).ACEF_Status__c);
    ACEF_PortalWorkflowService.decide7300Section(request.Id, '2', 'Approved', 'Grace Supervisor', null);
    System.assertEquals('Section 4 Pending', reload(request.Id).ACEF_Status__c, 'No CBP supervisor: straight to section 4');
    ACEF_PortalWorkflowService.decide7300Section(request.Id, '4', 'Approved', 'Alan PSO', null);
    ACEF_PortalWorkflowService.recordVetting(request.Id, 'Favorable', null);
    Test.stopTest();

    ACEF_Form_7300_Request__c row = reload(request.Id);
    System.assertEquals('Closed Favorable', row.ACEF_Status__c);
    System.assertEquals(null, row.ACEF_PGA_Application__c);
    ACEF_PortalWorkflowService.Progress progress = ACEF_PortalWorkflowService.getProgress(request.Id);
    System.assert(progress.closed && progress.favorable);
    System.assert(progress.openForms.isEmpty());
  }

  @isTest
  static void unfavorableVettingAndRejectionCloseTheRequest() {
    ACEF_Form_7300_Request__c request = newRequest();
    Id packageId = ACEF_PortalWorkflowService.setAccessAnswer(request.Id, 'Yes').packageRecordId;
    Test.startTest();
    submitForm7300(request.Id, false);
    ACEF_PortalWorkflowService.decide7300Section(request.Id, '2', 'Approved', 'Grace', null);
    ACEF_PortalWorkflowService.decide7300Section(request.Id, '4', 'Approved', 'Alan', null);
    completePackage(packageId);
    try {
      ACEF_PortalWorkflowService.recordVetting(request.Id, 'Unfavorable', null);
      System.assert(false, 'Unfavorable needs a note');
    } catch (AuraHandledException e) {
      System.assert(true);
    }
    ACEF_PortalWorkflowService.recordVetting(request.Id, 'Unfavorable', 'BI not cleared.');
    Test.stopTest();
    System.assertEquals('Closed Unfavorable', reload(request.Id).ACEF_Status__c);
    ACEF_PGA_Application__c closedPkg = [
      SELECT ACEF_Package_Status__c, ACEF_Status__c
      FROM ACEF_PGA_Application__c
      WHERE Id = :packageId
    ];
    System.assertEquals('Closed', closedPkg.ACEF_Package_Status__c);
    System.assertEquals('Unfavorable BI Determination', closedPkg.ACEF_Status__c);
    System.assert(ACEF_PortalWorkflowService.getProgress(request.Id).closed);

    ACEF_Form_7300_Request__c other = newRequest();
    ACEF_PortalWorkflowService.setAccessAnswer(other.Id, 'No');
    submitForm7300(other.Id, false);
    ACEF_PortalWorkflowService.decide7300Section(other.Id, '2', 'Rejected', 'Grace', 'Wrong agency.');
    ACEF_Form_7300_Request__c rejected = reload(other.Id);
    System.assertEquals('Closed', rejected.ACEF_Status__c);
    System.assertEquals('Rejected', rejected.ACEF_Sec2_Decision__c);
    System.assertEquals('Closed: Form 7300 not approved', ACEF_PortalWorkflowService.getProgress(other.Id).stage);
  }

  @isTest
  static void nativeVettingFromPackageOrRequest() {
    ACEF_Form_7300_Request__c request = newRequest();
    Id packageId = ACEF_PortalWorkflowService.setAccessAnswer(request.Id, 'Yes').packageRecordId;
    Test.startTest();
    submitForm7300(request.Id, false);
    ACEF_PortalWorkflowService.VettingContext ctx = ACEF_PortalWorkflowService.getVettingContext(packageId);
    System.assert(!ctx.awaitingVetting, 'Still with the signers');
    try {
      ACEF_PortalWorkflowService.recordVettingForRecord(packageId, 'Favorable', null);
      System.assert(false, 'Not ready for vetting yet');
    } catch (AuraHandledException e) {
      System.assert(true);
    }
    ACEF_PortalWorkflowService.decide7300Section(request.Id, '2', 'Approved', 'Grace', null);
    ACEF_PortalWorkflowService.decide7300Section(request.Id, '4', 'Approved', 'Alan', null);
    ctx = ACEF_PortalWorkflowService.getVettingContext(request.Id);
    System.assert(!ctx.awaitingVetting, 'CBPPGA-88: waits for the submitted package');
    System.assert(ctx.message.contains('not been submitted'), ctx.message);
    completePackage(packageId);
    System.assert(ACEF_PortalWorkflowService.getVettingContext(request.Id).awaitingVetting);
    ctx = ACEF_PortalWorkflowService.recordVettingForRecord(packageId, 'Favorable', null);
    Test.stopTest();
    System.assertEquals('Favorable', ctx.biDisposition);
    System.assert(!ctx.awaitingVetting);
    ACEF_PGA_Application__c pkg = [
      SELECT ACEF_Processing_Stage__c, ACEF_Status__c
      FROM ACEF_PGA_Application__c
      WHERE Id = :packageId
    ];
    System.assertEquals('Ready for Provisioning', pkg.ACEF_Status__c);
    System.assertEquals('Ready for readiness review', pkg.ACEF_Processing_Stage__c);
    System.assertEquals(null, ACEF_PortalWorkflowService.getVettingContext(null).request7300Id);
  }

  @isTest
  static void invalidInputsAreRejected() {
    ACEF_Form_7300_Request__c request = newRequest();
    List<String> failures = new List<String>();
    try {
      ACEF_PortalWorkflowService.setAccessAnswer(request.Id, 'Maybe');
      failures.add('answer');
    } catch (AuraHandledException e) {
      System.assert(true);
    }
    try {
      ACEF_PortalWorkflowService.setAccessAnswer(null, 'Yes');
      failures.add('no request');
    } catch (AuraHandledException e) {
      System.assert(true);
    }
    try {
      ACEF_PortalWorkflowService.listQueue('nope');
      failures.add('lane');
    } catch (AuraHandledException e) {
      System.assert(true);
    }
    for (List<String> bad : new List<List<String>>{
      new List<String>{ '9', 'Approved', 'Sam', null },
      new List<String>{ '2', 'Maybe', 'Sam', null },
      new List<String>{ '2', 'Approved', ' ', null },
      new List<String>{ '2', 'Rejected', 'Sam', null },
      new List<String>{ '2', 'Approved', 'Sam', null }
    }) {
      try {
        ACEF_PortalWorkflowService.decide7300Section(request.Id, bad[0], bad[1], bad[2], bad[3]);
        failures.add('section ' + bad);
      } catch (AuraHandledException e) {
        System.assert(true);
      }
    }
    System.assert(failures.isEmpty(), 'Expected every call to be rejected: ' + failures);

    ACEF_PortalWorkflowService.setAccessAnswer(request.Id, 'No');
    submitForm7300(request.Id, false);
    try {
      ACEF_PortalWorkflowService.setAccessAnswer(request.Id, 'Yes');
      System.assert(false, 'Answer is locked after Form 7300 is submitted');
    } catch (AuraHandledException e) {
      System.assert(true);
    }
    System.assertEquals(null, ACEF_PortalWorkflowService.getProgress(null).stage);
  }
}