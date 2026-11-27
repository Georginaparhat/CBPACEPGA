public with sharing class ACEF_ApplicationService {
  public class PortalInitResult {
    @AuraEnabled
    public Id request7300RecordId;
    @AuraEnabled
    public Id packageRecordId;
    @AuraEnabled
    public Boolean aceAccessInScope = false;
  }

  public class PortalRequestSummary {
    @AuraEnabled
    public Id request7300Id;
    @AuraEnabled
    public String requestName;
  }

  public class ChecklistState {
    @AuraEnabled
    public Id request7300Id;
    @AuraEnabled
    public Id packageId;
  }

  @AuraEnabled
  public static Id createPortalRequestForUser() {
    ACEF_Form_7300_Request__c request = new ACEF_Form_7300_Request__c(ACEF_Status__c = 'Draft');
    insert request;
    return request.Id;
  }

  @AuraEnabled(cacheable=true)
  public static List<PortalRequestSummary> listMyPortalRequests() {
    List<PortalRequestSummary> rows = new List<PortalRequestSummary>();
    for (ACEF_Form_7300_Request__c request : [
      SELECT Id, Name
      FROM ACEF_Form_7300_Request__c
      WHERE OwnerId = :UserInfo.getUserId()
      ORDER BY CreatedDate DESC
      LIMIT 50
    ]) {
      PortalRequestSummary row = new PortalRequestSummary();
      row.request7300Id = request.Id;
      row.requestName = request.Name;
      rows.add(row);
    }
    return rows;
  }

  @AuraEnabled
  public static PortalInitResult initializePortal(Boolean createIfMissing) {
    PortalInitResult result = new PortalInitResult();
    List<ACEF_Form_7300_Request__c> existing = [
      SELECT Id, ACEF_PGA_Application__c, ACEF_ACE_Access_Requested__c
      FROM ACEF_Form_7300_Request__c
      WHERE OwnerId = :UserInfo.getUserId()
      ORDER BY CreatedDate DESC
      LIMIT 1
    ];
    Id requestId = existing.isEmpty() ? null : existing[0].Id;
    if (requestId == null && createIfMissing == true) {
      requestId = createPortalRequestForUser();
    }
    if (requestId == null) {
      return result;
    }
    return ensureAcePackage(requestId);
  }

  @AuraEnabled
  public static PortalInitResult ensureAcePackage(Id request7300Id) {
    PortalInitResult result = new PortalInitResult();
    if (request7300Id == null) {
      return result;
    }
    ACEF_Form_7300_Request__c request = [
      SELECT Id, ACEF_ACE_Access_Answer__c, ACEF_ACE_Access_Requested__c, ACEF_PGA_Application__c
      FROM ACEF_Form_7300_Request__c
      WHERE Id = :request7300Id
      LIMIT 1
    ];
    Boolean yes = request.ACEF_ACE_Access_Answer__c == 'Yes' || request.ACEF_ACE_Access_Requested__c == true;
    result.request7300RecordId = request.Id;
    result.aceAccessInScope = yes;
    if (!yes) {
      return result;
    }
    if (request.ACEF_PGA_Application__c != null) {
      result.packageRecordId = request.ACEF_PGA_Application__c;
      return result;
    }
    ACEF_PGA_Application__c pkg = new ACEF_PGA_Application__c(
      ACEF_Form_7300_Request__c = request.Id,
      ACEF_Status__c = 'Draft',
      ACEF_Package_Status__c = 'Draft'
    );
    insert pkg;
    update new ACEF_Form_7300_Request__c(Id = request.Id, ACEF_PGA_Application__c = pkg.Id);
    result.packageRecordId = pkg.Id;
    return result;
  }

  @AuraEnabled(cacheable=true)
  public static ChecklistState getPortalChecklistState(Id request7300Id, Id packageId) {
    ChecklistState state = new ChecklistState();
    state.request7300Id = request7300Id;
    state.packageId = packageId;
    return state;
  }
}
