@isTest
private class ACEF_PgaSystemSelectionServiceTest {
  /*
   * agency0: S_R1 -> ACE_Reports, S_R2 -> AD_CVD + GCMC
   * agency1: S_R3 -> ACE_Account
   */
  @testSetup
  static void setup() {
    String a0 = ACEF_RoleMappingTestData.deptAgency(0);
    String a1 = ACEF_RoleMappingTestData.deptAgency(1);
    insert new List<ACEF_Role_Agency_Mapping__c>{
      ACEF_RoleMappingTestData.activeRoleAgency('S_R1', a0),
      ACEF_RoleMappingTestData.activeRoleAgency('S_R2', a0),
      ACEF_RoleMappingTestData.activeRoleAgency('S_R3', a1)
    };
    insert new List<ACEF_System_Role_Mapping__c>{
      ACEF_RoleMappingTestData.activeSystemRole('S_R1', 'ACE_Reports'),
      ACEF_RoleMappingTestData.activeSystemRole('S_R2', 'AD_CVD'),
      ACEF_RoleMappingTestData.activeSystemRole('S_R2', 'GCMC'),
      ACEF_RoleMappingTestData.activeSystemRole('S_R3', 'ACE_Account')
    };
    insert new ACEF_PGA_Application__c();
  }

  private static Id applicationId() {
    return [SELECT Id FROM ACEF_PGA_Application__c LIMIT 1].Id;
  }

  @isTest
  static void validSelectionIsSavedWithLabelsAndRoleCodes() {
    String a0 = ACEF_RoleMappingTestData.deptAgency(0);
    Id appId = applicationId();

    Test.startTest();
    ACEF_RoleEligibilityService.SelectionResult result = ACEF_PgaSystemSelectionService.saveSelection(
      appId,
      a0,
      new List<String>{ 'ACE_Reports', 'AD_CVD' },
      new List<String>{ 'S_R2' }
    );
    Test.stopTest();

    System.assert(result.valid, String.join(result.errors, ' '));
    ACEF_PGA_Application__c app = [
      SELECT
        ACEF_Department__c,
        ACEF_Agency__c,
        ACEF_Dept_Agency__c,
        ACEF_Requested_Systems__c,
        ACEF_Role_Codes__c,
        ACEF_Granted_Systems__c
      FROM ACEF_PGA_Application__c
      WHERE Id = :appId
    ];
    ACEF_RoleEligibilityService.DeptAgencyOption option;
    for (
      ACEF_RoleEligibilityService.DeptAgencyOption candidate : ACEF_RoleEligibilityService.getDeptAgencyOptions()
    ) {
      if (candidate.value == a0) {
        option = candidate;
      }
    }
    System.assertEquals(option.departmentLabel, app.ACEF_Department__c);
    System.assertEquals(option.agency, app.ACEF_Agency__c);
    System.assertEquals(a0, app.ACEF_Dept_Agency__c);
    System.assertEquals('ACE_Reports;AD_CVD', app.ACEF_Requested_Systems__c);
    System.assertEquals('S_R1;S_R2', app.ACEF_Role_Codes__c);
    System.assert(app.ACEF_Granted_Systems__c.contains('GCMC'));
    System.assert(result.requiresProvisioningEmail);

    ACEF_PgaSystemSelectionService.SavedSelection saved = ACEF_PgaSystemSelectionService.getSelection(
      appId
    );
    System.assertEquals(a0, saved.deptAgency);
    System.assertEquals(
      new List<String>{ 'ACE_Reports', 'AD_CVD' },
      saved.systems
    );
    System.assertEquals(new List<String>{ 'S_R1', 'S_R2' }, saved.roleCodes);
  }

  @isTest
  static void systemOfAnotherAgencyIsRejectedAndNothingSaved() {
    String a0 = ACEF_RoleMappingTestData.deptAgency(0);
    Id appId = applicationId();

    ACEF_RoleEligibilityService.SelectionResult result = ACEF_PgaSystemSelectionService.saveSelection(
      appId,
      a0,
      new List<String>{ 'ACE_Account' },
      new List<String>()
    );

    System.assert(!result.valid);
    ACEF_PGA_Application__c app = [
      SELECT ACEF_Dept_Agency__c, ACEF_Requested_Systems__c
      FROM ACEF_PGA_Application__c
      WHERE Id = :appId
    ];
    System.assertEquals(null, app.ACEF_Dept_Agency__c);
    System.assertEquals(null, app.ACEF_Requested_Systems__c);
  }

  @isTest
  static void systemActionsAreSavedAndRestored() {
    Id appId = applicationId();
    ACEF_PgaSystemSelectionService.saveSystemActions(
      appId,
      new List<String>{ 'ACE_Reports', 'AES' },
      new List<String>{ 'GCMC' },
      new List<String>()
    );
    ACEF_PgaSystemSelectionService.SavedSelection saved = ACEF_PgaSystemSelectionService.getSelection(appId);
    System.assertEquals(new List<String>{ 'ACE_Reports', 'AES' }, saved.systemsAdd);
    System.assertEquals(new List<String>{ 'GCMC' }, saved.systemsRemove);
    System.assert(saved.systemsRecertify.isEmpty());
    try {
      ACEF_PgaSystemSelectionService.saveSystemActions(null, null, null, null);
      System.assert(false, 'Expected an AuraHandledException');
    } catch (AuraHandledException e) {
      System.assert(true);
    }
  }

  @isTest
  static void emptyAndMissingInputsAreHandled() {
    ACEF_PgaSystemSelectionService.SavedSelection empty = ACEF_PgaSystemSelectionService.getSelection(
      null
    );
    System.assertEquals(null, empty.deptAgency);
    System.assert(empty.systems.isEmpty());
    System.assert(
      ACEF_PgaSystemSelectionService.getSelection(applicationId())
        .systems.isEmpty()
    );
    System.assertEquals(
      new List<String>{ 'A', 'B' },
      ACEF_PgaSystemSelectionService.split('A; ;B')
    );
    try {
      ACEF_PgaSystemSelectionService.saveSelection(
        null,
        'X',
        new List<String>(),
        new List<String>()
      );
      System.assert(false, 'Expected an AuraHandledException');
    } catch (AuraHandledException e) {
      System.assert(true);
    }
  }
}