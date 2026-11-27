public with sharing class ACEF_Form7300ProgressService {
  public static Boolean isReadyForBiDisposition(ACEF_Form_7300_Request__c request) {
    if (request == null) {
      return false;
    }
    return new Set<String>{ 'Section 4 Complete', 'With 7300 Processing', 'OIT BI Review' }
      .contains(request.ACEF_Status__c);
  }
}
