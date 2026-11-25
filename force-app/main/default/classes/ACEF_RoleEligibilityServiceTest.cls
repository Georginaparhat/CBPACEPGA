@isTest
private class ACEF_RoleEligibilityServiceTest {
  /*
   * dept0: T_R1 (active)       -> ACE_Reports
   *        T_R2 (active)       -> AD_CVD, GCMC
   *        T_R3 (inactive)     -> ACE_Account        (excluded: role inactive)
   *        T_R4 (future date)  -> Manifest_Data      (excluded: not yet active)
   *        T_R1                -> ACE_Account inactive (excluded: system row inactive)
   * dept1: T_R5 (active)       -> ACE_Account        (other agency)
   */
  @testSetup
  static void setup() {
    String d0 = ACEF_RoleMappingTestData.deptAgency(0);
    String d1 = ACEF_RoleMappingTestData.deptAgency(1);
    insert new List<ACEF_Role_Agency_Mapping__c>{
      ACEF_RoleMappingTestData.activeRoleAgency('T_R1', d0),
      ACEF_RoleMappingTestData.activeRoleAgency('T_R2', d0),
      ACEF_RoleMappingTestData.roleAgency('T_R3', d0, false, null),
      ACEF_RoleMappingTestData.roleAgency(
        'T_R4',
        d0,
        true,
        Date.today().addDays(30)
      ),
      ACEF_RoleMappingTestData.activeRoleAgency('T_R5', d1)
    };
    insert new List<ACEF_System_Role_Mapping__c>{
      ACEF_RoleMappingTestData.activeSystemRole('T_R1', 'ACE_Reports'),
      ACEF_RoleMappingTestData.systemRole('T_R1', 'ACE_Account', false, null),
      ACEF_RoleMappingTestData.activeSystemRole('T_R2', 'AD_CVD'),
      ACEF_RoleMappingTestData.activeSystemRole('T_R2', 'GCMC'),
      ACEF_RoleMappingTestData.activeSystemRole('T_R3', 'ACE_Account'),
      ACEF_RoleMappingTestData.activeSystemRole('T_R4', 'Manifest_Data'),
      ACEF_RoleMappingTestData.activeSystemRole('T_R5', 'ACE_Account')
    };
  }

  private static Set<String> systemValues(
    ACEF_RoleEligibilityService.EligibilityResult result
  ) {
    Set<String> values = new Set<String>();
    for (ACEF_RoleEligibilityService.SystemOption option : result.systems) {
      values.add(option.value);
    }
    return values;
  }

  @isTest
  static void eligibleSystemsUseOnlyActiveMappingsForTheAgency() {
    ACEF_RoleEligibilityService.EligibilityResult result = ACEF_RoleEligibilityService.getEligibleSystems(
      ACEF_RoleMappingTestData.deptAgency(0)
    );
    System.assertEquals(
      new Set<String>{ 'T_R1', 'T_R2' },
      new Set<String>(result.eligibleRoleCodes)
    );
    System.assertEquals(
      new Set<String>{ 'ACE_Reports', 'AD_CVD', 'GCMC' },
      systemValues(result)
    );
    for (ACEF_RoleEligibilityService.SystemOption option : result.systems) {
      System.assertEquals(
        option.value == 'AD_CVD',
        option.requiresRoleSelection,
        option.value
      );
    }
  }

  @isTest
  static void otherAgencySeesOnlyItsOwnSystems() {
    ACEF_RoleEligibilityService.EligibilityResult result = ACEF_RoleEligibilityService.getEligibleSystems(
      ACEF_RoleMappingTestData.deptAgency(1)
    );
    System.assertEquals(new Set<String>{ 'ACE_Account' }, systemValues(result));
  }

  @isTest
  static void agencyWithNoMappingsGetsNoSystems() {
    delete [
      SELECT Id
      FROM ACEF_System_Role_Mapping__c
      WHERE ACEF_Role_Code__c = 'T_R5'
    ];
    delete [
      SELECT Id
      FROM ACEF_Role_Agency_Mapping__c
      WHERE ACEF_Role_Code__c = 'T_R5'
    ];
    ACEF_RoleEligibilityService.EligibilityResult result = ACEF_RoleEligibilityService.getEligibleSystems(
      ACEF_RoleMappingTestData.deptAgency(1)
    );
    System.assert(result.systems.isEmpty());
    System.assert(result.eligibleRoleCodes.isEmpty());
  }

  @isTest
  static void blankDeptAgencyIsRejected() {
    try {
      ACEF_RoleEligibilityService.getEligibleSystems(' ');
      System.assert(false, 'Expected an AuraHandledException');
    } catch (AuraHandledException e) {
      System.assert(true);
    }
  }

  @isTest
  static void deptAgencyOptionsFollowTheDepartmentDependency() {
    List<ACEF_RoleEligibilityService.DeptAgencyOption> options = ACEF_RoleEligibilityService.getDeptAgencyOptions();
    System.assert(!options.isEmpty(), 'Expected agencies with a department');
    Map<String, String> departmentByAgency = ACEF_RoleEligibilityService.departmentByAgency();
    for (ACEF_RoleEligibilityService.DeptAgencyOption option : options) {
      System.assertNotEquals(null, option.department, option.value);
      System.assertEquals(
        departmentByAgency.get(option.value),
        option.department,
        'Agency must sit under the department set in the field dependency'
      );
      System.assertNotEquals(null, option.departmentLabel);
      System.assertEquals(
        option.departmentLabel + ' / ' + option.agency,
        option.label
      );
    }
  }

  @isTest
  static void legacyCombinedLabelIsTrimmedToTheAgency() {
    ACEF_RoleEligibilityService.DeptAgencyOption legacy = ACEF_RoleEligibilityService.toDeptAgencyOption(
      'X',
      'Department A / Agency 1',
      'DEPT_A',
      'Department A'
    );
    System.assertEquals('Agency 1', legacy.agency);
    System.assertEquals('Department A / Agency 1', legacy.label);
    ACEF_RoleEligibilityService.DeptAgencyOption plain = ACEF_RoleEligibilityService.toDeptAgencyOption(
      'Y',
      'Agency 2',
      'DEPT_A',
      'Department A'
    );
    System.assertEquals('Agency 2', plain.agency);
  }

  @isTest
  static void validForBitmapIsReadMostSignificantBitFirst() {
    // 0xA0 = 1010 0000: departments 0 and 2 are set.
    System.assert(ACEF_RoleEligibilityService.isBitSet('a0', 0));
    System.assert(!ACEF_RoleEligibilityService.isBitSet('a0', 1));
    System.assert(ACEF_RoleEligibilityService.isBitSet('a0', 2));
    System.assert(!ACEF_RoleEligibilityService.isBitSet('a0', 8));
    System.assert(ACEF_RoleEligibilityService.isBitSet('0001', 15));
  }

  @isTest
  static void resolveSelectionReturnsRoleCodesAndProvisioningFlag() {
    ACEF_RoleEligibilityService.SelectionResult result = ACEF_RoleEligibilityService.resolveSelection(
      ACEF_RoleMappingTestData.deptAgency(0),
      new List<String>{ 'ACE_Reports', 'AD_CVD' },
      new List<String>{ 't_r2' }
    );
    System.assert(result.valid, String.valueOf(result.errors));
    System.assertEquals(new List<String>{ 'T_R1', 'T_R2' }, result.roleCodes);
    System.assert(
      new Set<String>(result.grantedSystems).contains('GCMC'),
      'T_R2 also grants GCMC'
    );
    System.assert(
      result.requiresProvisioningEmail,
      'GCMC access needs the provisioning email'
    );
  }

  @isTest
  static void resolveSelectionWithoutGcmcOrAesNeedsNoEmail() {
    ACEF_RoleEligibilityService.SelectionResult result = ACEF_RoleEligibilityService.resolveSelection(
      ACEF_RoleMappingTestData.deptAgency(0),
      new List<String>{ 'ACE_Reports' },
      null
    );
    System.assert(result.valid, String.valueOf(result.errors));
    System.assert(!result.requiresProvisioningEmail);
  }

  @isTest
  static void adCvdNeedsARoleSelection() {
    ACEF_RoleEligibilityService.SelectionResult result = ACEF_RoleEligibilityService.resolveSelection(
      ACEF_RoleMappingTestData.deptAgency(0),
      new List<String>{ 'AD_CVD' },
      new List<String>()
    );
    System.assert(!result.valid);
  }

  @isTest
  static void ineligibleSystemOrRoleIsRejected() {
    String d0 = ACEF_RoleMappingTestData.deptAgency(0);
    System.assert(
      !ACEF_RoleEligibilityService.resolveSelection(
          d0,
          new List<String>{ 'ACE_Account' },
          null
        )
        .valid,
      'ACE_Account is only reachable through inactive mappings for dept0'
    );
    System.assert(
      !ACEF_RoleEligibilityService.resolveSelection(
          d0,
          new List<String>{ 'ACE_Reports' },
          new List<String>{ 'T_R5' }
        )
        .valid,
      'A role from another agency cannot be smuggled in'
    );
  }

  @isTest
  static void resolveSelectionRequiresInputs() {
    System.assert(
      !ACEF_RoleEligibilityService.resolveSelection(
          null,
          new List<String>{ 'ACE_Reports' },
          null
        )
        .valid
    );
    System.assert(
      !ACEF_RoleEligibilityService.resolveSelection(
          ACEF_RoleMappingTestData.deptAgency(0),
          null,
          null
        )
        .valid
    );
  }
}