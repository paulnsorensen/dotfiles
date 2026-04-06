#!/usr/bin/env npx tsx

interface PluginInfo {
  name: string;
  version: string;
  status: "loaded" | "error";
}

function getPluginInfo(): PluginInfo {
  return {
    name: "cheese-flow",
    version: "0.1.0",
    status: "loaded",
  };
}

function main(): void {
  const info = getPluginInfo();
  const pluginRoot = process.env.CLAUDE_PLUGIN_ROOT ?? "(not set)";

  console.log(JSON.stringify({ ...info, pluginRoot }, null, 2));
}

main();
