public with sharing class ACEF_CbpForm7300ProgressService {
  @AuraEnabled
  public static Id findIdByConfirmation(String confirmationNumber) {
    if (String.isBlank(confirmationNumber)) {
      return null;
    }
    List<ACEF_CBP_Form_7300__c> rows = [
      SELECT Id
      FROM ACEF_CBP_Form_7300__c
      WHERE Name = :confirmationNumber
      LIMIT 1
    ];
    return rows.isEmpty() ? null : rows[0].Id;
  }
}
