/**
 * CBPPGA-87: saves and restores the Department → Agency → Systems selection on
 * the ACE PGA Application (ACEF_PGA_Application__c) step of the ACE PGA Portal.
 *
 * The selection is re-checked on the server with
 * ACEF_RoleEligibilityService.resolveSelection, so a requester can only save
 * systems and role codes their agency is eligible for (active mappings only).
 * Department and Agency labels go to the existing text fields that the forms
 * and PDFs print; the agency value, systems and role codes go to their own
 * fields.
 */
public with sharing class ACEF_PgaSystemSelectionService {
  @TestVisible
  private static final String LIST_SEPARATOR = ';';

  public class SavedSelection {
    @AuraEnabled
    public String deptAgency;
    @AuraEnabled
    public List<String> systems = new List<String>();
    @AuraEnabled
    public List<String> roleCodes = new List<String>();
    /** PGA user roles table (systems): Add / Remove / Recertify choices. */
    @AuraEnabled
    public List<String> systemsAdd = new List<String>();
    @AuraEnabled
    public List<String> systemsRemove = new List<String>();
    @AuraEnabled
    public List<String> systemsRecertify = new List<String>();
  }

  /** The saved selection, used to prefill the picker. Empty when nothing is saved. */
  @AuraEnabled(cacheable=true)
  public static SavedSelection getSelection(Id applicationId) {
    SavedSelection out = new SavedSelection();
    if (applicationId == null) {
      return out;
    }
    List<ACEF_PGA_Application__c> rows = [
      SELECT
        ACEF_Dept_Agency__c,
        ACEF_Requested_Systems__c,
        ACEF_Role_Codes__c,
        ACEF_Systems_Add__c,
        ACEF_Systems_Remove__c,
        ACEF_Systems_Recertify__c
      FROM ACEF_PGA_Application__c
      WHERE Id = :applicationId
      LIMIT 1
    ];
    if (rows.isEmpty()) {
      return out;
    }
    out.deptAgency = rows[0].ACEF_Dept_Agency__c;
    out.systems = split(rows[0].ACEF_Requested_Systems__c);
    out.roleCodes = split(rows[0].ACEF_Role_Codes__c);
    out.systemsAdd = split(rows[0].ACEF_Systems_Add__c);
    out.systemsRemove = split(rows[0].ACEF_Systems_Remove__c);
    out.systemsRecertify = split(rows[0].ACEF_Systems_Recertify__c);
    return out;
  }

  /**
   * Saves the PGA user roles table choices (systems from System / Role Mapping) on the
   * application: Add, Remove and Recertify, as semicolon-separated system API names.
   */
  @AuraEnabled
  public static void saveSystemActions(
    Id applicationId,
    List<String> systemsAdd,
    List<String> systemsRemove,
    List<String> systemsRecertify
  ) {
    if (applicationId == null) {
      throw new AuraHandledException('Open your PGA package first.');
    }
    try {
      update new ACEF_PGA_Application__c(
        Id = applicationId,
        ACEF_Systems_Add__c = joinList(systemsAdd),
        ACEF_Systems_Remove__c = joinList(systemsRemove),
        ACEF_Systems_Recertify__c = joinList(systemsRecertify)
      );
    } catch (DmlException e) {
      throw new AuraHandledException(e.getDmlMessage(0));
    }
  }

  private static String joinList(List<String> values) {
    if (values == null || values.isEmpty()) {
      return null;
    }
    return String.join(values, LIST_SEPARATOR);
  }

  /**
   * Checks the selection and, when valid, saves it on the application.
   * Returns the check result; nothing is saved when it is not valid.
   */
  @AuraEnabled
  public static ACEF_RoleEligibilityService.SelectionResult saveSelection(
    Id applicationId,
    String deptAgency,
    List<String> systems,
    List<String> roleCodes
  ) {
    if (applicationId == null) {
      throw new AuraHandledException('Open your PGA package first.');
    }
    ACEF_RoleEligibilityService.SelectionResult result = ACEF_RoleEligibilityService.resolveSelection(
      deptAgency,
      systems,
      roleCodes
    );
    if (!result.valid) {
      return result;
    }
    ACEF_RoleEligibilityService.DeptAgencyOption option = findOption(deptAgency);
    ACEF_PGA_Application__c application = new ACEF_PGA_Application__c(
      Id = applicationId,
      ACEF_Department__c = option == null ? null : option.departmentLabel,
      ACEF_Agency__c = option == null ? null : option.agency,
      ACEF_Dept_Agency__c = deptAgency,
      ACEF_Requested_Systems__c = String.join(result.systems, LIST_SEPARATOR),
      ACEF_Role_Codes__c = String.join(result.roleCodes, LIST_SEPARATOR),
      ACEF_Granted_Systems__c = String.join(
        result.grantedSystems,
        LIST_SEPARATOR
      )
    );
    try {
      update application;
    } catch (DmlException e) {
      throw new AuraHandledException(e.getDmlMessage(0));
    }
    return result;
  }

  private static ACEF_RoleEligibilityService.DeptAgencyOption findOption(
    String deptAgency
  ) {
    for (
      ACEF_RoleEligibilityService.DeptAgencyOption option : ACEF_RoleEligibilityService.getDeptAgencyOptions()
    ) {
      if (option.value == deptAgency) {
        return option;
      }
    }
    return null;
  }

  @TestVisible
  private static List<String> split(String value) {
    List<String> out = new List<String>();
    if (String.isBlank(value)) {
      return out;
    }
    for (String part : value.split(LIST_SEPARATOR)) {
      if (String.isNotBlank(part)) {
        out.add(part.trim());
      }
    }
    return out;
  }
}