trigger ACEF_RoleAgencyMappingTrigger on ACEF_Role_Agency_Mapping__c(
  before insert,
  before update,
  before delete
) {
  if (Trigger.isDelete) {
    ACEF_RoleMappingTriggerHandler.guardRoleAgencyRemoval(Trigger.old, null);
    return;
  }
  ACEF_RoleMappingTriggerHandler.beforeSaveRoleAgency(Trigger.new);
  if (Trigger.isUpdate) {
    ACEF_RoleMappingTriggerHandler.guardRoleAgencyRemoval(
      Trigger.old,
      Trigger.newMap
    );
  }
}