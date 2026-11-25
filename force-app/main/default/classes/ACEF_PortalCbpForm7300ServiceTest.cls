@isTest
private class ACEF_PortalCbpForm7300ServiceTest {
  private static ACEF_Form_7300_Request__c newRequest() {
    ACEF_Form_7300_Request__c request = new ACEF_Form_7300_Request__c(
      ACEF_Status__c = 'Draft',
      ACEF_ACE_Access_Requested__c = false
    );
    insert request;
    return request;
  }

  @isTest
  static void submittedFormIsLinkedAndUnlocksThePackage() {
    ACEF_Form_7300_Request__c request = newRequest();
    ACEF_CBP_Form_7300__c form = ACEF_Form7300TestData.insertPending();
    String confirmation = [
      SELECT Name
      FROM ACEF_CBP_Form_7300__c
      WHERE Id = :form.Id
    ]
    .Name;

    System.assertEquals(
      null,
      ACEF_PortalCbpForm7300Service.getLinkedForm(request.Id)
    );

    Test.startTest();
    ACEF_ApplicationService.PortalInitResult result = ACEF_PortalCbpForm7300Service.linkSubmittedForm(
      request.Id,
      confirmation
    );
    Test.stopTest();

    System.assert(result.aceAccessInScope, 'ACE access should be in scope');
    System.assertNotEquals(
      null,
      result.packageRecordId,
      'A PGA package should be created'
    );
    ACEF_Form_7300_Request__c saved = [
      SELECT
        ACEF_CBP_Form_7300__c,
        ACEF_ACE_Access_Requested__c,
        ACEF_Status__c,
        ACEF_PGA_Application__c
      FROM ACEF_Form_7300_Request__c
      WHERE Id = :request.Id
    ];
    System.assertEquals(form.Id, saved.ACEF_CBP_Form_7300__c);
    System.assert(saved.ACEF_ACE_Access_Requested__c);
    // Section 1 Complete routes the request to the agency supervisor (existing trigger).
    System.assertEquals('Section 2 Pending', saved.ACEF_Status__c);
    System.assertEquals(result.packageRecordId, saved.ACEF_PGA_Application__c);

    ACEF_PortalCbpForm7300Service.LinkedForm linked = ACEF_PortalCbpForm7300Service.getLinkedForm(
      request.Id
    );
    System.assertEquals(form.Id, linked.formId);
    System.assertEquals(confirmation, linked.confirmationNumber);
  }

  @isTest
  static void missingInputsAndUnknownConfirmationAreRejected() {
    ACEF_Form_7300_Request__c request = newRequest();
    System.assertEquals(null, ACEF_PortalCbpForm7300Service.getLinkedForm(null));
    for (String confirmation : new List<String>{ null, '7300-DOES-NOT-EXIST' }) {
      try {
        ACEF_PortalCbpForm7300Service.linkSubmittedForm(request.Id, confirmation);
        System.assert(false, 'Expected an AuraHandledException');
      } catch (AuraHandledException e) {
        System.assert(true);
      }
    }
    System.assertEquals(
      'Draft',
      [SELECT ACEF_Status__c FROM ACEF_Form_7300_Request__c WHERE Id = :request.Id]
      .ACEF_Status__c
    );
  }
}