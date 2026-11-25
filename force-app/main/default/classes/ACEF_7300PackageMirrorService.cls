public without sharing class ACEF_7300PackageMirrorService {
    public static final Set<String> STATUSES_SECTION4_READY = new Set<String>{
        'Section 4 Complete',
        // CBPPGA-88: past Security / PSO and waiting on the BI determination (7300 Pending BI Determination).
        'With 7300 Processing',
        'OIT BI Review',
        'Closed Favorable',
        'Closed Unfavorable',
        'Closed'
    };

    public static void syncForRequestIds(Set<Id> request7300Ids) {
        if (request7300Ids == null || request7300Ids.isEmpty()) {
            return;
        }
        Map<Id, ACEF_Form_7300_Request__c> requests = new Map<Id, ACEF_Form_7300_Request__c>(
            [
                SELECT Id, Name, ACEF_Status__c, ACEF_BI_Disposition__c, ACEF_PGA_Application__c
                FROM ACEF_Form_7300_Request__c
                WHERE Id IN :request7300Ids
            ]
        );
        List<ACEF_PGA_Application__c> packages = [
            SELECT Id, ACEF_Form_7300_Request__c
            FROM ACEF_PGA_Application__c
            WHERE ACEF_Form_7300_Request__c IN :request7300Ids
        ];
        if (packages.isEmpty()) {
            return;
        }
        List<ACEF_PGA_Application__c> updates = new List<ACEF_PGA_Application__c>();
        for (ACEF_PGA_Application__c pkg : packages) {
            ACEF_Form_7300_Request__c req = requests.get(pkg.ACEF_Form_7300_Request__c);
            if (req != null) {
                updates.add(buildMirrorUpdate(pkg.Id, req));
            }
        }
        if (!updates.isEmpty()) {
            update updates;
        }
    }

    public static void syncForPackageIds(Set<Id> packageIds) {
        if (packageIds == null || packageIds.isEmpty()) {
            return;
        }
        List<ACEF_PGA_Application__c> packages = [
            SELECT Id, ACEF_Form_7300_Request__c
            FROM ACEF_PGA_Application__c
            WHERE Id IN :packageIds
        ];
        Set<Id> requestIds = new Set<Id>();
        for (ACEF_PGA_Application__c pkg : packages) {
            if (pkg.ACEF_Form_7300_Request__c != null) {
                requestIds.add(pkg.ACEF_Form_7300_Request__c);
            } else {
                clearMirror(pkg.Id);
            }
        }
        if (!requestIds.isEmpty()) {
            syncForRequestIds(requestIds);
        }
    }

    public static void clearMirror(Id packageId) {
        update new ACEF_PGA_Application__c(
            Id = packageId,
            ACEF_Linked_7300_Name__c = null,
            ACEF_Linked_7300_BI_Disposition__c = null,
            ACEF_7300_Clearance_Ready__c = false
        );
    }

    private static ACEF_PGA_Application__c buildMirrorUpdate(Id packageId, ACEF_Form_7300_Request__c req) {
        return new ACEF_PGA_Application__c(
            Id = packageId,
            ACEF_Linked_7300_Name__c = req.Name,
            ACEF_Linked_7300_BI_Disposition__c = req.ACEF_BI_Disposition__c,
            ACEF_7300_Clearance_Ready__c = STATUSES_SECTION4_READY.contains(req.ACEF_Status__c)
        );
    }

    public static Boolean userCanView7300Details() {
        return FeatureManagement.checkPermission('ACEF_View_Form_7300_Details');
    }
}