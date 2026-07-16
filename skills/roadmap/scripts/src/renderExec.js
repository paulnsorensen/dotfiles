
/**
 * Altitude 1 (exec) renderer: RoadmapModel -> Excalidraw frame.
 * Three columns (Now/Next/Later) grouped by outcome.horizon; one card per
 * outcome holding the outcome title, each member item's title, and its
 * unlocks lines. No arrows, no dates — this altitude is outcome-only.
 */

import { filterByAltitude } from './altitudeFilter.js';

/** @typedef {import('./types.js').RoadmapModel} RoadmapModel */

const HORIZONS = ['now', 'next', 'later'];
const COLUMN_LABELS = { now: 'Now', next: 'Next', later: 'Later' };
const COLUMN_X = { now: 40, next: 400, later: 760 };
const COLUMN_WIDTH = 320;
const CARD_PADDING = 16;
const LINE_HEIGHT = 20;
const CARD_GAP = 24;
const COLUMN_HEADER_Y = 40;
const CARDS_START_Y = 100;

function buildCardLines(outcome, items) {
  const lines = [outcome.title];
  for (const item of items) {
    lines.push(item.title);
    for (const unlock of item.unlocks) {
      lines.push(`- ${unlock}`);
    }
  }
  return lines;
}

/**
 * @param {RoadmapModel} inputModel
 * @returns {{frameName: string, elements: object[]}}
 */
export function renderExec(inputModel) {
  const model = filterByAltitude(inputModel, 1);
  const elements = [];
  let idCounter = 0;
  const nextId = (prefix) => `${prefix}-${idCounter++}`;

  for (const horizon of HORIZONS) {
    const x = COLUMN_X[horizon];

    elements.push({
      id: nextId(`column-${horizon}-label`),
      type: 'text',
      x,
      y: COLUMN_HEADER_Y,
      width: COLUMN_WIDTH,
      height: LINE_HEIGHT,
      text: COLUMN_LABELS[horizon],
    });

    let y = CARDS_START_Y;
    const outcomes = model.outcomes.filter((outcome) => outcome.horizon === horizon);

    for (const outcome of outcomes) {
      const items = model.items.filter((item) => outcome.items.includes(item.ref));
      const lines = buildCardLines(outcome, items);
      const height = lines.length * LINE_HEIGHT + CARD_PADDING * 2;

      elements.push({
        id: nextId(`${horizon}-card`),
        type: 'rectangle',
        x,
        y,
        width: COLUMN_WIDTH,
        height,
      });

      elements.push({
        id: nextId(`${horizon}-card-text`),
        type: 'text',
        x: x + CARD_PADDING,
        y: y + CARD_PADDING,
        width: COLUMN_WIDTH - CARD_PADDING * 2,
        height: height - CARD_PADDING * 2,
        text: lines.join('\n'),
      });

      y += height + CARD_GAP;
    }
  }

  return { frameName: 'Altitude 1 — Outcomes', elements };
}
