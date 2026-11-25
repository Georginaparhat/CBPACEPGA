import { LightningElement, api } from 'lwc';
import evaluateForUi from '@salesforce/apex/ACEF_ProvisioningGateService.evaluateForUi';
import applyReadiness from '@salesforce/apex/ACEF_ProvisioningUiActions.applyReadinessDecision';
import routeProvisioning from '@salesforce/apex/ACEF_ProvisioningUiActions.routeForProvisioning';
import completeProvisioning from '@salesforce/apex/ACEF_ProvisioningUiActions.markProvisioningComplete';
import verifyAceSecurity from '@salesforce/apex/ACEF_ProvisioningUiActions.verifyAceSecurity';
import recordBiDisposition from '@salesforce/apex/ACEF_ProvisioningUiActions.recordBiDisposition';
import getActionContext from '@salesforce/apex/ACEF_PackageLifecycleService.getActionContext';
import submitRequest from '@salesforce/apex/ACEF_PackageLifecycleService.submitRequest';
import provision from '@salesforce/apex/ACEF_PackageLifecycleService.provision';

/** CBPPGA-88 lifecycle actions: Submit Request, Provision, Complete Security Review. */
const LIFECYCLE_ACTIONS = ['submit', 'provision', 'security'];

export default class AceProvisioningFlowScreen extends LightningElement {
    @api recordId;
    @api actionKey;
    @api decision;
    @api disposition;
    @api accessArea;
    @api notes;

    gates;
    lifecycle;
    errorMessage;

    connectedCallback() {
        if (!this.accessArea) {
            this.accessArea = 'ACE Portal';
        }
        if (this.actionKey === 'readiness' && this.recordId) {
            evaluateForUi({ packageId: this.recordId })
                .then((data) => {
                    this.gates = data;
                })
                .catch((err) => {
                    this.errorMessage = err.body?.message || err.message;
                });
        }
        if (this.isLifecycle && this.recordId) {
            getActionContext({ packageId: this.recordId, actionKey: this.actionKey })
                .then((data) => {
                    this.lifecycle = data;
                })
                .catch((err) => {
                    this.errorMessage = err.body?.message || err.message;
                });
        }
    }

    get isLifecycle() {
        return LIFECYCLE_ACTIONS.includes(this.actionKey);
    }

    get showNotes() {
        return this.actionKey !== 'submit';
    }

    get lifecycleNoteClass() {
        return this.lifecycle && this.lifecycle.allowed
            ? 'slds-box slds-theme_shade slds-m-bottom_small'
            : 'slds-box slds-theme_warning slds-m-bottom_small';
    }

    get checklist() {
        return (this.lifecycle?.checklist || []).map((line, index) => ({
            key: `check-${index}`,
            label: line.label,
            icon: line.passed ? 'utility:success' : 'utility:clear',
            variant: line.passed ? 'success' : 'error',
            state: line.passed ? 'Done' : 'Open'
        }));
    }

    get hasChecklist() {
        return this.checklist.length > 0;
    }

    get notifyTeams() {
        return (this.lifecycle?.notifyTeams || []).map((team) => ({ key: team, label: team }));
    }

    get hasNotifyTeams() {
        return this.actionKey === 'provision' && this.notifyTeams.length > 0;
    }

    get isReadiness() {
        return this.actionKey === 'readiness';
    }

    get isRoute() {
        return this.actionKey === 'route';
    }

    get isBi() {
        return this.actionKey === 'bi';
    }

    get showGateWarning() {
        return this.isReadiness && this.gates && !this.gates.readyForReadiness;
    }

    get decisionOptions() {
        return [
            { label: 'Approve', value: 'Approve' },
            { label: 'Reject', value: 'Reject' },
            { label: 'Hold', value: 'Hold' }
        ];
    }

    get dispositionOptions() {
        return [
            { label: 'Favorable', value: 'Favorable' },
            { label: 'Unfavorable', value: 'Unfavorable' }
        ];
    }

    get accessAreaOptions() {
        return [
            { label: 'ACE Portal', value: 'ACE Portal' },
            { label: 'Entitlement', value: 'Entitlement' }
        ];
    }

    handleDecisionChange(event) {
        this.decision = event.detail.value;
    }

    handleDispositionChange(event) {
        this.disposition = event.detail.value;
    }

    handleAccessAreaChange(event) {
        this.accessArea = event.detail.value;
    }

    handleNotesChange(event) {
        this.notes = event.detail.value;
    }

    @api
    async validate() {
        if (this.isReadiness && !this.decision) {
            return { isValid: false, errorMessage: 'Select a readiness decision.' };
        }
        if (this.isBi && !this.disposition) {
            return { isValid: false, errorMessage: 'Select a BI disposition.' };
        }
        if (this.isRoute && !this.accessArea) {
            return { isValid: false, errorMessage: 'Select an access area.' };
        }
        if (this.isLifecycle && this.lifecycle && !this.lifecycle.allowed) {
            return { isValid: false, errorMessage: this.lifecycle.message };
        }
        try {
            if (this.isReadiness) {
                await applyReadiness({ packageId: this.recordId, decision: this.decision, notes: this.notes });
            } else if (this.actionKey === 'route') {
                await routeProvisioning({ packageId: this.recordId, accessArea: this.accessArea });
            } else if (this.actionKey === 'provisioner') {
                await completeProvisioning({ packageId: this.recordId, notes: this.notes });
            } else if (this.actionKey === 'security') {
                await verifyAceSecurity({ packageId: this.recordId, notes: this.notes });
            } else if (this.actionKey === 'submit') {
                await submitRequest({ packageId: this.recordId });
            } else if (this.actionKey === 'provision') {
                await provision({ packageId: this.recordId, notes: this.notes });
            } else if (this.isBi) {
                await recordBiDisposition({
                    request7300Id: this.recordId,
                    disposition: this.disposition,
                    notes: this.notes
                });
            }
            return { isValid: true };
        } catch (err) {
            return { isValid: false, errorMessage: err.body?.message || err.message };
        }
    }
}