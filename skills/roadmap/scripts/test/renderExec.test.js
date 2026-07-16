import assert from 'node:assert/strict';
import { test } from 'node:test';

import { renderExec } from '../src/renderExec.js';
import { fixtureModel } from './fixtures/roadmapModel.js';

const DATE_LIKE = /\d{4}-\d{2}-\d{2}/;

test('renderExec returns the altitude-1 frame name', () => {
  const { frameName } = renderExec(fixtureModel);
  assert.equal(frameName, 'Altitude 1 — Outcomes');
});

test('renderExec emits no arrow elements', () => {
  const { elements } = renderExec(fixtureModel);
  assert.equal(
    elements.filter((element) => element.type === 'arrow').length,
    0,
  );
});

test('renderExec emits no date strings anywhere', () => {
  const { elements } = renderExec(fixtureModel);
  for (const element of elements) {
    if (typeof element.text === 'string') {
      assert.equal(DATE_LIKE.test(element.text), false, `unexpected date in: ${element.text}`);
    }
  }
});

test('renderExec groups cards into Now/Next/Later columns by outcome.horizon', () => {
  const { elements } = renderExec(fixtureModel);
  const rects = elements.filter((element) => element.type === 'rectangle');

  // fixture has one outcome per horizon: now, next, later (in that order)
  assert.equal(rects.length, 3);

  const [nowRect, nextRect, laterRect] = rects;
  assert.ok(nowRect.x < nextRect.x, 'now column should sit left of next column');
  assert.ok(nextRect.x < laterRect.x, 'next column should sit left of later column');

  // all rectangles have non-overlapping x per column and positive dimensions
  for (const rect of rects) {
    assert.ok(rect.width > 0);
    assert.ok(rect.height > 0);
  }
});

test('renderExec cards contain outcome title, item titles, and unlocks text', () => {
  const { elements } = renderExec(fixtureModel);
  const texts = elements.filter((element) => element.type === 'text').map((element) => element.text);
  const allText = texts.join('\n');

  for (const outcome of fixtureModel.outcomes) {
    assert.ok(allText.includes(outcome.title), `missing outcome title: ${outcome.title}`);
  }

  for (const item of fixtureModel.items) {
    assert.ok(allText.includes(item.title), `missing item title: ${item.title}`);
    for (const unlock of item.unlocks) {
      assert.ok(allText.includes(unlock), `missing unlocks text: ${unlock}`);
    }
  }
});

test('renderExec elements all carry required Excalidraw fields', () => {
  const { elements } = renderExec(fixtureModel);
  assert.ok(elements.length > 0);

  const seenIds = new Set();
  for (const element of elements) {
    assert.equal(typeof element.id, 'string');
    assert.ok(!seenIds.has(element.id), `duplicate element id: ${element.id}`);
    seenIds.add(element.id);

    assert.ok(['rectangle', 'text'].includes(element.type));
    assert.equal(typeof element.x, 'number');
    assert.equal(typeof element.y, 'number');
    assert.equal(typeof element.width, 'number');
    assert.equal(typeof element.height, 'number');

    if (element.type === 'text') {
      assert.equal(typeof element.text, 'string');
    }
  }
});
