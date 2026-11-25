/* eslint-disable @lwc/lwc/no-api-reassignments -- portal pattern (from Kurt's acePortalHome): the
   request, package and ACE scope are public so the shell can pass them in, and are also updated here. */
import { LightningElement, api, wire } from 'lwc';
import initializePortal from '@salesforce/apex/ACEF_ApplicationService.initializePortal';
import ensureAcePackage from '@salesforce/apex/ACEF_ApplicationService.ensureAcePackage';
import getPortalChecklistState from '@salesforce/apex/ACEF_ApplicationService.getPortalChecklistState';
import getLinkedForm from '@salesforce/apex/ACEF_PortalCbpForm7300Service.getLinkedForm';
import linkSubmittedForm from '@salesforce/apex/ACEF_PortalCbpForm7300Service.linkSubmittedForm';
import setAccessAnswer from '@salesforce/apex/ACEF_PortalWorkflowService.setAccessAnswer';
import getProgress from '@salesforce/apex/ACEF_PortalWorkflowService.getProgress';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { loadPortalTheme } from 'c/acePortalTheme';

const STEP_META = {
    form004: {
        title: 'CBP Form 7300',
        role: 'Complete and submit the CBP Form 7300. It then goes to your supervisor, the CBP supervisor (if any), security signers and vetting.',
        summary: 'Complete each section, certify and submit. Your confirmation number and progress appear here.',
        formTitle: 'CBP Form 7300: Non-CBP user certification'
    },
    form001: {
        title: 'PGA access application',
        role: 'You complete it first, then your supervisor signs via email link.',
        summary: 'Digitized access application on your PGA package record.',
        formTitle: 'PGA access application'
    },
    form002: {
        title: 'Rules of Behavior',
        role: 'Acknowledge the rules on your PGA package whenever you are ready.',
        summary: 'Travels with the access application and the NDA in your package.',
        formTitle: 'Rules of Behavior'
    },
    form003: {
        title: 'Witnessed NDA (PDF upload)',
        role: 'Complete the official NDA offline, then upload the signed PDF.',
        summary: 'This form is not filled out in the portal; upload the witnessed PDF only.',
        formTitle: 'Witnessed NDA (PDF upload)'
    }
};

const ORDER = ['form004', 'form001', 'form002', 'form003'];

export default class AcePortalHome extends LightningElement {
    @api packageRecordId;
    @api request7300RecordId;
    @api aceAccessInScope = false;
    @api autoInitialize = false;
    @api initialFormStep;

    selectedId = 'form004';
    loading = false;
    checklistState;
    /** Form 7300 Test 2 record linked to this request: { formId, confirmationNumber }. */
    linkedForm7300;
    form7300JustSubmitted = false;
    /** Where the request is and who it is waiting on (ACEF_PortalWorkflowService.getProgress). */
    progress;
    progressLoaded = false;
    accessAnswerDraft;
    accessAnswerError;
    editingAnswer = false;
    accessAnswerOptions = [
        {
            label: 'Yes: I need ACE Portal access (Form 7300, ACE PGA application, Rules of Behavior and NDA)',
            value: 'Yes'
        },
        { label: 'No: Form 7300 only', value: 'No' }
    ];

    connectedCallback() {
        loadPortalTheme(this);
        if (this.initialFormStep) {
            this.selectedId = this.initialFormStep;
        }
        const shouldCreate7300 = !this.request7300RecordId && this.autoInitialize === true;
        if (shouldCreate7300) {
            this.bootstrap();
        } else if (this.request7300RecordId) {
            this.refreshAceScope();
        }
    }

    @api
    openFormStep(stepId) {
        if (stepId) {
            this.selectedId = stepId;
        }
    }

    @wire(getPortalChecklistState, { request7300Id: '$request7300RecordId', packageId: '$packageRecordId' })
    wiredChecklist({ data }) {
        if (data) {
            this.checklistState = data;
        }
    }

    async bootstrap() {
        this.loading = true;
        try {
            const result = await initializePortal({ createIfMissing: true });
            this.request7300RecordId = result.request7300RecordId;
            this.aceAccessInScope = result.aceAccessInScope === true;
            this.packageRecordId = result.packageRecordId;
            this.loadProgress();
        } catch (e) {
            this.dispatchEvent(
                new ShowToastEvent({
                    title: 'Setup failed',
                    message: e.body?.message || 'Could not start application.',
                    variant: 'error'
                })
            );
        } finally {
            this.loading = false;
        }
    }

    async refreshAceScope() {
        try {
            const result = await ensureAcePackage({ request7300Id: this.request7300RecordId });
            this.aceAccessInScope = result.aceAccessInScope === true;
            this.packageRecordId = result.packageRecordId;
        } catch {
            // Non-fatal when record not yet linkable
        }
        this.loadLinkedForm7300();
        this.loadProgress();
    }

    async loadProgress() {
        if (!this.request7300RecordId) {
            return;
        }
        try {
            this.progress = await getProgress({ request7300Id: this.request7300RecordId });
            this.accessAnswerDraft = this.progress.accessAnswer;
        } catch {
            this.progress = undefined;
        }
        this.progressLoaded = true;
    }

    /** Ask the ACE Portal access question before the package forms. */
    get showAccessQuestion() {
        return (
            Boolean(this.request7300RecordId) &&
            this.progressLoaded &&
            (this.editingAnswer || !(this.progress && this.progress.accessAnswer))
        );
    }

    get accessPathText() {
        const answer = this.progress && this.progress.accessAnswer;
        if (answer === 'Yes') {
            return 'ACE Portal access requested: Form 7300, ACE PGA application, Rules of Behavior and NDA.';
        }
        if (answer === 'No') {
            return 'No ACE Portal access: Form 7300 only.';
        }
        return '';
    }

    get canChangeAnswer() {
        return Boolean(this.progress && this.progress.accessAnswer) && !this.linkedForm7300;
    }

    get hasOpenForms() {
        return Boolean(this.progress && this.progress.openForms && this.progress.openForms.length);
    }

    get openFormsText() {
        return this.hasOpenForms ? this.progress.openForms.join(', ') : '';
    }

    handleChangeAnswer() {
        this.editingAnswer = true;
    }

    handleAccessAnswerChange(event) {
        this.accessAnswerDraft = event.detail.value;
        this.accessAnswerError = undefined;
    }

    async handleAccessAnswerSave() {
        if (!this.accessAnswerDraft) {
            this.accessAnswerError = 'Select Yes or No to continue.';
            return;
        }
        this.loading = true;
        try {
            await setAccessAnswer({ request7300Id: this.request7300RecordId, answer: this.accessAnswerDraft });
            this.editingAnswer = false;
            this.selectedId = 'form004';
            await this.refreshAceScope();
        } catch (e) {
            this.accessAnswerError = e.body?.message || 'Could not save your answer.';
        } finally {
            this.loading = false;
        }
    }

    handleAcePackage() {
        this.refreshAceScope();
    }

    async loadLinkedForm7300() {
        if (!this.request7300RecordId) {
            return;
        }
        try {
            this.linkedForm7300 = await getLinkedForm({ request7300Id: this.request7300RecordId });
        } catch {
            this.linkedForm7300 = undefined;
        }
    }

    /** Show the confirmation view on return visits; right after submit, Form 7300 Test 2 shows its own confirmation. */
    get showLinkedForm7300() {
        return Boolean(this.linkedForm7300) && !this.form7300JustSubmitted;
    }

    /** Form 7300 Test 2 submitted: link it to this request and unlock the PGA package steps. */
    async handleCbpForm7300Complete(event) {
        const confirmationNumber = event.detail && event.detail.confirmationNumber;
        this.form7300JustSubmitted = true;
        if (!this.request7300RecordId) {
            await this.bootstrap();
        }
        try {
            await linkSubmittedForm({
                request7300Id: this.request7300RecordId,
                confirmationNumber
            });
            // Picks up the new PGA package and the linked Form 7300.
            await this.refreshAceScope();
            this.dispatchEvent(
                new ShowToastEvent({
                    title: 'Form 7300 submitted',
                    message: 'Your PGA package is open. Continue with the PGA access application.',
                    variant: 'success'
                })
            );
        } catch (e) {
            this.dispatchEvent(
                new ShowToastEvent({
                    title: 'Form 7300 not linked',
                    message: e.body?.message || 'Could not link the Form 7300 to your request.',
                    variant: 'error'
                })
            );
        }
    }

    statusFor(stepId) {
        const row = this.checklistState?.steps?.find((s) => s.id === stepId);
        return row?.statusLabel || 'Open';
    }

    isLocked(stepId) {
        if (stepId === 'form002' || stepId === 'form003') {
            return false;
        }
        const row = this.checklistState?.steps?.find((s) => s.id === stepId);
        return row?.locked === true;
    }

    get steps() {
        const ids = this.aceAccessInScope ? ORDER : ['form004'];
        return ids.map((id, index) => {
            const meta = STEP_META[id];
            const locked = this.isLocked(id);
            const statusLabel = this.statusFor(id);
            const isCurrent = id === this.selectedId;
            let stepClass = 'step';
            if (isCurrent) {
                stepClass += ' step--current';
            }
            return {
                id,
                index: index + 1,
                title: meta.title,
                role: meta.role,
                summary: meta.summary,
                statusLabel,
                badgeClass: this.badgeClassFor(statusLabel),
                className: stepClass,
                ariaCurrent: isCurrent ? 'step' : null,
                isCurrent,
                locked
            };
        });
    }

    badgeClassFor(statusLabel) {
        const label = (statusLabel || '').toLowerCase();
        if (label.includes('pending') || label.includes('awaiting')) {
            return 'badge badge--pending';
        }
        if (label === 'open') {
            return 'badge badge--open';
        }
        if (label === 'locked' || label === 'draft') {
            return 'badge badge--draft';
        }
        if (label === 'complete' || (label.includes('complete') && !label.includes('pending'))) {
            return 'badge badge--complete';
        }
        return 'badge badge--draft';
    }

    get formCardHead() {
        const meta = STEP_META[this.selectedId] || STEP_META.form004;
        const total = this.aceAccessInScope ? ORDER.length : 1;
        const index = (this.aceAccessInScope ? ORDER : ['form004']).indexOf(this.selectedId) + 1;
        return {
            step: `Step ${index} of ${total}`,
            title: meta.formTitle || meta.title,
            summary: meta.summary
        };
    }

    get gateBanner() {
        return this.checklistState?.gateSummary;
    }

    get gateBannerFormatted() {
        if (!this.gateBanner) {
            return '';
        }
        if (this.gateBanner.startsWith('Required')) {
            return this.gateBanner;
        }
        return `Required for ACE Portal provisioning: ${this.gateBanner}`;
    }

    get showAccess() {
        return this.selectedId === 'form001';
    }

    get showRules() {
        return this.selectedId === 'form002';
    }

    get showNdaUpload() {
        return this.selectedId === 'form003';
    }

    get show7300() {
        return this.selectedId === 'form004';
    }

    handleSelect(event) {
        const id = event.currentTarget.dataset.id;
        const step = this.steps.find((s) => s.id === id);
        if (step?.locked) {
            return;
        }
        this.selectedId = id;
    }
}