/**
 * ACE PGA Portal: the CBP Form 7300 step uses Form 7300 Test 2 (cbpForm73002),
 * which saves an ACEF_CBP_Form_7300__c record. This class links that record to
 * the portal's ACEF_Form_7300_Request__c and unlocks the PGA package steps, as
 * the earlier portal 7300 form did when "ACE Portal access requested" was ticked.
 *
 * After submit the request follows Kurt's 7300 sequence: it moves to
 * Section 1 Complete and the existing trigger routes it to the agency
 * supervisor (Section 2 Pending), then the CBP supervisor when one is given,
 * then the security / PSO signers (section 4), then OIT BI vetting. The signer
 * emails captured in Form 7300 Test 2 are copied onto the request for routing.
 * The PGA package is created only when the requester answered Yes to
 * "Are you requesting ACE Portal access?".
 */
public with sharing class ACEF_PortalCbpForm7300Service {
  @TestVisible
  private static final String STATUS_SUBMITTED = 'Section 1 Complete';

  public class LinkedForm {
    @AuraEnabled
    public Id formId;
    @AuraEnabled
    public String confirmationNumber;
  }

  /** The Form 7300 Test 2 record already linked to the request, or null. */
  @AuraEnabled
  public static LinkedForm getLinkedForm(Id request7300Id) {
    if (request7300Id == null) {
      return null;
    }
    List<ACEF_Form_7300_Request__c> rows = [
      SELECT ACEF_CBP_Form_7300__c, ACEF_CBP_Form_7300__r.Name
      FROM ACEF_Form_7300_Request__c
      WHERE Id = :request7300Id
      LIMIT 1
    ];
    if (rows.isEmpty() || rows[0].ACEF_CBP_Form_7300__c == null) {
      return null;
    }
    LinkedForm out = new LinkedForm();
    out.formId = rows[0].ACEF_CBP_Form_7300__c;
    out.confirmationNumber = rows[0].ACEF_CBP_Form_7300__r.Name;
    return out;
  }

  /**
   * Called after Form 7300 Test 2 is submitted in the portal. Links the new
   * record (found by its confirmation number), marks ACE Portal access as
   * requested and returns the PGA package created for the request.
   */
  @AuraEnabled
  public static ACEF_ApplicationService.PortalInitResult linkSubmittedForm(
    Id request7300Id,
    String confirmationNumber
  ) {
    if (request7300Id == null || String.isBlank(confirmationNumber)) {
      throw new AuraHandledException(
        'The Form 7300 could not be linked. Refresh the page and try again.'
      );
    }
    Id formId = ACEF_CbpForm7300ProgressService.findIdByConfirmation(
      confirmationNumber
    );
    if (formId == null) {
      throw new AuraHandledException(
        'Form 7300 ' + confirmationNumber + ' was not found.'
      );
    }
    ACEF_Form_7300_Request__c request = [
      SELECT Id, ACEF_Status__c, ACEF_ACE_Access_Answer__c, ACEF_CBP_Form_7300__c
      FROM ACEF_Form_7300_Request__c
      WHERE Id = :request7300Id
      LIMIT 1
    ];
    ACEF_CBP_Form_7300__c form = [
      SELECT
        ACEF_First_Name__c,
        ACEF_Last_Name__c,
        ACEF_Home_Agency_Email__c,
        ACEF_Supervisor_Email__c,
        ACEF_CBP_Supervisor_Applies__c,
        ACEF_CBP_Supervisor_Email__c,
        ACEF_Security_Email__c,
        ACEF_User_Cert_Name__c
      FROM ACEF_CBP_Form_7300__c
      WHERE Id = :formId
    ];
    // An unanswered request (created before the question existed) counts as Yes.
    String answer = String.isBlank(request.ACEF_ACE_Access_Answer__c)
      ? 'Yes'
      : request.ACEF_ACE_Access_Answer__c;
    request.ACEF_ACE_Access_Answer__c = answer;
    request.ACEF_ACE_Access_Requested__c = answer == 'Yes';
    request.ACEF_CBP_Form_7300__c = formId;
    request.ACEF_First_Name__c = form.ACEF_First_Name__c;
    request.ACEF_Last_Name__c = form.ACEF_Last_Name__c;
    request.ACEF_Home_Agency_Email__c = form.ACEF_Home_Agency_Email__c;
    request.ACEF_Next_Agency_Supervisor_Email__c = form.ACEF_Supervisor_Email__c;
    request.ACEF_Next_CBP_Supervisor_Email__c = form.ACEF_CBP_Supervisor_Applies__c == true
      ? form.ACEF_CBP_Supervisor_Email__c
      : null;
    request.ACEF_PSO_Email__c = form.ACEF_Security_Email__c;
    request.ACEF_Section1_Signed_By__c = form.ACEF_User_Cert_Name__c;
    request.ACEF_Section1_Signed_Date__c = Date.today();
    if (request.ACEF_Status__c == null || request.ACEF_Status__c == 'Draft') {
      // The trigger routes Section 1 Complete to the agency supervisor (Section 2 Pending).
      request.ACEF_Status__c = STATUS_SUBMITTED;
    }
    try {
      update request;
    } catch (DmlException e) {
      throw new AuraHandledException(e.getDmlMessage(0));
    }
    return ACEF_ApplicationService.ensureAcePackage(request7300Id);
  }
}