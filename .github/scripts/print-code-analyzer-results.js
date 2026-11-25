#!/usr/bin/env node
// Prints every Salesforce Code Analyzer violation to the GitHub Actions log.
// Critical and high violations are also written as error annotations, which show on the
// workflow run and in the pull request "Files changed" tab.
// Usage: node print-code-analyzer-results.js <title> <results.json> [<title> <results.json> ...]

const fs = require('fs');
const path = require('path');

const SEVERITY = { 1: 'Critical', 2: 'High', 3: 'Moderate', 4: 'Low', 5: 'Info' };
const workspace = process.env.GITHUB_WORKSPACE || process.cwd();

// Workflow command values must escape these characters.
const escapeData = (s) => String(s).replace(/%/g, '%25').replace(/\r/g, '%0D').replace(/\n/g, '%0A');
const escapeProp = (s) => escapeData(s).replace(/:/g, '%3A').replace(/,/g, '%2C');

function toRepoPath(file, runDir) {
  if (!file) return '';
  const absolute = path.isAbsolute(file) ? file : path.join(runDir || workspace, file);
  return path.relative(workspace, absolute).split(path.sep).join('/').replace(/\\/g, '/');
}

const args = process.argv.slice(2);
for (let i = 0; i + 1 < args.length; i += 2) {
  const title = args[i];
  const file = args[i + 1];

  if (!fs.existsSync(file)) {
    console.log(`::warning::${escapeData(`${title}: results file ${file} was not produced.`)}`);
    continue;
  }

  const results = JSON.parse(fs.readFileSync(file, 'utf8'));
  const violations = (results.violations || [])
    .map((v) => {
      const loc = (v.locations || [])[v.primaryLocationIndex || 0] || {};
      return {
        severity: v.severity,
        rule: `${v.engine}:${v.rule}`,
        file: toRepoPath(loc.file, results.runDir),
        line: loc.startLine || 0,
        column: loc.startColumn || 0,
        message: (v.message || '').trim().split(/\r?\n/)[0],
        help: (v.resources || [])[0] || ''
      };
    })
    .sort((a, b) => a.severity - b.severity || a.file.localeCompare(b.file) || a.line - b.line);

  const counts = {};
  violations.forEach((v) => (counts[v.severity] = (counts[v.severity] || 0) + 1));
  const summary = Object.keys(SEVERITY)
    .map((s) => `${SEVERITY[s]}: ${counts[s] || 0}`)
    .join(', ');

  console.log(`\n===== ${title}: ${violations.length} violation(s) (${summary}) =====`);

  for (const sev of Object.keys(SEVERITY).map(Number)) {
    const group = violations.filter((v) => v.severity === sev);
    if (group.length === 0) continue;

    console.log(`::group::${escapeData(`${title} - ${SEVERITY[sev]} (${group.length})`)}`);
    for (const v of group) {
      const where = v.file ? `${v.file}:${v.line}` : '(no file)';
      console.log(`[${SEVERITY[sev]}] ${where}  ${v.rule}  ${v.message}${v.help ? `  (${v.help})` : ''}`);
    }
    console.log('::endgroup::');

    if (sev <= 2) {
      for (const v of group) {
        const props = [`title=${escapeProp(`${SEVERITY[sev]}: ${v.rule}`)}`];
        if (v.file) props.push(`file=${escapeProp(v.file)}`);
        if (v.line) props.push(`line=${v.line}`);
        if (v.column) props.push(`col=${v.column}`);
        console.log(`::error ${props.join(',')}::${escapeData(v.message)}`);
      }
    }
  }
}
