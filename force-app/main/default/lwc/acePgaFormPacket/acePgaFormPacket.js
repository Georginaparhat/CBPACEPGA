import { LightningElement, api } from 'lwc';
export default class AcePgaFormPacket extends LightningElement {
    @api recordId;
    @api savedData;
    @api sectionMode;
}
