/**
 * ACE PGA Portal workflow, following the sequence in Kurt's org.
 *
 * Requester: answers "Are you requesting ACE Portal access?" before the forms.
 *   No  ─► Form 7300 only.
 *   Yes ─► Form 7300 + PGA package (access application, Rules of Behavior, NDA).
 *
 * Form 7300 (both paths, existing ACEF_Form_7300_Request__c statuses and trigger):
 *   Section 2 Pending (agency supervisor) ─► Section 3 Pending (CBP supervisor, only when given)
 *   ─► Section 4 Pending (security / PSO signers) ─► With 7300 Processing ─► OIT BI vetting
 *   BI Unfavorable ─► Closed Unfavorable (the PGA package is closed too).
 *   BI Favorable   ─► No path: Closed Favorable (done). Yes path: OIT BI Review, package continues.
 *
 * PGA package (Yes path, existing ACEF_PGA_Application__c statuses and Kurt's orchestration):
 *   Form 001 supervisor sign-off ─► Readiness ─► Provisioning (route, complete)
 *   ─► ACE Security verification ─► Closed (7300 Closed Favorable).
 *
 * Workspace lanes for the ACE PGA Portal "Workspaces" page: supervisor, cbpSupervisor,
 * security, vetting, provisioning, aceSecurity. Emails are not sent; the handoff is the
 * next lane's queue.
 */
public with sharing class ACEF_PortalWorkflowService {
  public static final String ANSWER_YES = 'Yes';
  public static final String ANSWER_NO = 'No';

  public static final String LANE_SUPERVISOR = 'supervisor';
  public static final String LANE_CBP = 'cbpSupervisor';
  public static final String LANE_SECURITY = 'security';
  public static final String LANE_VETTING = 'vetting';
  public static final String LANE_PROVISIONING = 'provisioning';
  public static final String LANE_ACE_SECURITY = 'aceSecurity';

  public static final String KIND_7300 = 'form7300';
  public static final String KIND_FORM001 = 'form001';
  public static final String KIND_PACKAGE = 'package';

  private static final Map<String, String> PENDING_STATUS_BY_SECTION = new Map<String, String>{
    '2' => 'Section 2 Pending',
    '3' => 'Section 3 Pending',
    '4' => 'Section 4 Pending'
  };
  private static final Map<String, String> COMPLETE_STATUS_BY_SECTION = new Map<String, String>{
    '2' => 'Section 2 Complete',
    '3' => 'Section 3 Complete',
    '4' => 'Section 4 Complete'
  };

  // ------------------------------------------------------------------ DTOs

  public class Progress {
    @AuraEnabled
    public String accessAnswer;
    @AuraEnabled
    public String request7300Status;
    @AuraEnabled
    public String packageStatus;
    /** Where the request is now, in plain words. */
    @AuraEnabled
    public String stage;
    /** Who the request is waiting on. */
    @AuraEnabled
    public String waitingOn;
    @AuraEnabled
    public Boolean closed = false;
    @AuraEnabled
    public Boolean favorable = false;
    /** The requester's own forms that are still open (Yes path). */
    @AuraEnabled
    public List<String> openForms = new List<String>();
  }

  public class QueueItem {
    @AuraEnabled
    public String kind;
    @AuraEnabled
    public Id request7300Id;
    @AuraEnabled
    public String requestName;
    @AuraEnabled
    public Id packageId;
    @AuraEnabled
    public String packageName;
    @AuraEnabled
    public String requesterName;
    @AuraEnabled
    public String requesterEmail;
    @AuraEnabled
    public Boolean aceAccess;
    @AuraEnabled
    public String requestStatus;
    @AuraEnabled
    public String packageStatus;
    @AuraEnabled
    public Id form7300Id;
    @AuraEnabled
    public String confirmationNumber;
    @AuraEnabled
    public String supervisorEmail;
    @AuraEnabled
    public String cbpSupervisorEmail;
    @AuraEnabled
    public String securityEmail;
    @AuraEnabled
    public String biDisposition;
    @AuraEnabled
    public String accessArea;
    @AuraEnabled
    public String readinessStatus;
    @AuraEnabled
    public String provisioningStatus;
    @AuraEnabled
    public String requestedSystems;
    @AuraEnabled
    public String agency;
    /** Provisioning lane: package checks passed, so readiness can be approved. */
    @AuraEnabled
    public Boolean ready = false;
    /** Provisioning lane: the package checks still missing, in plain words. */
    @AuraEnabled
    public List<String> waitingOn = new List<String>();
    /** Unique key for lists (a request can appear once per kind). */
    @AuraEnabled
    public String key;
  }

  // ------------------------------------------------------------------ requester

  /** Saves the ACE Portal access answer. Yes creates the PGA package; No keeps Form 7300 only. */
  @AuraEnabled
  public static ACEF_ApplicationService.PortalInitResult setAccessAnswer(
    Id request7300Id,
    String answer
  ) {
    if (request7300Id == null) {
      throw new AuraHandledException('Start a request first.');
    }
    if (answer != ANSWER_YES && answer != ANSWER_NO) {
      throw new AuraHandledException('Answer Yes or No.');
    }
    ACEF_Form_7300_Request__c request = loadRequest(request7300Id);
    if (
      request.ACEF_CBP_Form_7300__c != null &&
      String.isNotBlank(request.ACEF_ACE_Access_Answer__c) &&
      request.ACEF_ACE_Access_Answer__c != answer
    ) {
      throw new AuraHandledException(
        'Your Form 7300 is already submitted, so the ACE Portal access answer can no longer change.'
      );
    }
    update new ACEF_Form_7300_Request__c(
      Id = request7300Id,
      ACEF_ACE_Access_Answer__c = answer,
      ACEF_ACE_Access_Requested__c = answer == ANSWER_YES
    );
    return ACEF_ApplicationService.ensureAcePackage(request7300Id);
  }

  /** Where the request is and who it is waiting on, for the requester's status panel. */
  @AuraEnabled
  public static Progress getProgress(Id request7300Id) {
    Progress out = new Progress();
    if (request7300Id == null) {
      return out;
    }
    ACEF_Form_7300_Request__c request = loadRequest(request7300Id);
    ACEF_PGA_Application__c pkg = request.ACEF_PGA_Application__c == null
      ? null
      : loadPackage(request.ACEF_PGA_Application__c);
    out.accessAnswer = request.ACEF_ACE_Access_Answer__c;
    out.request7300Status = request.ACEF_Status__c;
    out.packageStatus = pkg == null ? null : pkg.ACEF_Package_Status__c;
    Boolean yes = request.ACEF_ACE_Access_Requested__c == true;

    if (yes && pkg != null) {
      if (pkg.ACEF_Form001_User_Complete__c != true) {
        out.openForms.add('PGA access application');
      }
      if (pkg.ACEF_Form002_Complete__c != true) {
        out.openForms.add('Rules of Behavior');
      }
      if (pkg.ACEF_NDA_Uploaded__c != true) {
        out.openForms.add('Witnessed NDA upload');
      }
    }

    String status = request.ACEF_Status__c;
    if (String.isBlank(request.ACEF_ACE_Access_Answer__c)) {
      setStage(out, 'Answer: are you requesting ACE Portal access?', 'You');
    } else if (request.ACEF_CBP_Form_7300__c == null) {
      setStage(out, 'Complete and submit the CBP Form 7300', 'You');
    } else if (status == 'Section 1 Complete' || status == 'Section 2 Pending') {
      setStage(
        out,
        'Form 7300: agency supervisor review (section 2)',
        orDash(request.ACEF_Next_Agency_Supervisor_Email__c)
      );
    } else if (status == 'Section 2 Complete' || status == 'Section 3 Pending') {
      setStage(
        out,
        'Form 7300: CBP supervisor review (section 3)',
        orDash(request.ACEF_Next_CBP_Supervisor_Email__c)
      );
    } else if (status == 'Section 3 Complete' || status == 'Section 4 Pending') {
      setStage(
        out,
        'Form 7300: security / PSO signers (section 4)',
        orDash(request.ACEF_PSO_Email__c)
      );
    } else if (
      (status == 'Section 4 Complete' || status == 'With 7300 Processing') &&
      yes &&
      pkg != null &&
      ACEF_PackageLifecycleService.statusOf(pkg) == ACEF_PackageLifecycleService.STATUS_DRAFT
    ) {
      // CBPPGA-88: the BI review starts once the full package is in (Pending BI Review).
      packageStage(out, pkg);
    } else if (status == 'Section 4 Complete' || status == 'With 7300 Processing') {
      setStage(
        out,
        'Vetting: OIT background investigation (BI)',
        'CBP vetting team'
      );
    } else if (status == 'Closed Unfavorable') {
      setStage(out, 'Closed: background investigation unfavorable', null);
      out.closed = true;
    } else if (!yes && status == 'Closed Favorable') {
      setStage(out, 'Complete: Form 7300 approved (BI favorable)', null);
      out.closed = true;
      out.favorable = true;
    } else if (status == 'Closed' && (pkg == null || pkg.ACEF_Package_Status__c != 'Closed')) {
      setStage(out, 'Closed: Form 7300 not approved', null);
      out.closed = true;
    } else if (yes && pkg != null) {
      packageStage(out, pkg);
    } else {
      setStage(out, status, null);
    }
    return out;
  }

  // ------------------------------------------------------------------ workspaces

  /** Items waiting in one workspace lane, newest first. */
  @AuraEnabled
  public static List<QueueItem> listQueue(String lane) {
    List<QueueItem> items = new List<QueueItem>();
    if (lane == LANE_SUPERVISOR) {
      items.addAll(requestsWithStatus(new Set<String>{ 'Section 2 Pending' }));
      // By the sign-off flags, not the status: the Rules and NDA steps overwrite the package status.
      for (ACEF_PGA_Application__c pkg : packagesWhere(null, null)) {
        if (pkg.ACEF_Form001_User_Complete__c == true && pkg.ACEF_Form001_Supervisor_Complete__c != true) {
          items.add(toItem(KIND_FORM001, pkg));
        }
      }
    } else if (lane == LANE_CBP) {
      items.addAll(requestsWithStatus(new Set<String>{ 'Section 3 Pending' }));
    } else if (lane == LANE_SECURITY) {
      items.addAll(requestsWithStatus(new Set<String>{ 'Section 4 Pending' }));
    } else if (lane == LANE_VETTING) {
      for (QueueItem item : requestsWithStatus(new Set<String>{ 'Section 4 Complete', 'With 7300 Processing' })) {
        if (item.biDisposition != 'Favorable' && item.biDisposition != 'Unfavorable') {
          items.add(item);
        }
      }
    } else if (lane == LANE_PROVISIONING) {
      List<QueueItem> ready = new List<QueueItem>();
      List<QueueItem> notReady = new List<QueueItem>();
      for (ACEF_PGA_Application__c pkg : packagesWhere(null, 'Favorable')) {
        if (pkg.ACEF_Provisioning_Status__c != 'Complete') {
          QueueItem item = toItem(KIND_PACKAGE, pkg);
          addReadiness(item);
          if (item.ready) {
            ready.add(item);
          } else {
            notReady.add(item);
          }
        }
      }
      items.addAll(ready);
      items.addAll(notReady);
    } else if (lane == LANE_ACE_SECURITY) {
      for (ACEF_PGA_Application__c pkg : packagesWhere(null, 'Favorable')) {
        if (pkg.ACEF_Provisioning_Status__c == 'Complete' && pkg.ACEF_ACE_Security_Verified__c != true) {
          items.add(toItem(KIND_PACKAGE, pkg));
        }
      }
    } else {
      throw new AuraHandledException('Unknown workspace: ' + lane);
    }
    return items;
  }

  /**
   * Agency supervisor (2), CBP supervisor (3) or security / PSO signer (4) decision on the Form 7300.
   * Approve hands the request to the next section through the existing trigger; Reject closes it.
   */
  @AuraEnabled
  public static void decide7300Section(
    Id request7300Id,
    String section,
    String decision,
    String signerName,
    String notes
  ) {
    if (!PENDING_STATUS_BY_SECTION.containsKey(section)) {
      throw new AuraHandledException('Unknown Form 7300 section: ' + section);
    }
    if (decision != 'Approved' && decision != 'Rejected') {
      throw new AuraHandledException('Choose Approve or Reject.');
    }
    if (String.isBlank(signerName)) {
      throw new AuraHandledException('Type your name to sign.');
    }
    if (decision == 'Rejected' && String.isBlank(notes)) {
      throw new AuraHandledException('Add a reason for rejecting.');
    }
    ACEF_Form_7300_Request__c request = loadRequest(request7300Id);
    if (request.ACEF_Status__c != PENDING_STATUS_BY_SECTION.get(section)) {
      throw new AuraHandledException(
        'Section ' + section + ' is not waiting for review (status: ' + request.ACEF_Status__c + ').'
      );
    }
    ACEF_Form_7300_Request__c change = new ACEF_Form_7300_Request__c(Id = request7300Id);
    String name = signerName.trim();
    if (section == '2') {
      change.ACEF_Sec2_Decision__c = decision;
      change.ACEF_Section2_Signed_By__c = name;
      change.ACEF_Section2_Signed_Date__c = Date.today();
      if (decision == 'Rejected') {
        change.ACEF_Sec2_Rejection_Reason__c = notes;
      }
    } else if (section == '3') {
      change.ACEF_Sec3_Decision__c = decision;
      change.ACEF_Section3_Signed_By__c = name;
      change.ACEF_Section3_Signed_Date__c = Date.today();
    } else {
      change.ACEF_Section4_Signed_By__c = name;
      change.ACEF_Section4_Signed_Date__c = Date.today();
    }
    change.ACEF_Status__c = decision == 'Approved' ? COMPLETE_STATUS_BY_SECTION.get(section) : 'Closed';
    update change;
    if (decision == 'Rejected') {
      closePackage(request.ACEF_PGA_Application__c);
    }
  }

  /**
   * OIT BI vetting (Kurt's applyBiDisposition). Unfavorable closes the request and the package.
   * Favorable: Form 7300 only (No path) is complete; with ACE Portal access the package moves on.
   */
  @AuraEnabled
  public static void recordVetting(Id request7300Id, String disposition, String notes) {
    if (disposition == 'Unfavorable' && String.isBlank(notes)) {
      throw new AuraHandledException('Add a note explaining the Unfavorable outcome.');
    }
    // CBPPGA-88: with ACE Portal access, BI adjudication happens while the package is in Pending BI Review.
    ACEF_PackageLifecycleService.assertReadyForBi(request7300Id);
    try {
      ACEF_ProvisioningOrchestration.applyBiDisposition(request7300Id, disposition, notes);
    } catch (AuraHandledException e) {
      throw e;
    } catch (Exception e) {
      throw new AuraHandledException(e.getMessage());
    }
    ACEF_Form_7300_Request__c request = loadRequest(request7300Id);
    if (disposition == 'Favorable') {
      if (request.ACEF_ACE_Access_Requested__c != true) {
        update new ACEF_Form_7300_Request__c(Id = request7300Id, ACEF_Status__c = 'Closed Favorable');
      } else if (request.ACEF_PGA_Application__c != null) {
        ACEF_ProvisioningOrchestration.syncPackageFlags(new List<Id>{ request.ACEF_PGA_Application__c });
      }
    }
  }

  /**
   * Provisioning readiness checks for one package, always fresh (Kurt's evaluateForUi is
   * cacheable, so the browser can show an out-of-date result after an action).
   */
  @AuraEnabled
  public static ACEF_ProvisioningGateService.GateResult getGates(Id packageId) {
    if (packageId == null) {
      return null;
    }
    return ACEF_ProvisioningGateService.buildResult(ACEF_ProvisioningGateService.loadPackage(packageId));
  }

  public class VettingContext {
    @AuraEnabled
    public Id request7300Id;
    @AuraEnabled
    public String requestName;
    @AuraEnabled
    public String requestStatus;
    @AuraEnabled
    public String biDisposition;
    @AuraEnabled
    public Boolean aceAccess = false;
    /** True when the Form 7300 has passed security (section 4) and has no BI result yet. */
    @AuraEnabled
    public Boolean awaitingVetting = false;
    @AuraEnabled
    public String message;
  }

  /** Native app: vetting state for a package or a Form 7300 Request record. */
  @AuraEnabled
  public static VettingContext getVettingContext(Id recordId) {
    VettingContext ctx = new VettingContext();
    Id requestId = resolveRequestId(recordId);
    if (requestId == null) {
      ctx.message = 'No Form 7300 request is linked to this record.';
      return ctx;
    }
    ACEF_Form_7300_Request__c request = [
      SELECT Id, Name, ACEF_Status__c, ACEF_BI_Disposition__c, ACEF_ACE_Access_Requested__c
      FROM ACEF_Form_7300_Request__c
      WHERE Id = :requestId
      LIMIT 1
    ];
    ctx.request7300Id = request.Id;
    ctx.requestName = request.Name;
    ctx.requestStatus = request.ACEF_Status__c;
    ctx.biDisposition = request.ACEF_BI_Disposition__c;
    ctx.aceAccess = request.ACEF_ACE_Access_Requested__c == true;
    Boolean decided = request.ACEF_BI_Disposition__c == 'Favorable' || request.ACEF_BI_Disposition__c == 'Unfavorable';
    Boolean pastSecurity = request.ACEF_Status__c == 'Section 4 Complete' || request.ACEF_Status__c == 'With 7300 Processing';
    ctx.awaitingVetting = pastSecurity && !decided;
    String packageBlock = decided || !pastSecurity ? null : ACEF_PackageLifecycleService.biBlockReason(request.Id);
    if (decided) {
      ctx.message = 'BI outcome already recorded: ' + request.ACEF_BI_Disposition__c + '.';
    } else if (packageBlock != null) {
      ctx.awaitingVetting = false;
      ctx.message = packageBlock;
    } else if (!pastSecurity) {
      ctx.message = 'Not ready for vetting yet: the Form 7300 is still with the requester or signers (status: ' + request.ACEF_Status__c + ').';
    }
    return ctx;
  }

  /** Native app: records the BI outcome from a package or a Form 7300 Request record. */
  @AuraEnabled
  public static VettingContext recordVettingForRecord(Id recordId, String disposition, String notes) {
    Id requestId = resolveRequestId(recordId);
    if (requestId == null) {
      throw new AuraHandledException('No Form 7300 request is linked to this record.');
    }
    VettingContext before = getVettingContext(recordId);
    if (!before.awaitingVetting) {
      throw new AuraHandledException(before.message);
    }
    recordVetting(requestId, disposition, notes);
    return getVettingContext(recordId);
  }

  private static Id resolveRequestId(Id recordId) {
    if (recordId == null) {
      return null;
    }
    if (recordId.getSobjectType() == ACEF_Form_7300_Request__c.SObjectType) {
      return recordId;
    }
    if (recordId.getSobjectType() == ACEF_PGA_Application__c.SObjectType) {
      List<ACEF_PGA_Application__c> rows = [
        SELECT ACEF_Form_7300_Request__c
        FROM ACEF_PGA_Application__c
        WHERE Id = :recordId
        LIMIT 1
      ];
      return rows.isEmpty() ? null : rows[0].ACEF_Form_7300_Request__c;
    }
    return null;
  }

  // ------------------------------------------------------------------ internals

  /** Package and clearance checks that must pass before readiness can be approved. */
  private static final Set<String> READINESS_GROUPS = new Set<String>{ 'package', 'clearance' };

  private static void addReadiness(QueueItem item) {
    ACEF_ProvisioningGateService.GateResult gates = getGates(item.packageId);
    item.ready = gates.readyForReadiness == true;
    for (ACEF_ProvisioningGateService.GateLine line : gates.lines) {
      if (line.passed != true && READINESS_GROUPS.contains(line.groupKey)) {
        item.waitingOn.add(line.label);
      }
    }
  }

  private static void setStage(Progress out, String stage, String waitingOn) {
    out.stage = stage;
    out.waitingOn = waitingOn;
  }

  private static void packageStage(Progress out, ACEF_PGA_Application__c pkg) {
    ACEF_ProvisioningGateService.GateResult gates = ACEF_ProvisioningGateService.buildResult(
      ACEF_ProvisioningGateService.loadPackage(pkg.Id)
    );
    String lifecycle = ACEF_PackageLifecycleService.statusOf(pkg);
    if (pkg.ACEF_Package_Status__c == 'Closed' && pkg.ACEF_ACE_Security_Verified__c == true) {
      setStage(out, 'Complete: ACE Portal access provisioned and verified', null);
      out.closed = true;
      out.favorable = true;
    } else if (pkg.ACEF_Package_Status__c == 'Closed') {
      setStage(out, 'Closed', null);
      out.closed = true;
    } else if (pkg.ACEF_Form001_User_Complete__c != true) {
      setStage(out, 'Complete your PGA access application', 'You');
    } else if (pkg.ACEF_Form001_Supervisor_Complete__c != true) {
      setStage(out, 'PGA access application: supervisor sign-off', 'Agency supervisor');
    } else if (!out.openForms.isEmpty()) {
      setStage(out, 'Complete your remaining forms', 'You');
    } else if (lifecycle == ACEF_PackageLifecycleService.STATUS_READY) {
      // CBPPGA-88: after the BI the stage follows the package lifecycle Status.
      setStage(out, 'Provisioning: ACE Portal access being set up', 'ACE Provisioning Team');
    } else if (
      lifecycle == ACEF_PackageLifecycleService.STATUS_PROVISIONED ||
      lifecycle == ACEF_PackageLifecycleService.STATUS_ACE_SECURITY
    ) {
      setStage(out, 'ACE Security verification', 'ACE Security');
    } else if (pkg.ACEF_Readiness_Status__c != 'Approved') {
      setStage(
        out,
        gates.readyForReadiness ? 'Provisioning: readiness review' : 'Provisioning: waiting for package checks',
        'ACE PGA provisioning team'
      );
    } else if (pkg.ACEF_Provisioning_Status__c != 'Complete') {
      setStage(out, 'Provisioning: ACE Portal access being set up', 'ACE PGA provisioning team');
    } else {
      setStage(out, 'ACE Security verification', 'ACE Security');
    }
  }

  private static List<QueueItem> requestsWithStatus(Set<String> statuses) {
    List<QueueItem> items = new List<QueueItem>();
    for (ACEF_Form_7300_Request__c request : [
      SELECT
        Id, Name, ACEF_Status__c, ACEF_ACE_Access_Requested__c, ACEF_First_Name__c, ACEF_Last_Name__c,
        ACEF_Home_Agency_Email__c, ACEF_Next_Agency_Supervisor_Email__c, ACEF_Next_CBP_Supervisor_Email__c,
        ACEF_PSO_Email__c, ACEF_BI_Disposition__c, ACEF_CBP_Form_7300__c, ACEF_CBP_Form_7300__r.Name,
        ACEF_PGA_Application__c, ACEF_PGA_Application__r.Name, ACEF_PGA_Application__r.ACEF_Package_Status__c,
        ACEF_PGA_Application__r.ACEF_Requested_Systems__c, ACEF_PGA_Application__r.ACEF_Agency__c
      FROM ACEF_Form_7300_Request__c
      WHERE ACEF_Status__c IN :statuses
      ORDER BY LastModifiedDate DESC
      LIMIT 50
    ]) {
      QueueItem item = new QueueItem();
      item.kind = KIND_7300;
      item.key = KIND_7300 + request.Id;
      item.request7300Id = request.Id;
      item.requestName = request.Name;
      item.requestStatus = request.ACEF_Status__c;
      item.aceAccess = request.ACEF_ACE_Access_Requested__c == true;
      item.requesterName = joinName(request.ACEF_First_Name__c, request.ACEF_Last_Name__c);
      item.requesterEmail = request.ACEF_Home_Agency_Email__c;
      item.supervisorEmail = request.ACEF_Next_Agency_Supervisor_Email__c;
      item.cbpSupervisorEmail = request.ACEF_Next_CBP_Supervisor_Email__c;
      item.securityEmail = request.ACEF_PSO_Email__c;
      item.biDisposition = request.ACEF_BI_Disposition__c;
      item.form7300Id = request.ACEF_CBP_Form_7300__c;
      item.confirmationNumber = request.ACEF_CBP_Form_7300__r?.Name;
      item.packageId = request.ACEF_PGA_Application__c;
      item.packageName = request.ACEF_PGA_Application__r?.Name;
      item.packageStatus = request.ACEF_PGA_Application__r?.ACEF_Package_Status__c;
      item.requestedSystems = request.ACEF_PGA_Application__r?.ACEF_Requested_Systems__c;
      item.agency = request.ACEF_PGA_Application__r?.ACEF_Agency__c;
      items.add(item);
    }
    return items;
  }

  private static List<ACEF_PGA_Application__c> packagesWhere(String packageStatus, String biDisposition) {
    String soql =
      'SELECT Id, Name, ACEF_Package_Status__c, ACEF_Form001_Applicant_Name__c, ACEF_Work_Email__c, ' +
      'ACEF_Form001_User_Complete__c, ACEF_Form001_Supervisor_Complete__c, ' +
      'ACEF_Access_Area__c, ACEF_Readiness_Status__c, ACEF_Provisioning_Status__c, ACEF_ACE_Security_Verified__c, ' +
      'ACEF_Requested_Systems__c, ACEF_Agency__c, ACEF_Form_7300_Request__c, ACEF_Form_7300_Request__r.Name, ' +
      'ACEF_Form_7300_Request__r.ACEF_Status__c, ACEF_Form_7300_Request__r.ACEF_BI_Disposition__c, ' +
      'ACEF_Form_7300_Request__r.ACEF_Next_Agency_Supervisor_Email__c, ' +
      'ACEF_Form_7300_Request__r.ACEF_CBP_Form_7300__c, ACEF_Form_7300_Request__r.ACEF_CBP_Form_7300__r.Name ' +
      'FROM ACEF_PGA_Application__c WHERE ACEF_Package_Status__c != \'Closed\'';
    if (packageStatus != null) {
      soql += ' AND ACEF_Package_Status__c = :packageStatus';
    }
    if (biDisposition != null) {
      soql += ' AND ACEF_Form_7300_Request__r.ACEF_BI_Disposition__c = :biDisposition';
    }
    soql += ' ORDER BY LastModifiedDate DESC LIMIT 50';
    return (List<ACEF_PGA_Application__c>) Database.queryWithBinds(
      soql,
      new Map<String, Object>{ 'packageStatus' => packageStatus, 'biDisposition' => biDisposition },
      AccessLevel.SYSTEM_MODE
    );
  }

  private static QueueItem toItem(String kind, ACEF_PGA_Application__c pkg) {
    QueueItem item = new QueueItem();
    item.kind = kind;
    item.key = kind + pkg.Id;
    item.packageId = pkg.Id;
    item.packageName = pkg.Name;
    item.packageStatus = pkg.ACEF_Package_Status__c;
    item.requesterName = pkg.ACEF_Form001_Applicant_Name__c;
    item.requesterEmail = pkg.ACEF_Work_Email__c;
    item.accessArea = pkg.ACEF_Access_Area__c;
    item.readinessStatus = pkg.ACEF_Readiness_Status__c;
    item.provisioningStatus = pkg.ACEF_Provisioning_Status__c;
    item.requestedSystems = pkg.ACEF_Requested_Systems__c;
    item.agency = pkg.ACEF_Agency__c;
    item.aceAccess = true;
    item.request7300Id = pkg.ACEF_Form_7300_Request__c;
    item.requestName = pkg.ACEF_Form_7300_Request__r?.Name;
    item.requestStatus = pkg.ACEF_Form_7300_Request__r?.ACEF_Status__c;
    item.biDisposition = pkg.ACEF_Form_7300_Request__r?.ACEF_BI_Disposition__c;
    item.supervisorEmail = pkg.ACEF_Form_7300_Request__r?.ACEF_Next_Agency_Supervisor_Email__c;
    item.form7300Id = pkg.ACEF_Form_7300_Request__r?.ACEF_CBP_Form_7300__c;
    item.confirmationNumber = pkg.ACEF_Form_7300_Request__r?.ACEF_CBP_Form_7300__r?.Name;
    return item;
  }

  private static void closePackage(Id packageId) {
    if (packageId == null) {
      return;
    }
    update new ACEF_PGA_Application__c(
      Id = packageId,
      ACEF_Package_Status__c = 'Closed',
      ACEF_Readiness_Status__c = 'Rejected',
      ACEF_Provisioning_Status__c = 'Not Started'
    );
  }

  private static ACEF_Form_7300_Request__c loadRequest(Id request7300Id) {
    List<ACEF_Form_7300_Request__c> rows = [
      SELECT
        Id, ACEF_Status__c, ACEF_ACE_Access_Answer__c, ACEF_ACE_Access_Requested__c, ACEF_CBP_Form_7300__c,
        ACEF_PGA_Application__c, ACEF_Next_Agency_Supervisor_Email__c, ACEF_Next_CBP_Supervisor_Email__c,
        ACEF_PSO_Email__c, ACEF_BI_Disposition__c
      FROM ACEF_Form_7300_Request__c
      WHERE Id = :request7300Id
      LIMIT 1
    ];
    if (rows.isEmpty()) {
      throw new AuraHandledException('Form 7300 request not found.');
    }
    return rows[0];
  }

  private static ACEF_PGA_Application__c loadPackage(Id packageId) {
    return [
      SELECT
        Id, ACEF_Package_Status__c, ACEF_Form001_User_Complete__c, ACEF_Form001_Supervisor_Complete__c,
        ACEF_Form002_Complete__c, ACEF_NDA_Uploaded__c, ACEF_Readiness_Status__c,
        ACEF_Provisioning_Status__c, ACEF_ACE_Security_Verified__c, ACEF_Status__c
      FROM ACEF_PGA_Application__c
      WHERE Id = :packageId
      LIMIT 1
    ];
  }

  private static String joinName(String first, String last) {
    return ((first == null ? '' : first) + ' ' + (last == null ? '' : last)).trim();
  }

  private static String orDash(String value) {
    return String.isBlank(value) ? '—' : value;
  }
}