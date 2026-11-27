public with sharing class ACEF_Form001AccessService {
  public class Form001Defaults {
    @AuraEnabled
    public String applicantName;
    @AuraEnabled
    public Boolean createNewUser;
  }

  @AuraEnabled(cacheable=true)
  public static Form001Defaults getForm001Defaults(Id packageId) {
    Form001Defaults defaults = new Form001Defaults();
    if (packageId == null) {
      return defaults;
    }
    ACEF_PGA_Application__c pkg = [
      SELECT ACEF_Form001_Applicant_Name__c, ACEF_Form001_Create_New_User__c
      FROM ACEF_PGA_Application__c
      WHERE Id = :packageId
      LIMIT 1
    ];
    defaults.applicantName = pkg.ACEF_Form001_Applicant_Name__c;
    defaults.createNewUser = pkg.ACEF_Form001_Create_New_User__c;
    return defaults;
  }
}
