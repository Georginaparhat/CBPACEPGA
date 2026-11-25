/**
 * CBPPGA-87 test data for Role / Agency Mapping and System / Role Mapping.
 * Dept/Agency values are read from the picklist at run time, so tests keep
 * working when admins rename or replace the placeholder values.
 */
@isTest
public class ACEF_RoleMappingTestData {
  public static final Date YESTERDAY = Date.today().addDays(-1);

  public static String deptAgency(Integer index) {
    // Only agencies that sit under an active department can be saved.
    List<String> values = new List<String>();
    for (
      ACEF_RoleEligibilityService.DeptAgencyOption option : ACEF_RoleEligibilityService.getDeptAgencyOptions()
    ) {
      values.add(option.value);
    }
    System.assert(
      values.size() > index,
      'Tests need at least ' + (index + 1) + ' active Dept/Agency values.'
    );
    return values[index];
  }

  /** Department that the agency value belongs to, from the field dependency. */
  public static String department(String deptAgency) {
    return ACEF_RoleEligibilityService.departmentByAgency().get(deptAgency);
  }

  public static ACEF_Role_Agency_Mapping__c roleAgency(
    String code,
    String deptAgency,
    Boolean active,
    Date activationDate
  ) {
    return new ACEF_Role_Agency_Mapping__c(
      ACEF_Role_Code__c = code,
      ACEF_Role_Name__c = 'Role ' + code,
      ACEF_Department__c = department(deptAgency),
      ACEF_Dept_Agency__c = deptAgency,
      ACEF_Activated__c = active,
      ACEF_Activation_Date__c = activationDate
    );
  }

  public static ACEF_Role_Agency_Mapping__c activeRoleAgency(
    String code,
    String deptAgency
  ) {
    return roleAgency(code, deptAgency, true, YESTERDAY);
  }

  public static ACEF_System_Role_Mapping__c systemRole(
    String code,
    String systemValue,
    Boolean active,
    Date activationDate
  ) {
    return new ACEF_System_Role_Mapping__c(
      ACEF_Role_Code__c = code,
      ACEF_Role_Name__c = 'Role ' + code,
      ACEF_System__c = systemValue,
      ACEF_Activated__c = active,
      ACEF_Activation_Date__c = activationDate
    );
  }

  public static ACEF_System_Role_Mapping__c activeSystemRole(
    String code,
    String systemValue
  ) {
    return systemRole(code, systemValue, true, YESTERDAY);
  }
}