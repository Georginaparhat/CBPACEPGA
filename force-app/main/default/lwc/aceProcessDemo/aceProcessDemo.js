import { LightningElement, api, wire } from "lwc";
import { ShowToastEvent } from "lightning/platformShowToastEvent";
import { NavigationMixin, CurrentPageReference } from "lightning/navigation";
import demoSignIn from "@salesforce/apex/ACEF_ProcessDemoService.demoSignIn";
import demoRegister from "@salesforce/apex/ACEF_ProcessDemoService.demoRegister";
import demoResetIdentity from "@salesforce/apex/ACEF_ProcessDemoService.demoResetIdentity";
import listReviews from "@salesforce/apex/ACEF_ProcessDemoService.listReviews";
import startReview from "@salesforce/apex/ACEF_ProcessDemoService.startReview";
import getState from "@salesforce/apex/ACEF_ProcessDemoService.getState";
import acceptRules from "@salesforce/apex/ACEF_ProcessDemoService.acceptRules";
import saveApplication from "@salesforce/apex/ACEF_ProcessDemoService.saveApplication";
import listForm7300Options from "@salesforce/apex/ACEF_ProcessDemoService.listForm7300Options";
import completeForm7300 from "@salesforce/apex/ACEF_ProcessDemoService.completeForm7300";
import findForm7300ByConfirmation from "@salesforce/apex/ACEF_CbpForm7300ProgressService.findIdByConfirmation";
import submit from "@salesforce/apex/ACEF_ProcessDemoService.submit";
import listPendingSteps from "@salesforce/apex/ACEF_ProcessDemoService.listPendingSteps";
import decide from "@salesforce/apex/ACEF_ProcessDemoService.decide";
import completeSecurity from "@salesforce/apex/ACEF_ProcessDemoService.completeSecurity";
import completeProvisioning from "@salesforce/apex/ACEF_ProcessDemoService.completeProvisioning";
import completeVetting from "@salesforce/apex/ACEF_ProcessDemoService.completeVetting";
import RulesOfBehaviorModal from "c/aceRulesOfBehaviorModal";

/**
 * ACE PGA process demo. One component, one view per actor lane of the User Experience
 * Process Map, chosen by the `persona` property on each demo page:
 * requester | supervisor | cbpSupervisor | security | provisioning | overview.
 *
 * cbplogin.gov sign-in and JIT provisioning are mimicked: personas with signIn=true see a
 * cbplogin.gov screen first ("Has an account?"). An unknown email goes through
 * "Register via cbplogin.gov", then the JIT step shows the portal user that first sign-in creates
 * (ACEF_Demo_Identity__c). Workspaces then list only the steps routed to the signed-in email.
 * Call-to-action email links open the right workspace tab with c__email and c__step.
 */
const PERSONAS = {
  requester: { name: "Riley Requester", role: "Requester (PGA employee)", stepType: null, signIn: true, defaultEmail: "riley.requester@agency.example.gov" },
  supervisor: { name: "Sam Supervisor", role: "7300 Supervisor", stepType: "Supervisor", signIn: true, defaultEmail: "sam.supervisor@agency.example.gov" },
  cbpSupervisor: { name: "Casey CBP", role: "CBP Supervisor (optional path)", stepType: "CBP Supervisor", signIn: true, defaultEmail: "casey.cbp@cbp.example.gov" },
  security: { name: "Pat Security", role: "Security Personnel", stepType: "Security", signIn: true, defaultEmail: "security-office@example.gov" },
  vetting: { name: "CBP Vetting Team", role: "Vetting (background investigation)", stepType: "Vetting", signIn: false },
  provisioning: { name: "ACE PGA Provisioning Team", role: "Provisioning", stepType: "Provisioning", signIn: false },
  overview: { name: "Process owner", role: "Package tracker", stepType: null, signIn: false }
};

/** Demo tab that each call-to-action link opens. */
const WORKSPACE_TAB = {
  Supervisor: "ACEF_Demo_2_Supervisor",
  "CBP Supervisor": "ACEF_Demo_3_CBP_Supervisor"
};

const STORAGE_PREFIX = "acepgaDemoIdentity:";
const UNFAVORABLE_STATUS = "Closed - Unfavorable BI";
const RULES_REJECTED_MESSAGE = "You must accept the Rules of Behavior to continue.";

const PATH = [
  { value: "Draft", label: "Complete & submit" },
  { value: "Awaiting Supervisors", label: "Supervisor approval" },
  { value: "Vetting", label: "Vetting (BI)" },
  { value: "Security & Provisioning", label: "Security & provisioning" },
  { value: "Approved", label: "Approved" }
];

export default class AceProcessDemo extends NavigationMixin(LightningElement) {
  @api persona = "requester";

  // cbplogin.gov mimic
  identity;
  pendingIdentity;
  signInStage = "email";
  signInEmail = "";
  signInName = "";
  mfaDone = false;
  linkEmail;
  linkStepId;
  allSteps = [];

  reviews = [];
  reviewId;
  state;
  loading = false;
  pickerSelection;
  pickerValue;
  form7300Options = [];
  form7300Id;
  form7300JustSubmitted = false;
  newName = "Riley Requester";
  newEmail = "riley.requester@agency.example.gov";
  app = { phone: "", positionTitle: "", govEmployee: true, supervisorEmail: "", cbpSupervisorEmail: "" };

  steps = [];
  selectedStepId;
  decision = { section: "", signedName: "", attested: false, comments: "" };
  security = { investigationType: "", investigationStatus: "", officerName: "", notes: "", attested: false };
  vetting = { outcome: "", vetterName: "", notes: "" };
  rulesError;
  biOutcomeOptions = [
    { label: "Favorable", value: "Favorable" },
    { label: "Unfavorable", value: "Unfavorable" }
  ];

  connectedCallback() {
    this.identity = this.loadStoredIdentity();
    if (!this.identity && this.isRequester) {
      this.signInEmail = this.personaInfo.defaultEmail;
    }
    if (this.identity && this.isRequester) {
      this.newName = this.identity.name;
      this.newEmail = this.identity.email;
    }
    this.refresh();
  }

  /** Call-to-action link: ?c__email=…&c__step=… opens this workspace for that recipient and step. */
  @wire(CurrentPageReference)
  handlePageReference(ref) {
    const state = (ref && ref.state) || {};
    const email = state.c__email ? String(state.c__email).toLowerCase() : undefined;
    const step = state.c__step;
    if (email === this.linkEmail && step === this.linkStepId) {
      return;
    }
    this.linkEmail = email;
    this.linkStepId = step;
    if (!email) {
      return;
    }
    if (this.identity && this.identity.email !== email) {
      // The link is for someone else: they must sign in as the recipient.
      this.signOut();
    }
    if (!this.identity) {
      this.signInEmail = email;
      this.signInStage = "email";
    }
    this.refresh();
  }

  // ---------------------------------------------------------------- cbplogin.gov sign-in + JIT (mimicked)

  get needsSignIn() {
    return this.personaInfo.signIn === true;
  }
  get showSignIn() {
    return this.needsSignIn && !this.identity;
  }
  get showContent() {
    return !this.showSignIn;
  }
  get isStageEmail() {
    return this.signInStage === "email";
  }
  get isStageRegister() {
    return this.signInStage === "register";
  }
  get isStageProvisioned() {
    return this.signInStage === "provisioned";
  }
  get signInPrompt() {
    if (this.linkEmail) {
      return `You opened a call-to-action link sent to ${this.linkEmail}. Sign in with that cbplogin.gov account to open the ${this.personaInfo.role} workspace.`;
    }
    return this.isRequester
      ? "Visit the ACE PGA Package Submission Portal. Sign in with your cbplogin.gov account to open your Requester Workspace."
      : `Sign in with your cbplogin.gov account to open the ${this.personaInfo.role} workspace.`;
  }
  get displayName() {
    return this.identity ? this.identity.name : this.personaInfo.name;
  }
  get jitDetails() {
    const i = this.pendingIdentity;
    if (!i) {
      return [];
    }
    return [
      { label: "Salesforce username", value: i.username },
      { label: "Federation ID (from cbplogin.gov)", value: i.federationId },
      { label: "Hash ID", value: i.hashId },
      { label: "Profile", value: i.profileName },
      { label: "Permission set", value: i.permissionSet },
      { label: "Registered", value: i.registeredAt ? new Date(i.registeredAt).toLocaleString() : "—" }
    ];
  }
  get continueLabel() {
    return `Continue to ${this.isRequester ? "Requester Workspace" : this.personaInfo.role + " workspace"}`;
  }

  handleSignInEmail(event) {
    this.signInEmail = event.target.value;
  }
  handleSignInName(event) {
    this.signInName = event.target.value;
  }
  handleMfa(event) {
    this.mfaDone = event.target.checked;
  }
  async handleSignInContinue() {
    await this.run(async () => {
      const found = await demoSignIn({ email: this.signInEmail });
      if (found) {
        this.setIdentity(found);
        this.toast("Signed in via cbplogin.gov", `Account found for ${found.email}.`, "success");
      } else {
        this.signInStage = "register";
        this.signInName = this.signInName || this.personaInfo.name;
        this.mfaDone = false;
      }
    });
  }
  async handleRegister() {
    if (!this.mfaDone) {
      this.toast("Finish cbplogin.gov registration", "Confirm the email verification and multi-factor authentication step.", "warning");
      return;
    }
    await this.run(async () => {
      this.pendingIdentity = await demoRegister({ name: this.signInName, email: this.signInEmail, persona: this.persona });
      this.signInStage = "provisioned";
    }, "Registered via cbplogin.gov");
  }
  handleBackToEmail() {
    this.signInStage = "email";
  }
  handleEnterWorkspace() {
    this.setIdentity(this.pendingIdentity);
  }
  async handleResetIdentity() {
    await this.run(async () => demoResetIdentity({ email: this.signInEmail }), `Demo account for ${this.signInEmail} removed. Continue to show registration.`);
  }
  handleSignOut() {
    this.signOut();
    this.signInEmail = this.linkEmail || this.defaultSignInEmail();
    this.refresh();
  }

  setIdentity(identity) {
    this.identity = identity;
    this.pendingIdentity = undefined;
    this.signInStage = "email";
    try {
      window.sessionStorage.setItem(STORAGE_PREFIX + this.persona, JSON.stringify(identity));
    } catch {
      // Storage unavailable: the sign-in lasts until the page reloads.
    }
    if (this.isRequester) {
      this.newName = identity.name;
      this.newEmail = identity.email;
    }
    this.selectedStepId = undefined;
    this.refresh();
  }

  signOut() {
    this.identity = undefined;
    this.pendingIdentity = undefined;
    this.signInStage = "email";
    try {
      window.sessionStorage.removeItem(STORAGE_PREFIX + this.persona);
    } catch {
      // ignore
    }
  }

  loadStoredIdentity() {
    try {
      const raw = window.sessionStorage.getItem(STORAGE_PREFIX + this.persona);
      return raw ? JSON.parse(raw) : undefined;
    } catch {
      return undefined;
    }
  }

  defaultSignInEmail() {
    const waiting = this.allSteps.find((item) => item.step.ACEF_Assignee_Email__c);
    return (waiting && waiting.step.ACEF_Assignee_Email__c) || this.personaInfo.defaultEmail || "";
  }

  /** Call-to-action link in the requester's sent emails: opens the recipient's workspace tab. */
  handleOpenLink(event) {
    const { email, step, type } = event.target.dataset;
    const apiName = WORKSPACE_TAB[type];
    if (!apiName) {
      return;
    }
    this[NavigationMixin.Navigate]({
      type: "standard__navItemPage",
      attributes: { apiName },
      state: { c__email: email, c__step: step }
    });
  }

  // ---------------------------------------------------------------- persona & view flags

  get personaInfo() {
    return PERSONAS[this.persona] || PERSONAS.requester;
  }
  get isRequester() {
    return this.persona === "requester";
  }
  get isApprover() {
    return this.persona === "supervisor" || this.persona === "cbpSupervisor";
  }
  get isSecurity() {
    return this.persona === "security";
  }
  get isProvisioning() {
    return this.persona === "provisioning";
  }
  get isVetting() {
    return this.persona === "vetting";
  }
  get isOverview() {
    return this.persona === "overview";
  }
  get isWorkspace() {
    return this.isApprover || this.isVetting || this.isSecurity || this.isProvisioning;
  }
  get bannerText() {
    const p = this.personaInfo;
    if (!this.needsSignIn) {
      return `${p.name} · ${p.role}`;
    }
    return this.identity
      ? `Signed in via cbplogin.gov as ${this.identity.name} (${this.identity.email}) · ${p.role}`
      : `Not signed in · ${p.role}`;
  }
  get showSignOut() {
    return this.needsSignIn && !!this.identity;
  }

  // ---------------------------------------------------------------- data loading

  async refresh() {
    this.loading = true;
    try {
      if (this.isRequester || this.isOverview) {
        this.reviews = await listReviews();
        if (!this.reviewId && this.reviews.length) {
          this.reviewId = this.reviews[0].Id;
        }
        if (this.isRequester) {
          this.form7300Options = await listForm7300Options();
        }
        await this.loadState();
      } else {
        this.allSteps = await listPendingSteps({ stepType: this.personaInfo.stepType });
        // Only what was routed to the signed-in person (email match, case-insensitive).
        const me = this.identity && this.identity.email;
        this.steps =
          this.needsSignIn && me
            ? this.allSteps.filter((item) => (item.step.ACEF_Assignee_Email__c || "").toLowerCase() === me)
            : this.needsSignIn
              ? []
              : this.allSteps;
        if (this.showSignIn && !this.signInEmail) {
          this.signInEmail = this.linkEmail || this.defaultSignInEmail();
        }
        if (this.linkStepId && this.steps.some((item) => item.step.Id === this.linkStepId)) {
          if (this.selectedStepId !== this.linkStepId) {
            this.selectedStepId = this.linkStepId;
            this.resetForms();
          }
        } else if (!this.steps.some((item) => item.step.Id === this.selectedStepId)) {
          this.selectedStepId = this.steps.length ? this.steps[0].step.Id : undefined;
          this.resetForms();
        }
      }
    } catch (error) {
      this.toast("Something went wrong", reduceError(error), "error");
    } finally {
      this.loading = false;
    }
  }

  async loadState() {
    if (!this.reviewId) {
      this.state = undefined;
      return;
    }
    this.applyState(await getState({ reviewId: this.reviewId }));
  }

  applyState(state) {
    this.state = state;
    const r = state.review;
    this.app = {
      phone: r.ACEF_Phone__c || "",
      positionTitle: r.ACEF_Position_Title__c || "",
      govEmployee: r.ACEF_Gov_Employee__c !== false,
      supervisorEmail: r.ACEF_Supervisor_Email__c || "",
      cbpSupervisorEmail: r.ACEF_CBP_Supervisor_Email__c || ""
    };
    this.form7300Id = r.ACEF_Form_7300__c;
    if (r.ACEF_Dept_Agency__c) {
      this.pickerValue = {
        deptAgency: r.ACEF_Dept_Agency__c,
        systems: split(r.ACEF_Requested_Systems__c),
        roleCodes: split(r.ACEF_Role_Codes__c)
      };
    } else {
      this.pickerValue = undefined;
    }
  }

  resetForms() {
    this.decision = { section: "", signedName: this.displayName, attested: false, comments: "" };
    this.security = { investigationType: "", investigationStatus: "", officerName: this.displayName, notes: "", attested: false };
    this.vetting = { outcome: "", vetterName: this.displayName, notes: "" };
  }

  // ---------------------------------------------------------------- shared view data

  get review() {
    return this.state && this.state.review;
  }
  get reviewOptions() {
    return this.reviews.map((r) => ({
      label: `${r.Name} · ${r.ACEF_Requester_Name__c || ""} · ${r.ACEF_Status__c}`,
      value: r.Id
    }));
  }
  get pathSteps() {
    return PATH;
  }
  get currentPathStep() {
    const status = this.activeReview && this.activeReview.ACEF_Status__c;
    if (status === "Returned for Information" || status === "Rejected") {
      return "Awaiting Supervisors";
    }
    if (status === UNFAVORABLE_STATUS) {
      return "Vetting";
    }
    return status || "Draft";
  }
  get pathHasError() {
    const status = this.activeReview && this.activeReview.ACEF_Status__c;
    return status === "Returned for Information" || status === "Rejected" || status === UNFAVORABLE_STATUS;
  }
  get activeState() {
    if (this.isWorkspace) {
      const item = this.steps.find((s) => s.step.Id === this.selectedStepId);
      return item ? item.state : undefined;
    }
    return this.state;
  }
  get activeReview() {
    return this.activeState && this.activeState.review;
  }
  get statusBanner() {
    const r = this.activeReview;
    if (!r) {
      return undefined;
    }
    if (r.ACEF_Status__c === "Returned for Information") {
      return { css: "demo__notice demo__notice_warn", text: `Returned for more information: ${r.ACEF_Return_Comments__c || ""}` };
    }
    if (r.ACEF_Status__c === "Rejected") {
      return { css: "demo__notice demo__notice_error", text: `Rejected: ${r.ACEF_Return_Comments__c || ""}` };
    }
    if (r.ACEF_Status__c === "Approved") {
      return { css: "demo__notice demo__notice_ok", text: "Package approved, recorded and routed. Both fulfilment branches are complete." };
    }
    return undefined;
  }
  get summary() {
    const s = this.activeState;
    if (!s) {
      return [];
    }
    const r = s.review;
    return [
      { label: "Package", value: `${r.Name} · ${r.ACEF_Status__c}` },
      { label: "Requester", value: `${r.ACEF_Requester_Name__c || "—"} (${r.ACEF_Requester_Email__c || "—"})` },
      { label: "Department / Agency", value: s.deptAgencyLabel || "—" },
      { label: "Position title", value: r.ACEF_Position_Title__c || "—" },
      { label: "Requested systems", value: s.requestedSystemsLabel || "—" },
      { label: "Role codes (resolved on server)", value: (r.ACEF_Role_Codes__c || "—").split(";").join(", ") },
      { label: "Supervisor", value: r.ACEF_Supervisor_Email__c || "—" },
      { label: "CBP supervisor", value: r.ACEF_CBP_Supervisor_Email__c || "Not provided (no CBP approval needed)" },
      { label: "CBP Form 7300", value: r.ACEF_Form_7300__r ? r.ACEF_Form_7300__r.Name : r.ACEF_Form_7300_Complete__c ? "Completed" : "—" },
      { label: "NDA", value: s.ndaFileName || "—" }
    ];
  }
  get timeline() {
    const s = this.activeState;
    if (!s) {
      return [];
    }
    return s.steps.map((step) => ({
      id: step.Id,
      title: `${step.ACEF_Step_Type__c} · round ${step.ACEF_Round__c || 1}`,
      status: step.ACEF_Status__c,
      badge: badgeClass(step.ACEF_Status__c),
      who: step.ACEF_Assignee_Email__c,
      detail: [
        step.ACEF_Signed_Name__c ? `Signed: ${step.ACEF_Signed_Name__c}` : null,
        step.ACEF_Section_Response__c,
        step.ACEF_Comments__c ? `Comments: ${step.ACEF_Comments__c}` : null
      ]
        .filter(Boolean)
        .join(" · ")
    }));
  }
  get hasTimeline() {
    return this.timeline.length > 0;
  }
  get pdfUrl() {
    return this.activeState && this.activeState.pdfUrl;
  }

  // ---------------------------------------------------------------- requester

  get checklist() {
    const r = this.review;
    if (!r) {
      return [];
    }
    return [
      { key: "rules", label: "Rules of Behavior", done: r.ACEF_Rules_Accepted__c },
      { key: "app", label: "ACE PGA Application", done: r.ACEF_Application_Complete__c },
      { key: "7300", label: "CBP Form 7300", done: r.ACEF_Form_7300_Complete__c },
      { key: "nda", label: "NDA PDF upload", done: !!this.state.ndaFileName }
    ].map((item) => ({ ...item, icon: item.done ? "utility:success" : "utility:routing_offline", variant: item.done ? "success" : "" }));
  }
  get editable() {
    return this.state && this.state.editable;
  }
  get locked() {
    return !this.editable;
  }
  get submitDisabled() {
    return !this.editable || (this.state && this.state.missing.length > 0);
  }
  get missingText() {
    return this.state && this.state.missing.length ? `Still needed: ${this.state.missing.join(" · ")}` : "Everything is complete. You can submit the package.";
  }
  get rulesAccepted() {
    return this.review && this.review.ACEF_Rules_Accepted__c;
  }
  get rulesButtonLabel() {
    return this.rulesAccepted ? "Rules of Behavior accepted" : "I accept the Rules of Behavior";
  }
  get rulesButtonDisabled() {
    return this.locked || this.rulesAccepted;
  }
  get callToActionEmails() {
    return ((this.state && this.state.callToActionEmails) || []).map((e) => ({
      ...e,
      key: e.stepId || e.toAddress,
      hasLink: !!WORKSPACE_TAB[e.stepType],
      linkLabel: `Open ${e.stepType} Workspace (call-to-action link)`
    }));
  }
  get hasCallToAction() {
    return this.callToActionEmails.length > 0 && this.review && this.review.ACEF_Status__c !== "Draft";
  }
  get form7300Label() {
    const r = this.review;
    return r && r.ACEF_Form_7300__r ? `Linked: ${r.ACEF_Form_7300__r.Name}` : r && r.ACEF_Form_7300_Complete__c ? "Marked complete" : "Not complete";
  }

  handleReviewChange(event) {
    this.reviewId = event.detail.value;
    this.rulesError = undefined;
    this.form7300JustSubmitted = false;
    this.pickerSelection = undefined;
    this.loadState().catch((error) => this.toast("Could not load", reduceError(error), "error"));
  }
  handleNewName(event) {
    this.newName = event.target.value;
  }
  handleNewEmail(event) {
    this.newEmail = event.target.value;
  }
  async handleStart() {
    await this.run(async () => {
      this.form7300JustSubmitted = false;
      this.reviewId = await startReview({ requesterName: this.newName, requesterEmail: this.newEmail });
      this.pickerSelection = undefined;
      await this.refresh();
    }, "New package started");
  }
  /** Rules of Behavior pop-up: Accept records acceptance; Reject shows that acceptance is required. */
  async handleAcceptRules() {
    const result = await RulesOfBehaviorModal.open({ size: "large", label: "Rules of Behavior" });
    if (result === "accept") {
      this.rulesError = undefined;
      await this.run(async () => this.applyState(await acceptRules({ reviewId: this.reviewId })), "Rules of Behavior accepted");
    } else if (result === "reject") {
      this.rulesError = RULES_REJECTED_MESSAGE;
    }
  }
  handlePickerChange(event) {
    // Inner checkbox/combobox change events also bubble out of the picker; keep only the picker's own.
    if (event.detail && Object.prototype.hasOwnProperty.call(event.detail, "deptAgency")) {
      this.pickerSelection = event.detail;
    }
  }
  handleAppField(event) {
    const field = event.target.dataset.field;
    const value = event.target.type === "checkbox" ? event.target.checked : event.target.value;
    this.app = { ...this.app, [field]: value };
  }
  async handleSaveApplication() {
    const picker = this.template.querySelector("c-ace-pga-system-picker");
    const check = picker ? picker.validate() : { isValid: true, errors: [] };
    if (!check.isValid) {
      this.toast("Check the application", check.errors.join(" "), "warning");
      return;
    }
    const selection = (picker ? picker.value : this.pickerSelection) || {};
    const payload = { ...this.app, deptAgency: selection.deptAgency, systems: selection.systems || [], roleCodes: selection.roleCodes || [] };
    await this.run(
      async () => this.applyState(await saveApplication({ reviewId: this.reviewId, payloadJson: JSON.stringify(payload) })),
      "Application saved and checked against the role map"
    );
  }
  handleForm7300Change(event) {
    this.form7300Id = event.detail.value;
  }

  /** Form 7300 Test 2 stays on screen until it is complete, and right after submit so its confirmation shows. */
  get showForm7300() {
    const r = this.review;
    return !this.locked && (!(r && r.ACEF_Form_7300_Complete__c) || this.form7300JustSubmitted);
  }

  /** Prefill Form 7300 Test 2 from what the requester already gave (no personal data is invented). */
  get form7300Prefill() {
    const name = (this.identity && this.identity.name) || this.newName || "";
    const parts = name.trim().split(/\s+/);
    const lastName = parts.length > 1 ? parts.pop() : "";
    return {
      firstName: parts.join(" "),
      lastName,
      homeAgencyEmail: (this.identity && this.identity.email) || this.newEmail || "",
      cellPhone: this.app.phone || "",
      supervisorEmail: this.app.supervisorEmail || "",
      cbpSupervisorApplies: Boolean(this.app.cbpSupervisorEmail),
      cbpSupervisorEmail: this.app.cbpSupervisorEmail || ""
    };
  }

  /** Form 7300 Test 2 submitted: link the new 7300 record to this package and mark the step complete. */
  async handleForm7300Submitted(event) {
    const confirmationNumber = event.detail && event.detail.confirmationNumber;
    this.form7300JustSubmitted = true;
    await this.run(async () => {
      const form7300Id = confirmationNumber ? await findForm7300ByConfirmation({ confirmationNumber }) : null;
      this.applyState(await completeForm7300({ reviewId: this.reviewId, form7300Id: form7300Id || null }));
    }, confirmationNumber ? `Form 7300 ${confirmationNumber} submitted and linked to this package` : "CBP Form 7300 complete");
  }
  async handleComplete7300() {
    await this.run(
      async () => this.applyState(await completeForm7300({ reviewId: this.reviewId, form7300Id: this.form7300Id || null })),
      "CBP Form 7300 complete"
    );
  }
  async handleUploadFinished() {
    await this.run(async () => this.loadState(), "NDA uploaded");
  }
  async handleSubmit() {
    await this.run(async () => {
      this.applyState(await submit({ reviewId: this.reviewId }));
      this.reviews = await listReviews();
    }, "Package submitted. Call-to-action emails sent to the supervisor(s).");
  }

  // ---------------------------------------------------------------- workspaces

  get stepOptions() {
    return this.steps.map((item) => ({
      label: `${item.state.review.Name} · ${item.state.review.ACEF_Requester_Name__c} · round ${item.step.ACEF_Round__c || 1}`,
      value: item.step.Id
    }));
  }
  get hasSteps() {
    return this.steps.length > 0;
  }
  get noStepsText() {
    const others = [...new Set(this.allSteps.map((item) => item.step.ACEF_Assignee_Email__c).filter(Boolean))];
    if (this.identity && others.length) {
      return `Nothing routed to ${this.identity.email}. Waiting in this lane for: ${others.join(", ")}. Sign out and sign in as that person, or open the link from their email.`;
    }
    return `Nothing waiting for ${this.personaInfo.role}. Submit a package as the requester, or approve the earlier step first.`;
  }
  get myEmail() {
    const s = this.activeState;
    if (!s) {
      return undefined;
    }
    return (s.callToActionEmails || []).find((e) => {
      const step = this.steps.find((item) => item.step.Id === this.selectedStepId);
      return step && e.toAddress === step.step.ACEF_Assignee_Email__c;
    });
  }
  get provisioningEmail() {
    return this.activeState && this.activeState.provisioningEmail;
  }
  get noProvisioningEmail() {
    return this.activeState && !this.activeState.provisioningEmail;
  }
  get investigationTypes() {
    return ["Tier 1", "Tier 2", "Tier 3", "Tier 4", "Tier 5"].map((v) => ({ label: v, value: v }));
  }
  get investigationStatuses() {
    return ["Favorable", "Pending", "Unfavorable"].map((v) => ({ label: v, value: v }));
  }
  get sectionLabel() {
    return this.persona === "cbpSupervisor" ? "CBP supervisor section: confirm the CBP sponsorship" : "Supervisor section (Form 7300): justify the access request";
  }

  handleStepChange(event) {
    this.selectedStepId = event.detail.value;
    this.resetForms();
  }
  handleDecisionField(event) {
    const field = event.target.dataset.field;
    const value = event.target.type === "checkbox" ? event.target.checked : event.target.value;
    this.decision = { ...this.decision, [field]: value };
  }
  handleSecurityField(event) {
    const field = event.target.dataset.field;
    const value = event.target.type === "checkbox" ? event.target.checked : event.detail ? event.detail.value : event.target.value;
    this.security = { ...this.security, [field]: value };
  }
  async handleDecision(event) {
    const decision = event.target.dataset.decision;
    const d = this.decision;
    const messages = {
      Approved: "Approved and signed",
      Returned: "Returned to the requester for more information",
      Rejected: "Package rejected"
    };
    await this.run(async () => {
      await decide({
        stepId: this.selectedStepId,
        decision,
        signedName: d.signedName,
        attested: d.attested,
        sectionResponse: d.section,
        comments: d.comments
      });
      this.selectedStepId = undefined;
      await this.refresh();
    }, messages[decision]);
  }
  async handleSecuritySubmit() {
    const s = this.security;
    await this.run(async () => {
      await completeSecurity({
        stepId: this.selectedStepId,
        investigationType: s.investigationType,
        investigationStatus: s.investigationStatus,
        officerName: s.officerName,
        notes: s.notes,
        attested: s.attested
      });
      this.selectedStepId = undefined;
      await this.refresh();
    }, "Security section submitted. 7300 record saved, PDF generated and SharePoint item created.");
  }
  handleVettingField(event) {
    const field = event.target.dataset.field;
    const value = event.detail ? event.detail.value : event.target.value;
    this.vetting = { ...this.vetting, [field]: value };
  }
  async handleVettingSubmit() {
    const v = this.vetting;
    await this.run(async () => {
      await completeVetting({
        stepId: this.selectedStepId,
        outcome: v.outcome,
        vetterName: v.vetterName,
        notes: v.notes
      });
      this.selectedStepId = undefined;
      await this.refresh();
    }, v.outcome === "Favorable"
      ? "BI Favorable: package moved to Security and Provisioning"
      : "BI Unfavorable: package closed, the process ends");
  }
  get vettingNeedsNote() {
    return this.vetting.outcome === "Unfavorable";
  }
  async handleProvision() {
    const needsEmail = !!this.provisioningEmail;
    await this.run(async () => {
      await completeProvisioning({ stepId: this.selectedStepId });
      this.selectedStepId = undefined;
      await this.refresh();
    }, needsEmail ? "Provisioning email sent and ACE Portal provisioning called" : "ACE Portal provisioning called (no email needed)");
  }
  handleRefresh() {
    this.refresh();
  }

  // ---------------------------------------------------------------- helpers

  async run(action, successMessage) {
    this.loading = true;
    try {
      await action();
      if (successMessage) {
        this.toast(successMessage, "", "success");
      }
    } catch (error) {
      this.toast("Not done", reduceError(error), "error");
    } finally {
      this.loading = false;
    }
  }

  toast(title, message, variant) {
    this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
  }
}

function split(value) {
  return value ? value.split(";").filter(Boolean) : [];
}

function badgeClass(status) {
  if (status === "Approved" || status === "Completed") {
    return "slds-badge slds-theme_success";
  }
  if (status === "Returned" || status === "Pending") {
    return "slds-badge slds-theme_warning";
  }
  if (status === "Rejected") {
    return "slds-badge slds-theme_error";
  }
  return "slds-badge";
}

function reduceError(error) {
  if (!error) {
    return "Unknown error";
  }
  if (error.body && error.body.message) {
    return error.body.message;
  }
  return error.message || String(error);
}