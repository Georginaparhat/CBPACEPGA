/**
 * ACE PGA process demo: walks one package through the User Experience Process Map.
 *
 *   Requester  ─► Rules of Behavior, ACE PGA Application (CBPPGA-87 picker), Form 7300, NDA upload
 *              ─► Submit (only when everything is complete)
 *   System     ─► Supervisor step (always) + CBP Supervisor step (only when that email is given)
 *   Supervisors ─► review, complete their section, attest and Approve | Return | Reject
 *   All supervisors approved ─► Vetting step: the vetting team records the BI outcome
 *   Vetting    ─► Favorable: parallel split, Security step + Provisioning step
 *              ─► Unfavorable: package closed (Closed - Unfavorable BI); the process ends
 *   Security   ─► security section, 7300 PDF + SharePoint (mimicked)
 *   Provisioning ─► GCMC/AES prefilled email (only when needed) + automated ACE Portal call (mimicked)
 *   Both done  ─► join: package Approved
 *
 * Uses only the new ACEF_Package_Review__c and ACEF_Approval_Step__c objects. Existing
 * objects are read, never written. cbplogin.gov sign-in, email sending, SharePoint and the
 * ACE Portal callout are mimicked for the stakeholder demo.
 */
public with sharing class ACEF_ProcessDemoService {
  public static final String REVIEW_DRAFT = 'Draft';
  public static final String REVIEW_AWAITING = 'Awaiting Supervisors';
  public static final String REVIEW_RETURNED = 'Returned for Information';
  public static final String REVIEW_REJECTED = 'Rejected';
  public static final String REVIEW_VETTING = 'Vetting';
  public static final String REVIEW_FULFILMENT = 'Security & Provisioning';
  public static final String REVIEW_APPROVED = 'Approved';
  public static final String REVIEW_UNFAVORABLE = 'Closed - Unfavorable BI';

  public static final String TYPE_SUPERVISOR = 'Supervisor';
  public static final String TYPE_CBP = 'CBP Supervisor';
  public static final String TYPE_VETTING = 'Vetting';
  public static final String TYPE_SECURITY = 'Security';
  public static final String TYPE_PROVISIONING = 'Provisioning';

  public static final String STEP_PENDING = 'Pending';
  public static final String STEP_APPROVED = 'Approved';
  public static final String STEP_RETURNED = 'Returned';
  public static final String STEP_REJECTED = 'Rejected';
  public static final String STEP_COMPLETED = 'Completed';
  public static final String STEP_CANCELLED = 'Cancelled';

  /** Placeholder addresses until the real mailboxes are confirmed. */
  public static final String SUPPORT_MAILBOX = 'ace-pga-provisioning@example.gov';
  public static final String SECURITY_MAILBOX = 'security-office@example.gov';
  public static final String VETTING_MAILBOX = 'vetting-team@example.gov';

  public static final String BI_FAVORABLE = 'Favorable';
  public static final String BI_UNFAVORABLE = 'Unfavorable';

  // ------------------------------------------------------------------ DTOs

  public class EmailPreview {
    @AuraEnabled
    public String toAddress;
    @AuraEnabled
    public String subject;
    @AuraEnabled
    public String body;
    /** Call-to-action emails only: the routed step the link opens. */
    @AuraEnabled
    public String stepType;
    @AuraEnabled
    public Id stepId;
  }

  public class Option {
    @AuraEnabled
    public String value;
    @AuraEnabled
    public String label;
  }

  public class ReviewState {
    @AuraEnabled
    public ACEF_Package_Review__c review;
    @AuraEnabled
    public List<ACEF_Approval_Step__c> steps = new List<ACEF_Approval_Step__c>();
    @AuraEnabled
    public List<String> missing = new List<String>();
    @AuraEnabled
    public Boolean editable = false;
    @AuraEnabled
    public String ndaFileName;
    @AuraEnabled
    public String deptAgencyLabel;
    @AuraEnabled
    public String requestedSystemsLabel;
    @AuraEnabled
    public String pdfUrl;
    @AuraEnabled
    public List<EmailPreview> callToActionEmails = new List<EmailPreview>();
    @AuraEnabled
    public EmailPreview provisioningEmail;
  }

  public class StepItem {
    @AuraEnabled
    public ACEF_Approval_Step__c step;
    @AuraEnabled
    public ReviewState state;
  }

  /** A mimicked cbplogin.gov identity and the portal user JIT provisioning would create for it. */
  public class DemoIdentity {
    @AuraEnabled
    public String name;
    @AuraEnabled
    public String email;
    @AuraEnabled
    public String username;
    @AuraEnabled
    public String federationId;
    @AuraEnabled
    public String hashId;
    @AuraEnabled
    public String persona;
    @AuraEnabled
    public String profileName;
    @AuraEnabled
    public String permissionSet;
    @AuraEnabled
    public Datetime registeredAt;
    @AuraEnabled
    public Datetime lastSignInAt;
    /** True only on the registration that just created the identity (the JIT moment). */
    @AuraEnabled
    public Boolean justProvisioned = false;
  }

  // ------------------------------------------------------------------ cbplogin.gov sign-in + JIT (mimicked)

  /** Profile and permission set JIT provisioning would assign, by demo persona (placeholders). */
  private static final String PORTAL_PROFILE = 'ACE PGA Portal User (Experience Cloud)';
  private static final Map<String, String> PERMSET_BY_PERSONA = new Map<String, String>{
    'requester' => 'ACE Portal Access - Requester',
    'supervisor' => 'ACE Portal Access - Supervisor Workspace',
    'cbpSupervisor' => 'ACE Portal Access - CBP Supervisor Workspace',
    'security' => 'ACE Portal Access - Security Workspace'
  };

  /**
   * "Has an account?" Returns the identity for this email and records the sign-in,
   * or null when the email has not registered via cbplogin.gov yet.
   */
  @AuraEnabled
  public static DemoIdentity demoSignIn(String email) {
    String key = normalizeEmail(email);
    List<ACEF_Demo_Identity__c> rows = findIdentity(key);
    if (rows.isEmpty()) {
      return null;
    }
    rows[0].ACEF_Last_Sign_In__c = System.now();
    update rows[0];
    return toIdentity(rows[0], false);
  }

  /**
   * "Register via cbplogin.gov" then first sign-in: JIT provisioning creates the portal user
   * (mimicked as a Demo Identity record) with username, federation ID, profile and permission set.
   * Registering an email that already exists just signs it in.
   */
  @AuraEnabled
  public static DemoIdentity demoRegister(String name, String email, String persona) {
    String key = normalizeEmail(email);
    if (String.isBlank(name)) {
      throw new AuraHandledException('Enter your full name to register.');
    }
    List<ACEF_Demo_Identity__c> existing = findIdentity(key);
    if (!existing.isEmpty()) {
      return demoSignIn(key);
    }
    String personaKey = PERMSET_BY_PERSONA.containsKey(persona) ? persona : 'requester';
    ACEF_Demo_Identity__c row = new ACEF_Demo_Identity__c(
      Name = name.trim().left(80),
      ACEF_Email__c = key,
      ACEF_Username__c = key + '.acepga',
      ACEF_Federation_Id__c = key,
      ACEF_Hash_Id__c = hashId(key),
      ACEF_Persona__c = personaKey,
      ACEF_Profile__c = PORTAL_PROFILE,
      ACEF_Permission_Set__c = PERMSET_BY_PERSONA.get(personaKey),
      ACEF_Registered_At__c = System.now(),
      ACEF_Last_Sign_In__c = System.now()
    );
    insert row;
    return toIdentity(row, true);
  }

  /** Demo rehearsal helper: forget this email so the registration path can be shown again. */
  @AuraEnabled
  public static void demoResetIdentity(String email) {
    delete findIdentity(normalizeEmail(email));
  }

  private static List<ACEF_Demo_Identity__c> findIdentity(String key) {
    return [
      SELECT
        Id, Name, ACEF_Email__c, ACEF_Username__c, ACEF_Federation_Id__c, ACEF_Hash_Id__c,
        ACEF_Persona__c, ACEF_Profile__c, ACEF_Permission_Set__c, ACEF_Registered_At__c, ACEF_Last_Sign_In__c
      FROM ACEF_Demo_Identity__c
      WHERE ACEF_Email__c = :key
      LIMIT 1
    ];
  }

  private static String normalizeEmail(String email) {
    String key = email == null ? '' : email.trim().toLowerCase();
    if (!Pattern.matches('[^@\\s]+@[^@\\s]+\\.[^@\\s]+', key)) {
      throw new AuraHandledException('Enter a valid email address.');
    }
    return key;
  }

  private static String hashId(String email) {
    return EncodingUtil.convertToHex(Crypto.generateDigest('SHA-256', Blob.valueOf(email))).left(16);
  }

  private static DemoIdentity toIdentity(ACEF_Demo_Identity__c row, Boolean justProvisioned) {
    DemoIdentity out = new DemoIdentity();
    out.name = row.Name;
    out.email = row.ACEF_Email__c;
    out.username = row.ACEF_Username__c;
    out.federationId = row.ACEF_Federation_Id__c;
    out.hashId = row.ACEF_Hash_Id__c;
    out.persona = row.ACEF_Persona__c;
    out.profileName = row.ACEF_Profile__c;
    out.permissionSet = row.ACEF_Permission_Set__c;
    out.registeredAt = row.ACEF_Registered_At__c;
    out.lastSignInAt = row.ACEF_Last_Sign_In__c;
    out.justProvisioned = justProvisioned;
    return out;
  }

  // ------------------------------------------------------------------ requester

  @AuraEnabled
  public static List<ACEF_Package_Review__c> listReviews() {
    return [
      SELECT Id, Name, ACEF_Requester_Name__c, ACEF_Status__c, ACEF_Submitted_At__c, CreatedDate
      FROM ACEF_Package_Review__c
      ORDER BY CreatedDate DESC
      LIMIT 20
    ];
  }

  @AuraEnabled
  public static Id startReview(String requesterName, String requesterEmail) {
    if (String.isBlank(requesterName) || String.isBlank(requesterEmail)) {
      throw new AuraHandledException('Enter the requester name and email.');
    }
    String email = requesterEmail.trim().toLowerCase();
    ACEF_Package_Review__c review = new ACEF_Package_Review__c(
      ACEF_Requester_Name__c = requesterName.trim(),
      ACEF_Requester_Email__c = email,
      ACEF_Username__c = email,
      ACEF_Hash_Id__c = EncodingUtil.convertToHex(Crypto.generateDigest('SHA-256', Blob.valueOf(email))).left(16),
      ACEF_Status__c = REVIEW_DRAFT,
      ACEF_Round__c = 0
    );
    insert review;
    return review.Id;
  }

  @AuraEnabled
  public static ReviewState getState(Id reviewId) {
    return buildState(loadReview(reviewId));
  }

  @AuraEnabled
  public static ReviewState acceptRules(Id reviewId) {
    ACEF_Package_Review__c review = loadEditable(reviewId);
    review.ACEF_Rules_Accepted__c = true;
    review.ACEF_Rules_Accepted_At__c = System.now();
    update review;
    return getState(reviewId);
  }

  /**
   * Saves the ACE PGA Application section. Systems and roles are re-checked on the server
   * with the CBPPGA-87 eligibility service, so only eligible systems can be requested.
   */
  @AuraEnabled
  public static ReviewState saveApplication(Id reviewId, String payloadJson) {
    ACEF_Package_Review__c review = loadEditable(reviewId);
    Map<String, Object> payload = (Map<String, Object>) JSON.deserializeUntyped(
      String.isBlank(payloadJson) ? '{}' : payloadJson
    );
    String deptAgency = (String) payload.get('deptAgency');
    List<String> systems = toStrings(payload.get('systems'));
    List<String> roleCodes = toStrings(payload.get('roleCodes'));
    String supervisorEmail = trimToNull((String) payload.get('supervisorEmail'));
    String cbpEmail = trimToNull((String) payload.get('cbpSupervisorEmail'));
    String phone = trimToNull((String) payload.get('phone'));
    String title = trimToNull((String) payload.get('positionTitle'));

    List<String> errors = new List<String>();
    ACEF_RoleEligibilityService.SelectionResult selection = ACEF_RoleEligibilityService.resolveSelection(
      deptAgency,
      systems,
      roleCodes
    );
    if (!selection.valid) {
      errors.addAll(selection.errors);
    }
    if (supervisorEmail == null) {
      errors.add('Enter the supervisor email.');
    }
    if (phone == null) {
      errors.add('Enter a phone number.');
    }
    if (title == null) {
      errors.add('Enter a position title.');
    }
    if (!errors.isEmpty()) {
      throw new AuraHandledException(String.join(errors, ' '));
    }

    review.ACEF_Dept_Agency__c = deptAgency;
    review.ACEF_Requested_Systems__c = String.join(selection.systems, ';');
    review.ACEF_Role_Codes__c = String.join(selection.roleCodes, ';');
    review.ACEF_Granted_Systems__c = String.join(selection.grantedSystems, ';');
    review.ACEF_Requires_Provisioning_Email__c = selection.requiresProvisioningEmail;
    review.ACEF_Supervisor_Email__c = supervisorEmail;
    review.ACEF_CBP_Supervisor_Email__c = cbpEmail;
    review.ACEF_Phone__c = phone;
    review.ACEF_Position_Title__c = title;
    review.ACEF_Gov_Employee__c = payload.get('govEmployee') == true;
    review.ACEF_Application_Complete__c = true;
    update review;
    return getState(reviewId);
  }

  /** Recent Form 7300 records the requester can attach (name only; no personal data is shown). */
  @AuraEnabled
  public static List<Option> listForm7300Options() {
    List<Option> options = new List<Option>();
    for (ACEF_CBP_Form_7300__c form : [
      SELECT Id, Name
      FROM ACEF_CBP_Form_7300__c
      ORDER BY CreatedDate DESC
      LIMIT 25
    ]) {
      Option option = new Option();
      option.value = form.Id;
      option.label = form.Name;
      options.add(option);
    }
    return options;
  }

  /**
   * Marks the Form 7300 complete. When an existing 7300 record is chosen it is linked (read-only)
   * and its supervisor emails pre-fill any blank routing emails, as in the process map.
   */
  @AuraEnabled
  public static ReviewState completeForm7300(Id reviewId, Id form7300Id) {
    ACEF_Package_Review__c review = loadEditable(reviewId);
    if (form7300Id != null) {
      ACEF_CBP_Form_7300__c form = [
        SELECT Id, ACEF_Supervisor_Email__c, ACEF_CBP_Supervisor_Email__c
        FROM ACEF_CBP_Form_7300__c
        WHERE Id = :form7300Id
      ];
      review.ACEF_Form_7300__c = form.Id;
      if (String.isBlank(review.ACEF_Supervisor_Email__c) && String.isNotBlank(form.ACEF_Supervisor_Email__c)) {
        review.ACEF_Supervisor_Email__c = form.ACEF_Supervisor_Email__c;
      }
      if (String.isBlank(review.ACEF_CBP_Supervisor_Email__c) && String.isNotBlank(form.ACEF_CBP_Supervisor_Email__c)) {
        review.ACEF_CBP_Supervisor_Email__c = form.ACEF_CBP_Supervisor_Email__c;
      }
    }
    review.ACEF_Form_7300_Complete__c = true;
    update review;
    return getState(reviewId);
  }

  /** Submit the full package: only when every form is complete and the NDA is uploaded. */
  @AuraEnabled
  public static ReviewState submit(Id reviewId) {
    ACEF_Package_Review__c review = loadEditable(reviewId);
    ReviewState current = buildState(review);
    if (!current.missing.isEmpty()) {
      throw new AuraHandledException('The package is not complete: ' + String.join(current.missing, '; ') + '.');
    }
    Integer round = (review.ACEF_Round__c == null ? 0 : review.ACEF_Round__c.intValue()) + 1;
    review.ACEF_Round__c = round;
    review.ACEF_Status__c = REVIEW_AWAITING;
    review.ACEF_Submitted_At__c = System.now();
    review.ACEF_NDA_Uploaded__c = true;
    review.ACEF_Return_Comments__c = null;
    update review;

    List<ACEF_Approval_Step__c> steps = new List<ACEF_Approval_Step__c>{
      newStep(review.Id, TYPE_SUPERVISOR, review.ACEF_Supervisor_Email__c, round)
    };
    if (String.isNotBlank(review.ACEF_CBP_Supervisor_Email__c)) {
      steps.add(newStep(review.Id, TYPE_CBP, review.ACEF_CBP_Supervisor_Email__c, round));
    }
    insert steps;
    return getState(reviewId);
  }

  // ------------------------------------------------------------------ workspaces

  /** Pending steps for one lane (Supervisor, CBP Supervisor, Vetting, Security, Provisioning), newest first. */
  @AuraEnabled
  public static List<StepItem> listPendingSteps(String stepType) {
    List<StepItem> items = new List<StepItem>();
    Set<Id> reviewIds = new Set<Id>();
    List<ACEF_Approval_Step__c> steps = [
      SELECT Id, Name, ACEF_Package_Review__c, ACEF_Step_Type__c, ACEF_Status__c, ACEF_Assignee_Email__c, ACEF_Round__c, CreatedDate
      FROM ACEF_Approval_Step__c
      WHERE ACEF_Step_Type__c = :stepType AND ACEF_Status__c = :STEP_PENDING
      ORDER BY CreatedDate DESC
      LIMIT 20
    ];
    for (ACEF_Approval_Step__c step : steps) {
      reviewIds.add(step.ACEF_Package_Review__c);
    }
    Map<Id, ACEF_Package_Review__c> reviews = loadReviews(reviewIds);
    for (ACEF_Approval_Step__c step : steps) {
      StepItem item = new StepItem();
      item.step = step;
      item.state = buildState(reviews.get(step.ACEF_Package_Review__c));
      items.add(item);
    }
    return items;
  }

  /**
   * Supervisor or CBP Supervisor decision. Approve needs the supervisor section, the typed name
   * and the attestation; Return and Reject need comments.
   */
  @AuraEnabled
  public static ReviewState decide(
    Id stepId,
    String decision,
    String signedName,
    Boolean attested,
    String sectionResponse,
    String comments
  ) {
    ACEF_Approval_Step__c step = loadPendingStep(stepId, new Set<String>{ TYPE_SUPERVISOR, TYPE_CBP });
    if (decision == STEP_APPROVED) {
      if (String.isBlank(sectionResponse) || String.isBlank(signedName) || attested != true) {
        throw new AuraHandledException(
          'To approve, complete the supervisor section, type your name and accept the attestation.'
        );
      }
    } else if (decision == STEP_RETURNED || decision == STEP_REJECTED) {
      if (String.isBlank(comments)) {
        throw new AuraHandledException('Add comments so the requester knows what to change.');
      }
    } else {
      throw new AuraHandledException('Unknown decision: ' + decision);
    }
    step.ACEF_Status__c = decision;
    step.ACEF_Signed_Name__c = trimToNull(signedName);
    step.ACEF_Attested__c = attested == true;
    step.ACEF_Section_Response__c = trimToNull(sectionResponse);
    step.ACEF_Comments__c = trimToNull(comments);
    step.ACEF_Decision_At__c = System.now();
    update step;

    ACEF_Package_Review__c review = loadReview(step.ACEF_Package_Review__c);
    Set<String> supervisorTypes = new Set<String>{ TYPE_SUPERVISOR, TYPE_CBP };
    List<ACEF_Approval_Step__c> otherPending = [
      SELECT Id
      FROM ACEF_Approval_Step__c
      WHERE
        ACEF_Package_Review__c = :review.Id
        AND ACEF_Status__c = :STEP_PENDING
        AND ACEF_Step_Type__c IN :supervisorTypes
    ];
    if (decision == STEP_RETURNED || decision == STEP_REJECTED) {
      for (ACEF_Approval_Step__c other : otherPending) {
        other.ACEF_Status__c = STEP_CANCELLED;
      }
      update otherPending;
      review.ACEF_Status__c = decision == STEP_RETURNED ? REVIEW_RETURNED : REVIEW_REJECTED;
      review.ACEF_Return_Comments__c = comments;
      update review;
    } else if (otherPending.isEmpty()) {
      // All supervisors approved: the package goes to vetting (BI) before provisioning.
      Integer round = review.ACEF_Round__c == null ? 1 : review.ACEF_Round__c.intValue();
      insert newStep(review.Id, TYPE_VETTING, VETTING_MAILBOX, round);
      review.ACEF_Status__c = REVIEW_VETTING;
      update review;
    }
    return getState(review.Id);
  }

  /**
   * Vetting team records the background investigation (BI) outcome.
   * Favorable: parallel split into Security and Provisioning (provisioning becomes available).
   * Unfavorable: the package is closed and the process ends.
   */
  @AuraEnabled
  public static ReviewState completeVetting(Id stepId, String outcome, String vetterName, String notes) {
    ACEF_Approval_Step__c step = loadPendingStep(stepId, new Set<String>{ TYPE_VETTING });
    if (outcome != BI_FAVORABLE && outcome != BI_UNFAVORABLE) {
      throw new AuraHandledException('Select the BI outcome: Favorable or Unfavorable.');
    }
    if (String.isBlank(vetterName)) {
      throw new AuraHandledException('Type your name to record the BI outcome.');
    }
    if (outcome == BI_UNFAVORABLE && String.isBlank(notes)) {
      throw new AuraHandledException('Add a note explaining the Unfavorable outcome.');
    }
    step.ACEF_Status__c = STEP_COMPLETED;
    step.ACEF_Signed_Name__c = vetterName.trim();
    step.ACEF_Attested__c = true;
    step.ACEF_Section_Response__c = 'BI outcome: ' + outcome;
    step.ACEF_Comments__c = trimToNull(notes);
    step.ACEF_Decision_At__c = System.now();
    update step;

    ACEF_Package_Review__c review = loadReview(step.ACEF_Package_Review__c);
    review.ACEF_BI_Outcome__c = outcome;
    if (outcome == BI_FAVORABLE) {
      startFulfilment(review);
    } else {
      review.ACEF_Status__c = REVIEW_UNFAVORABLE;
      review.ACEF_Completed_At__c = System.now();
      update review;
    }
    return getState(review.Id);
  }

  /** Favorable BI: parallel split into security and provisioning. */
  private static void startFulfilment(ACEF_Package_Review__c review) {
    Integer round = review.ACEF_Round__c == null ? 1 : review.ACEF_Round__c.intValue();
    String securityEmail = SECURITY_MAILBOX;
    if (review.ACEF_Form_7300__c != null) {
      ACEF_CBP_Form_7300__c form = [
        SELECT ACEF_Security_Email__c
        FROM ACEF_CBP_Form_7300__c
        WHERE Id = :review.ACEF_Form_7300__c
      ];
      if (String.isNotBlank(form.ACEF_Security_Email__c)) {
        securityEmail = form.ACEF_Security_Email__c;
      }
    }
    insert new List<ACEF_Approval_Step__c>{
      newStep(review.Id, TYPE_SECURITY, securityEmail, round),
      newStep(review.Id, TYPE_PROVISIONING, SUPPORT_MAILBOX, round)
    };
    review.ACEF_Status__c = REVIEW_FULFILMENT;
    update review;
  }

  /** Security personnel complete and submit the security section; the 7300 PDF + SharePoint step is mimicked. */
  @AuraEnabled
  public static ReviewState completeSecurity(
    Id stepId,
    String investigationType,
    String investigationStatus,
    String officerName,
    String notes,
    Boolean attested
  ) {
    ACEF_Approval_Step__c step = loadPendingStep(stepId, new Set<String>{ TYPE_SECURITY });
    if (String.isBlank(investigationType) || String.isBlank(investigationStatus) || String.isBlank(officerName) || attested != true) {
      throw new AuraHandledException(
        'Complete the investigation type and status, type your name and accept the attestation.'
      );
    }
    ACEF_Package_Review__c review = loadReview(step.ACEF_Package_Review__c);
    review.ACEF_Investigation_Type__c = investigationType;
    review.ACEF_Investigation_Status__c = investigationStatus;
    review.ACEF_Security_Officer__c = officerName.trim();
    review.ACEF_Security_Notes__c = trimToNull(notes);
    review.ACEF_Pdf_Generated_At__c = System.now();
    update review;

    step.ACEF_Status__c = STEP_COMPLETED;
    step.ACEF_Signed_Name__c = officerName.trim();
    step.ACEF_Attested__c = true;
    step.ACEF_Section_Response__c = investigationType + ' · ' + investigationStatus;
    step.ACEF_Decision_At__c = System.now();
    update step;
    joinIfDone(review.Id);
    return getState(review.Id);
  }

  /** Provisioning team: GCMC/AES email (only when needed) and the automated ACE Portal call, both mimicked. */
  @AuraEnabled
  public static ReviewState completeProvisioning(Id stepId) {
    ACEF_Approval_Step__c step = loadPendingStep(stepId, new Set<String>{ TYPE_PROVISIONING });
    ACEF_Package_Review__c review = loadReview(step.ACEF_Package_Review__c);
    if (review.ACEF_Requires_Provisioning_Email__c) {
      review.ACEF_Provisioning_Email_Sent_At__c = System.now();
    }
    review.ACEF_Provisioning_Status__c = 'Provisioned';
    review.ACEF_Provisioning_Reference__c = 'ACE-DEMO-' + String.valueOf(Crypto.getRandomInteger()).replace('-', '').left(8);
    update review;

    step.ACEF_Status__c = STEP_COMPLETED;
    step.ACEF_Section_Response__c = review.ACEF_Requires_Provisioning_Email__c
      ? 'Provisioning email sent to support mailbox; ACE Portal provisioning called.'
      : 'No GCMC/AES requested, so no email; ACE Portal provisioning called.';
    step.ACEF_Decision_At__c = System.now();
    update step;
    joinIfDone(review.Id);
    return getState(review.Id);
  }

  // ------------------------------------------------------------------ internals

  private static void joinIfDone(Id reviewId) {
    ACEF_Package_Review__c review = loadReview(reviewId);
    Integer round = review.ACEF_Round__c == null ? 1 : review.ACEF_Round__c.intValue();
    Integer done = 0;
    for (ACEF_Approval_Step__c step : [
      SELECT ACEF_Step_Type__c, ACEF_Status__c
      FROM ACEF_Approval_Step__c
      WHERE ACEF_Package_Review__c = :reviewId AND ACEF_Round__c = :round
    ]) {
      if ((step.ACEF_Step_Type__c == TYPE_SECURITY || step.ACEF_Step_Type__c == TYPE_PROVISIONING) &&
        step.ACEF_Status__c == STEP_COMPLETED) {
        done++;
      }
    }
    if (done == 2) {
      review.ACEF_Status__c = REVIEW_APPROVED;
      review.ACEF_Completed_At__c = System.now();
      update review;
    }
  }

  private static ACEF_Approval_Step__c newStep(Id reviewId, String stepType, String email, Integer round) {
    return new ACEF_Approval_Step__c(
      ACEF_Package_Review__c = reviewId,
      ACEF_Step_Type__c = stepType,
      ACEF_Status__c = STEP_PENDING,
      ACEF_Assignee_Email__c = email,
      ACEF_Round__c = round
    );
  }

  private static ACEF_Approval_Step__c loadPendingStep(Id stepId, Set<String> allowedTypes) {
    List<ACEF_Approval_Step__c> steps = [
      SELECT Id, ACEF_Package_Review__c, ACEF_Step_Type__c, ACEF_Status__c, ACEF_Round__c
      FROM ACEF_Approval_Step__c
      WHERE Id = :stepId
    ];
    if (steps.isEmpty() || !allowedTypes.contains(steps[0].ACEF_Step_Type__c)) {
      throw new AuraHandledException('This step is not available in this workspace.');
    }
    if (steps[0].ACEF_Status__c != STEP_PENDING) {
      throw new AuraHandledException('This step has already been completed.');
    }
    return steps[0];
  }

  private static ACEF_Package_Review__c loadEditable(Id reviewId) {
    ACEF_Package_Review__c review = loadReview(reviewId);
    if (review.ACEF_Status__c != REVIEW_DRAFT && review.ACEF_Status__c != REVIEW_RETURNED) {
      throw new AuraHandledException('This package has been submitted and can no longer be edited.');
    }
    return review;
  }

  private static ACEF_Package_Review__c loadReview(Id reviewId) {
    Map<Id, ACEF_Package_Review__c> reviews = loadReviews(new Set<Id>{ reviewId });
    if (!reviews.containsKey(reviewId)) {
      throw new AuraHandledException('Package not found.');
    }
    return reviews.get(reviewId);
  }

  private static Map<Id, ACEF_Package_Review__c> loadReviews(Set<Id> reviewIds) {
    return new Map<Id, ACEF_Package_Review__c>([
      SELECT
        Id, Name, ACEF_Requester_Name__c, ACEF_Requester_Email__c, ACEF_Username__c, ACEF_Hash_Id__c,
        ACEF_Phone__c, ACEF_Position_Title__c, ACEF_Gov_Employee__c, ACEF_Dept_Agency__c,
        ACEF_Requested_Systems__c, ACEF_Role_Codes__c, ACEF_Granted_Systems__c,
        ACEF_Requires_Provisioning_Email__c, ACEF_Supervisor_Email__c, ACEF_CBP_Supervisor_Email__c,
        ACEF_Rules_Accepted__c, ACEF_Rules_Accepted_At__c, ACEF_Application_Complete__c,
        ACEF_Form_7300__c, ACEF_Form_7300__r.Name, ACEF_Form_7300_Complete__c, ACEF_NDA_Uploaded__c,
        ACEF_Status__c, ACEF_Round__c, ACEF_Submitted_At__c, ACEF_Completed_At__c, ACEF_Return_Comments__c,
        ACEF_Investigation_Type__c, ACEF_Investigation_Status__c, ACEF_Security_Officer__c,
        ACEF_Security_Notes__c, ACEF_Pdf_Generated_At__c, ACEF_Provisioning_Email_Sent_At__c,
        ACEF_Provisioning_Status__c, ACEF_Provisioning_Reference__c, ACEF_BI_Outcome__c, CreatedDate
      FROM ACEF_Package_Review__c
      WHERE Id IN :reviewIds
    ]);
  }

  @TestVisible
  private static ReviewState buildState(ACEF_Package_Review__c review) {
    ReviewState state = new ReviewState();
    state.review = review;
    state.editable = review.ACEF_Status__c == REVIEW_DRAFT || review.ACEF_Status__c == REVIEW_RETURNED;
    state.steps = [
      SELECT
        Id, Name, ACEF_Step_Type__c, ACEF_Status__c, ACEF_Assignee_Email__c, ACEF_Round__c,
        ACEF_Signed_Name__c, ACEF_Attested__c, ACEF_Section_Response__c, ACEF_Comments__c,
        ACEF_Decision_At__c, CreatedDate
      FROM ACEF_Approval_Step__c
      WHERE ACEF_Package_Review__c = :review.Id
      ORDER BY CreatedDate ASC, Name ASC
    ];
    List<ContentDocumentLink> files = [
      SELECT ContentDocument.Title, ContentDocument.FileExtension
      FROM ContentDocumentLink
      WHERE LinkedEntityId = :review.Id
      ORDER BY SystemModstamp DESC
      LIMIT 1
    ];
    if (!files.isEmpty()) {
      state.ndaFileName = files[0].ContentDocument.Title +
        (String.isBlank(files[0].ContentDocument.FileExtension) ? '' : '.' + files[0].ContentDocument.FileExtension);
    }
    if (!review.ACEF_Rules_Accepted__c) {
      state.missing.add('Accept the Rules of Behavior');
    }
    if (!review.ACEF_Application_Complete__c) {
      state.missing.add('Complete the ACE PGA Application');
    }
    if (!review.ACEF_Form_7300_Complete__c) {
      state.missing.add('Complete the CBP Form 7300');
    }
    if (state.ndaFileName == null) {
      state.missing.add('Upload the signed NDA PDF');
    }
    state.deptAgencyLabel = picklistLabel(review.ACEF_Dept_Agency__c);
    state.requestedSystemsLabel = systemLabels(review.ACEF_Requested_Systems__c);
    if (review.ACEF_Form_7300__c != null) {
      state.pdfUrl = '/apex/ACEF_CbpForm7300OfficialPdf?id=' + review.ACEF_Form_7300__c;
    }
    for (ACEF_Approval_Step__c step : state.steps) {
      if ((step.ACEF_Step_Type__c == TYPE_SUPERVISOR || step.ACEF_Step_Type__c == TYPE_CBP) &&
        step.ACEF_Round__c == review.ACEF_Round__c) {
        state.callToActionEmails.add(callToAction(review, step, state));
      }
    }
    if (review.ACEF_Requires_Provisioning_Email__c) {
      state.provisioningEmail = provisioningEmail(review, state);
    }
    return state;
  }

  private static EmailPreview callToAction(ACEF_Package_Review__c review, ACEF_Approval_Step__c step, ReviewState state) {
    EmailPreview email = new EmailPreview();
    email.toAddress = step.ACEF_Assignee_Email__c;
    email.stepType = step.ACEF_Step_Type__c;
    email.stepId = step.Id;
    email.subject = 'Action needed: review ACE PGA package ' + review.Name + ' for ' + review.ACEF_Requester_Name__c;
    email.body =
      'Hello,\n\n' + review.ACEF_Requester_Name__c + ' (' + review.ACEF_Requester_Email__c + ') submitted an ACE PGA access package and listed you as ' +
      (step.ACEF_Step_Type__c == TYPE_CBP ? 'CBP supervisor' : 'supervisor') + '.\n\n' +
      'Agency: ' + nullToDash(state.deptAgencyLabel) + '\nPosition title: ' + nullToDash(review.ACEF_Position_Title__c) +
      '\nRequested systems: ' + nullToDash(state.requestedSystemsLabel) + '\n\n' +
      'Click the link below and sign in with cbplogin.gov (first time? you will be asked to register) to open your ' +
      (step.ACEF_Step_Type__c == TYPE_CBP ? 'CBP Supervisor' : 'Supervisor') +
      ' Workspace, review the CBP Form 7300 and the ACE PGA Application, complete your section and approve.\n\n' +
      '[Open ' + (step.ACEF_Step_Type__c == TYPE_CBP ? 'CBP Supervisor' : 'Supervisor') + ' Workspace]';
    return email;
  }

  private static EmailPreview provisioningEmail(ACEF_Package_Review__c review, ReviewState state) {
    EmailPreview email = new EmailPreview();
    email.toAddress = SUPPORT_MAILBOX;
    email.subject = 'ACE PGA provisioning request (GCMC/AES): ' + review.ACEF_Username__c;
    email.body =
      'Username: ' + nullToDash(review.ACEF_Username__c) +
      '\nHash ID: ' + nullToDash(review.ACEF_Hash_Id__c) +
      '\nPhone number: ' + nullToDash(review.ACEF_Phone__c) +
      '\nEmail address: ' + nullToDash(review.ACEF_Requester_Email__c) +
      '\nSupervisor email address: ' + nullToDash(review.ACEF_Supervisor_Email__c) +
      '\nGovernment employee: ' + (review.ACEF_Gov_Employee__c ? 'Yes' : 'No') +
      '\nAgency: ' + nullToDash(state.deptAgencyLabel) +
      '\nPosition title: ' + nullToDash(review.ACEF_Position_Title__c) +
      '\nRequested system(s): ' + nullToDash(systemLabels(review.ACEF_Granted_Systems__c));
    return email;
  }

  private static String picklistLabel(String value) {
    if (String.isBlank(value)) {
      return null;
    }
    for (Schema.PicklistEntry entry : ACEF_Package_Review__c.ACEF_Dept_Agency__c.getDescribe().getPicklistValues()) {
      if (entry.getValue() == value) {
        return entry.getLabel();
      }
    }
    return value;
  }

  private static String systemLabels(String values) {
    if (String.isBlank(values)) {
      return null;
    }
    Map<String, String> labels = new Map<String, String>();
    for (Schema.PicklistEntry entry : ACEF_System_Role_Mapping__c.ACEF_System__c.getDescribe().getPicklistValues()) {
      labels.put(entry.getValue(), entry.getLabel());
    }
    List<String> out = new List<String>();
    for (String value : values.split(';')) {
      out.add(labels.containsKey(value) ? labels.get(value) : value);
    }
    return String.join(out, ', ');
  }

  private static List<String> toStrings(Object raw) {
    List<String> out = new List<String>();
    if (raw instanceof List<Object>) {
      for (Object item : (List<Object>) raw) {
        if (item != null) {
          out.add(String.valueOf(item));
        }
      }
    }
    return out;
  }

  private static String trimToNull(String value) {
    return String.isBlank(value) ? null : value.trim();
  }

  private static String nullToDash(String value) {
    return String.isBlank(value) ? '—' : value;
  }
}