/**
 * CBPPGA-87: works out which ACE systems a requester may ask for, from the
 * two admin-maintained matrices.
 *
 *   Dept/Agency ──► Role / Agency Mapping ──► eligible role codes
 *               ──► System / Role Mapping ──► systems tied to those codes
 *
 * Only mappings that are Activated with an Activation Date on or before today
 * are used (AC5). Department (ACEF_Department__c) controls Agency
 * (ACEF_Dept_Agency__c) through a field dependency that admins maintain in
 * Setup. Each agency value belongs to one department, so the agency value alone
 * identifies the Dept/Agency pair used for matching.
 */
public with sharing class ACEF_RoleEligibilityService {
  /** Separator used only for values that have no department in the dependency (legacy labels). */
  public static final String DEPT_AGENCY_DELIMITER = ' / ';

  /** Systems where the requester must pick specific roles in a dependent list (process map: AD/CVD). */
  public static final Set<String> ROLE_SELECTION_SYSTEMS = new Set<String>{
    'AD_CVD'
  };

  /** Systems that trigger the prefilled provisioning email (process map: GCMC or AES). */
  public static final Set<String> PROVISIONING_EMAIL_SYSTEMS = new Set<String>{
    'GCMC',
    'AES'
  };

  public class DeptAgencyOption {
    /** Agency picklist API name (ACEF_Dept_Agency__c). */
    @AuraEnabled
    public String value;
    /** "Department / Agency" display label. */
    @AuraEnabled
    public String label;
    /** Department picklist API name (ACEF_Department__c). */
    @AuraEnabled
    public String department;
    @AuraEnabled
    public String departmentLabel;
    /** Agency display label. */
    @AuraEnabled
    public String agency;
  }

  public class RoleOption {
    @AuraEnabled
    public String roleCode;
    @AuraEnabled
    public String roleName;
  }

  public class SystemOption {
    @AuraEnabled
    public String value;
    @AuraEnabled
    public String label;
    @AuraEnabled
    public Boolean requiresRoleSelection;
    @AuraEnabled
    public List<RoleOption> roles = new List<RoleOption>();
  }

  public class EligibilityResult {
    @AuraEnabled
    public String deptAgency;
    @AuraEnabled
    public List<String> eligibleRoleCodes = new List<String>();
    @AuraEnabled
    public List<SystemOption> systems = new List<SystemOption>();
  }

  public class SelectionResult {
    @AuraEnabled
    public Boolean valid = true;
    @AuraEnabled
    public List<String> errors = new List<String>();
    @AuraEnabled
    public List<String> systems = new List<String>();
    /** Role codes the request resolves to: the payload for provisioning. */
    @AuraEnabled
    public List<String> roleCodes = new List<String>();
    /** Every system the resolved role codes grant, including ones not picked directly. */
    @AuraEnabled
    public List<String> grantedSystems = new List<String>();
    @AuraEnabled
    public Boolean requiresProvisioningEmail = false;
  }

  // ------------------------------------------------------------------ public API

  /**
   * Active Agency values with the Department each belongs to (from the field
   * dependency), in the admin's Department order, then Agency order. Agencies
   * whose department is inactive or unset are left out.
   */
  @AuraEnabled(cacheable=true)
  public static List<DeptAgencyOption> getDeptAgencyOptions() {
    Map<String, String> departmentLabels = new Map<String, String>();
    for (
      Schema.PicklistEntry entry : ACEF_Role_Agency_Mapping__c.ACEF_Department__c.getDescribe()
        .getPicklistValues()
    ) {
      if (entry.isActive()) {
        departmentLabels.put(entry.getValue(), entry.getLabel());
      }
    }
    Map<String, String> departmentByAgency = departmentByAgency();
    Map<String, List<DeptAgencyOption>> byDepartment = new Map<String, List<DeptAgencyOption>>();
    for (
      Schema.PicklistEntry entry : ACEF_Role_Agency_Mapping__c.ACEF_Dept_Agency__c.getDescribe()
        .getPicklistValues()
    ) {
      String department = departmentByAgency.get(entry.getValue());
      if (!entry.isActive() || !departmentLabels.containsKey(department)) {
        continue;
      }
      if (!byDepartment.containsKey(department)) {
        byDepartment.put(department, new List<DeptAgencyOption>());
      }
      byDepartment.get(department)
        .add(
          toDeptAgencyOption(
            entry.getValue(),
            entry.getLabel(),
            department,
            departmentLabels.get(department)
          )
        );
    }
    List<DeptAgencyOption> options = new List<DeptAgencyOption>();
    for (String department : departmentLabels.keySet()) {
      if (byDepartment.containsKey(department)) {
        options.addAll(byDepartment.get(department));
      }
    }
    return options;
  }

  /**
   * Agency API name to Department API name, read from the field dependency on
   * Role / Agency Mapping. An agency valid for several departments maps to the
   * first one in picklist order.
   */
  public static Map<String, String> departmentByAgency() {
    List<Schema.PicklistEntry> departments = ACEF_Role_Agency_Mapping__c.ACEF_Department__c.getDescribe()
      .getPicklistValues();
    Map<String, String> out = new Map<String, String>();
    for (
      Schema.PicklistEntry entry : ACEF_Role_Agency_Mapping__c.ACEF_Dept_Agency__c.getDescribe()
        .getPicklistValues()
    ) {
      String validFor = (String) ((Map<String, Object>) JSON.deserializeUntyped(
          JSON.serialize(entry)
        ))
        .get('validFor');
      if (String.isBlank(validFor)) {
        continue;
      }
      String hex = EncodingUtil.convertToHex(
        EncodingUtil.base64Decode(validFor)
      );
      for (Integer i = 0; i < departments.size(); i++) {
        if (isBitSet(hex, i)) {
          out.put(entry.getValue(), departments[i].getValue());
          break;
        }
      }
    }
    return out;
  }

  /** Systems the Dept/Agency may request, each with the eligible role codes behind it (AC8). */
  @AuraEnabled(cacheable=true)
  public static EligibilityResult getEligibleSystems(String deptAgency) {
    if (String.isBlank(deptAgency)) {
      throw new AuraHandledException('Select a department and agency first.');
    }
    return evaluate(deptAgency, Date.today());
  }

  /**
   * Server-side check of a requester's picks, so the client cannot ask for a
   * system or role the agency is not eligible for.
   * @param deptAgency        Dept/Agency picklist value (API name)
   * @param systems           system API names the requester selected
   * @param selectedRoleCodes role codes picked in dependent lists (e.g. AD/CVD)
   */
  @AuraEnabled
  public static SelectionResult resolveSelection(
    String deptAgency,
    List<String> systems,
    List<String> selectedRoleCodes
  ) {
    SelectionResult out = new SelectionResult();
    if (String.isBlank(deptAgency)) {
      out.valid = false;
      out.errors.add('Select a department and agency.');
      return out;
    }
    if (systems == null || systems.isEmpty()) {
      out.valid = false;
      out.errors.add('Select at least one system.');
      return out;
    }
    EligibilityResult eligibility = evaluate(deptAgency, Date.today());
    Map<String, SystemOption> byValue = new Map<String, SystemOption>();
    for (SystemOption option : eligibility.systems) {
      byValue.put(option.value, option);
    }
    Set<String> picked = new Set<String>();
    if (selectedRoleCodes != null) {
      for (String code : selectedRoleCodes) {
        picked.add(ACEF_RoleMappingTriggerHandler.normalizeCode(code));
      }
    }

    Set<String> roleCodes = new Set<String>();
    Set<String> chosenSystems = new Set<String>(systems);
    for (String systemValue : chosenSystems) {
      SystemOption option = byValue.get(systemValue);
      if (option == null) {
        out.valid = false;
        out.errors.add(
          systemValue +
          ' is not available for the selected department and agency.'
        );
        continue;
      }
      out.systems.add(option.value);
      if (option.requiresRoleSelection) {
        Integer matched = 0;
        for (RoleOption role : option.roles) {
          if (
            picked.contains(
              ACEF_RoleMappingTriggerHandler.normalizeCode(role.roleCode)
            )
          ) {
            roleCodes.add(role.roleCode);
            matched++;
          }
        }
        if (matched == 0) {
          out.valid = false;
          out.errors.add('Select at least one ' + option.label + ' role.');
        }
      } else {
        for (RoleOption role : option.roles) {
          roleCodes.add(role.roleCode);
        }
      }
    }

    // Any picked role that is not offered under a chosen system is rejected.
    Set<String> offered = new Set<String>();
    for (String code : roleCodes) {
      offered.add(ACEF_RoleMappingTriggerHandler.normalizeCode(code));
    }
    for (String code : picked) {
      if (code != null && !offered.contains(code)) {
        out.valid = false;
        out.errors.add(
          'Role ' + code + ' is not available for the selected systems.'
        );
      }
    }

    out.roleCodes = new List<String>(roleCodes);
    out.roleCodes.sort();
    Set<String> granted = grantedSystems(roleCodes, Date.today());
    out.grantedSystems = new List<String>(granted);
    out.grantedSystems.sort();
    for (String systemValue : PROVISIONING_EMAIL_SYSTEMS) {
      if (granted.contains(systemValue)) {
        out.requiresProvisioningEmail = true;
      }
    }
    return out;
  }

  // ------------------------------------------------------------------ internals

  @TestVisible
  private static DeptAgencyOption toDeptAgencyOption(
    String value,
    String agencyLabel,
    String department,
    String departmentLabel
  ) {
    DeptAgencyOption option = new DeptAgencyOption();
    option.value = value;
    option.department = department;
    option.departmentLabel = departmentLabel;
    // Strip a legacy "Department / " prefix so the Agency list shows just the agency.
    String agency = agencyLabel;
    if (
      agency != null &&
      departmentLabel != null &&
      agency.startsWith(departmentLabel + DEPT_AGENCY_DELIMITER)
    ) {
      agency = agency.substring(
        (departmentLabel + DEPT_AGENCY_DELIMITER).length()
      );
    }
    option.agency = agency;
    option.label = departmentLabel + DEPT_AGENCY_DELIMITER + agency;
    return option;
  }

  /** Bit test on a picklist validFor bitmap (hex), most significant bit first. */
  @TestVisible
  private static Boolean isBitSet(String hex, Integer index) {
    Integer byteIndex = index >> 3;
    if (hex == null || hex.length() < (byteIndex + 1) * 2) {
      return false;
    }
    Integer byteValue =
      hexDigit(hex.substring(byteIndex * 2, byteIndex * 2 + 1)) * 16 +
      hexDigit(hex.substring(byteIndex * 2 + 1, byteIndex * 2 + 2));
    Integer mask = 128 >> (index & 7);
    return (byteValue & mask) != 0;
  }

  private static Integer hexDigit(String digit) {
    return '0123456789abcdef'.indexOf(digit.toLowerCase());
  }

  @TestVisible
  private static EligibilityResult evaluate(String deptAgency, Date asOf) {
    EligibilityResult result = new EligibilityResult();
    result.deptAgency = deptAgency;

    Set<String> eligibleCodes = new Set<String>();
    Set<String> normalizedEligible = new Set<String>();
    for (ACEF_Role_Agency_Mapping__c row : [
      SELECT ACEF_Role_Code__c
      FROM ACEF_Role_Agency_Mapping__c
      WHERE
        ACEF_Dept_Agency__c = :deptAgency
        AND ACEF_Activated__c = TRUE
        AND ACEF_Activation_Date__c <= :asOf
      ORDER BY ACEF_Role_Code__c
    ]) {
      String normalized = ACEF_RoleMappingTriggerHandler.normalizeCode(
        row.ACEF_Role_Code__c
      );
      if (!normalizedEligible.contains(normalized)) {
        normalizedEligible.add(normalized);
        eligibleCodes.add(row.ACEF_Role_Code__c);
      }
    }
    result.eligibleRoleCodes = new List<String>(eligibleCodes);
    if (eligibleCodes.isEmpty()) {
      return result;
    }

    Map<String, List<RoleOption>> rolesBySystem = new Map<String, List<RoleOption>>();
    for (ACEF_System_Role_Mapping__c row : [
      SELECT ACEF_Role_Code__c, ACEF_Role_Name__c, ACEF_System__c
      FROM ACEF_System_Role_Mapping__c
      WHERE
        ACEF_Role_Code__c IN :eligibleCodes
        AND ACEF_Activated__c = TRUE
        AND ACEF_Activation_Date__c <= :asOf
      ORDER BY ACEF_Role_Code__c
    ]) {
      if (!rolesBySystem.containsKey(row.ACEF_System__c)) {
        rolesBySystem.put(row.ACEF_System__c, new List<RoleOption>());
      }
      RoleOption role = new RoleOption();
      role.roleCode = row.ACEF_Role_Code__c;
      role.roleName = row.ACEF_Role_Name__c;
      rolesBySystem.get(row.ACEF_System__c).add(role);
    }

    // Keep the admin's picklist order for systems.
    for (
      Schema.PicklistEntry entry : ACEF_System_Role_Mapping__c.ACEF_System__c.getDescribe()
        .getPicklistValues()
    ) {
      if (!entry.isActive() || !rolesBySystem.containsKey(entry.getValue())) {
        continue;
      }
      SystemOption option = new SystemOption();
      option.value = entry.getValue();
      option.label = entry.getLabel();
      option.requiresRoleSelection = ROLE_SELECTION_SYSTEMS.contains(
        entry.getValue()
      );
      option.roles = rolesBySystem.get(entry.getValue());
      result.systems.add(option);
    }
    return result;
  }

  private static Set<String> grantedSystems(Set<String> roleCodes, Date asOf) {
    Set<String> granted = new Set<String>();
    if (roleCodes.isEmpty()) {
      return granted;
    }
    for (ACEF_System_Role_Mapping__c row : [
      SELECT ACEF_System__c
      FROM ACEF_System_Role_Mapping__c
      WHERE
        ACEF_Role_Code__c IN :roleCodes
        AND ACEF_Activated__c = TRUE
        AND ACEF_Activation_Date__c <= :asOf
    ]) {
      granted.add(row.ACEF_System__c);
    }
    return granted;
  }
}