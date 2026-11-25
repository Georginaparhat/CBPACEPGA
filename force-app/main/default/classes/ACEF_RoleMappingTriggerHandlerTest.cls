@isTest
private class ACEF_RoleMappingTriggerHandlerTest {
  private static String dept0() {
    return ACEF_RoleMappingTestData.deptAgency(0);
  }

  private static String dept1() {
    return ACEF_RoleMappingTestData.deptAgency(1);
  }

  private static String firstError(Database.SaveResult result) {
    return result.getErrors().isEmpty()
      ? null
      : result.getErrors()[0].getMessage();
  }

  private static String firstError(Database.DeleteResult result) {
    return result.getErrors().isEmpty()
      ? null
      : result.getErrors()[0].getMessage();
  }

  @isTest
  static void insertSetsUniqueKeyAndTrimsCode() {
    ACEF_Role_Agency_Mapping__c row = ACEF_RoleMappingTestData.activeRoleAgency(
      '  t_code1 ',
      dept0()
    );
    insert row;
    row = [
      SELECT ACEF_Role_Code__c, ACEF_Unique_Key__c
      FROM ACEF_Role_Agency_Mapping__c
      WHERE Id = :row.Id
    ];
    System.assertEquals(
      't_code1',
      row.ACEF_Role_Code__c,
      'Surrounding spaces are removed, casing kept'
    );
    System.assertEquals('T_CODE1|' + dept0(), row.ACEF_Unique_Key__c);
  }

  @isTest
  static void duplicateRoleCodeAndDeptAgencyIsRejected() {
    insert ACEF_RoleMappingTestData.activeRoleAgency('T_DUP', dept0());
    Database.SaveResult result = Database.insert(
      ACEF_RoleMappingTestData.activeRoleAgency('t_dup', dept0()),
      false
    );
    System.assert(
      !result.isSuccess(),
      'Same code (any case) and Dept/Agency must be rejected'
    );
    System.assert(
      firstError(result).contains('already mapped to this Dept/Agency'),
      firstError(result)
    );
  }

  @isTest
  static void duplicateWithinOneSaveIsRejected() {
    List<Database.SaveResult> results = Database.insert(
      new List<ACEF_Role_Agency_Mapping__c>{
        ACEF_RoleMappingTestData.activeRoleAgency('T_BATCH', dept0()),
        ACEF_RoleMappingTestData.activeRoleAgency('T_BATCH', dept0())
      },
      false
    );
    System.assert(results[0].isSuccess(), 'First row saves');
    System.assert(!results[1].isSuccess(), 'Second identical row is rejected');
  }

  @isTest
  static void sameRoleCodeForDifferentDeptAgencyIsAllowed() {
    insert new List<ACEF_Role_Agency_Mapping__c>{
      ACEF_RoleMappingTestData.activeRoleAgency('T_SHARED', dept0()),
      ACEF_RoleMappingTestData.activeRoleAgency('T_SHARED', dept1())
    };
    System.assertEquals(
      2,
      [
        SELECT COUNT()
        FROM ACEF_Role_Agency_Mapping__c
        WHERE ACEF_Role_Code__c = 'T_SHARED'
      ]
    );
  }

  @isTest
  static void activatedRecordNeedsActivationDate() {
    Database.SaveResult ram = Database.insert(
      ACEF_RoleMappingTestData.roleAgency('T_NODATE', dept0(), true, null),
      false
    );
    System.assert(
      !ram.isSuccess(),
      'AC4: activated Role / Agency Mapping needs an Activation Date'
    );
    insert ACEF_RoleMappingTestData.roleAgency(
      'T_NODATE',
      dept0(),
      false,
      null
    );
    Database.SaveResult srm = Database.insert(
      ACEF_RoleMappingTestData.systemRole(
        'T_NODATE',
        'ACE_Reports',
        true,
        null
      ),
      false
    );
    System.assert(
      !srm.isSuccess(),
      'AC4: activated System / Role Mapping needs an Activation Date'
    );
  }

  @isTest
  static void inactiveRecordWithoutDateIsAllowed() {
    insert ACEF_RoleMappingTestData.roleAgency('T_DRAFT', dept0(), false, null);
    System.assertEquals(
      1,
      [
        SELECT COUNT()
        FROM ACEF_Role_Agency_Mapping__c
        WHERE ACEF_Role_Code__c = 'T_DRAFT'
      ]
    );
  }

  @isTest
  static void systemRoleNeedsExistingRoleCode() {
    Database.SaveResult result = Database.insert(
      ACEF_RoleMappingTestData.activeSystemRole('T_UNKNOWN', 'ACE_Reports'),
      false
    );
    System.assert(
      !result.isSuccess(),
      'AC7: code must exist in Role / Agency Mapping'
    );
    System.assert(
      firstError(result).contains('does not exist in Role / Agency Mapping'),
      firstError(result)
    );
  }

  @isTest
  static void systemRoleAcceptsCodeFromInactiveRoleAgencyRow() {
    insert ACEF_RoleMappingTestData.roleAgency(
      'T_INACTIVE',
      dept0(),
      false,
      null
    );
    insert ACEF_RoleMappingTestData.activeSystemRole(
      't_inactive',
      'ACE_Reports'
    );
    System.assertEquals(1, [SELECT COUNT() FROM ACEF_System_Role_Mapping__c]);
  }

  @isTest
  static void duplicateRoleCodeAndSystemIsRejected() {
    insert ACEF_RoleMappingTestData.activeRoleAgency('T_SYS', dept0());
    insert ACEF_RoleMappingTestData.activeSystemRole('T_SYS', 'ACE_Reports');
    Database.SaveResult result = Database.insert(
      ACEF_RoleMappingTestData.activeSystemRole('T_SYS', 'ACE_Reports'),
      false
    );
    System.assert(!result.isSuccess(), 'AC6: Role Code + System is unique');
    insert ACEF_RoleMappingTestData.activeSystemRole('T_SYS', 'ACE_Account');
    System.assertEquals(2, [SELECT COUNT() FROM ACEF_System_Role_Mapping__c]);
  }

  @isTest
  static void cannotDeleteLastRoleAgencyRowStillUsedBySystemRole() {
    ACEF_Role_Agency_Mapping__c row = ACEF_RoleMappingTestData.activeRoleAgency(
      'T_USED',
      dept0()
    );
    insert row;
    insert ACEF_RoleMappingTestData.activeSystemRole('T_USED', 'ACE_Reports');
    Database.DeleteResult result = Database.delete(row, false);
    System.assert(
      !result.isSuccess(),
      'Last row for a referenced code cannot be deleted'
    );
    System.assert(
      firstError(result).contains('Deactivate this mapping'),
      firstError(result)
    );
  }

  @isTest
  static void canDeleteRowWhenAnotherRowKeepsTheCode() {
    ACEF_Role_Agency_Mapping__c first = ACEF_RoleMappingTestData.activeRoleAgency(
      'T_TWO',
      dept0()
    );
    insert new List<ACEF_Role_Agency_Mapping__c>{
      first,
      ACEF_RoleMappingTestData.activeRoleAgency('T_TWO', dept1())
    };
    insert ACEF_RoleMappingTestData.activeSystemRole('T_TWO', 'ACE_Reports');
    delete first;
    System.assertEquals(
      1,
      [
        SELECT COUNT()
        FROM ACEF_Role_Agency_Mapping__c
        WHERE ACEF_Role_Code__c = 'T_TWO'
      ]
    );
  }

  @isTest
  static void cannotRenameLastReferencedRoleCode() {
    ACEF_Role_Agency_Mapping__c row = ACEF_RoleMappingTestData.activeRoleAgency(
      'T_RENAME',
      dept0()
    );
    insert row;
    insert ACEF_RoleMappingTestData.activeSystemRole('T_RENAME', 'ACE_Reports');
    row.ACEF_Role_Code__c = 'T_RENAMED';
    Database.SaveResult result = Database.update(row, false);
    System.assert(
      !result.isSuccess(),
      'Changing a referenced code would orphan System / Role Mapping'
    );
  }

  @isTest
  static void deactivatingReferencedRowIsAllowed() {
    ACEF_Role_Agency_Mapping__c row = ACEF_RoleMappingTestData.activeRoleAgency(
      'T_DEACT',
      dept0()
    );
    insert row;
    insert ACEF_RoleMappingTestData.activeSystemRole('T_DEACT', 'ACE_Reports');
    row.ACEF_Activated__c = false;
    update row;
    System.assertEquals(
      false,
      [
        SELECT ACEF_Activated__c
        FROM ACEF_Role_Agency_Mapping__c
        WHERE Id = :row.Id
      ]
      .ACEF_Activated__c
    );
  }

  @isTest
  static void unreferencedRowCanBeDeleted() {
    ACEF_Role_Agency_Mapping__c row = ACEF_RoleMappingTestData.activeRoleAgency(
      'T_FREE',
      dept0()
    );
    insert row;
    delete row;
    System.assertEquals(0, [SELECT COUNT() FROM ACEF_Role_Agency_Mapping__c]);
  }

  @isTest
  static void bulkInsertOf200RowsSucceeds() {
    List<ACEF_Role_Agency_Mapping__c> roles = new List<ACEF_Role_Agency_Mapping__c>();
    List<ACEF_System_Role_Mapping__c> systems = new List<ACEF_System_Role_Mapping__c>();
    for (Integer i = 0; i < 200; i++) {
      roles.add(
        ACEF_RoleMappingTestData.activeRoleAgency('T_BULK_' + i, dept0())
      );
      systems.add(
        ACEF_RoleMappingTestData.activeSystemRole('T_BULK_' + i, 'ACE_Reports')
      );
    }
    Test.startTest();
    insert roles;
    insert systems;
    Test.stopTest();
    System.assertEquals(200, [SELECT COUNT() FROM ACEF_System_Role_Mapping__c]);
  }
}