
/**
 * Composition root for the /roadmap generator.
 *
 *   node src/cli.js <sidecar-path> [--out <dir>]
 *
 * Wires the real capabilities (Linear fetch, renderers, Notion publish) into
 * runPipeline from environment configuration, writes the rendered outputs to
 * --out (default ./roadmap-out), and prints a report of produced files and
 * skipped capabilities. Never calls MCP — the skill layer creates the
 * Excalidraw scene from the emitted frame JSON afterwards.
 *
 * Known gaps, wired honestly rather than papered over (both reported as
 * skipped entries, never silent):
 * - no Excalidraw share link exists at CLI time (the scene is created later
 *   by the skill layer), so publish receives shareLink: null and omits the
 *   bookmark block;
 * - @notionhq/client v2 cannot perform the multipart step of Notion's File
 *   Upload API, so no PNG image blocks are published from the CLI.
 */

import { mkdir, readFile, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
import { parse as parseYaml } from 'yaml';

import { fetchLinear } from './fetchLinear.js';
import { mergeSidecar } from './mergeSidecar.js';
import { renderExec } from './renderExec.js';
import { renderLanes } from './renderLanes.js';
import { renderDag } from './renderDag.js';
import { publish } from './publish.js';
import { runPipeline } from './runPipeline.js';

async function defaultCreateNotionClient(auth) {
  const { Client } = await import('@notionhq/client');
  return new Client({ auth });
}

/**
 * Builds the runPipeline capabilities for the given environment and sidecar.
 *
 * - fetchLinear: present only when env.LINEAR_API_KEY is set.
 * - renderers: always present; each wraps its renderer with the
 *   mergeSidecar adaptation (raw YAML text + LinearModel -> RoadmapModel).
 * - publish: present only when env.NOTION_API_KEY is set AND the sidecar
 *   declares notion.page; wired with shareLink: null and no PNGs (see the
 *   module doc), which the returned `skipped` entries report.
 *
 * @param {Object} input
 * @param {NodeJS.ProcessEnv|Record<string, string>} input.env
 * @param {string} input.sidecarText  raw sidecar YAML
 * @param {(auth: string) => Promise<object>|object} [input.createNotionClient]  test seam
 * @returns {{capabilities: import('./runPipeline.js').RunPipelineCapabilities, skipped: {capability: string, reason: string}[]}}
 */
export function buildCapabilities({ env, sidecarText, createNotionClient = defaultCreateNotionClient }) {
  const parsed = parseYaml(sidecarText) ?? {};
  const subject = parsed.subject;
  const notionPage = parsed.notion?.page;
  const emptyLinear = { team: subject, projects: [], initiatives: [], relations: [] };
  const toRoadmapModel = (model) => mergeSidecar(model.linear ?? emptyLinear, model.sidecar);
  const skipped = [];

  const capabilities = {
    readFile: (sidecarPath) => readFile(sidecarPath, 'utf8'),
    renderers: {
      renderExec: async (model) => renderExec(toRoadmapModel(model)),
      renderLanes: async (model) => renderLanes(toRoadmapModel(model)),
      renderDag: async (model) => renderDag(toRoadmapModel(model)),
    },
  };

  if (env.LINEAR_API_KEY) {
    capabilities.fetchLinear = () => fetchLinear(subject);
  }

  if (env.NOTION_API_KEY && notionPage) {
    skipped.push({
      capability: 'notion-bookmark',
      reason:
        'no Excalidraw share link exists at CLI time (the skill layer creates the scene afterwards); bookmark block omitted',
    });
    skipped.push({
      capability: 'notion-images',
      reason:
        "no uploadImage strategy: @notionhq/client v2 cannot perform the multipart step of Notion's File Upload API; image blocks omitted",
    });
    capabilities.publish = async () => {
      const notionClient = await createNotionClient(env.NOTION_API_KEY);
      return publish({ pngs: [], shareLink: null, notionPage }, { notionClient });
    };
  }

  return { capabilities, skipped };
}

function parseArgs(argv) {
  let sidecarPath = null;
  let outDir = './roadmap-out';
  for (let i = 0; i < argv.length; i += 1) {
    if (argv[i] === '--out') {
      outDir = argv[i + 1];
      if (!outDir) throw new Error('--out requires a directory argument');
      i += 1;
    } else if (sidecarPath === null) {
      sidecarPath = argv[i];
    } else {
      throw new Error(`unexpected argument: ${argv[i]}`);
    }
  }
  if (!sidecarPath) throw new Error('usage: node src/cli.js <sidecar-path> [--out <dir>]');
  return { sidecarPath, outDir };
}

async function main(argv) {
  const { sidecarPath, outDir } = parseArgs(argv);
  const sidecarText = await readFile(sidecarPath, 'utf8');
  const { capabilities, skipped: wiringSkipped } = buildCapabilities({ env: process.env, sidecarText });

  const { outputs, skipped } = await runPipeline(sidecarPath, capabilities);

  await mkdir(outDir, { recursive: true });
  const written = [];
  const writeOutput = async (name, data) => {
    const path = join(outDir, name);
    await writeFile(path, data);
    written.push(path);
  };
  await writeOutput('altitude-1.json', JSON.stringify(outputs.exec, null, 2));
  await writeOutput('altitude-2.json', JSON.stringify(outputs.lanes, null, 2));
  await writeOutput('altitude-3.png', outputs.dag);

  for (const path of written) console.log(`wrote ${path}`);
  for (const { capability, reason } of [...skipped, ...wiringSkipped]) {
    console.log(`skipped ${capability}: ${reason}`);
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main(process.argv.slice(2)).catch((error) => {
    console.error(error.message);
    process.exitCode = 1;
  });
}
