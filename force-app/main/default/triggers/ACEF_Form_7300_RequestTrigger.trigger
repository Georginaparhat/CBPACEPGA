trigger ACEF_Form_7300_RequestTrigger on ACEF_Form_7300_Request__c (before insert, before update, after insert, after update) {
    if (Trigger.isBefore) {
        for (ACEF_Form_7300_Request__c row : Trigger.new) {
            if (row.ACEF_Status__c == 'Section 1 Complete') {
                row.ACEF_Status__c = 'Section 2 Pending';
            } else if (row.ACEF_Status__c == 'Section 2 Complete') {
                row.ACEF_Status__c = String.isNotBlank(row.ACEF_Next_CBP_Supervisor_Email__c)
                    ? 'Section 3 Pending'
                    : 'Section 4 Pending';
            } else if (row.ACEF_Status__c == 'Section 3 Complete') {
                row.ACEF_Status__c = 'Section 4 Pending';
            } else if (row.ACEF_Status__c == 'Section 4 Complete') {
                row.ACEF_Status__c = 'With 7300 Processing';
            }
        }
        return;
    }

    Set<Id> requestIds = new Set<Id>();
    for (ACEF_Form_7300_Request__c row : Trigger.new) {
        if (row.ACEF_PGA_Application__c != null) {
            requestIds.add(row.Id);
        }
    }
    if (!requestIds.isEmpty()) {
        ACEF_7300PackageMirrorService.syncForRequestIds(requestIds);
    }
    if (Trigger.isUpdate) {
        ACEF_ProvisioningOrchestration.after7300Update(Trigger.new, Trigger.oldMap);
    }
}
