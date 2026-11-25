import { LightningElement, api } from 'lwc';
import { CloseActionScreenEvent } from 'lightning/actions';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { notifyRecordUpdateAvailable } from 'lightning/uiRecordApi';
import getVettingContext from '@salesforce/apex/ACEF_PortalWorkflowService.getVettingContext';
import recordVettingForRecord from '@salesforce/apex/ACEF_PortalWorkflowService.recordVettingForRecord';

/**
 * Vetting (OIT background investigation) in the native app. The portal ends after the Security / PSO
 * step, so the BI outcome is recorded here: as a quick action on the ACE PGA Application Package, or as a
 * panel on the Form 7300 Request record page (Form 7300 only requests have no package).
 * Favorable: Form 7300 only requests are complete; packages move on to readiness and provisioning.
 * Unfavorable: the request and its package are closed.
 */
export default class AceRecordBiOutcome extends LightningElement {
    /** 'action' (quick action, default) or 'panel' (record page). */
    @api variant = 'action';
    context;
    outcome;
    notes = '';
    loading = false;
    error;
    _recordId;

    @api
    get recordId() {
        return this._recordId;
    }
    set recordId(value) {
        this._recordId = value;
        if (value) {
            this.load();
        }
    }

    options = [
        { label: 'Favorable', value: 'Favorable' },
        { label: 'Unfavorable', value: 'Unfavorable' }
    ];

    get isPanel() {
        return this.variant === 'panel';
    }

    get showClose() {
        return !this.isPanel;
    }

    get showForm() {
        return Boolean(this.context && this.context.awaitingVetting);
    }

    get notesRequired() {
        return this.outcome === 'Unfavorable';
    }

    get nextStepText() {
        if (!this.context) {
            return '';
        }
        return this.context.aceAccess
            ? 'Favorable moves the package to Ready for Provisioning. Unfavorable sets Unfavorable BI Determination and stops processing.'
            : 'Form 7300 only (no ACE Portal access): Favorable completes the request. Unfavorable closes it.';
    }

    async load() {
        this.loading = true;
        try {
            this.context = await getVettingContext({ recordId: this._recordId });
            this.error = undefined;
        } catch (e) {
            this.error = reduceError(e);
        } finally {
            this.loading = false;
        }
    }

    handleOutcome(event) {
        this.outcome = event.detail.value;
    }

    handleNotes(event) {
        this.notes = event.detail.value;
    }

    handleCancel() {
        this.dispatchEvent(new CloseActionScreenEvent());
    }

    async handleSave() {
        if (!this.outcome) {
            this.error = 'Select Favorable or Unfavorable.';
            return;
        }
        if (this.outcome === 'Unfavorable' && !this.notes.trim()) {
            this.error = 'Add a note explaining the Unfavorable outcome.';
            return;
        }
        this.loading = true;
        try {
            this.context = await recordVettingForRecord({
                recordId: this._recordId,
                disposition: this.outcome,
                notes: this.notes
            });
            this.error = undefined;
            this.dispatchEvent(
                new ShowToastEvent({ title: 'BI outcome recorded', message: `Background investigation: ${this.outcome}.`, variant: 'success' })
            );
            await notifyRecordUpdateAvailable([{ recordId: this._recordId }]);
            if (!this.isPanel) {
                this.dispatchEvent(new CloseActionScreenEvent());
            }
        } catch (e) {
            this.error = reduceError(e);
        } finally {
            this.loading = false;
        }
    }
}

function reduceError(error) {
    if (error && error.body && error.body.message) {
        return error.body.message;
    }
    return (error && error.message) || 'Something went wrong.';
}