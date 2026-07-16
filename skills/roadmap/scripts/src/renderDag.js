/**
 * Renders the altitude-3 dependency DAG (model.items + model.edges) to a PNG.
 *
 * layoutDag(model) restricts the model to altitude-3 items (filterByAltitude)
 * at entry, then runs elkjs layered layout over the surviving items/edges —
 * items tagged out of altitude 3 never reach the DAG.
 *
 * renderDag(model) takes the positioned elk graph and paints it: node cards
 * via satori (for real text shaping) composited with hand-built SVG <path>
 * edges routed from elk's edge sections, then rasterized to PNG by resvg.
 * satori needs a real .ttf; loadFont is injectable so callers/tests can
 * supply one directly. If satori itself fails for any reason (font missing,
 * unparseable, etc.) renderDag falls back to a plain hand-built SVG for the
 * node cards (rects + <text>) so the PNG still renders — satori is a fidelity
 * upgrade, not a hard dependency of the pipeline.
 */

import { readdir, readFile } from 'node:fs/promises';
import { join } from 'node:path';
import ELK from 'elkjs';
import satori from 'satori';
import { Resvg } from '@resvg/resvg-js';

import { filterByAltitude } from './altitudeFilter.js';

const elk = new ELK();

const NODE_HEIGHT = 64;
const NODE_MIN_WIDTH = 140;
const NODE_CHAR_WIDTH = 8;
const NODE_PADDING = 40;

const DEFAULT_FONT_CANDIDATES = ['/System/Library/Fonts/Supplemental/Arial.ttf'];
const SYSTEM_FONT_SCAN_DIRS = ['/System/Library/Fonts/Supplemental', '/System/Library/Fonts'];

const ARROW_MARKER = `
  <marker id="dag-arrowhead" markerWidth="8" markerHeight="8" refX="7" refY="4" orient="auto">
    <path d="M0,0 L8,4 L0,8 Z" fill="#666666" />
  </marker>
`;

function estimateNodeWidth(title) {
  return Math.max(NODE_MIN_WIDTH, title.length * NODE_CHAR_WIDTH + NODE_PADDING);
}

/**
 * Filters the model to altitude 3, lays out the remaining items/edges with
 * elkjs, and returns the positioned graph (children carry x/y/width/height
 * plus the source RoadmapItem under `.item`; edges carry `.sections` with
 * routed points). Exported for testing.
 *
 * @param {import('./types.js').RoadmapModel} inputModel
 * @param {{layoutOptions?: Record<string, string>}} [options]
 */
async function layoutDag(inputModel, options = {}) {
  const model = filterByAltitude(inputModel, 3);
  const graph = {
    id: 'root',
    layoutOptions: {
      'elk.algorithm': 'layered',
      'elk.direction': 'RIGHT',
      'elk.spacing.nodeNode': '40',
      'elk.layered.spacing.nodeNodeBetweenLayers': '80',
      ...options.layoutOptions,
    },
    children: model.items.map((item) => ({
      id: item.ref,
      width: estimateNodeWidth(item.title),
      height: NODE_HEIGHT,
      item,
    })),
    edges: model.edges.map((edge) => ({
      id: `${edge.sourceRef}->${edge.targetRef}`,
      sources: [edge.sourceRef],
      targets: [edge.targetRef],
    })),
  };

  return elk.layout(graph);
}

async function scanForSystemFont() {
  for (const dir of SYSTEM_FONT_SCAN_DIRS) {
    const entries = await readdir(dir, { withFileTypes: true }).catch(() => []);
    const ttf = entries.find((entry) => entry.isFile() && entry.name.toLowerCase().endsWith('.ttf'));
    if (ttf) return readFile(join(dir, ttf.name));
  }
  return null;
}

/** Default font loader for satori: a known system TTF, else the first .ttf found by scanning. */
async function defaultFontLoader() {
  for (const candidate of DEFAULT_FONT_CANDIDATES) {
    const data = await readFile(candidate).catch(() => null);
    if (data) return data;
  }

  const scanned = await scanForSystemFont();
  if (scanned) return scanned;

  throw new Error('renderDag: no system TTF font found; pass options.loadFont');
}

function escapeXml(value) {
  return value.replace(/[&<>"']/g, (char) => (
    { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&apos;' }[char]
  ));
}

function edgePathData(edge, margin) {
  const section = edge.sections?.[0];
  if (!section) return null;
  const points = [section.startPoint, ...(section.bendPoints ?? []), section.endPoint];
  return points.map((point, index) => `${index === 0 ? 'M' : 'L'} ${point.x + margin} ${point.y + margin}`).join(' ');
}

function buildEdgesSvg(edges, margin) {
  return edges
    .map((edge) => {
      const d = edgePathData(edge, margin);
      if (!d) return '';
      return `<path d="${d}" fill="none" stroke="#666666" stroke-width="2" marker-end="url(#dag-arrowhead)" />`;
    })
    .join('\n');
}

function nodeCardElement(node, margin, fontName) {
  const item = node.item;
  return {
    type: 'div',
    props: {
      style: {
        position: 'absolute',
        left: node.x + margin,
        top: node.y + margin,
        width: node.width,
        height: node.height,
        display: 'flex',
        flexDirection: 'column',
        justifyContent: 'center',
        padding: '8px 12px',
        background: '#ffffff',
        border: '2px solid #333333',
        borderRadius: 8,
        fontFamily: fontName,
      },
      children: [
        { type: 'div', props: { style: { fontSize: 16, fontWeight: 700, color: '#111111' }, children: item.title } },
        item.status
          ? { type: 'div', props: { style: { fontSize: 12, color: '#666666', marginTop: 4 }, children: item.status } }
          : null,
      ].filter(Boolean),
    },
  };
}

async function renderNodeCardsSatori(nodes, { width, height, margin, fontData, fontName }) {
  const tree = {
    type: 'div',
    props: {
      style: { width, height, position: 'relative', display: 'flex' },
      children: nodes.map((node) => nodeCardElement(node, margin, fontName)),
    },
  };

  const svg = await satori(tree, {
    width,
    height,
    fonts: [{ name: fontName, data: fontData, weight: 400, style: 'normal' }],
  });

  const inner = svg.match(/^<svg[^>]*>([\s\S]*)<\/svg>$/);
  return inner ? inner[1] : svg;
}

function buildNodeCardsPlainSvg(nodes, margin) {
  return nodes
    .map((node) => {
      const item = node.item;
      const x = node.x + margin;
      const y = node.y + margin;
      const statusLine = item.status
        ? `<text x="${x + 12}" y="${y + 44}" font-size="12" fill="#666666">${escapeXml(item.status)}</text>`
        : '';
      return `
        <rect x="${x}" y="${y}" width="${node.width}" height="${node.height}" rx="8" fill="#ffffff" stroke="#333333" stroke-width="2" />
        <text x="${x + 12}" y="${y + 24}" font-size="16" font-weight="700" fill="#111111">${escapeXml(item.title)}</text>
        ${statusLine}
      `;
    })
    .join('\n');
}

/**
 * Lays out and rasterizes model.items/model.edges (altitude-3 dependency DAG)
 * to a PNG buffer.
 *
 * @param {import('./types.js').RoadmapModel} model
 * @param {{
 *   margin?: number,
 *   fontName?: string,
 *   loadFont?: () => Promise<Buffer>,
 *   layoutOptions?: Record<string, string>,
 * }} [options]
 * @returns {Promise<Buffer>}
 */
async function renderDag(model, options = {}) {
  const graph = await layoutDag(model, options);
  const margin = options.margin ?? 24;
  const width = graph.width + margin * 2;
  const height = graph.height + margin * 2;
  const fontName = options.fontName ?? 'Arial';

  const edgesSvg = buildEdgesSvg(graph.edges, margin);

  let nodesSvg;
  try {
    const loadFont = options.loadFont ?? defaultFontLoader;
    const fontData = await loadFont();
    nodesSvg = await renderNodeCardsSatori(graph.children, { width, height, margin, fontData, fontName });
  } catch (error) {
    // satori fidelity path failed (no usable system TTF, unparseable font, etc.) —
    // fall back to hand-built SVG rects/text so renderDag still ships a PNG.
    console.error(`renderDag: satori node rendering failed (${error.message}); falling back to plain SVG`);
    nodesSvg = buildNodeCardsPlainSvg(graph.children, margin);
  }

  const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="${width}" height="${height}" viewBox="0 0 ${width} ${height}">
    <rect width="${width}" height="${height}" fill="#ffffff" />
    <defs>${ARROW_MARKER}</defs>
    <g>${edgesSvg}</g>
    ${nodesSvg}
  </svg>`;

  const resvg = new Resvg(svg);
  return resvg.render().asPng();
}

export { layoutDag, renderDag };
