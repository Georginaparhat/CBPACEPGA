import { LightningElement, api } from 'lwc';
export default class AceElasticResponses extends LightningElement {
    @api recordId;
    @api savedData;
    @api sectionMode;
}
