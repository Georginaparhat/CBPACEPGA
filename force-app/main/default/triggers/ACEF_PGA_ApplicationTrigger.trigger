trigger ACEF_PGA_ApplicationTrigger on ACEF_PGA_Application__c (after insert, after update) {
    Set<Id> packageIds = new Set<Id>();
    for (ACEF_PGA_Application__c row : Trigger.new) {
        if (Trigger.isInsert) {
            if (row.ACEF_Form_7300_Request__c != null) {
                packageIds.add(row.Id);
            }
        } else {
            ACEF_PGA_Application__c prior = Trigger.oldMap.get(row.Id);
            if (row.ACEF_Form_7300_Request__c != prior.ACEF_Form_7300_Request__c) {
                packageIds.add(row.Id);
            }
        }
    }
    if (!packageIds.isEmpty()) {
        ACEF_7300PackageMirrorService.syncForPackageIds(packageIds);
    }
    // CBPPGA-88: Draft moves to Pending BI Review once the full package is in.
    ACEF_PackageLifecycleService.autoSubmit(Trigger.new);
}