import { LightningElement, api, wire } from "lwc";
import getDeptAgencyOptions from "@salesforce/apex/ACEF_RoleEligibilityService.getDeptAgencyOptions";
import getEligibleSystems from "@salesforce/apex/ACEF_RoleEligibilityService.getEligibleSystems";

/**
 * CBPPGA-87. Department → Agency → requestable systems → dependent roles.
 *
 * Step 1 Department, step 2 Agency (only that department's agencies, from the
 * Department → Agency field dependency), step 3 the systems that agency may
 * request. `deptAgency` is the Agency picklist API name. Systems come from the role
 * map and the roles-by-function matrix. Systems flagged requiresRoleSelection
 * (AD/CVD) show a dependent role list.
 *
 * Fires `change` with
 * { department, departmentLabel, agency, deptAgency, systems, roleCodes }.
 * The server re-checks the selection with ACEF_RoleEligibilityService.resolveSelection
 * before anything is saved.
 */
export default class AcePgaSystemPicker extends LightningElement {
  @api disabled = false;

  options = [];
  department;
  deptAgency;
  systems = [];
  selectedSystems = [];
  selectedRoles = {};
  loadingSystems = false;
  systemsLoaded = false;
  errorMessage;
  _pending;

  /** Prefill: { deptAgency, systems, roleCodes }. */
  @api
  get value() {
    return this.buildValue();
  }
  set value(next) {
    this._pending = next;
    if (this.options.length) {
      this.applyPending();
    }
  }

  @wire(getDeptAgencyOptions)
  wiredOptions({ data, error }) {
    if (data) {
      this.options = data;
      this.errorMessage = undefined;
      this.applyPending();
    } else if (error) {
      this.errorMessage = reduceError(error);
    }
  }

  get departmentOptions() {
    const seen = new Set();
    const out = [];
    this.options.forEach((option) => {
      if (!seen.has(option.department)) {
        seen.add(option.department);
        out.push({
          label: option.departmentLabel || option.department,
          value: option.department
        });
      }
    });
    return out;
  }

  get agencyOptions() {
    return this.options
      .filter((option) => option.department === this.department)
      .map((option) => ({ label: option.agency, value: option.value }));
  }

  get agencyDisabled() {
    return this.disabled || !this.department;
  }

  get systemOptions() {
    return this.systems.map((system) => ({
      label: system.label,
      value: system.value
    }));
  }

  get roleSelections() {
    return this.systems
      .filter(
        (system) =>
          system.requiresRoleSelection &&
          this.selectedSystems.includes(system.value)
      )
      .map((system) => ({
        system: system.value,
        label: `${system.label} roles`,
        options: (system.roles || []).map((role) => ({
          label: role.roleName
            ? `${role.roleName} (${role.roleCode})`
            : role.roleCode,
          value: role.roleCode
        })),
        value: this.selectedRoles[system.value] || []
      }));
  }

  get showSystems() {
    return !this.loadingSystems && this.systems.length > 0;
  }

  get showNoSystems() {
    return (
      !this.loadingSystems && this.systemsLoaded && this.systems.length === 0
    );
  }

  handleDepartmentChange(event) {
    // Keep the inner input's own change event inside; only this component's change (with deptAgency) goes out.
    event.stopPropagation();
    this.department = event.detail.value;
    this.resetAgency();
    const agencies = this.agencyOptions;
    if (agencies.length === 1) {
      this.selectAgency(agencies[0].value);
    } else {
      this.notify();
    }
  }

  handleAgencyChange(event) {
    // Keep the inner input's own change event inside; only this component's change (with deptAgency) goes out.
    event.stopPropagation();
    this.selectAgency(event.detail.value);
  }

  handleSystemsChange(event) {
    // Keep the inner input's own change event inside; only this component's change (with deptAgency) goes out.
    event.stopPropagation();
    this.selectedSystems = [...event.detail.value];
    const kept = {};
    this.selectedSystems.forEach((value) => {
      if (this.selectedRoles[value]) {
        kept[value] = this.selectedRoles[value];
      }
    });
    this.selectedRoles = kept;
    this.notify();
  }

  handleRolesChange(event) {
    // Keep the inner input's own change event inside; only this component's change (with deptAgency) goes out.
    event.stopPropagation();
    const system = event.target.dataset.system;
    this.selectedRoles = {
      ...this.selectedRoles,
      [system]: [...event.detail.value]
    };
    this.notify();
  }

  /** Checks the selection and marks the inputs. Returns { isValid, errors }. */
  @api
  validate() {
    const errors = [];
    if (!this.deptAgency) {
      errors.push("Select a department and agency.");
    }
    if (this.deptAgency && this.selectedSystems.length === 0) {
      errors.push("Select at least one system.");
    }
    this.roleSelections.forEach((selection) => {
      if (!selection.value.length) {
        errors.push(
          `Select at least one ${selection.label.replace(/ roles$/, "")} role.`
        );
      }
    });
    this.template
      .querySelectorAll("lightning-combobox, lightning-checkbox-group")
      .forEach((input) => input.reportValidity && input.reportValidity());
    return { isValid: errors.length === 0, errors };
  }

  // ------------------------------------------------------------ internals

  resetAgency() {
    this.deptAgency = undefined;
    this.systems = [];
    this.selectedSystems = [];
    this.selectedRoles = {};
    this.systemsLoaded = false;
  }

  async selectAgency(deptAgency, restore) {
    this.deptAgency = deptAgency;
    this.systems = [];
    this.selectedSystems = [];
    this.selectedRoles = {};
    this.systemsLoaded = false;
    this.loadingSystems = true;
    this.errorMessage = undefined;
    try {
      const result = await getEligibleSystems({ deptAgency });
      this.systems = (result && result.systems) || [];
      if (restore) {
        this.restoreSelections(restore);
      }
    } catch (error) {
      this.errorMessage = reduceError(error);
    } finally {
      this.loadingSystems = false;
      this.systemsLoaded = true;
    }
    this.notify();
  }

  restoreSelections({ systems = [], roleCodes = [] }) {
    const available = new Map(
      this.systems.map((system) => [system.value, system])
    );
    this.selectedSystems = systems.filter((value) => available.has(value));
    const roles = {};
    this.selectedSystems.forEach((value) => {
      const system = available.get(value);
      if (system.requiresRoleSelection) {
        const codes = (system.roles || []).map((role) => role.roleCode);
        roles[value] = roleCodes.filter((code) => codes.includes(code));
      }
    });
    this.selectedRoles = roles;
  }

  applyPending() {
    const pending = this._pending;
    if (!pending || !pending.deptAgency) {
      return;
    }
    this._pending = undefined;
    const option = this.options.find(
      (candidate) => candidate.value === pending.deptAgency
    );
    if (!option) {
      return;
    }
    this.department = option.department;
    this.selectAgency(option.value, pending);
  }

  buildValue() {
    const option = this.options.find(
      (candidate) => candidate.value === this.deptAgency
    );
    const roleCodes = new Set();
    this.systems
      .filter((system) => this.selectedSystems.includes(system.value))
      .forEach((system) => {
        const codes = system.requiresRoleSelection
          ? this.selectedRoles[system.value] || []
          : (system.roles || []).map((role) => role.roleCode);
        codes.forEach((code) => roleCodes.add(code));
      });
    return {
      department: this.department,
      departmentLabel: option ? option.departmentLabel : undefined,
      agency: option ? option.agency : undefined,
      deptAgency: this.deptAgency,
      systems: [...this.selectedSystems],
      roleCodes: [...roleCodes].sort()
    };
  }

  notify() {
    this.dispatchEvent(
      new CustomEvent("change", { detail: this.buildValue() })
    );
  }
}

function reduceError(error) {
  if (!error) {
    return "Something went wrong.";
  }
  if (error.body && error.body.message) {
    return error.body.message;
  }
  return error.message || "Something went wrong.";
}