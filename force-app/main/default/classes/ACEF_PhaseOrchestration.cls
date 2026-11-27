public with sharing class ACEF_PhaseOrchestration {
  public class SignerContext {
    @AuraEnabled
    public Boolean allowed = false;
    @AuraEnabled
    public Id packageId;
    @AuraEnabled
    public Boolean show7300Section2 = false;
    @AuraEnabled
    public Boolean showForm001Supervisor = false;
    @AuraEnabled
    public Boolean show7300Section3 = false;
    @AuraEnabled
    public Boolean show7300Section4 = false;
  }

  @AuraEnabled
  public static SignerContext validateSignerContext(String role, Id request7300Id, Id packageId) {
    SignerContext context = new SignerContext();
    context.packageId = packageId;
    context.allowed = request7300Id != null && String.isNotBlank(role);
    context.show7300Section2 = role == 'supervisor';
    context.showForm001Supervisor = role == 'supervisor';
    context.show7300Section3 = role == 'cbpSupervisor';
    context.show7300Section4 = role == 'security';
    return context;
  }
}
