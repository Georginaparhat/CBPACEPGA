/**
 * CBPPGA-88. ACE PGA provisioning lifecycle on the package (ACEF_PGA_Application__c.ACEF_Status__c).
 *
 *   Draft ─(Submit Request, or automatically once the full package is in)─► Pending BI Review
 *   Pending BI Review ─(BI Favorable)─► Ready for Provisioning
 *   Pending BI Review ─(BI Unfavorable)─► Unfavorable BI Determination (processing stops)
 *   Ready for Provisioning ─(Provision: emails the AES / GCMC teams when requested)─► Provisioned ─► ACE Security Review
 *   ACE Security Review ─(Complete Security Review)─► Complete
 *
 * "Full package" = CBP Form 7300 through Security / PSO (7300 Pending BI Determination), ACE PGA
 * Application signed by applicant and supervisor, Rules of Behavior and NDA (the gate service's
 * packageComplete). The portal's own progress stays in ACEF_Package_Status__c.
 */
public with sharing class ACEF_PackageLifecycleService {
  public static final String STATUS_DRAFT = 'Draft';
  public static final String STATUS_PENDING_BI = 'Pending BI Review';
  public static final String STATUS_READY = 'Ready for Provisioning';
  public static final String STATUS_PROVISIONED = 'Provisioned';
  public static final String STATUS_ACE_SECURITY = 'ACE Security Review';
  public static final String STATUS_COMPLETE = 'Complete';
  public static final String STATUS_UNFAVORABLE = 'Unfavorable BI Determination';

  public static final String ACTION_SUBMIT = 'submit';
  public static final String ACTION_PROVISION = 'provision';
  public static final String ACTION_SECURITY = 'security';

  @TestVisible
  private static final String AUTO_SUBMITTER = 'Automatic (full package received)';

  public class CheckLine {
    @AuraEnabled
    public String label;
    @AuraEnabled
    public Boolean passed = false;
  }

  public class ActionContext {
    @AuraEnabled
    public String status;
    @AuraEnabled
    public Boolean allowed = false;
    @AuraEnabled
    public String message;
    @AuraEnabled
    public List<CheckLine> checklist = new List<CheckLine>();
    /** Provision: the system teams that will be emailed. */
    @AuraEnabled
    public List<String> notifyTeams = new List<String>();
  }

  // ------------------------------------------------------------------ UI actions

  /** What the Submit Request / Provision / Complete Security Review screens show before the user confirms. */
  @AuraEnabled
  public static ActionContext getActionContext(Id packageId, String actionKey) {
    ACEF_PGA_Application__c pkg = loadPackage(packageId);
    ActionContext ctx = new ActionContext();
    ctx.status = statusOf(pkg);
    if (actionKey == ACTION_SUBMIT) {
      ACEF_ProvisioningGateService.GateResult gates = ACEF_ProvisioningGateService.buildResult(
        ACEF_ProvisioningGateService.loadPackage(packageId)
      );
      ctx.checklist = submitChecklist(pkg, gates);
      if (ctx.status != STATUS_DRAFT) {
        ctx.message = 'Already submitted. Status: ' + ctx.status + '.';
      } else if (gates.packageComplete != true) {
        ctx.message = 'The full package is not in yet. Submit is available once every item below is complete.';
      } else {
        ctx.allowed = true;
        ctx.message = 'Submit sends the package to the ACE Provisioning Team as Pending BI Review.';
      }
    } else if (actionKey == ACTION_PROVISION) {
      for (ACEF_System_Notification__mdt team : notificationsFor(pkg)) {
        ctx.notifyTeams.add(teamLabel(team));
      }
      if (ctx.status != STATUS_READY) {
        ctx.message = 'Provision is available when the status is Ready for Provisioning. Status: ' + ctx.status + '.';
      } else {
        ctx.allowed = true;
        ctx.message = ctx.notifyTeams.isEmpty()
          ? 'AES and GCMC access were not requested, so no system team email is needed. Provision moves the package to Provisioned and then ACE Security Review.'
          : 'Provision emails the system teams below, then moves the package to Provisioned and then ACE Security Review.';
      }
    } else if (actionKey == ACTION_SECURITY) {
      if (ctx.status != STATUS_ACE_SECURITY) {
        ctx.message = 'Complete Security Review is available when the status is ACE Security Review. Status: ' + ctx.status + '.';
      } else {
        ctx.allowed = true;
        ctx.message = 'Confirm the ACE security review is done. The package moves to Complete.';
      }
    } else {
      throw failure('Unknown action: ' + actionKey);
    }
    return ctx;
  }

  /** Submit Request: Draft ─► Pending BI Review (Ready for Provisioning if the BI is already favorable). */
  @AuraEnabled
  public static void submitRequest(Id packageId) {
    ActionContext ctx = getActionContext(packageId, ACTION_SUBMIT);
    if (!ctx.allowed) {
      throw failure(ctx.message);
    }
    ACEF_PGA_Application__c pkg = loadPackage(packageId);
    update submitted(pkg, UserInfo.getName());
  }

  /**
   * Provision: Ready for Provisioning ─► Provisioned ─► ACE Security Review. Generates the Hash ID,
   * marks provisioning complete and, when AES or GCMC access was requested, emails those system
   * teams (recipients in ACEF_System_Notification__mdt). A failed email rolls everything back.
   */
  @AuraEnabled
  public static void provision(Id packageId, String notes) {
    ACEF_PGA_Application__c pkg = loadPackage(packageId);
    if (statusOf(pkg) != STATUS_READY) {
      throw failure(
        'Provision is available when the status is Ready for Provisioning. Status: ' + statusOf(pkg) + '.'
      );
    }
    List<ACEF_System_Notification__mdt> teams = notificationsFor(pkg);
    String hashId = ACEF_HashIdService.generateForPackage(packageId).hashId;
    Datetime now = System.now();

    ACEF_PGA_Application__c change = new ACEF_PGA_Application__c(
      Id = packageId,
      ACEF_Status__c = STATUS_PROVISIONED,
      ACEF_Provisioning_Status__c = 'Complete',
      ACEF_Provisioning_Complete_Date__c = now,
      ACEF_Provisioning_Complete_By__c = UserInfo.getName()
    );
    List<String> log = new List<String>();
    if (teams.isEmpty()) {
      log.add(now.format() + ': AES / GCMC access not requested; no system team email sent.');
    } else {
      List<Messaging.SingleEmailMessage> mails = new List<Messaging.SingleEmailMessage>();
      for (ACEF_System_Notification__mdt team : teams) {
        List<String> recipients = splitEmails(team.Recipient_Emails__c);
        if (recipients.isEmpty()) {
          throw failure(
            'No recipient email is set for ' + team.System__c + ' in System Notification (custom metadata).'
          );
        }
        mails.add(buildEmail(pkg, team, recipients, hashId));
        log.add(now.format() + ': emailed ' + teamLabel(team) + ' (' + String.join(recipients, ', ') + ')');
        String systemName = team.System__c.trim().toUpperCase();
        if (systemName == 'AES') {
          change.ACEF_AES_Notified_At__c = now;
        } else if (systemName == 'GCMC') {
          change.ACEF_GCMC_Notified_At__c = now;
        }
      }
      try {
        Messaging.sendEmail(mails, true);
      } catch (EmailException e) {
        throw failure('Could not send the system team email: ' + e.getMessage());
      }
    }
    change.ACEF_System_Notification_Log__c = appendLines(pkg.ACEF_System_Notification_Log__c, log);
    if (String.isNotBlank(notes)) {
      change.ACEF_Readiness_Notes__c = appendLines(
        pkg.ACEF_Readiness_Notes__c,
        new List<String>{ 'Provision: ' + notes.trim() }
      );
    }
    update change;
    // Provisioned is recorded, then the package moves on to the ACE security review.
    update new ACEF_PGA_Application__c(Id = packageId, ACEF_Status__c = STATUS_ACE_SECURITY);
  }

  // ------------------------------------------------------------------ automation

  /**
   * Package trigger (after insert / update): a Draft package moves on by itself once the full package
   * is in. Uses the record's 7300 mirror fields, so it works for portal users too.
   */
  public static void autoSubmit(List<ACEF_PGA_Application__c> rows) {
    if (autoSubmitDisabled) {
      return;
    }
    Map<Id, ACEF_PGA_Application__c> candidates = new Map<Id, ACEF_PGA_Application__c>();
    for (ACEF_PGA_Application__c row : rows) {
      if (statusOf(row) != STATUS_DRAFT || row.ACEF_Package_Status__c == 'Closed') {
        continue;
      }
      if (ACEF_ProvisioningGateService.computePackageComplete(row)) {
        candidates.put(row.Id, row);
      }
    }
    if (candidates.isEmpty()) {
      return;
    }
    // A nested trigger run (7300 mirror sync) may already have submitted the package.
    List<ACEF_PGA_Application__c> updates = new List<ACEF_PGA_Application__c>();
    for (ACEF_PGA_Application__c current : [
      SELECT Id, ACEF_Status__c, ACEF_Linked_7300_BI_Disposition__c
      FROM ACEF_PGA_Application__c
      WHERE Id IN :candidates.keySet()
    ]) {
      if (statusOf(current) == STATUS_DRAFT) {
        updates.add(submitted(current, AUTO_SUBMITTER));
      }
    }
    if (!updates.isEmpty()) {
      update updates;
    }
  }

  /** Tests only: lets a test hold a complete package in Draft to exercise Submit Request. */
  @TestVisible
  private static Boolean autoSubmitDisabled = false;

  /**
   * BI adjudication happens while the package is in Pending BI Review. Returns why the BI outcome
   * can't be recorded yet for this Form 7300, or null when it can (Form 7300 only requests, with no
   * ACE Portal access, are not held back).
   */
  public static String biBlockReason(Id request7300Id) {
    if (request7300Id == null) {
      return null;
    }
    List<ACEF_Form_7300_Request__c> rows = [
      SELECT ACEF_ACE_Access_Requested__c, ACEF_PGA_Application__c
      FROM ACEF_Form_7300_Request__c
      WHERE Id = :request7300Id
      LIMIT 1
    ];
    if (rows.isEmpty() || rows[0].ACEF_ACE_Access_Requested__c != true || rows[0].ACEF_PGA_Application__c == null) {
      return null;
    }
    ACEF_PGA_Application__c pkg = [
      SELECT Name, ACEF_Status__c
      FROM ACEF_PGA_Application__c
      WHERE Id = :rows[0].ACEF_PGA_Application__c
      LIMIT 1
    ];
    String status = statusOf(pkg);
    if (status == STATUS_PENDING_BI) {
      return null;
    }
    if (status == STATUS_DRAFT) {
      return 'ACE PGA package ' + pkg.Name +
        ' has not been submitted yet. The BI outcome is recorded once the full package is in and the status is Pending BI Review.';
    }
    return 'The BI outcome is recorded while the package is in Pending BI Review. ACE PGA package ' + pkg.Name +
      ' status: ' + status + '.';
  }

  public static void assertReadyForBi(Id request7300Id) {
    String reason = biBlockReason(request7300Id);
    if (reason != null) {
      throw failure(reason);
    }
  }

  // ------------------------------------------------------------------ helpers

  /** AuraHandledException with its message readable in Apex too (getMessage), not only in the UI. */
  private static AuraHandledException failure(String message) {
    AuraHandledException e = new AuraHandledException(message);
    e.setMessage(message);
    return e;
  }

  public static String statusOf(ACEF_PGA_Application__c pkg) {
    return String.isBlank(pkg.ACEF_Status__c) ? STATUS_DRAFT : pkg.ACEF_Status__c;
  }

  /** Draft ─► Pending BI Review. A BI already decided on the linked 7300 is applied straight away. */
  private static ACEF_PGA_Application__c submitted(ACEF_PGA_Application__c pkg, String submittedBy) {
    String next = STATUS_PENDING_BI;
    if (pkg.ACEF_Linked_7300_BI_Disposition__c == 'Favorable') {
      next = STATUS_READY;
    } else if (pkg.ACEF_Linked_7300_BI_Disposition__c == 'Unfavorable') {
      next = STATUS_UNFAVORABLE;
    }
    return new ACEF_PGA_Application__c(
      Id = pkg.Id,
      ACEF_Status__c = next,
      ACEF_Submitted_At__c = System.now(),
      ACEF_Submitted_By__c = submittedBy
    );
  }

  /** The four items of the full package, as the ticket lists them. */
  private static List<CheckLine> submitChecklist(
    ACEF_PGA_Application__c pkg,
    ACEF_ProvisioningGateService.GateResult gates
  ) {
    Map<String, Boolean> byKey = new Map<String, Boolean>();
    for (ACEF_ProvisioningGateService.GateLine line : gates.lines) {
      byKey.put(line.key, line.passed == true);
    }
    Boolean section4 = byKey.containsKey('7300_section4')
      ? byKey.get('7300_section4')
      : pkg.ACEF_7300_Clearance_Ready__c == true;
    List<CheckLine> out = new List<CheckLine>();
    out.add(line('CBP Form 7300 through Security / PSO (Pending BI Determination)', byKey.get('7300_link') == true && section4));
    out.add(line('ACE PGA Application signed by the applicant', byKey.get('form001_user') == true));
    out.add(line('ACE PGA Application signed by the supervisor', byKey.get('form001_supervisor') == true));
    out.add(line('Rules of Behavior complete', byKey.get('form002') == true));
    out.add(line('NDA uploaded', byKey.get('form003_nda') == true));
    return out;
  }

  private static CheckLine line(String label, Boolean passed) {
    CheckLine l = new CheckLine();
    l.label = label;
    l.passed = passed;
    return l;
  }

  /**
   * Active system teams whose system was requested on the package: picked systems, systems marked Add
   * or Recertify in the PGA user roles table, and systems the requested roles grant (not Remove).
   */
  @TestVisible
  private static List<ACEF_System_Notification__mdt> notificationsFor(ACEF_PGA_Application__c pkg) {
    Set<String> requested = new Set<String>();
    for (String value : new List<String>{
      pkg.ACEF_Requested_Systems__c,
      pkg.ACEF_Systems_Add__c,
      pkg.ACEF_Systems_Recertify__c,
      pkg.ACEF_Granted_Systems__c
    }) {
      requested.addAll(splitSystems(value));
    }
    Map<String, ACEF_System_Notification__mdt> bySystem = new Map<String, ACEF_System_Notification__mdt>();
    for (ACEF_System_Notification__mdt team : ACEF_System_Notification__mdt.getAll().values()) {
      if (team.Active__c == true && String.isNotBlank(team.System__c)) {
        String systemName = team.System__c.trim().toUpperCase();
        if (requested.contains(systemName)) {
          bySystem.put(systemName, team);
        }
      }
    }
    List<String> keys = new List<String>(bySystem.keySet());
    keys.sort();
    List<ACEF_System_Notification__mdt> out = new List<ACEF_System_Notification__mdt>();
    for (String key : keys) {
      out.add(bySystem.get(key));
    }
    return out;
  }

  private static Set<String> splitSystems(String value) {
    Set<String> out = new Set<String>();
    if (String.isBlank(value)) {
      return out;
    }
    for (String part : value.split('[;,\\n]')) {
      if (String.isNotBlank(part)) {
        out.add(part.trim().toUpperCase());
      }
    }
    return out;
  }

  private static List<String> splitEmails(String value) {
    List<String> out = new List<String>();
    if (String.isBlank(value)) {
      return out;
    }
    for (String part : value.split('[;,\\s]+')) {
      if (String.isNotBlank(part)) {
        out.add(part.trim());
      }
    }
    return out;
  }

  private static String teamLabel(ACEF_System_Notification__mdt team) {
    return String.isNotBlank(team.Team_Name__c) ? team.Team_Name__c : team.System__c + ' team';
  }

  private static Messaging.SingleEmailMessage buildEmail(
    ACEF_PGA_Application__c pkg,
    ACEF_System_Notification__mdt team,
    List<String> recipients,
    String hashId
  ) {
    String systemName = team.System__c.trim();
    List<String> body = new List<String>{
      'Hello ' + teamLabel(team) + ',',
      '',
      'The ACE Provisioning Team has provisioned ACE PGA package ' + pkg.Name + '. ' + systemName +
      ' access was requested for this user. Please set up their ' + systemName + ' access.',
      '',
      'Applicant: ' + orDash(pkg.ACEF_Form001_Applicant_Name__c),
      'Work email: ' + orDash(pkg.ACEF_Work_Email__c),
      'Work phone: ' + orDash(pkg.ACEF_Work_Phone__c),
      'Agency: ' + orDash(pkg.ACEF_Agency__c),
      'ACE user ID: ' + orDash(pkg.ACEF_Form001_ACE_User_ID__c),
      'Requested systems: ' + orDash(pkg.ACEF_Requested_Systems__c),
      'Role codes: ' + orDash(pkg.ACEF_Role_Codes__c),
      'Hash ID: ' + orDash(hashId),
      '',
      'Package: ' + URL.getOrgDomainUrl().toExternalForm() + '/' + pkg.Id
    };
    Messaging.SingleEmailMessage mail = new Messaging.SingleEmailMessage();
    mail.setToAddresses(recipients);
    mail.setSubject('ACE PGA provisioning: ' + systemName + ' access for ' + pkg.Name);
    mail.setPlainTextBody(String.join(body, '\n'));
    mail.setSaveAsActivity(false);
    return mail;
  }

  private static String orDash(String value) {
    return String.isBlank(value) ? '-' : value;
  }

  private static String appendLines(String existing, List<String> added) {
    String joined = String.join(added, '\n');
    return String.isBlank(existing) ? joined : existing + '\n' + joined;
  }

  private static ACEF_PGA_Application__c loadPackage(Id packageId) {
    List<ACEF_PGA_Application__c> rows = [
      SELECT
        Id,
        Name,
        ACEF_Status__c,
        ACEF_Package_Status__c,
        ACEF_7300_Clearance_Ready__c,
        ACEF_Linked_7300_BI_Disposition__c,
        ACEF_Requested_Systems__c,
        ACEF_Systems_Add__c,
        ACEF_Systems_Recertify__c,
        ACEF_Granted_Systems__c,
        ACEF_Role_Codes__c,
        ACEF_Form001_Applicant_Name__c,
        ACEF_Form001_ACE_User_ID__c,
        ACEF_Work_Email__c,
        ACEF_Work_Phone__c,
        ACEF_Agency__c,
        ACEF_System_Notification_Log__c,
        ACEF_Readiness_Notes__c
      FROM ACEF_PGA_Application__c
      WHERE Id = :packageId
      LIMIT 1
    ];
    if (rows.isEmpty()) {
      throw failure('ACE PGA Application Package not found.');
    }
    return rows[0];
  }
}