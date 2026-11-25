import { LightningElement, wire } from 'lwc';
import { CurrentPageReference } from 'lightning/navigation';
import validateSignerContext from '@salesforce/apex/ACEF_PhaseOrchestration.validateSignerContext';

export default class AceSignerHub extends LightningElement {
    role;
    request7300Id;
    packageId;
    context;
    error;

    @wire(CurrentPageReference)
    parseState(pageRef) {
        const state = pageRef?.state || {};
        this.role = state.c__role || state.role;
        this.request7300Id = state.c__request7300Id || state.request7300Id;
        this.packageId = state.c__packageId || state.packageId;
        if (this.role && this.request7300Id) {
            this.loadContext();
        }
    }

    async loadContext() {
        try {
            this.context = await validateSignerContext({
                role: this.role,
                request7300Id: this.request7300Id,
                packageId: this.packageId
            });
            if (this.context?.packageId) {
                this.packageId = this.context.packageId;
            }
        } catch (e) {
            this.error = e.body?.message || e.message;
        }
    }

    get blocked() {
        return this.context && !this.context.allowed;
    }

    get showAgencySupervisor7300() {
        return this.context?.allowed && this.context?.show7300Section2;
    }

    get showForm001Supervisor() {
        return this.context?.allowed && this.context?.showForm001Supervisor && this.packageId;
    }

    get showCbpSupervisor7300() {
        return this.context?.allowed && this.context?.show7300Section3;
    }

    get showAgencySection4() {
        return this.context?.allowed && this.context?.show7300Section4;
    }
}