@isTest
private class ACEF_ProvisioningHomeServiceTest {
  @isTest
  static void countsPackagesByStageAndAssignment() {
    ACEF_Form_7300_Request__c request = new ACEF_Form_7300_Request__c(ACEF_Status__c = 'Draft');
    insert request;
    insert new List<ACEF_PGA_Application__c>{
      new ACEF_PGA_Application__c(ACEF_Form_7300_Request__c = request.Id),
      new ACEF_PGA_Application__c(ACEF_ACE_Security_Verified__c = true, ACEF_Status__c = 'Complete')
    };

    Test.startTest();
    ACEF_ProvisioningHomeService.Summary summary = ACEF_ProvisioningHomeService.getSummary();
    Test.stopTest();

    System.assertEquals(2, summary.totalPackages);
    Map<String, ACEF_ProvisioningHomeService.Tile> byKey = new Map<String, ACEF_ProvisioningHomeService.Tile>();
    for (ACEF_ProvisioningHomeService.Tile t : summary.tiles) {
      byKey.put(t.key, t);
      System.assertNotEquals(null, t.listViewName);
    }
    System.assertEquals(1, byKey.get('assigned').count, 'Open package owned by the running user');
    System.assertEquals(1, byKey.get('XPGA_Stage_Completed').count);
    System.assertEquals(1, byKey.get('XPGA_Stage_Waiting_Forms').count, 'New package starts in Draft');
    System.assertEquals(ACEF_ProvisioningHomeService.STAGES.size() + 2, summary.tiles.size());
    System.assertEquals(0, byKey.get('form7300Only').count);
  }
}