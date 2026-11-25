import { LightningElement, api } from 'lwc';
import { loadPortalTheme } from 'c/acePortalTheme';
import { updateRecord } from 'lightning/uiRecordApi';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { showErrorSummary } from 'c/aceFormValidation';
import { RULES_OF_BEHAVIOR } from 'c/aceForm002RulesContent';
import RulesOfBehaviorModal from 'c/aceRulesOfBehaviorModal';
import ID_FIELD from '@salesforce/schema/ACEF_PGA_Application__c.Id';
import STATUS_FIELD from '@salesforce/schema/ACEF_PGA_Application__c.ACEF_Package_Status__c';
import FORM002_FIELD from '@salesforce/schema/ACEF_PGA_Application__c.ACEF_Form002_Complete__c';
import PRINTED_NAME_FIELD from '@salesforce/schema/ACEF_PGA_Application__c.ACEF_Form002_Printed_Name__c';
import ATTEST_DATE_FIELD from '@salesforce/schema/ACEF_PGA_Application__c.ACEF_Form002_Attestation_Date__c';

export default class AceFormRules extends LightningElement {
    @api recordId;
    submitted = false;
    attested = false;
    printedName = '';
    attestationDate;

    get hasRecord() {
        return Boolean(this.recordId);
    }

    get rulesTitle() {
        return RULES_OF_BEHAVIOR.title;
    }

    get acknowledgmentText() {
        return RULES_OF_BEHAVIOR.acknowledgment;
    }

    get rulesMeta() {
        return RULES_OF_BEHAVIOR.meta.map((text, index) => ({ key: `meta-${index}`, text }));
    }

    get rulesIntro() {
        return RULES_OF_BEHAVIOR.intro.map((text, index) => ({ key: `intro-${index}`, text }));
    }

    get rulesSections() {
        return RULES_OF_BEHAVIOR.sections.map((section) => ({
            key: section.id,
            title: section.title,
            intro: section.intro || null,
            bullets: section.bullets.map((text, index) => ({ key: `${section.id}-${index}`, text }))
        }));
    }

    get rulesAcronyms() {
        return RULES_OF_BEHAVIOR.acronyms.map((row, index) => ({
            key: `acr-${index}`,
            term: row.term,
            definition: row.definition
        }));
    }

    get rulesFooter() {
        return RULES_OF_BEHAVIOR.footer.map((text, index) => ({ key: `foot-${index}`, text }));
    }

    connectedCallback() {
        loadPortalTheme(this);
    }

    handleAttestChange(event) {
        this.attested = event.target.checked;
    }

    handleNameChange(event) {
        this.printedName = event.detail.value;
    }

    handleDateChange(event) {
        this.attestationDate = event.detail.value;
    }

    reportValidity() {
        return [...this.template.querySelectorAll('lightning-input')].reduce(
            (valid, field) => field.reportValidity() && valid,
            true
        );
    }

    async handleSubmit(event) {
        event.preventDefault();
        if (!this.recordId) {
            return;
        }
        if (!this.reportValidity() || !this.attested) {
            showErrorSummary(this.template, [
                'Check the attestation and complete printed name and date before acknowledging the rules.'
            ]);
            return;
        }
        showErrorSummary(this.template, []);
        // Rules of Behavior pop-up: the requester must Accept before the acknowledgment is saved.
        const choice = await RulesOfBehaviorModal.open({ size: 'large', label: 'Rules of Behavior' });
        if (choice === 'reject') {
            showErrorSummary(this.template, ['You must accept the Rules of Behavior to continue.']);
            return;
        }
        if (choice !== 'accept') {
            return;
        }
        const fields = {};
        fields[ID_FIELD.fieldApiName] = this.recordId;
        fields[FORM002_FIELD.fieldApiName] = true;
        fields[PRINTED_NAME_FIELD.fieldApiName] = this.printedName;
        fields[ATTEST_DATE_FIELD.fieldApiName] = this.attestationDate;
        fields[STATUS_FIELD.fieldApiName] = 'NDA Upload Pending';
        try {
            await updateRecord({ fields });
            this.submitted = true;
            this.dispatchEvent(
                new ShowToastEvent({
                    title: 'Rules acknowledged',
                    message: 'Rules of Behavior attestation was saved.',
                    variant: 'success'
                })
            );
        } catch (e) {
            this.dispatchEvent(
                new ShowToastEvent({
                    title: 'Save failed',
                    message: e.body?.message || 'Could not save the rules attestation.',
                    variant: 'error'
                })
            );
        }
    }
}