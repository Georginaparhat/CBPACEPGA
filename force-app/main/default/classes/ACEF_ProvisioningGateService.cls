public with sharing class ACEF_ProvisioningGateService {
    public class GateLine {
        @AuraEnabled
        public String key;
        @AuraEnabled
        public String groupKey;
        @AuraEnabled
        public String label;
        @AuraEnabled
        public Boolean passed;
        @AuraEnabled
        public String detail;
        /** met | pending | open | failed — for provisioning readiness UI */
        @AuraEnabled
        public String uiStatus;
    }

    private static final String TITLE_ACCESS_APPLICATION = 'PGA User Application Form for ACE Portal Access';
    private static final String TITLE_RULES = 'Rules of Behavior for PGA Users of ACE';
    private static final String TITLE_NDA = 'DHS Non-Disclosure Agreement';
    private static final String TITLE_7300 = 'CBP Form 7300';

    public class GateResult {
        @AuraEnabled
        public Boolean packageComplete;
        @AuraEnabled
        public Boolean biFavorable;
        @AuraEnabled
        public Boolean readyForReadiness;
        @AuraEnabled
        public Boolean canRouteProvisioning;
        @AuraEnabled
        public Boolean canMarkProvisioningComplete;
        @AuraEnabled
        public Boolean canVerifyAceSecurity;
        @AuraEnabled
        public List<GateLine> lines;
        @AuraEnabled
        public String linked7300Name;
        @AuraEnabled
        public String linked7300BiDisposition;
        @AuraEnabled
        public Boolean canView7300Details;
    }

    public class EvaluateRequest {
        @InvocableVariable(label='PGA Application Id' required=true)
        public Id packageId;
    }

    public class EvaluateResponse {
        @InvocableVariable
        public Boolean readyForReadiness;
        @InvocableVariable
        public Boolean packageComplete;
        @InvocableVariable
        public Boolean biFavorable;
        @InvocableVariable
        public String summaryMessage;
    }

    @AuraEnabled(cacheable=true)
    public static GateResult evaluateForUi(Id packageId) {
        ACEF_PGA_Application__c pkg = loadPackage(packageId);
        return buildResult(pkg);
    }

    @InvocableMethod(label='Evaluate provisioning gates' description='Returns readiness gate flags for a PGA package')
    public static List<EvaluateResponse> evaluateInvocable(List<EvaluateRequest> requests) {
        List<EvaluateResponse> out = new List<EvaluateResponse>();
        for (EvaluateRequest req : requests) {
            ACEF_PGA_Application__c pkg = loadPackage(req.packageId);
            GateResult gates = buildResult(pkg);
            EvaluateResponse row = new EvaluateResponse();
            row.readyForReadiness = gates.readyForReadiness;
            row.packageComplete = gates.packageComplete;
            row.biFavorable = gates.biFavorable;
            row.summaryMessage = gates.readyForReadiness
                ? 'All readiness gates passed.'
                : 'One or more readiness gates have not passed.';
            out.add(row);
        }
        return out;
    }

    public static GateResult buildResult(ACEF_PGA_Application__c pkg) {
        GateResult result = new GateResult();
        result.lines = new List<GateLine>();
        Boolean show7300Details = ACEF_7300PackageMirrorService.userCanView7300Details();
        result.canView7300Details = show7300Details;

        Boolean form001User = pkg.ACEF_Form001_User_Complete__c == true;
        Boolean form001Supervisor = pkg.ACEF_Form001_Supervisor_Complete__c == true;
        Boolean form002 = pkg.ACEF_Form002_Complete__c == true;
        Boolean form003 = pkg.ACEF_NDA_Uploaded__c == true;
        Boolean nda = form003;

        Boolean linked7300 =
            pkg.ACEF_Form_7300_Request__c != null || String.isNotBlank(pkg.ACEF_Linked_7300_Name__c);
        String linkedName = pkg.ACEF_Linked_7300_Name__c;
        String biDisposition = pkg.ACEF_Linked_7300_BI_Disposition__c;
        Boolean section4 = pkg.ACEF_7300_Clearance_Ready__c == true;
        Boolean biFavorable = linked7300 && biDisposition == 'Favorable';

        if (show7300Details && pkg.ACEF_Form_7300_Request__r != null) {
            if (String.isBlank(linkedName)) {
                linkedName = pkg.ACEF_Form_7300_Request__r.Name;
            }
            if (String.isBlank(biDisposition)) {
                biDisposition = pkg.ACEF_Form_7300_Request__r.ACEF_BI_Disposition__c;
            }
            section4 =
                ACEF_7300PackageMirrorService.STATUSES_SECTION4_READY.contains(
                    pkg.ACEF_Form_7300_Request__r.ACEF_Status__c
                );
            biFavorable = linked7300 && biDisposition == 'Favorable';
        }

        result.linked7300Name = linkedName;
        result.linked7300BiDisposition = biDisposition;

        result.packageComplete = form001User && form001Supervisor && form002 && nda && linked7300 && section4;
        result.biFavorable = biFavorable;
        result.readyForReadiness = result.packageComplete && biFavorable;

        Boolean readinessApproved = pkg.ACEF_Readiness_Status__c == 'Approved';
        Boolean formsForRoute = form002 && form003;
        Boolean accessAreaSet = String.isNotBlank(pkg.ACEF_Access_Area__c);
        result.canRouteProvisioning = result.readyForReadiness && readinessApproved && formsForRoute && accessAreaSet;

        Boolean provisioningComplete = pkg.ACEF_Provisioning_Status__c == 'Complete';
        result.canMarkProvisioningComplete = readinessApproved && !provisioningComplete;
        result.canVerifyAceSecurity = provisioningComplete && pkg.ACEF_ACE_Security_Verified__c != true;

        addGate(
            result.lines,
            'form001_user',
            'package',
            'Access application signed by user',
            form001User,
            TITLE_ACCESS_APPLICATION,
            form001User ? 'met' : 'open'
        );
        addGate(
            result.lines,
            'form001_supervisor',
            'package',
            'Access application signed by supervisor',
            form001Supervisor,
            TITLE_ACCESS_APPLICATION,
            form001Supervisor ? 'met' : 'open'
        );
        addGate(
            result.lines,
            'form002',
            'package',
            'Rules of Behavior complete',
            form002,
            TITLE_RULES,
            form002 ? 'met' : 'open'
        );
        addGate(
            result.lines,
            'form003_nda',
            'package',
            'Witnessed NDA uploaded',
            form003,
            TITLE_NDA,
            form003 ? 'met' : 'open'
        );
        addGate(
            result.lines,
            '7300_link',
            'clearance',
            TITLE_7300 + ' request linked',
            linked7300,
            linked7300 ? linkedName : 'Link a CBP Form 7300 request',
            linked7300 ? 'met' : 'open'
        );
        if (show7300Details && pkg.ACEF_Form_7300_Request__r != null) {
            addGate(
                result.lines,
                '7300_section4',
                'clearance',
                TITLE_7300 + ' section 4 ready',
                section4,
                'Status: ' + pkg.ACEF_Form_7300_Request__r.ACEF_Status__c,
                section4 ? 'met' : 'open'
            );
        }
        String biDetail = linked7300 ? 'Disposition: ' + String.valueOf(biDisposition) : null;
        String biUi = biUiStatus(linked7300, biDisposition, biFavorable);
        addGate(
            result.lines,
            'bi_favorable',
            'clearance',
            'Background investigation favorable',
            biFavorable,
            biDetail,
            biUi
        );
        addGate(
            result.lines,
            'readiness_approved',
            'provisioning',
            'Readiness approved',
            readinessApproved,
            pkg.ACEF_Readiness_Status__c,
            readinessApproved ? 'met' : 'open'
        );
        addGate(
            result.lines,
            'provisioning_complete',
            'provisioning',
            'Provisioning complete',
            provisioningComplete,
            pkg.ACEF_Provisioning_Status__c,
            provisioningComplete ? 'met' : 'open'
        );
        addGate(
            result.lines,
            'ace_security',
            'provisioning',
            'ACE Security verified',
            pkg.ACEF_ACE_Security_Verified__c == true,
            null,
            pkg.ACEF_ACE_Security_Verified__c == true ? 'met' : 'open'
        );

        return result;
    }

    public static Boolean computeReadyForReadiness(ACEF_PGA_Application__c pkg) {
        return buildResult(pkg).readyForReadiness;
    }

    public static Boolean computePackageComplete(ACEF_PGA_Application__c pkg) {
        return buildResult(pkg).packageComplete;
    }

    public static ACEF_PGA_Application__c loadPackage(Id packageId) {
        String soql =
            'SELECT Id, Name, ACEF_Package_Status__c, ACEF_Form001_User_Complete__c, ' +
            'ACEF_Form001_Supervisor_Complete__c, ACEF_Form002_Complete__c, ACEF_NDA_Uploaded__c, ' +
            'ACEF_Access_Area__c, ACEF_Hash_Id__c, ACEF_Ready_For_Readiness__c, ACEF_Readiness_Status__c, ' +
            'ACEF_Provisioning_Status__c, ACEF_ACE_Security_Verified__c, ACEF_Roles_Requested__c, ' +
            'ACEF_Form_7300_Request__c, ACEF_Linked_7300_Name__c, ACEF_Linked_7300_BI_Disposition__c, ' +
            'ACEF_7300_Clearance_Ready__c, ACEF_Readiness_Notes__c';
        if (ACEF_7300PackageMirrorService.userCanView7300Details()) {
            soql +=
                ', ACEF_Form_7300_Request__r.Name, ACEF_Form_7300_Request__r.ACEF_Status__c, ' +
                'ACEF_Form_7300_Request__r.ACEF_BI_Disposition__c';
        }
        soql += ' FROM ACEF_PGA_Application__c WHERE Id = :packageId LIMIT 1';
        List<ACEF_PGA_Application__c> rows = Database.query(soql);
        if (rows.isEmpty()) {
            throw new AuraHandledException('PGA Application Package not found.');
        }
        return rows[0];
    }

    private static String biUiStatus(Boolean linked7300, String disposition, Boolean favorable) {
        if (favorable) {
            return 'met';
        }
        if (!linked7300) {
            return 'open';
        }
        if (disposition == 'Unfavorable') {
            return 'failed';
        }
        return 'pending';
    }

    private static void addGate(
        List<GateLine> lines,
        String key,
        String groupKey,
        String label,
        Boolean passed,
        String detail,
        String uiStatus
    ) {
        GateLine line = new GateLine();
        line.key = key;
        line.groupKey = groupKey;
        line.label = label;
        line.passed = passed;
        line.detail = detail;
        line.uiStatus = uiStatus;
        lines.add(line);
    }
}