import { LightningElement } from 'lwc';
import { loadPortalTheme } from 'c/acePortalTheme';
import listQueue from '@salesforce/apex/ACEF_PortalWorkflowService.listQueue';
import decide7300Section from '@salesforce/apex/ACEF_PortalWorkflowService.decide7300Section';
import recordVetting from '@salesforce/apex/ACEF_PortalWorkflowService.recordVetting';
import getGates from '@salesforce/apex/ACEF_PortalWorkflowService.getGates';
import applyReadinessDecision from '@salesforce/apex/ACEF_ProvisioningUiActions.applyReadinessDecision';
import routeForProvisioning from '@salesforce/apex/ACEF_ProvisioningUiActions.routeForProvisioning';
import markProvisioningComplete from '@salesforce/apex/ACEF_ProvisioningUiActions.markProvisioningComplete';
import verifyAceSecurity from '@salesforce/apex/ACEF_ProvisioningUiActions.verifyAceSecurity';

/**
 * ACE PGA Portal "Workspaces" page: the handoffs after the requester submits, in the
 * order used in Kurt's org.
 *
 *   Form 7300:  Agency supervisor (section 2) → CBP supervisor (section 3, when given)
 *               → Security / PSO signers (section 4) → Vetting (OIT BI)
 *   PGA package (ACE Portal access = Yes): Form 001 supervisor sign-off (Agency supervisor lane)
 *               → Provisioning (readiness, route, complete) → ACE Security verification → Closed
 *
 * Each lane lists what is waiting for it. Emails are not sent: approving moves the item
 * to the next lane's queue.
 */
const LANES = [
    {
        id: 'supervisor',
        label: 'Agency supervisor',
        help: 'Form 7300 section 2, and the PGA access application (Form 001) supervisor sign-off.',
        section: '2'
    },
    { id: 'cbpSupervisor', label: 'CBP supervisor', help: 'Form 7300 section 3 (only when a CBP supervisor is given).', section: '3' },
    { id: 'security', label: 'Security / PSO', help: 'Form 7300 section 4: security / PSO signers.', section: '4' },
    // The portal ends after the Security / PSO step. Vetting (BI), provisioning and ACE Security
    // verification happen in Salesforce (ACE PGA Processing app); those lanes are kept but hidden.
    { id: 'vetting', label: 'Vetting (BI)', help: 'OIT background investigation. Favorable continues; Unfavorable ends the process.', hidden: true },
    { id: 'provisioning', label: 'Provisioning', help: 'ACE Portal access only: readiness review, route for provisioning, mark complete.', hidden: true },
    { id: 'aceSecurity', label: 'ACE Security', help: 'ACE Portal access only: verify ACE Security access, then the request closes.', hidden: true }
];

export default class AcePortalWorkspaces extends LightningElement {
    laneId = 'supervisor';
    items = [];
    selectedKey;
    loading = false;
    message;
    messageVariant = 'success';
    gates;

    signerName = '';
    notes = '';
    biOutcome;
    accessArea;

    biOptions = [
        { label: 'Favorable', value: 'Favorable' },
        { label: 'Unfavorable', value: 'Unfavorable' }
    ];
    accessAreaOptions = [
        { label: 'ACE Portal', value: 'ACE Portal' },
        { label: 'Entitlement', value: 'Entitlement' }
    ];

    connectedCallback() {
        loadPortalTheme(this);
        this.loadQueue();
    }

    // ------------------------------------------------------------------ lanes and queue

    get lanes() {
        return LANES.filter((lane) => !lane.hidden).map((lane) => ({
            ...lane,
            className: lane.id === this.laneId ? 'lane lane--active' : 'lane',
            ariaPressed: lane.id === this.laneId ? 'true' : 'false'
        }));
    }

    get lane() {
        return LANES.find((lane) => lane.id === this.laneId);
    }

    get rows() {
        return this.items.map((item) => ({
            ...item,
            className: item.key === this.selectedKey ? 'queue__item queue__item--active' : 'queue__item',
            title: item.requesterName || item.requesterEmail || item.requestName || item.packageName,
            subtitle: this.describe(item),
            showReadiness: this.laneId === 'provisioning',
            readinessLabel: item.ready ? 'Ready' : 'Not ready yet',
            readinessClass: item.ready ? 'badge badge--ready' : 'badge badge--waiting'
        }));
    }

    get hasItems() {
        return this.items.length > 0;
    }

    get selected() {
        return this.items.find((item) => item.key === this.selectedKey);
    }

    get is7300Review() {
        const s = this.selected;
        return Boolean(s) && s.kind === 'form7300' && Boolean(this.lane.section);
    }

    get isForm001Review() {
        const s = this.selected;
        return Boolean(s) && s.kind === 'form001';
    }

    get isVetting() {
        return Boolean(this.selected) && this.laneId === 'vetting';
    }

    get isProvisioning() {
        return Boolean(this.selected) && this.laneId === 'provisioning';
    }

    get isAceSecurity() {
        return Boolean(this.selected) && this.laneId === 'aceSecurity';
    }

    get sectionTitle() {
        const titles = {
            2: 'Form 7300 section 2: agency supervisor certification',
            3: 'Form 7300 section 3: CBP supervisor certification',
            4: 'Form 7300 section 4: security / PSO signers'
        };
        return titles[this.lane.section];
    }

    get accessText() {
        const s = this.selected;
        if (!s) {
            return '';
        }
        return s.aceAccess ? 'Yes: Form 7300 and PGA package' : 'No: Form 7300 only';
    }

    get notesRequired() {
        return this.biOutcome === 'Unfavorable';
    }

    get gateLines() {
        return (this.gates && this.gates.lines ? this.gates.lines : []).map((line) => ({
            ...line,
            icon: line.passed ? '✔' : '•',
            className: line.passed ? 'gate gate--passed' : 'gate'
        }));
    }

    /** Provisioning: the package checks that still block readiness approval. */
    get notReadyItems() {
        const s = this.selected;
        return s && !s.ready && s.waitingOn ? s.waitingOn : [];
    }

    get showNotReady() {
        return this.isProvisioning && this.notReadyItems.length > 0;
    }

    get readinessDisabled() {
        const s = this.selected;
        return !this.gates || !this.gates.readyForReadiness || (s && s.readinessStatus === 'Approved');
    }

    get routeDisabled() {
        const s = this.selected;
        return (
            !this.gates ||
            !s ||
            s.readinessStatus !== 'Approved' ||
            s.provisioningStatus === 'Requested' ||
            !this.accessArea ||
            !this.routeGatesPassed
        );
    }

    /** Route needs Rules of Behavior and the NDA on top of approved readiness (server rule). */
    get routeGatesPassed() {
        const lines = (this.gates && this.gates.lines) || [];
        const passed = (key) => lines.some((line) => line.key === key && line.passed);
        return passed('form002') && passed('form003_nda');
    }

    get completeDisabled() {
        const s = this.selected;
        return !s || s.provisioningStatus !== 'Requested';
    }

    get messageClass() {
        return this.messageVariant === 'error' ? 'notice notice--error' : 'notice notice--success';
    }

    describe(item) {
        const parts = [];
        if (item.kind === 'form001') {
            parts.push('PGA access application: supervisor sign-off');
        } else if (item.kind === 'package') {
            parts.push(item.packageName);
            if (item.provisioningStatus) {
                parts.push('Provisioning: ' + item.provisioningStatus);
            }
        } else {
            parts.push(item.confirmationNumber ? 'Form 7300 ' + item.confirmationNumber : item.requestName);
            parts.push(item.aceAccess ? 'ACE Portal access' : '7300 only');
        }
        return parts.filter(Boolean).join(' · ');
    }

    handleLane(event) {
        this.laneId = event.currentTarget.dataset.id;
        this.message = undefined;
        this.loadQueue();
    }

    handleSelect(event) {
        this.selectedKey = event.currentTarget.dataset.key;
        this.resetInputs();
        this.loadGates();
    }

    handleRefresh() {
        this.loadQueue();
    }

    async loadQueue() {
        this.loading = true;
        try {
            this.items = await listQueue({ lane: this.laneId });
            if (!this.items.some((item) => item.key === this.selectedKey)) {
                this.selectedKey = this.items.length ? this.items[0].key : undefined;
                this.resetInputs();
            }
            await this.loadGates();
        } catch (error) {
            this.items = [];
            this.showMessage(reduceError(error), 'error');
        } finally {
            this.loading = false;
        }
    }

    async loadGates() {
        this.gates = undefined;
        const s = this.selected;
        if (!s || !s.packageId || (this.laneId !== 'provisioning' && this.laneId !== 'aceSecurity')) {
            return;
        }
        try {
            this.gates = await getGates({ packageId: s.packageId });
        } catch (error) {
            this.showMessage(reduceError(error), 'error');
        }
    }

    resetInputs() {
        const s = this.selected;
        this.signerName = '';
        this.notes = '';
        this.biOutcome = undefined;
        this.accessArea = s && s.accessArea ? s.accessArea : 'ACE Portal';
    }

    // ------------------------------------------------------------------ inputs

    handleSignerName(event) {
        this.signerName = event.detail.value;
    }

    handleNotes(event) {
        this.notes = event.detail.value;
    }

    handleBiOutcome(event) {
        this.biOutcome = event.detail.value;
    }

    handleAccessArea(event) {
        this.accessArea = event.detail.value;
    }

    // ------------------------------------------------------------------ actions

    handleApprove7300() {
        return this.decide('Approved');
    }

    handleReject7300() {
        return this.decide('Rejected');
    }

    decide(decision) {
        const s = this.selected;
        const section = this.lane.section;
        return this.run(
            () =>
                decide7300Section({
                    request7300Id: s.request7300Id,
                    section,
                    decision,
                    signerName: this.signerName,
                    notes: this.notes
                }),
            decision === 'Approved'
                ? section === '4'
                    ? 'Section 4 approved. The request is now with CBP for vetting and provisioning in Salesforce (ACE PGA Processing app).'
                    : `Section ${section} approved. The request moved to the next step.`
                : `Section ${section} rejected. The request is closed.`
        );
    }

    handleRecordVetting() {
        const s = this.selected;
        const outcome = this.biOutcome;
        if (!outcome) {
            this.showMessage('Select Favorable or Unfavorable.', 'error');
            return undefined;
        }
        let next = 'The request is closed.';
        if (outcome === 'Favorable') {
            next = s.aceAccess ? 'The PGA package moves on to provisioning.' : 'Form 7300 only: the request is complete.';
        }
        return this.run(
            () => recordVetting({ request7300Id: s.request7300Id, disposition: outcome, notes: this.notes }),
            `BI ${outcome} recorded. ${next}`
        );
    }

    handleApproveReadiness() {
        return this.run(
            () => applyReadinessDecision({ packageId: this.selected.packageId, decision: 'Approve', notes: this.notes }),
            'Readiness approved. Route the package for provisioning next.'
        );
    }

    handleRoute() {
        return this.run(
            () => routeForProvisioning({ packageId: this.selected.packageId, accessArea: this.accessArea }),
            'Routed for provisioning.'
        );
    }

    handleComplete() {
        return this.run(
            () => markProvisioningComplete({ packageId: this.selected.packageId, notes: this.notes }),
            'Provisioning complete. The package moves to ACE Security verification.'
        );
    }

    handleVerify() {
        return this.run(
            () => verifyAceSecurity({ packageId: this.selected.packageId, notes: this.notes }),
            'ACE Security verified. The request is closed.'
        );
    }

    async run(action, successMessage) {
        this.loading = true;
        try {
            await action();
            this.showMessage(successMessage, 'success');
            await this.loadQueue();
        } catch (error) {
            this.showMessage(reduceError(error), 'error');
        } finally {
            this.loading = false;
        }
    }

    showMessage(text, variant) {
        this.message = text;
        this.messageVariant = variant;
    }
}

function reduceError(error) {
    if (!error) {
        return 'Something went wrong.';
    }
    if (error.body && error.body.message) {
        return error.body.message;
    }
    return error.message || 'Something went wrong.';
}