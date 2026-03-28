#!/usr/bin/env node

/**
 * Leave-one-out cross-validation for the layered violation classifier.
 * Tests: structural patterns → clean pre-filters → LR with threshold.
 * Usage: node eval-classifier.js
 */

const fs = require('fs');
const path = require('path');
const natural = require('natural');
const { VIOLATION_PATTERNS, CLEAN_PRE_FILTERS, VIOLATION_CONFIDENCE_THRESHOLD } = require('./violation-patterns');

function classifyWithLayers(classifier, text) {
  if (VIOLATION_PATTERNS.some(p => p.test(text))) {
    return { label: 'violation', layer: 'structural' };
  }
  if (CLEAN_PRE_FILTERS.some(p => p.test(text))) {
    return { label: 'clean', layer: 'pre-filter' };
  }
  if (!classifier) return { label: 'clean', layer: 'fallback' };
  const scores = classifier.getClassifications(text);
  const violation = scores.find(s => s.label === 'violation');
  const conf = violation ? violation.value : 0;
  if (conf >= VIOLATION_CONFIDENCE_THRESHOLD) {
    return { label: 'violation', layer: 'ml', confidence: conf };
  }
  return { label: 'clean', layer: 'ml', confidence: conf };
}

function main() {
  const dataPath = path.join(__dirname, 'violation-training.json');
  const data = JSON.parse(fs.readFileSync(dataPath, 'utf8'));

  const allExamples = [
    ...data.violation.map(text => ({ text, label: 'violation' })),
    ...data.clean.map(text => ({ text, label: 'clean' }))
  ];

  console.log(`Training data: ${data.violation.length} violation, ${data.clean.length} clean`);
  console.log(`Violation patterns: ${VIOLATION_PATTERNS.length}, Clean pre-filters: ${CLEAN_PRE_FILTERS.length}`);
  console.log(`ML confidence threshold: ${VIOLATION_CONFIDENCE_THRESHOLD}`);
  console.log(`Running leave-one-out cross-validation (${allExamples.length} rounds)...\n`);

  const start = Date.now();
  let tp = 0, fp = 0, tn = 0, fn = 0;
  const misclassifications = [];
  const layerCounts = { structural: 0, 'pre-filter': 0, ml: 0, fallback: 0 };

  for (let i = 0; i < allExamples.length; i++) {
    const held = allExamples[i];

    const classifier = new natural.LogisticRegressionClassifier();
    for (let j = 0; j < allExamples.length; j++) {
      if (j === i) continue;
      classifier.addDocument(allExamples[j].text, allExamples[j].label);
    }
    classifier.train();

    const result = classifyWithLayers(classifier, held.text);
    layerCounts[result.layer]++;

    if (held.label === 'violation' && result.label === 'violation') tp++;
    else if (held.label === 'clean' && result.label === 'clean') tn++;
    else if (held.label === 'clean' && result.label === 'violation') {
      fp++;
      misclassifications.push({ ...result, text: held.text, actual: 'clean', predicted: 'violation' });
    } else {
      fn++;
      misclassifications.push({ ...result, text: held.text, actual: 'violation', predicted: 'clean' });
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

  console.log('=== Layer Distribution ===');
  for (const [layer, count] of Object.entries(layerCounts)) {
    if (count > 0) console.log(`  ${layer}: ${count} (${(count / total * 100).toFixed(1)}%)`);
  }

  console.log('\n=== Confusion Matrix ===');
  console.log(`                 Predicted`);
  console.log(`              violation  clean`);
  console.log(`Actual viol.    ${String(tp).padStart(3)}      ${String(fn).padStart(3)}`);
  console.log(`Actual clean    ${String(fp).padStart(3)}      ${String(tn).padStart(3)}`);

  if (misclassifications.length > 0) {
    console.log(`\n=== Misclassifications (${misclassifications.length}) ===`);
    for (const m of misclassifications) {
      const conf = m.confidence !== undefined ? ` conf=${m.confidence.toFixed(3)}` : '';
      console.log(`  [${m.actual} → ${m.predicted}] (${m.layer}${conf}) "${m.text.substring(0, 100)}${m.text.length > 100 ? '...' : ''}"`);
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
