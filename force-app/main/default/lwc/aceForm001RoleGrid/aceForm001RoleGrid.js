import { LightningElement, api, wire } from 'lwc';
import { getRecord, getFieldValue } from 'lightning/uiRecordApi';
import getEligibleSystems from '@salesforce/apex/ACEF_RoleEligibilityService.getEligibleSystems';
import getSelection from '@salesforce/apex/ACEF_PgaSystemSelectionService.getSelection';
import { FORM001_ROLES } from './aceForm001RoleOptions';
import ROLES_ADD from '@salesforce/schema/ACEF_PGA_Application__c.ACEF_Form001_Roles_Add__c';
import ROLES_REMOVE from '@salesforce/schema/ACEF_PGA_Application__c.ACEF_Form001_Roles_Remove__c';
import ROLES_RECERT from '@salesforce/schema/ACEF_PGA_Application__c.ACEF_Form001_Roles_Recertify__c';
import PORT_CODE from '@salesforce/schema/ACEF_PGA_Application__c.ACEF_Form001_USCG_Port_Code__c';

const FIELDS = [ROLES_ADD, ROLES_REMOVE, ROLES_RECERT, PORT_CODE];

/** source="systems": rows are the systems from System / Role Mapping for the selected agency (CBPPGA-87). */
const SOURCE_SYSTEMS = 'systems';

function parseMulti(value) {
    if (!value) {
        return new Set();
    }
    return new Set(
        value
            .split(';')
            .map((s) => s.trim())
            .filter(Boolean)
    );
}

function joinMulti(set) {
    return [...set].join(';');
}

export default class AceForm001RoleGrid extends LightningElement {
    @api recordId;
    /** 'roles' (default): the Form 001 role list. 'systems': systems for the selected agency. */
    @api source = 'roles';
    _add = new Set();
    _remove = new Set();
    _recert = new Set();
    _sysAdd = new Set();
    _sysRemove = new Set();
    _sysRecert = new Set();
    portCode = '';
    systems = [];
    systemsLoaded = false;
    systemsError;
    _deptAgency;

    /** Agency (ACEF_Dept_Agency value) chosen above; drives the systems rows. */
    @api
    get deptAgency() {
        return this._deptAgency;
    }
    set deptAgency(value) {
        if (value === this._deptAgency) {
            return;
        }
        this._deptAgency = value;
        this.loadSystems();
    }

    get isSystems() {
        return this.source === SOURCE_SYSTEMS;
    }

    /** Systems mode only: the saved Add / Remove / Recertify choices (read through Apex). */
    get systemsRecordId() {
        return this.isSystems ? this.recordId : undefined;
    }

    @wire(getSelection, { applicationId: '$systemsRecordId' })
    wiredSystemsSelection({ data }) {
        if (!data) {
            return;
        }
        this._sysAdd = new Set(data.systemsAdd || []);
        this._sysRemove = new Set(data.systemsRemove || []);
        this._sysRecert = new Set(data.systemsRecertify || []);
    }

    @wire(getRecord, { recordId: '$recordId', fields: FIELDS })
    wiredRecord({ data }) {
        if (!data) {
            return;
        }
        this._add = parseMulti(getFieldValue(data, ROLES_ADD));
        this._remove = parseMulti(getFieldValue(data, ROLES_REMOVE));
        this._recert = parseMulti(getFieldValue(data, ROLES_RECERT));
        this.portCode = getFieldValue(data, PORT_CODE) || '';
    }

    async loadSystems() {
        if (!this.isSystems || !this._deptAgency) {
            this.systems = [];
            this.systemsLoaded = false;
            return;
        }
        try {
            const result = await getEligibleSystems({ deptAgency: this._deptAgency });
            this.systems = (result && result.systems) || [];
            this.systemsError = undefined;
        } catch (error) {
            this.systems = [];
            this.systemsError = (error && error.body && error.body.message) || 'Could not load the systems.';
        }
        this.systemsLoaded = true;
    }

    get columnLabel() {
        return this.isSystems ? 'System' : 'Role';
    }

    get showRows() {
        return !this.isSystems || this.systems.length > 0;
    }

    get showSelectAgency() {
        return this.isSystems && !this._deptAgency;
    }

    get showNoSystems() {
        return this.isSystems && Boolean(this._deptAgency) && this.systemsLoaded && this.systems.length === 0;
    }

    get rows() {
        if (this.isSystems) {
            return this.systems.map((system) => ({
                label: system.label,
                value: system.value,
                key: system.value,
                isUscg: false,
                addChecked: this._sysAdd.has(system.value),
                removeChecked: this._sysRemove.has(system.value),
                recertChecked: this._sysRecert.has(system.value)
            }));
        }
        return FORM001_ROLES.map((label) => ({
            label,
            value: label,
            key: label,
            isUscg: label === 'USCG Ship Hold Analyst',
            addChecked: this._add.has(label),
            removeChecked: this._remove.has(label),
            recertChecked: this._recert.has(label)
        }));
    }

    handleToggle(event) {
        const role = event.target.dataset.role;
        const column = event.target.dataset.column;
        const checked = event.target.checked;
        let target;
        if (this.isSystems) {
            target = column === 'add' ? this._sysAdd : column === 'remove' ? this._sysRemove : this._sysRecert;
        } else {
            target = column === 'add' ? this._add : column === 'remove' ? this._remove : this._recert;
        }
        if (checked) {
            target.add(role);
        } else {
            target.delete(role);
        }
        this._add = new Set(this._add);
        this._remove = new Set(this._remove);
        this._recert = new Set(this._recert);
        this._sysAdd = new Set(this._sysAdd);
        this._sysRemove = new Set(this._sysRemove);
        this._sysRecert = new Set(this._sysRecert);
    }

    handlePortCode(event) {
        this.portCode = event.detail.value;
    }

    @api
    getValues() {
        const values = {
            rolesAdd: joinMulti(this._add),
            rolesRemove: joinMulti(this._remove),
            rolesRecertify: joinMulti(this._recert),
            portCode: this.portCode,
            rolesRequestedSummary: joinMulti(this._add)
        };
        if (this.isSystems) {
            // Keep only systems the selected agency can still request.
            const available = new Set(this.systems.map((system) => system.value));
            const keep = (set) => new Set([...set].filter((value) => available.has(value)));
            const added = keep(this._sysAdd);
            values.systemsAdd = [...added];
            values.systemsRemove = [...keep(this._sysRemove)];
            values.systemsRecertify = [...keep(this._sysRecert)];
            values.rolesRequestedSummary = this.systems
                .filter((system) => added.has(system.value))
                .map((system) => system.label)
                .join(';');
        }
        return values;
    }
}