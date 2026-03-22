#!/usr/bin/env node

/**
 * Leave-one-out cross-validation for the violation classifier.
 * Usage: node eval-classifier.js [--verbose]
 */

const fs = require('fs');
const path = require('path');

const VERBOSE = process.argv.includes('--verbose');

function main() {
  const winkNLP = require('wink-nlp');
  const model = require('wink-eng-lite-web-model');
  const nbc = require('wink-naive-bayes-text-classifier');

  // Single NLP instance shared across all folds (heavy object)
  const nlp = winkNLP(model);
  const its = nlp.its;

  const prepTask = (text) => {
    const doc = nlp.readDoc(text);
    return doc.tokens().filter(t => t.out(its.type) === 'word').out(its.normal);
  };

  const dataPath = path.join(__dirname, 'violation-training.json');
  const data = JSON.parse(fs.readFileSync(dataPath, 'utf8'));

  const allExamples = [
    ...data.violation.map(text => ({ text, label: 'violation' })),
    ...data.clean.map(text => ({ text, label: 'clean' }))
  ];

  console.log(`Training data: ${data.violation.length} violation, ${data.clean.length} clean`);
  console.log(`Running leave-one-out cross-validation (${allExamples.length} rounds)...\n`);

  const start = Date.now();
  let tp = 0, fp = 0, tn = 0, fn = 0;
  const misclassifications = [];

  for (let i = 0; i < allExamples.length; i++) {
    const held = allExamples[i];

    // Lightweight classifier per fold (reuses shared NLP)
    const classifier = nbc();
    classifier.definePrepTasks([prepTask]);
    classifier.defineConfig({ considerOnlyPresence: true, smoothingFactor: 1 });

    for (let j = 0; j < allExamples.length; j++) {
      if (j === i) continue;
      classifier.learn(allExamples[j].text, allExamples[j].label);
    }
    classifier.consolidate();

    const predicted = classifier.predict(held.text);

    if (held.label === 'violation' && predicted === 'violation') tp++;
    else if (held.label === 'clean' && predicted === 'clean') tn++;
    else if (held.label === 'clean' && predicted === 'violation') {
      fp++;
      misclassifications.push({ text: held.text, actual: 'clean', predicted: 'violation' });
    } else {
      fn++;
      misclassifications.push({ text: held.text, actual: 'violation', predicted: 'clean' });
    }
  }

  const elapsed = Date.now() - start;
  const total = allExamples.length;

  const accuracy = ((tp + tn) / total * 100).toFixed(1);
  const precision = tp + fp > 0 ? (tp / (tp + fp) * 100).toFixed(1) : 'N/A';
  const recall = tp + fn > 0 ? (tp / (tp + fn) * 100).toFixed(1) : 'N/A';
  const f1 = precision !== 'N/A' && recall !== 'N/A'
    ? (2 * parseFloat(precision) * parseFloat(recall) / (parseFloat(precision) + parseFloat(recall))).toFixed(1)
    : 'N/A';

  console.log('=== Results ===');
  console.log(`Accuracy:  ${accuracy}% (${tp + tn}/${total})`);
  console.log(`Precision: ${precision}% (violation predictions that were correct)`);
  console.log(`Recall:    ${recall}% (actual violations that were caught)`);
  console.log(`F1 Score:  ${f1}%`);
  console.log(`Time:      ${elapsed}ms (${(elapsed / total).toFixed(1)}ms per fold)\n`);

  console.log('=== Confusion Matrix ===');
  console.log(`                 Predicted`);
  console.log(`              violation  clean`);
  console.log(`Actual viol.    ${String(tp).padStart(3)}      ${String(fn).padStart(3)}`);
  console.log(`Actual clean    ${String(fp).padStart(3)}      ${String(tn).padStart(3)}`);

  if (misclassifications.length > 0) {
    console.log(`\n=== Misclassifications (${misclassifications.length}) ===`);
    for (const m of misclassifications) {
      console.log(`  [${m.actual} → ${m.predicted}] "${m.text.substring(0, 100)}${m.text.length > 100 ? '...' : ''}"`);
    }
  } else {
    console.log('\nNo misclassifications — perfect accuracy.');
  }

  if (parseFloat(accuracy) < 90) {
    console.log('\nFAIL: Accuracy below 90% threshold.');
    process.exit(1);
  }
}

main();
