public with sharing class ACEF_ProvisioningUiActions {
    @AuraEnabled
    public static void recordBiDisposition(Id request7300Id, String disposition, String notes) {
        // CBPPGA-88: with ACE Portal access, BI adjudication happens in Pending BI Review.
        ACEF_PackageLifecycleService.assertReadyForBi(request7300Id);
        ACEF_ProvisioningOrchestration.applyBiDisposition(request7300Id, disposition, notes);
    }

    @AuraEnabled
    public static void applyReadinessDecision(Id packageId, String decision, String notes) {
        ACEF_ProvisioningOrchestration.applyReadinessDecision(packageId, decision, notes);
    }

    @AuraEnabled
    public static void routeForProvisioning(Id packageId, String accessArea) {
        ACEF_ProvisioningOrchestration.routeForProvisioning(packageId, accessArea);
    }

    @AuraEnabled
    public static void markProvisioningComplete(Id packageId, String notes) {
        ACEF_ProvisioningOrchestration.markProvisioningComplete(packageId, notes);
    }

    @AuraEnabled
    public static void verifyAceSecurity(Id packageId, String notes) {
        ACEF_ProvisioningOrchestration.verifyAceSecurity(packageId, notes);
    }
}