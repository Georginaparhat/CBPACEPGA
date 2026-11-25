import LightningModal from 'lightning/modal';
import { RULES_OF_BEHAVIOR } from 'c/aceForm002RulesContent';

/**
 * Rules of Behavior pop-up for the ACE PGA process demo. Shows the same Rules of Behavior
 * document as the portal's Rules step (aceFormRules2, text from aceForm002RulesContent)
 * and closes with 'accept' or 'reject'.
 */
export default class AceRulesOfBehaviorModal extends LightningModal {
    get acknowledgmentText() {
        return RULES_OF_BEHAVIOR.acknowledgment;
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
    get rulesIntro() {
        return RULES_OF_BEHAVIOR.intro.map((text, index) => ({ key: `intro-${index}`, text }));
    }
    get rulesMeta() {
        return RULES_OF_BEHAVIOR.meta.map((text, index) => ({ key: `meta-${index}`, text }));
    }
    get rulesSections() {
        return RULES_OF_BEHAVIOR.sections.map((section) => ({
            key: section.id,
            title: section.title,
            intro: section.intro || null,
            bullets: section.bullets.map((text, index) => ({ key: `${section.id}-${index}`, text }))
        }));
    }
    get rulesTitle() {
        return RULES_OF_BEHAVIOR.title;
    }

    handleAccept() {
        this.close('accept');
    }

    handleReject() {
        this.close('reject');
    }
}