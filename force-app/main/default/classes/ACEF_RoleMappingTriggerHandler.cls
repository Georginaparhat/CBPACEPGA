/**
 * CBPPGA-87: integrity rules for the two role-mapping objects.
 *
 *  - Role / Agency Mapping: Role Code + Dept/Agency is unique (AC6).
 *  - System / Role Mapping: Role Code + System is unique (AC6), and the Role Code
 *    must already exist in Role / Agency Mapping (AC7).
 *  - A Role / Agency Mapping row cannot be deleted, or have its Role Code changed,
 *    when it is the last row for a code that System / Role Mapping still uses.
 *    Admins deactivate mappings instead (AC2).
 *
 * Role codes are compared trimmed and case-insensitively. The stored value keeps
 * the admin's casing; only surrounding spaces are removed.
 */
public with sharing class ACEF_RoleMappingTriggerHandler {
  @TestVisible
  private static final String KEY_SEPARATOR = '|';

  public static String normalizeCode(String code) {
    return code == null ? null : code.trim().toUpperCase();
  }

  public static String buildKey(String code, String qualifier) {
    String normalized = normalizeCode(code);
    if (String.isBlank(normalized) || String.isBlank(qualifier)) {
      return null;
    }
    return normalized + KEY_SEPARATOR + qualifier;
  }

  // ---------------------------------------------------------------- Role / Agency Mapping

  public static void beforeSaveRoleAgency(
    List<ACEF_Role_Agency_Mapping__c> rows
  ) {
    for (ACEF_Role_Agency_Mapping__c row : rows) {
      if (row.ACEF_Role_Code__c != null) {
        row.ACEF_Role_Code__c = row.ACEF_Role_Code__c.trim();
      }
      row.ACEF_Unique_Key__c = buildKey(
        row.ACEF_Role_Code__c,
        row.ACEF_Dept_Agency__c
      );
    }
    Set<String> keys = collectKeys(rows);
    Map<String, Id> existing = new Map<String, Id>();
    for (ACEF_Role_Agency_Mapping__c match : INTEGRITY.roleAgencyByKey(keys)) {
      existing.put(match.ACEF_Unique_Key__c.toUpperCase(), match.Id);
    }
    rejectDuplicates(
      rows,
      existing,
      'This Role Code is already mapped to this Dept/Agency.'
    );
  }

  /**
   * Blocks deletes and role-code changes that would leave System / Role Mapping
   * rows pointing at a code that no longer exists in Role / Agency Mapping.
   * @param oldRows Trigger.old
   * @param newMap  Trigger.newMap for updates; null for deletes
   */
  public static void guardRoleAgencyRemoval(
    List<ACEF_Role_Agency_Mapping__c> oldRows,
    Map<Id, ACEF_Role_Agency_Mapping__c> newMap
  ) {
    Map<String, List<SObject>> leavingByCode = new Map<String, List<SObject>>();
    Set<String> arrivingCodes = new Set<String>();
    for (ACEF_Role_Agency_Mapping__c oldRow : oldRows) {
      String oldCode = normalizeCode(oldRow.ACEF_Role_Code__c);
      if (String.isBlank(oldCode)) {
        continue;
      }
      SObject errorTarget = oldRow;
      if (newMap != null) {
        ACEF_Role_Agency_Mapping__c newRow = newMap.get(oldRow.Id);
        String newCode = normalizeCode(newRow.ACEF_Role_Code__c);
        arrivingCodes.add(newCode);
        if (oldCode == newCode) {
          continue;
        }
        errorTarget = newRow;
      }
      if (!leavingByCode.containsKey(oldCode)) {
        leavingByCode.put(oldCode, new List<SObject>());
      }
      leavingByCode.get(oldCode).add(errorTarget);
    }
    if (leavingByCode.isEmpty()) {
      return;
    }

    Set<Id> changingIds = new Set<Id>();
    for (ACEF_Role_Agency_Mapping__c oldRow : oldRows) {
      changingIds.add(oldRow.Id);
    }
    Set<String> stillPresent = new Set<String>(arrivingCodes);
    for (
      ACEF_Role_Agency_Mapping__c other : INTEGRITY.roleAgencyByCode(
        leavingByCode.keySet(),
        changingIds
      )
    ) {
      stillPresent.add(normalizeCode(other.ACEF_Role_Code__c));
    }
    Set<String> referenced = new Set<String>();
    for (
      ACEF_System_Role_Mapping__c ref : INTEGRITY.systemRoleByCode(
        leavingByCode.keySet()
      )
    ) {
      referenced.add(normalizeCode(ref.ACEF_Role_Code__c));
    }

    for (String code : leavingByCode.keySet()) {
      if (referenced.contains(code) && !stillPresent.contains(code)) {
        for (SObject target : leavingByCode.get(code)) {
          target.addError(
            'Role Code ' +
              code +
              ' is used in System / Role Mapping. ' +
              'Deactivate this mapping instead of deleting it or changing its Role Code.'
          );
        }
      }
    }
  }

  // ---------------------------------------------------------------- System / Role Mapping

  public static void beforeSaveSystemRole(
    List<ACEF_System_Role_Mapping__c> rows
  ) {
    Set<String> codes = new Set<String>();
    for (ACEF_System_Role_Mapping__c row : rows) {
      if (row.ACEF_Role_Code__c != null) {
        row.ACEF_Role_Code__c = row.ACEF_Role_Code__c.trim();
        codes.add(row.ACEF_Role_Code__c);
      }
      row.ACEF_Unique_Key__c = buildKey(
        row.ACEF_Role_Code__c,
        row.ACEF_System__c
      );
    }

    Set<String> knownCodes = new Set<String>();
    for (
      ACEF_Role_Agency_Mapping__c known : INTEGRITY.roleAgencyByCode(
        codes,
        new Set<Id>()
      )
    ) {
      knownCodes.add(normalizeCode(known.ACEF_Role_Code__c));
    }
    for (ACEF_System_Role_Mapping__c row : rows) {
      String code = normalizeCode(row.ACEF_Role_Code__c);
      if (String.isNotBlank(code) && !knownCodes.contains(code)) {
        row.ACEF_Role_Code__c.addError(
          'Role Code ' +
            row.ACEF_Role_Code__c +
            ' does not exist in Role / Agency Mapping. Add it there first.'
        );
      }
    }

    Set<String> keys = collectKeys(rows);
    Map<String, Id> existing = new Map<String, Id>();
    for (ACEF_System_Role_Mapping__c match : INTEGRITY.systemRoleByKey(keys)) {
      existing.put(match.ACEF_Unique_Key__c.toUpperCase(), match.Id);
    }
    rejectDuplicates(
      rows,
      existing,
      'This Role Code is already mapped to this System.'
    );
  }

  // ---------------------------------------------------------------- shared helpers

  private static Set<String> collectKeys(List<SObject> rows) {
    Set<String> keys = new Set<String>();
    for (SObject row : rows) {
      String key = (String) row.get('ACEF_Unique_Key__c');
      if (key != null) {
        keys.add(key);
      }
    }
    return keys;
  }

  /** Friendly duplicate errors, before the unique index raises DUPLICATE_VALUE. */
  private static void rejectDuplicates(
    List<SObject> rows,
    Map<String, Id> existingByKey,
    String message
  ) {
    Map<String, Id> seenInBatch = new Map<String, Id>();
    for (SObject row : rows) {
      String key = (String) row.get('ACEF_Unique_Key__c');
      if (key == null) {
        continue;
      }
      String upperKey = key.toUpperCase();
      Id existingId = existingByKey.get(upperKey);
      if (existingId != null && existingId != row.Id) {
        row.addError(message);
      } else if (seenInBatch.containsKey(upperKey)) {
        row.addError(message + ' (duplicated within this save)');
      } else {
        seenInBatch.put(upperKey, row.Id);
      }
    }
  }

  private static final Integrity INTEGRITY = new Integrity();

  /**
   * Integrity checks must see every mapping row, not only those the editing
   * user can see, so these reads run without sharing. They return only ids,
   * codes and keys, used for validation messages.
   */
  private without sharing class Integrity {
    public List<ACEF_Role_Agency_Mapping__c> roleAgencyByKey(Set<String> keys) {
      if (keys.isEmpty()) {
        return new List<ACEF_Role_Agency_Mapping__c>();
      }
      return [
        SELECT Id, ACEF_Unique_Key__c
        FROM ACEF_Role_Agency_Mapping__c
        WHERE ACEF_Unique_Key__c IN :keys
      ];
    }

    public List<ACEF_Role_Agency_Mapping__c> roleAgencyByCode(
      Set<String> codes,
      Set<Id> excludeIds
    ) {
      if (codes.isEmpty()) {
        return new List<ACEF_Role_Agency_Mapping__c>();
      }
      return [
        SELECT Id, ACEF_Role_Code__c
        FROM ACEF_Role_Agency_Mapping__c
        WHERE ACEF_Role_Code__c IN :codes AND Id NOT IN :excludeIds
      ];
    }

    public List<ACEF_System_Role_Mapping__c> systemRoleByKey(Set<String> keys) {
      if (keys.isEmpty()) {
        return new List<ACEF_System_Role_Mapping__c>();
      }
      return [
        SELECT Id, ACEF_Unique_Key__c
        FROM ACEF_System_Role_Mapping__c
        WHERE ACEF_Unique_Key__c IN :keys
      ];
    }

    public List<ACEF_System_Role_Mapping__c> systemRoleByCode(
      Set<String> codes
    ) {
      if (codes.isEmpty()) {
        return new List<ACEF_System_Role_Mapping__c>();
      }
      return [
        SELECT Id, ACEF_Role_Code__c
        FROM ACEF_System_Role_Mapping__c
        WHERE ACEF_Role_Code__c IN :codes
      ];
    }
  }
}