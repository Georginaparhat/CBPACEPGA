import { LightningElement, api, wire } from 'lwc';
import { loadPortalTheme } from 'c/acePortalTheme';
import { updateRecord, getRecord, getFieldValue } from 'lightning/uiRecordApi';
import { getObjectInfo } from 'lightning/uiObjectInfoApi';
import PGA_APPLICATION_OBJECT from '@salesforce/schema/ACEF_PGA_Application__c';
import ROLE_ADD_FIELD from '@salesforce/schema/ACEF_PGA_Application__c.ACEF_Form001_Role_Add__c';
import ROLE_CHANGE_FIELD from '@salesforce/schema/ACEF_PGA_Application__c.ACEF_Form001_Role_Change__c';
import ROLE_REMOVE_FIELD from '@salesforce/schema/ACEF_PGA_Application__c.ACEF_Form001_Role_Remove__c';
import ROLE_RESTORE_FIELD from '@salesforce/schema/ACEF_PGA_Application__c.ACEF_Form001_Role_Restore__c';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { reportInputFieldValidity, showErrorSummary } from 'c/aceFormValidation';
import getForm001Defaults from '@salesforce/apex/ACEF_Form001AccessService.getForm001Defaults';
import getSelection from '@salesforce/apex/ACEF_PgaSystemSelectionService.getSelection';
import saveSelection from '@salesforce/apex/ACEF_PgaSystemSelectionService.saveSelection';
import ID_FIELD from '@salesforce/schema/ACEF_PGA_Application__c.Id';
import STATUS_FIELD from '@salesforce/schema/ACEF_PGA_Application__c.ACEF_Package_Status__c';
import FORM001_FIELD from '@salesforce/schema/ACEF_PGA_Application__c.ACEF_Form001_User_Complete__c';
import FORM001_SUPERVISOR_FIELD from '@salesforce/schema/ACEF_PGA_Application__c.ACEF_Form001_Supervisor_Complete__c';
import APPLICANT_NAME_FIELD from '@salesforce/schema/ACEF_PGA_Application__c.ACEF_Form001_Applicant_Name__c';
import CREATE_NEW_USER_FIELD from '@salesforce/schema/ACEF_PGA_Application__c.ACEF_Form001_Create_New_User__c';
import ROLES_ADD_FIELD from '@salesforce/schema/ACEF_PGA_Application__c.ACEF_Form001_Roles_Add__c';
import ROLES_REMOVE_FIELD from '@salesforce/schema/ACEF_PGA_Application__c.ACEF_Form001_Roles_Remove__c';
import ROLES_RECERT_FIELD from '@salesforce/schema/ACEF_PGA_Application__c.ACEF_Form001_Roles_Recertify__c';
import PORT_CODE_FIELD from '@salesforce/schema/ACEF_PGA_Application__c.ACEF_Form001_USCG_Port_Code__c';
import ROLES_REQUESTED_FIELD from '@salesforce/schema/ACEF_PGA_Application__c.ACEF_Roles_Requested__c';
import saveSystemActions from '@salesforce/apex/ACEF_PgaSystemSelectionService.saveSystemActions';
import APPLICANT_SIGNED_BY_FIELD from '@salesforce/schema/ACEF_PGA_Application__c.ACEF_Form001_Applicant_Signed_By__c';
import APPLICANT_SIGNED_DATE_FIELD from '@salesforce/schema/ACEF_PGA_Application__c.ACEF_Form001_Applicant_Signed_Date__c';
import SUPERVISOR_SIGNED_BY_FIELD from '@salesforce/schema/ACEF_PGA_Application__c.ACEF_Form001_Supervisor_Signed_By__c';
import SUPERVISOR_SIGNED_DATE_FIELD from '@salesforce/schema/ACEF_PGA_Application__c.ACEF_Form001_Supervisor_Signed_Date__c';

export default class AceFormAccess extends LightningElement {
    @api recordId;
    /** user (default) or supervisor */
    @api mode = 'user';
    submitted = false;
    defaultsApplied = false;
    /** CBPPGA-87: saved Department → Agency → Systems selection, used to prefill the picker. */
    pickerValue;
    selection;

    @wire(getSelection, { applicationId: '$recordId' })
    wiredSelection({ data }) {
        if (data && data.deptAgency && !this.selection) {
            this.pickerValue = {
                deptAgency: data.deptAgency,
                systems: data.systems || [],
                roleCodes: data.roleCodes || []
            };
        }
    }

    /** Agency chosen in the picker (or the saved one); the systems table follows it. */
    get gridDeptAgency() {
        return (this.selection && this.selection.deptAgency) || (this.pickerValue && this.pickerValue.deptAgency);
    }

    /** Field labels for the checkboxes shown beside their box (same text as the field labels). */
    objectFieldLabels = {};

    @wire(getObjectInfo, { objectApiName: PGA_APPLICATION_OBJECT })
    wiredObjectInfo({ data }) {
        if (data && data.fields) {
            const labels = {};
            Object.keys(data.fields).forEach((name) => {
                labels[name] = data.fields[name].label;
            });
            this.objectFieldLabels = labels;
        }
    }

    /** Checkboxes shown label first, box after (Create new user, Update roles); saved on submit. */
    inlineValues = {};
    inlineDirty = false;

    @wire(getRecord, {
        recordId: '$recordId',
        fields: [CREATE_NEW_USER_FIELD, ROLE_ADD_FIELD, ROLE_CHANGE_FIELD, ROLE_REMOVE_FIELD, ROLE_RESTORE_FIELD]
    })
    wiredInlineChecks({ data }) {
        if (!data || this.inlineDirty) {
            return;
        }
        const values = {};
        [CREATE_NEW_USER_FIELD, ROLE_ADD_FIELD, ROLE_CHANGE_FIELD, ROLE_REMOVE_FIELD, ROLE_RESTORE_FIELD].forEach((field) => {
            values[field.fieldApiName] = getFieldValue(data, field) === true;
        });
        this.inlineValues = values;
    }

    get checkboxValues() {
        const v = this.inlineValues;
        return {
            createNewUser: v[CREATE_NEW_USER_FIELD.fieldApiName] === true,
            roleAdd: v[ROLE_ADD_FIELD.fieldApiName] === true,
            roleChange: v[ROLE_CHANGE_FIELD.fieldApiName] === true,
            roleRemove: v[ROLE_REMOVE_FIELD.fieldApiName] === true,
            roleRestore: v[ROLE_RESTORE_FIELD.fieldApiName] === true
        };
    }

    handleInlineCheck(event) {
        this.inlineDirty = true;
        this.inlineValues = { ...this.inlineValues, [event.target.dataset.field]: event.target.checked };
    }

    get checkboxLabels() {
        const l = this.objectFieldLabels;
        return {
            createNewUser: l.ACEF_Form001_Create_New_User__c,
            roleAdd: l.ACEF_Form001_Role_Add__c,
            roleChange: l.ACEF_Form001_Role_Change__c,
            roleRemove: l.ACEF_Form001_Role_Remove__c,
            roleRestore: l.ACEF_Form001_Role_Restore__c
        };
    }

    handlePickerChange(event) {
        // Only the picker's own change carries deptAgency; ignore any inner input event.
        if (event.detail && Object.prototype.hasOwnProperty.call(event.detail, 'deptAgency')) {
            this.selection = event.detail;
            showErrorSummary(this.template, []);
        }
    }

    @wire(getForm001Defaults, { packageId: '$recordId' })
    wiredDefaults({ data }) {
        if (!data || this.defaultsApplied || this.isSupervisor) {
            return;
        }
        this.defaultsApplied = true;
        const patch = {};
        if (data.applicantName) {
            patch[APPLICANT_NAME_FIELD.fieldApiName] = data.applicantName;
        }
        if (data.createNewUser === true) {
            patch[CREATE_NEW_USER_FIELD.fieldApiName] = true;
        }
        if (Object.keys(patch).length === 0) {
            return;
        }
        patch[ID_FIELD.fieldApiName] = this.recordId;
        updateRecord({ fields: patch }).catch(() => {});
    }

    get hasRecord() {
        return Boolean(this.recordId);
    }

    get isSupervisor() {
        return this.mode === 'supervisor';
    }

    get submitLabel() {
        return this.isSupervisor ? 'Submit supervisor attestation' : 'Submit application';
    }

    connectedCallback() {
        loadPortalTheme(this);
    }

    async handleSubmit(event) {
        event.preventDefault();
        if (!this.recordId) {
            return;
        }
        const form = this.template.querySelector('lightning-record-edit-form');
        const fieldsValid = reportInputFieldValidity(form);
        const picker = this.isSupervisor ? null : this.template.querySelector('c-ace-pga-system-picker');
        const pickerCheck = picker ? picker.validate() : { isValid: true, errors: [] };
        if (!fieldsValid || !pickerCheck.isValid) {
            const errors = [...pickerCheck.errors];
            if (!fieldsValid) {
                errors.push('Complete all required fields before submitting the access application.');
            }
            showErrorSummary(this.template, errors);
            return;
        }
        showErrorSummary(this.template, []);

        if (picker) {
            // CBPPGA-87: the server re-checks the selection against the active mappings before saving it.
            const choice = picker.value;
            try {
                const result = await saveSelection({
                    applicationId: this.recordId,
                    deptAgency: choice.deptAgency,
                    systems: choice.systems || [],
                    roleCodes: choice.roleCodes || []
                });
                if (!result.valid) {
                    showErrorSummary(this.template, result.errors);
                    return;
                }
            } catch (e) {
                showErrorSummary(this.template, [e.body?.message || 'Could not save the selected systems.']);
                return;
            }
        }
        const fields = { ...event.detail.fields };
        fields[ID_FIELD.fieldApiName] = this.recordId;

        const today = new Date().toISOString().slice(0, 10);
        let systemActions;

        if (this.isSupervisor) {
            fields[FORM001_SUPERVISOR_FIELD.fieldApiName] = true;
            fields[STATUS_FIELD.fieldApiName] = 'Form 002 In Progress';
            const supName = fields.ACEF_Form001_Supervisor_Name_Title__c;
            if (supName) {
                fields[SUPERVISOR_SIGNED_BY_FIELD.fieldApiName] = supName;
            }
            fields[SUPERVISOR_SIGNED_DATE_FIELD.fieldApiName] = today;
        } else {
            const roleGrid = this.template.querySelector('c-ace-form001-role-grid');
            if (roleGrid) {
                const roleValues = roleGrid.getValues();
                fields[ROLES_ADD_FIELD.fieldApiName] = roleValues.rolesAdd;
                fields[ROLES_REMOVE_FIELD.fieldApiName] = roleValues.rolesRemove;
                fields[ROLES_RECERT_FIELD.fieldApiName] = roleValues.rolesRecertify;
                fields[PORT_CODE_FIELD.fieldApiName] = roleValues.portCode;
                fields[ROLES_REQUESTED_FIELD.fieldApiName] = roleValues.rolesRequestedSummary;
                if (roleValues.systemsAdd !== undefined) {
                    // CBPPGA-87: the table lists systems from System / Role Mapping for the selected agency.
                    systemActions = {
                        systemsAdd: roleValues.systemsAdd,
                        systemsRemove: roleValues.systemsRemove,
                        systemsRecertify: roleValues.systemsRecertify
                    };
                }
            }
            Object.keys(this.inlineValues).forEach((name) => {
                fields[name] = this.inlineValues[name] === true;
            });
            fields[FORM001_FIELD.fieldApiName] = true;
            fields[STATUS_FIELD.fieldApiName] = 'Awaiting Form 001 Supervisor';
            const applicantName = fields.ACEF_Form001_Applicant_Name__c;
            if (applicantName) {
                fields[APPLICANT_SIGNED_BY_FIELD.fieldApiName] = applicantName;
            }
            fields[APPLICANT_SIGNED_DATE_FIELD.fieldApiName] = today;
        }

        try {
            if (systemActions) {
                await saveSystemActions({ applicationId: this.recordId, ...systemActions });
            }
            await updateRecord({ fields });
            this.submitted = true;
            this.dispatchEvent(
                new ShowToastEvent({
                    title: 'Application saved',
                    message: 'Your access application was saved on your PGA package.',
                    variant: 'success'
                })
            );
        } catch (e) {
            this.dispatchEvent(
                new ShowToastEvent({
                    title: 'Save failed',
                    message: e.body?.message || 'Could not save the access application.',
                    variant: 'error'
                })
            );
        }
    }
}