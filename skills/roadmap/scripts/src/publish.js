
/**
 * publish() pushes a rendered roadmap (altitude PNGs + the Excalidraw share
 * link) onto a Notion page: a heading, a bookmark block for the share link,
 * and one image block per PNG, in one `blocks.children.append` call.
 *
 * `notionClient` is injected — this module never constructs one; the CLI
 * wires the real @notionhq/client `Client` instance.
 *
 * @notionhq/client v2 has no `fileUploads` namespace and its generic
 * `request()` always JSON-encodes the body, so it cannot perform the
 * multipart "send file bytes" step of Notion's File Upload API. Rather than
 * bake one specific (and here, unverifiable) upload strategy into this
 * module, image resolution is delegated to an injectable `uploadImage`
 * function: production wiring can implement the file-upload flow directly
 * against the REST API, or resolve to an already-hosted external URL.
 * Either way, tests inject a recording stub and never hit the network.
 */

/**
 * @typedef {Object} NotionExternalImage
 * @property {'external'} type
 * @property {{url: string}} external
 */

/**
 * @typedef {Object} NotionFileUploadImage
 * @property {'file_upload'} type
 * @property {{id: string}} file_upload
 */

/**
 * @callback UploadImage
 * @param {*} png  one entry of the `pngs` array passed to publish()
 * @returns {Promise<NotionExternalImage|NotionFileUploadImage>}
 */

const HEADING_TEXT = 'Excalidraw roadmap';

function headingBlock() {
  return {
    object: 'block',
    type: 'heading_2',
    heading_2: { rich_text: [{ type: 'text', text: { content: HEADING_TEXT } }] },
  };
}

function bookmarkBlock(shareLink) {
  return { object: 'block', type: 'bookmark', bookmark: { url: shareLink } };
}

function imageBlock(image) {
  return { object: 'block', type: 'image', image };
}

/** @type {UploadImage} */
async function defaultUploadImage(png) {
  throw new Error(
    'publish: no uploadImage strategy configured. @notionhq/client v2 has no ' +
      "fileUploads API and its request() always JSON-encodes the body, so it can't " +
      "perform the multipart upload step of Notion's File Upload API. Inject an " +
      'uploadImage(png) that either drives that upload flow directly (e.g. via fetch) ' +
      "or resolves to an already-hosted external URL, returning " +
      "{ type: 'file_upload', file_upload: { id } } or { type: 'external', external: { url } }. " +
      `Received png: ${JSON.stringify(png)}`,
  );
}

/**
 * @param {Object} input
 * @param {*[]} input.pngs  altitude PNG entries, one image block per entry
 * @param {string} input.shareLink  Excalidraw share URL
 * @param {string} input.notionPage  Notion page id blocks are appended to
 * @param {Object} deps
 * @param {import('@notionhq/client').Client} deps.notionClient
 * @param {UploadImage} [deps.uploadImage]
 */
export async function publish(
  { pngs, shareLink, notionPage },
  { notionClient, uploadImage = defaultUploadImage },
) {
  const imageBlocks = [];
  for (const png of pngs) {
    imageBlocks.push(imageBlock(await uploadImage(png)));
  }

  return notionClient.blocks.children.append({
    block_id: notionPage,
    children: [headingBlock(), bookmarkBlock(shareLink), ...imageBlocks],
  });
}
