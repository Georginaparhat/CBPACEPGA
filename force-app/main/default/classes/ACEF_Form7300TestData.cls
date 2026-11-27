@isTest
public class ACEF_Form7300TestData {
  public static ACEF_CBP_Form_7300__c insertPending() {
    ACEF_CBP_Form_7300__c form = new ACEF_CBP_Form_7300__c(
      ACEF_First_Name__c = 'Riley',
      ACEF_Last_Name__c = 'Requester',
      ACEF_Home_Agency_Email__c = 'riley.requester@agency.example.gov',
      ACEF_Supervisor_Email__c = 'grace@agency.gov',
      ACEF_Security_Email__c = 'alan.pso@agency.example.gov',
      ACEF_User_Cert_Name__c = 'Riley Requester'
    );
    insert form;
    return form;
  }
}
