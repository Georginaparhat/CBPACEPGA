import { LightningElement, wire } from 'lwc';
import { CurrentPageReference } from 'lightning/navigation';
import { refreshApex } from '@salesforce/apex';
import createPortalRequestForUser from '@salesforce/apex/ACEF_ApplicationService.createPortalRequestForUser';
import listMyPortalRequests from '@salesforce/apex/ACEF_ApplicationService.listMyPortalRequests';
import ensureAcePackage from '@salesforce/apex/ACEF_ApplicationService.ensureAcePackage';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { loadPortalTheme } from 'c/acePortalTheme';
import basePath from '@salesforce/community/basePath';

const FORM_CARDS = [
    {
        stepId: 'form004',
        title: 'CBP Form 7300',
        summary: 'Certification and access dates. Required first step for every request.'
    },
    {
        stepId: 'form001',
        title: 'PGA access application',
        summary: 'PGA User Application Form for ACE Portal Access on your package after ACE Portal access is requested.'
    },
    {
        stepId: 'form002',
        title: 'Rules of Behavior',
        summary: 'Acknowledge rules anytime on your PGA package.'
    },
    {
        stepId: 'form003',
        title: 'Witnessed NDA',
        summary: 'Upload the signed NDA PDF when you are ready.'
    }
];

export default class AcePortalShell extends LightningElement {
    view = 'home';
    activeRequestId;
    activePackageId;
    activeRequestName;
    workspaceStep = 'form004';
    creating = false;
    listWireResult;

    formCards = FORM_CARDS;
    autoInitDisabled = false;

    connectedCallback() {
        loadPortalTheme(this);
    }

    @wire(CurrentPageReference)
    parsePageRef(pageRef) {
        const state = pageRef?.state || {};
        if (state.c__view === 'requests') {
            this.view = 'requests';
        }
        if (state.c__request7300Id) {
            this.openRequest(state.c__request7300Id, state.c__step || 'form004', null);
        }
    }

    @wire(listMyPortalRequests)
    wiredRequests(result) {
        this.listWireResult = result;
    }

    get requests() {
        return this.listWireResult?.data || [];
    }

    get requestsLoading() {
        return this.listWireResult?.loading;
    }

    get requestsError() {
        return this.listWireResult?.error?.body?.message;
    }

    get isHome() {
        return this.view === 'home';
    }

    get isRequests() {
        return this.view === 'requests';
    }

    get isWorkspace() {
        return this.view === 'workspace';
    }

    get hasActiveRequest() {
        return Boolean(this.activeRequestId);
    }

    get mastheadLead() {
        if (this.isWorkspace) {
            return 'Complete each step in order, starting with CBP Form 7300. When you request ACE Portal access, the PGA package steps unlock for your access application, Rules of Behavior, and witnessed NDA upload.';
        }
        return 'Start on the home tab, track requests under My Requests, and complete forms for each open request.';
    }

    /** Handoff workspaces page (supervisor, CBP supervisor, security, vetting, provisioning, ACE Security). */
    get workspacesUrl() {
        return `${basePath}/workspaces`;
    }

    get navHomeClass() {
        return this.isHome ? 'nav-pill nav-pill--active' : 'nav-pill';
    }

    get navRequestsClass() {
        return this.isRequests ? 'nav-pill nav-pill--active' : 'nav-pill';
    }

    get continueButtonLabel() {
        return this.activeRequestName ? `Continue ${this.activeRequestName}` : 'Continue request';
    }

    get workspaceKey() {
        return `${this.activeRequestId || 'none'}-${this.workspaceStep}`;
    }

    showHome() {
        this.view = 'home';
    }

    showRequests() {
        this.view = 'requests';
        this.refreshRequestList();
    }

    async refreshRequestList() {
        if (this.listWireResult) {
            await refreshApex(this.listWireResult);
        }
    }

    async handleStartNew() {
        this.creating = true;
        try {
            const requestId = await createPortalRequestForUser();
            await this.openRequest(requestId, 'form004', 'New request');
            await this.refreshRequestList();
            this.dispatchEvent(
                new ShowToastEvent({
                    title: 'Request started',
                    message: 'Your draft Form 7300 is ready to complete.',
                    variant: 'success'
                })
            );
        } catch (e) {
            this.dispatchEvent(
                new ShowToastEvent({
                    title: 'Could not start request',
                    message: e.body?.message || e.message,
                    variant: 'error'
                })
            );
        } finally {
            this.creating = false;
        }
    }

    handleOpenRequest(event) {
        const id = event.currentTarget.dataset.id;
        const name = event.currentTarget.dataset.name;
        this.openRequest(id, 'form004', name);
    }

    handleContinueActive() {
        if (this.activeRequestId) {
            this.view = 'workspace';
        }
    }

    handleFormCard(event) {
        const stepId = event.currentTarget.dataset.step;
        if (!this.activeRequestId) {
            this.dispatchEvent(
                new ShowToastEvent({
                    title: 'Select a request',
                    message: 'Start a new request or open one from My Requests before opening a form.',
                    variant: 'info'
                })
            );
            return;
        }
        this.workspaceStep = stepId;
        this.view = 'workspace';
    }

    async openRequest(requestId, stepId, requestName) {
        this.activeRequestId = requestId;
        this.workspaceStep = stepId || 'form004';
        if (requestName) {
            this.activeRequestName = requestName;
        } else {
            const match = this.requests.find((r) => r.request7300Id === requestId);
            this.activeRequestName = match?.requestName || 'Request';
        }
        try {
            const scope = await ensureAcePackage({ request7300Id: requestId });
            this.activePackageId = scope.packageRecordId;
        } catch {
            this.activePackageId = null;
        }
        this.view = 'workspace';
    }

    handleBackFromWorkspace() {
        this.view = 'home';
    }
}