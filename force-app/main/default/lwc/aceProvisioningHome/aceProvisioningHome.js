import { LightningElement } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import getSummary from '@salesforce/apex/ACEF_ProvisioningHomeService.getSummary';

/**
 * ACE Provisioning (ACE PGA Processing app) homepage: package counts by processing stage after the
 * portal's Security / PSO step, each opening the matching list view. Styled like aceInternalHome.
 */
export default class AceProvisioningHome extends NavigationMixin(LightningElement) {
    summary;
    loading = true;
    error;

    connectedCallback() {
        this.load();
    }

    async load() {
        this.loading = true;
        try {
            this.summary = await getSummary();
            this.error = undefined;
        } catch (e) {
            this.error = (e && e.body && e.body.message) || 'Could not load the homepage counts.';
        } finally {
            this.loading = false;
        }
    }

    get totalPackages() {
        return this.summary ? this.summary.totalPackages : 0;
    }

    get tiles() {
        return ((this.summary && this.summary.tiles) || []).map((tile) => ({
            ...tile,
            className: tile.key === 'assigned' ? 'metric metric--highlight' : 'metric'
        }));
    }

    handleRefresh() {
        this.load();
    }

    handleOpenList(event) {
        const { object, list } = event.currentTarget.dataset;
        this[NavigationMixin.Navigate]({
            type: 'standard__objectPage',
            attributes: { objectApiName: object, actionName: 'list' },
            state: { filterName: list }
        });
    }
}