public with sharing class ACEF_ProvisioningOrchestration {
    public static void afterPgaApplicationUpdate(List<ACEF_PGA_Application__c> records, Map<Id, ACEF_PGA_Application__c> oldMap) {
        Set<Id> packageIds = new Set<Id>();
        for (ACEF_PGA_Application__c row : records) {
            packageIds.add(row.Id);
        }
        Map<Id, ACEF_PGA_Application__c> enriched = loadPackages(packageIds);

        List<ACEF_PGA_Application__c> flagUpdates = new List<ACEF_PGA_Application__c>();
        List<ACEF_PGA_Application__c> statusUpdates = new List<ACEF_PGA_Application__c>();

        for (ACEF_PGA_Application__c row : records) {
            ACEF_PGA_Application__c pkg = enriched.get(row.Id);
            if (pkg == null) {
                continue;
            }
            Boolean ready = ACEF_ProvisioningGateService.computeReadyForReadiness(pkg);
            Boolean packageComplete = ACEF_ProvisioningGateService.computePackageComplete(pkg);
            if (row.ACEF_Ready_For_Readiness__c != ready) {
                flagUpdates.add(new ACEF_PGA_Application__c(Id = row.Id, ACEF_Ready_For_Readiness__c = ready));
            }
            ACEF_PGA_Application__c prior = oldMap.get(row.Id);
            if (packageComplete && prior.ACEF_Package_Status__c != 'Package Complete' && !isPostPackageStatus(row.ACEF_Package_Status__c)) {
                statusUpdates.add(new ACEF_PGA_Application__c(Id = row.Id, ACEF_Package_Status__c = 'Package Complete'));
            }
            if (row.ACEF_Package_Status__c == 'Provisioning' && prior.ACEF_Package_Status__c != 'Provisioning') {
                maybeNotifyAts(row);
            }
        }

        if (!flagUpdates.isEmpty()) {
            update flagUpdates;
        }
        if (!statusUpdates.isEmpty()) {
            update statusUpdates;
        }
    }

    public static void after7300Update(List<ACEF_Form_7300_Request__c> records, Map<Id, ACEF_Form_7300_Request__c> oldMap) {
        Set<Id> packageIds = new Set<Id>();
        Set<Id> favorablePackageIds = new Set<Id>();
        for (ACEF_Form_7300_Request__c row : records) {
            ACEF_Form_7300_Request__c prior = oldMap.get(row.Id);
            if (row.ACEF_BI_Disposition__c != prior.ACEF_BI_Disposition__c) {
                if (row.ACEF_PGA_Application__c != null) {
                    packageIds.add(row.ACEF_PGA_Application__c);
                    if (row.ACEF_BI_Disposition__c == 'Favorable') {
                        favorablePackageIds.add(row.ACEF_PGA_Application__c);
                    }
                }
                if (row.ACEF_BI_Disposition__c == 'Unfavorable') {
                    handleUnfavorableBi(row);
                }
            }
        }
        if (packageIds.isEmpty()) {
            return;
        }
        Map<Id, ACEF_PGA_Application__c> packages = loadPackages(packageIds);
        List<ACEF_PGA_Application__c> updates = new List<ACEF_PGA_Application__c>();
        for (Id packageId : packageIds) {
            ACEF_PGA_Application__c pkg = packages.get(packageId);
            if (pkg == null) {
                continue;
            }
            Boolean ready = ACEF_ProvisioningGateService.computeReadyForReadiness(pkg);
            ACEF_PGA_Application__c change = new ACEF_PGA_Application__c(Id = packageId, ACEF_Ready_For_Readiness__c = ready);
            // CBPPGA-88: BI adjudication Favorable moves Pending BI Review to Ready for Provisioning.
            if (
                favorablePackageIds.contains(packageId) &&
                ACEF_PackageLifecycleService.statusOf(pkg) == ACEF_PackageLifecycleService.STATUS_PENDING_BI
            ) {
                change.ACEF_Status__c = ACEF_PackageLifecycleService.STATUS_READY;
            }
            updates.add(change);
        }
        if (!updates.isEmpty()) {
            update updates;
        }
    }

    public static void applyBiDisposition(Id request7300Id, String disposition, String notes) {
        if (disposition != 'Favorable' && disposition != 'Unfavorable') {
            throw new AuraHandledException('Disposition must be Favorable or Unfavorable.');
        }
        ACEF_Form_7300_Request__c req = [
            SELECT
                Id,
                ACEF_PGA_Application__c,
                ACEF_BI_Disposition__c,
                ACEF_Status__c,
                ACEF_Current_Section__c,
                ACEF_Next_CBP_Supervisor_Email__c,
                ACEF_Sec2_Decision__c,
                ACEF_Sec3_Decision__c
            FROM ACEF_Form_7300_Request__c
            WHERE Id = :request7300Id
            LIMIT 1
        ];
        if (!ACEF_Form7300ProgressService.isReadyForBiDisposition(req)) {
            throw new AuraHandledException(
                'Background investigation disposition requires a fully completed Form 7300 (sections 1 through 4).'
            );
        }
        req.ACEF_BI_Disposition__c = disposition;
        req.ACEF_BI_Disposition_Date__c = Date.today();
        req.ACEF_BI_Notes__c = notes;
        if (disposition == 'Favorable') {
            req.ACEF_Status__c = 'OIT BI Review';
        } else {
            req.ACEF_Status__c = 'Closed Unfavorable';
        }
        update req;
    }

    public static void applyReadinessDecision(Id packageId, String decision, String notes) {
        ACEF_PGA_Application__c pkg = ACEF_ProvisioningGateService.loadPackage(packageId);
        if (!ACEF_ProvisioningGateService.computeReadyForReadiness(pkg)) {
            throw new AuraHandledException('Package is not ready for readiness vetting.');
        }
        String normalized = decision == null ? '' : decision.trim();
        if (normalized != 'Approve' && normalized != 'Reject' && normalized != 'Hold') {
            throw new AuraHandledException('Decision must be Approve, Reject, or Hold.');
        }
        ACEF_PGA_Application__c updateRow = new ACEF_PGA_Application__c(
            Id = packageId,
            ACEF_Readiness_Notes__c = notes
        );
        if (normalized == 'Approve') {
            updateRow.ACEF_Readiness_Status__c = 'Approved';
            updateRow.ACEF_Readiness_Approved_Date__c = Date.today();
            updateRow.ACEF_Readiness_Approved_By__c = UserInfo.getName();
            updateRow.ACEF_Package_Status__c = 'Readiness Review';
        } else if (normalized == 'Reject') {
            updateRow.ACEF_Readiness_Status__c = 'Rejected';
            updateRow.ACEF_Package_Status__c = 'Closed';
        } else {
            updateRow.ACEF_Readiness_Status__c = 'On Hold';
        }
        update updateRow;
    }

    public static void routeForProvisioning(Id packageId, String accessArea) {
        ACEF_PGA_Application__c pkg = ACEF_ProvisioningGateService.loadPackage(packageId);
        ACEF_ProvisioningGateService.GateResult gates = ACEF_ProvisioningGateService.buildResult(pkg);
        if (!gates.canRouteProvisioning) {
            throw new AuraHandledException('Routing gates are not satisfied (readiness, forms 002/003, access area).');
        }
        String area = String.isNotBlank(accessArea) ? accessArea : pkg.ACEF_Access_Area__c;
        ACEF_HashIdService.generateForPackage(packageId);
        update new ACEF_PGA_Application__c(
            Id = packageId,
            ACEF_Access_Area__c = area,
            ACEF_Provisioning_Status__c = 'Requested',
            ACEF_Package_Status__c = 'Provisioning'
        );
    }

    public static void markProvisioningComplete(Id packageId, String notes) {
        ACEF_PGA_Application__c pkg = ACEF_ProvisioningGateService.loadPackage(packageId);
        if (pkg.ACEF_Readiness_Status__c != 'Approved') {
            throw new AuraHandledException('Readiness must be approved before provisioning completion.');
        }
        update new ACEF_PGA_Application__c(
            Id = packageId,
            ACEF_Provisioning_Status__c = 'Complete',
            ACEF_Provisioning_Complete_Date__c = System.now(),
            ACEF_Provisioning_Complete_By__c = UserInfo.getName()
        );
    }

    public static void verifyAceSecurity(Id packageId, String notes) {
        ACEF_PGA_Application__c pkg = ACEF_ProvisioningGateService.loadPackage(packageId);
        // CBPPGA-88: Complete Security Review is available in ACE Security Review only.
        String lifecycle = [SELECT ACEF_Status__c FROM ACEF_PGA_Application__c WHERE Id = :packageId].ACEF_Status__c;
        if (lifecycle != ACEF_PackageLifecycleService.STATUS_ACE_SECURITY) {
            throw new AuraHandledException(
                'Complete Security Review is available when the status is ACE Security Review. Status: ' +
                (String.isBlank(lifecycle) ? ACEF_PackageLifecycleService.STATUS_DRAFT : lifecycle) + '.'
            );
        }
        if (pkg.ACEF_Provisioning_Status__c != 'Complete') {
            throw new AuraHandledException('Provisioning must be complete before ACE Security verification.');
        }
        update new ACEF_PGA_Application__c(
            Id = packageId,
            ACEF_ACE_Security_Verified__c = true,
            ACEF_ACE_Security_Verified_Date__c = Date.today(),
            ACEF_ACE_Security_Verified_By__c = UserInfo.getName(),
            ACEF_Status__c = ACEF_PackageLifecycleService.STATUS_COMPLETE,
            ACEF_Package_Status__c = 'Closed',
            ACEF_Readiness_Notes__c = mergeNotes(pkg.ACEF_Readiness_Notes__c, notes)
        );
        if (pkg.ACEF_Form_7300_Request__c != null) {
            update new ACEF_Form_7300_Request__c(
                Id = pkg.ACEF_Form_7300_Request__c,
                ACEF_Status__c = 'Closed Favorable'
            );
        }
    }

    public static void syncPackageFlags(List<Id> packageIds) {
        if (packageIds == null || packageIds.isEmpty()) {
            return;
        }
        Map<Id, ACEF_PGA_Application__c> packages = loadPackages(new Set<Id>(packageIds));
        List<ACEF_PGA_Application__c> updates = new List<ACEF_PGA_Application__c>();
        for (Id packageId : packageIds) {
            ACEF_PGA_Application__c pkg = packages.get(packageId);
            if (pkg == null) {
                continue;
            }
            updates.add(
                new ACEF_PGA_Application__c(
                    Id = packageId,
                    ACEF_Ready_For_Readiness__c = ACEF_ProvisioningGateService.computeReadyForReadiness(pkg)
                )
            );
        }
        if (!updates.isEmpty()) {
            update updates;
        }
    }

    private static void handleUnfavorableBi(ACEF_Form_7300_Request__c row) {
        if (row.ACEF_PGA_Application__c == null) {
            return;
        }
        update new ACEF_PGA_Application__c(
            Id = row.ACEF_PGA_Application__c,
            ACEF_Readiness_Status__c = 'Rejected',
            ACEF_Status__c = ACEF_PackageLifecycleService.STATUS_UNFAVORABLE,
            ACEF_Package_Status__c = 'Closed',
            ACEF_Ready_For_Readiness__c = false,
            ACEF_Provisioning_Status__c = 'Not Started'
        );
    }

    private static void maybeNotifyAts(ACEF_PGA_Application__c row) {
        String roles = row.ACEF_Roles_Requested__c;
        if (String.isBlank(roles)) {
            return;
        }
        String lower = roles.toLowerCase();
        if (lower.contains('manifest') || lower.contains('aes') || lower.contains('quota')) {
            update new ACEF_PGA_Application__c(Id = row.Id, ACEF_ATS_Notified__c = true);
        }
    }

    private static Map<Id, ACEF_PGA_Application__c> loadPackages(Set<Id> packageIds) {
        Map<Id, ACEF_PGA_Application__c> out = new Map<Id, ACEF_PGA_Application__c>(
            [
                SELECT
                    Id,
                    ACEF_Status__c,
                    ACEF_Package_Status__c,
                    ACEF_Form001_User_Complete__c,
                    ACEF_Form001_Supervisor_Complete__c,
                    ACEF_Form002_Complete__c,
                    ACEF_NDA_Uploaded__c,
                    ACEF_Access_Area__c,
                    ACEF_Readiness_Status__c,
                    ACEF_Provisioning_Status__c,
                    ACEF_ACE_Security_Verified__c,
                    ACEF_Roles_Requested__c,
                    ACEF_Ready_For_Readiness__c,
                    ACEF_Form_7300_Request__c,
                    ACEF_Linked_7300_Name__c,
                    ACEF_Linked_7300_BI_Disposition__c,
                    ACEF_7300_Clearance_Ready__c,
                    ACEF_Form_7300_Request__r.Name,
                    ACEF_Form_7300_Request__r.ACEF_Status__c,
                    ACEF_Form_7300_Request__r.ACEF_BI_Disposition__c
                FROM ACEF_PGA_Application__c
                WHERE Id IN :packageIds
            ]
        );
        return out;
    }

    private static Boolean isPostPackageStatus(String status) {
        return status == 'Package Complete' ||
            status == 'Readiness Review' ||
            status == 'Provisioning' ||
            status == 'Closed';
    }

    private static String mergeNotes(String existing, String added) {
        if (String.isBlank(added)) {
            return existing;
        }
        if (String.isBlank(existing)) {
            return added;
        }
        return existing + '\n' + added;
    }
}