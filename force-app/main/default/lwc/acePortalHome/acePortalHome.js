import { LightningElement, api } from 'lwc';
export default class AcePortalHome extends LightningElement {
    @api recordId;
    @api savedData;
    @api sectionMode;
}
