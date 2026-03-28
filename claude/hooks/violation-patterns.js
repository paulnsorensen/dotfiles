/**
 * Shared pattern definitions for the layered violation classifier.
 * Used by semantic-stop-guard.js (runtime) and eval-classifier.js (validation).
 */

// Layer 1: Structural violation patterns (high precision — these ARE violations)
const VIOLATION_PATTERNS = [
  /\bScore:\s*\d{2,}\s*[—–-]/i,
  /\bconfidence:\s*\d{2,}\s*[—–-]/i,
  /\bFinding\s*\(\d{2,}\):/i,
  /^\s*\|\s*\d+\s*\|[^|]*\|\s*FAIL\s*\|/,
  /^FAIL:\s/,
  /\bSelf-eval.*\bFAIL\b/i,
  /\bWARN:.*\b(unresolved|unaddressed)\b/i,
  /\b(scored|flagged)\s+\d{2,}\b.*\b(not|no|without)\s+(fix|act|address|resolv)/i,
  /\b(deferred|deferring)\b.*\b(follow-?up|future|separate)\b/i,
  /\bskipping\s+the\s+(press|age|review)\s+phase\b/i,
  /\bremain\s+un(addressed|resolved)\b/i,
  /\bnoted\s+the\s+violation\b.*\bmoved on\b/i,
  /\baddress\s+the\s+remaining\s+findings\b/i,
];

// Layer 2: Clean pre-filters (high precision — these are NOT violations)
const CLEAN_PRE_FILTERS = [
  /^(fixed|resolved|addressed|remediated)\b/i,
  /\b(the hook|the classifier|the predicate|the guard)\b.*\b(fires|detects|classif|match)/i,
  /^\s*\|?\s*(Score|#|Rank)\s*\|\s*(Type|Category)/i,
  /^(Self-evaluation required|Unresolved violations detected)/i,
  /\bnow both paths\b/i,
  /\bchanged to\b.*\bwhich matches\b/i,
  /\ball\s+\d+\s+(self-eval\s+)?items?\s+(now\s+)?pass/i,
  /\ball\s+(scored\s+)?findings\s+have\s+been\s+(addressed|resolved)/i,
  /\bno\s+(unresolved\s+)?violations\s+remain/i,
  /\b(resolved|fixed)\s+all\s+(flagged\s+)?(items|findings|violations)/i,
  /\ball\s+parameters\s+are\s+within\b/i,
  /^Plan:\s/i,
];

const VIOLATION_CONFIDENCE_THRESHOLD = 0.55;

module.exports = { VIOLATION_PATTERNS, CLEAN_PRE_FILTERS, VIOLATION_CONFIDENCE_THRESHOLD };
