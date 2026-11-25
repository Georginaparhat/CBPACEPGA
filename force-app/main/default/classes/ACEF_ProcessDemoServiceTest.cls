@isTest
private class ACEF_ProcessDemoServiceTest {
  private static String agency;

  @testSetup
  static void setup() {
    String dept = ACEF_RoleMappingTestData.deptAgency(0);
    insert new List<ACEF_Role_Agency_Mapping__c>{
      ACEF_RoleMappingTestData.activeRoleAgency('T_REPORTS', dept),
      ACEF_RoleMappingTestData.activeRoleAgency('T_ADCVD_3', dept)
    };
    insert new List<ACEF_System_Role_Mapping__c>{
      ACEF_RoleMappingTestData.activeSystemRole('T_REPORTS', 'ACE_Reports'),
      ACEF_RoleMappingTestData.activeSystemRole('T_ADCVD_3', 'AD_CVD'),
      ACEF_RoleMappingTestData.activeSystemRole('T_ADCVD_3', 'GCMC')
    };
  }

  private static Id completePackage(String cbpEmail, List<String> systems, List<String> roles) {
    Id reviewId = ACEF_ProcessDemoService.startReview('Demo Requester', 'Requester@Example.gov');
    ACEF_ProcessDemoService.acceptRules(reviewId);
    Map<String, Object> payload = new Map<String, Object>{
      'deptAgency' => ACEF_RoleMappingTestData.deptAgency(0),
      'systems' => systems,
      'roleCodes' => roles,
      'supervisorEmail' => 'supervisor@example.gov',
      'cbpSupervisorEmail' => cbpEmail,
      'phone' => '555-0100',
      'positionTitle' => 'Analyst',
      'govEmployee' => true
    };
    ACEF_ProcessDemoService.saveApplication(reviewId, JSON.serialize(payload));
    ACEF_ProcessDemoService.completeForm7300(reviewId, null);
    insert new ContentVersion(
      Title = 'Signed NDA',
      PathOnClient = 'Signed NDA.pdf',
      VersionData = Blob.valueOf('%PDF-1.4 demo'),
      FirstPublishLocationId = reviewId
    );
    return reviewId;
  }

  private static ACEF_Approval_Step__c pendingStep(Id reviewId, String stepType) {
    return [
      SELECT Id
      FROM ACEF_Approval_Step__c
      WHERE ACEF_Package_Review__c = :reviewId AND ACEF_Step_Type__c = :stepType AND ACEF_Status__c = 'Pending'
      LIMIT 1
    ];
  }

  @isTest
  static void fullFlowWithCbpSupervisorEndsApproved() {
    Id reviewId = completePackage('cbp.supervisor@example.gov', new List<String>{ 'ACE_Reports', 'AD_CVD' }, new List<String>{ 'T_ADCVD_3' });

    Test.startTest();
    ACEF_ProcessDemoService.ReviewState state = ACEF_ProcessDemoService.submit(reviewId);
    System.assertEquals(ACEF_ProcessDemoService.REVIEW_AWAITING, state.review.ACEF_Status__c);
    System.assertEquals(2, state.steps.size(), 'Supervisor and CBP supervisor are both routed');
    System.assertEquals(2, state.callToActionEmails.size());
    System.assertEquals(true, state.review.ACEF_Requires_Provisioning_Email__c, 'AD/CVD role 3 grants GCMC');
    System.assertEquals(1, ACEF_ProcessDemoService.listPendingSteps('Supervisor').size());

    state = ACEF_ProcessDemoService.decide(pendingStep(reviewId, 'Supervisor').Id, 'Approved', 'Sam Supervisor', true, 'Needs access for duties.', null);
    System.assertEquals(ACEF_ProcessDemoService.REVIEW_AWAITING, state.review.ACEF_Status__c, 'CBP supervisor still pending');

    state = ACEF_ProcessDemoService.decide(pendingStep(reviewId, 'CBP Supervisor').Id, 'Approved', 'Casey CBP', true, 'Agree.', null);
    System.assertEquals(ACEF_ProcessDemoService.REVIEW_VETTING, state.review.ACEF_Status__c, 'Vetting after both approvals');
    System.assertEquals(0, [SELECT COUNT() FROM ACEF_Approval_Step__c WHERE ACEF_Package_Review__c = :reviewId AND ACEF_Step_Type__c = 'Provisioning'],
      'Provisioning is not available before a Favorable BI');
    System.assertEquals(1, ACEF_ProcessDemoService.listPendingSteps('Vetting').size());

    state = ACEF_ProcessDemoService.completeVetting(pendingStep(reviewId, 'Vetting').Id, 'Favorable', 'Ruben Vetting', null);
    System.assertEquals(ACEF_ProcessDemoService.REVIEW_FULFILMENT, state.review.ACEF_Status__c, 'Parallel split after a Favorable BI');
    System.assertEquals('Favorable', state.review.ACEF_BI_Outcome__c);
    System.assertNotEquals(null, state.provisioningEmail);
    System.assert(state.provisioningEmail.body.contains('Hash ID'));

    state = ACEF_ProcessDemoService.completeSecurity(pendingStep(reviewId, 'Security').Id, 'Tier 2', 'Favorable', 'Pat Security', 'Checked.', true);
    System.assertEquals(ACEF_ProcessDemoService.REVIEW_FULFILMENT, state.review.ACEF_Status__c, 'Waits for provisioning (join)');

    state = ACEF_ProcessDemoService.completeProvisioning(pendingStep(reviewId, 'Provisioning').Id);
    Test.stopTest();

    System.assertEquals(ACEF_ProcessDemoService.REVIEW_APPROVED, state.review.ACEF_Status__c);
    System.assertNotEquals(null, state.review.ACEF_Provisioning_Email_Sent_At__c);
    System.assertNotEquals(null, state.review.ACEF_Completed_At__c);
    System.assertEquals('requester@example.gov', state.review.ACEF_Username__c);
  }

  @isTest
  static void submitIsBlockedUntilPackageIsComplete() {
    Id reviewId = ACEF_ProcessDemoService.startReview('Demo Requester', 'r@example.gov');
    ACEF_ProcessDemoService.ReviewState state = ACEF_ProcessDemoService.getState(reviewId);
    System.assertEquals(4, state.missing.size());
    try {
      ACEF_ProcessDemoService.submit(reviewId);
      System.assert(false, 'Expected the submit gate to block');
    } catch (AuraHandledException e) {
      System.assertEquals(0, [SELECT COUNT() FROM ACEF_Approval_Step__c]);
    }
  }

  @isTest
  static void returnThenResubmitStartsANewRound() {
    Id reviewId = completePackage(null, new List<String>{ 'ACE_Reports' }, new List<String>());
    ACEF_ProcessDemoService.submit(reviewId);
    Id stepId = pendingStep(reviewId, 'Supervisor').Id;
    try {
      ACEF_ProcessDemoService.decide(stepId, 'Returned', null, false, null, null);
      System.assert(false, 'Return needs comments');
    } catch (AuraHandledException e) {
      System.assert(true);
    }
    ACEF_ProcessDemoService.ReviewState state = ACEF_ProcessDemoService.decide(stepId, 'Returned', null, false, null, 'Add your position title.');
    System.assertEquals(ACEF_ProcessDemoService.REVIEW_RETURNED, state.review.ACEF_Status__c);
    System.assertEquals(true, state.editable);

    state = ACEF_ProcessDemoService.submit(reviewId);
    System.assertEquals(2, state.review.ACEF_Round__c);
    System.assertEquals(1, [SELECT COUNT() FROM ACEF_Approval_Step__c WHERE ACEF_Package_Review__c = :reviewId AND ACEF_Status__c = 'Pending']);
    System.assertEquals(false, state.review.ACEF_Requires_Provisioning_Email__c);
  }

  @isTest
  static void rejectCancelsOtherSupervisorAndLocksPackage() {
    Id reviewId = completePackage('cbp@example.gov', new List<String>{ 'ACE_Reports' }, new List<String>());
    ACEF_ProcessDemoService.submit(reviewId);
    ACEF_ProcessDemoService.ReviewState state = ACEF_ProcessDemoService.decide(
      pendingStep(reviewId, 'Supervisor').Id, 'Rejected', null, false, null, 'Not eligible.');
    System.assertEquals(ACEF_ProcessDemoService.REVIEW_REJECTED, state.review.ACEF_Status__c);
    System.assertEquals(1, [SELECT COUNT() FROM ACEF_Approval_Step__c WHERE ACEF_Status__c = 'Cancelled']);
    try {
      ACEF_ProcessDemoService.acceptRules(reviewId);
      System.assert(false, 'Rejected packages are locked');
    } catch (AuraHandledException e) {
      System.assert(e.getMessage() != null);
    }
  }

  @isTest
  static void unfavorableBiEndsTheProcess() {
    Id reviewId = completePackage(null, new List<String>{ 'ACE_Reports' }, new List<String>());
    ACEF_ProcessDemoService.submit(reviewId);
    ACEF_ProcessDemoService.decide(pendingStep(reviewId, 'Supervisor').Id, 'Approved', 'Sam', true, 'ok', null);

    ACEF_ProcessDemoService.ReviewState state = ACEF_ProcessDemoService.completeVetting(
      pendingStep(reviewId, 'Vetting').Id, 'Unfavorable', 'Ruben Vetting', 'BI not cleared.');

    System.assertEquals(ACEF_ProcessDemoService.REVIEW_UNFAVORABLE, state.review.ACEF_Status__c);
    System.assertEquals('Unfavorable', state.review.ACEF_BI_Outcome__c);
    System.assertNotEquals(null, state.review.ACEF_Completed_At__c);
    System.assertEquals(0, [SELECT COUNT() FROM ACEF_Approval_Step__c WHERE ACEF_Package_Review__c = :reviewId AND ACEF_Status__c = 'Pending'],
      'Nothing is left to do: no security or provisioning steps');
    System.assertEquals(false, state.editable);
  }

  @isTest
  static void invalidInputsAreRejected() {
    try {
      ACEF_ProcessDemoService.startReview('', '');
      System.assert(false);
    } catch (AuraHandledException e) {
      System.assert(true);
    }
    Id reviewId = ACEF_ProcessDemoService.startReview('Demo', 'd@example.gov');
    try {
      Map<String, Object> payload = new Map<String, Object>{
        'deptAgency' => ACEF_RoleMappingTestData.deptAgency(0),
        'systems' => new List<String>{ 'Manifest_Data' },
        'roleCodes' => new List<String>()
      };
      ACEF_ProcessDemoService.saveApplication(reviewId, JSON.serialize(payload));
      System.assert(false, 'Ineligible system and missing fields');
    } catch (AuraHandledException e) {
      System.assert(true);
    }

    Id fullId = completePackage(null, new List<String>{ 'ACE_Reports' }, new List<String>());
    ACEF_ProcessDemoService.submit(fullId);
    Id stepId = pendingStep(fullId, 'Supervisor').Id;
    try {
      ACEF_ProcessDemoService.decide(stepId, 'Approved', 'Sam', false, 'ok', null);
      System.assert(false, 'Approve needs the attestation');
    } catch (AuraHandledException e) {
      System.assert(true);
    }
    try {
      ACEF_ProcessDemoService.decide(stepId, 'Maybe', 'Sam', true, 'ok', null);
      System.assert(false, 'Unknown decision');
    } catch (AuraHandledException e) {
      System.assert(true);
    }
    try {
      ACEF_ProcessDemoService.completeSecurity(stepId, 'Tier 1', 'Favorable', 'Pat', null, true);
      System.assert(false, 'Wrong lane');
    } catch (AuraHandledException e) {
      System.assert(true);
    }
    ACEF_ProcessDemoService.decide(stepId, 'Approved', 'Sam', true, 'ok', null);
    try {
      ACEF_ProcessDemoService.decide(stepId, 'Approved', 'Sam', true, 'ok', null);
      System.assert(false, 'Already decided');
    } catch (AuraHandledException e) {
      System.assert(true);
    }
    Id vettingId = pendingStep(fullId, 'Vetting').Id;
    for (List<String> bad : new List<List<String>>{
      new List<String>{ 'Maybe', 'Ruben', 'x' },
      new List<String>{ 'Favorable', ' ', null },
      new List<String>{ 'Unfavorable', 'Ruben', null }
    }) {
      try {
        ACEF_ProcessDemoService.completeVetting(vettingId, bad[0], bad[1], bad[2]);
        System.assert(false, 'Vetting input should be rejected: ' + bad);
      } catch (AuraHandledException e) {
        System.assert(true);
      }
    }
    ACEF_ProcessDemoService.completeVetting(vettingId, 'Favorable', 'Ruben', null);
    try {
      ACEF_ProcessDemoService.completeSecurity(pendingStep(fullId, 'Security').Id, null, null, null, null, false);
      System.assert(false, 'Security section incomplete');
    } catch (AuraHandledException e) {
      System.assert(true);
    }
    System.assertNotEquals(null, ACEF_ProcessDemoService.listReviews());
    System.assertNotEquals(null, ACEF_ProcessDemoService.listForm7300Options());
  }

  @isTest
  static void cbploginRegistrationMimicsJitProvisioning() {
    // Has an account? No.
    System.assertEquals(null, ACEF_ProcessDemoService.demoSignIn('Sam.Supervisor@Example.gov'));

    // Register via cbplogin.gov: JIT creates the portal user on first sign-in.
    ACEF_ProcessDemoService.DemoIdentity created = ACEF_ProcessDemoService.demoRegister(
      'Sam Supervisor',
      ' Sam.Supervisor@Example.gov ',
      'supervisor'
    );
    System.assert(created.justProvisioned);
    System.assertEquals('sam.supervisor@example.gov', created.email);
    System.assertEquals('sam.supervisor@example.gov.acepga', created.username);
    System.assertEquals('supervisor', created.persona);
    System.assert(created.permissionSet.contains('Supervisor'));
    System.assertEquals(16, created.hashId.length());

    // Has an account? Yes: later sign-ins go straight through, and re-registering does not duplicate.
    ACEF_ProcessDemoService.DemoIdentity again = ACEF_ProcessDemoService.demoSignIn('SAM.SUPERVISOR@example.gov');
    System.assertNotEquals(null, again);
    System.assert(!again.justProvisioned);
    ACEF_ProcessDemoService.demoRegister('Sam Supervisor', 'sam.supervisor@example.gov', 'security');
    System.assertEquals(1, [SELECT COUNT() FROM ACEF_Demo_Identity__c]);

    // Rehearsal reset.
    ACEF_ProcessDemoService.demoResetIdentity('sam.supervisor@example.gov');
    System.assertEquals(null, ACEF_ProcessDemoService.demoSignIn('sam.supervisor@example.gov'));
  }

  @isTest
  static void cbploginInputsAreChecked() {
    try {
      ACEF_ProcessDemoService.demoSignIn('not-an-email');
      System.assert(false, 'Expected an invalid email error');
    } catch (AuraHandledException e) {
      System.assert(true);
    }
    try {
      ACEF_ProcessDemoService.demoRegister(' ', 'new.user@example.gov', 'requester');
      System.assert(false, 'Expected a name error');
    } catch (AuraHandledException e) {
      System.assert(true);
    }
    ACEF_ProcessDemoService.DemoIdentity fallback = ACEF_ProcessDemoService.demoRegister(
      'New User',
      'new.user@example.gov',
      'unknownPersona'
    );
    System.assertEquals('requester', fallback.persona);
  }
}