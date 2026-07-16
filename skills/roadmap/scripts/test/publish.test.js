
import assert from 'node:assert/strict';
import { test } from 'node:test';

import { publish } from '../src/publish.js';

/** Recording stand-in for @notionhq/client's Client; never touches the network. */
function makeRecordingNotionClient() {
  const appendCalls = [];
  return {
    calls: appendCalls,
    blocks: {
      children: {
        append: async (args) => {
          appendCalls.push(args);
          return { object: 'list', results: [] };
        },
      },
    },
  };
}

test('publish appends a heading, a share-link bookmark, and one image block per png', async () => {
  const notionClient = makeRecordingNotionClient();
  const pngs = ['altitude-1.png', 'altitude-2.png', 'altitude-3.png'];
  const uploadedImages = pngs.map((png, i) => ({
    type: 'external',
    external: { url: `https://cdn.example.com/${i}-${png}` },
  }));
  let call = 0;
  const uploadImage = async (png) => {
    assert.equal(png, pngs[call]);
    return uploadedImages[call++];
  };

  await publish(
    { pngs, shareLink: 'https://excalidraw.com/#room=abc', notionPage: 'fixture-page-id' },
    { notionClient, uploadImage },
  );

  assert.equal(notionClient.calls.length, 1);
  const [{ block_id: blockId, children }] = notionClient.calls;
  assert.equal(blockId, 'fixture-page-id');

  assert.equal(children[0].object, 'block');
  assert.equal(children[0].type, 'heading_2');

  assert.deepEqual(children[1], {
    object: 'block',
    type: 'bookmark',
    bookmark: { url: 'https://excalidraw.com/#room=abc' },
  });

  const imageChildren = children.slice(2);
  assert.equal(imageChildren.length, pngs.length);
  imageChildren.forEach((child, i) => {
    assert.deepEqual(child, { object: 'block', type: 'image', image: uploadedImages[i] });
  });
});

test('publish calls uploadImage once per png, in order', async () => {
  const notionClient = makeRecordingNotionClient();
  const pngs = ['a.png', 'b.png'];
  const seen = [];
  const uploadImage = async (png) => {
    seen.push(png);
    return { type: 'external', external: { url: `https://cdn.example.com/${png}` } };
  };

  await publish(
    { pngs, shareLink: 'https://excalidraw.com/#room=xyz', notionPage: 'page-2' },
    { notionClient, uploadImage },
  );

  assert.deepEqual(seen, pngs);
});

test('publish with no pngs appends only the heading and bookmark, never calling uploadImage', async () => {
  const notionClient = makeRecordingNotionClient();
  let uploadImageCalls = 0;
  const uploadImage = async () => {
    uploadImageCalls += 1;
    return { type: 'external', external: { url: 'unused' } };
  };

  await publish(
    { pngs: [], shareLink: 'https://excalidraw.com/#room=empty', notionPage: 'page-3' },
    { notionClient, uploadImage },
  );

  assert.equal(uploadImageCalls, 0);
  const [{ children }] = notionClient.calls;
  assert.equal(children.length, 2);
  assert.equal(children[0].type, 'heading_2');
  assert.equal(children[1].type, 'bookmark');
});

test('publish rejects via the default uploadImage when none is injected, and never calls the notion client', async () => {
  const notionClient = makeRecordingNotionClient();

  await assert.rejects(
    () =>
      publish(
        { pngs: ['altitude-1.png'], shareLink: 'https://excalidraw.com/#room=abc', notionPage: 'page-4' },
        { notionClient },
      ),
    /no uploadImage strategy configured/,
  );

  assert.equal(notionClient.calls.length, 0);
});
