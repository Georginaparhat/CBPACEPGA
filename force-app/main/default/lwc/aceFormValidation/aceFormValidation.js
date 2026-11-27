export function reportInputFieldValidity(form) {
    if (!form) {
        return true;
    }
    const fields = form.querySelectorAll('lightning-input-field');
    let valid = true;
    fields.forEach((field) => {
        if (!field.reportValidity()) {
            valid = false;
        }
    });
    return valid;
}

export function showErrorSummary(template, errors) {
    const summary = template?.querySelector('[data-error-summary]');
    if (!summary) {
        return;
    }
    const messages = errors || [];
    summary.textContent = messages.join(' ');
    summary.hidden = messages.length === 0;
}
