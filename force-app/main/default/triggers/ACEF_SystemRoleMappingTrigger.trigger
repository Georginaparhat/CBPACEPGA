trigger ACEF_SystemRoleMappingTrigger on ACEF_System_Role_Mapping__c(
  before insert,
  before update
) {
  ACEF_RoleMappingTriggerHandler.beforeSaveSystemRole(Trigger.new);
}