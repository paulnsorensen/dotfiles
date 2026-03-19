/** @type {import('dependency-cruiser').IConfiguration} */
module.exports = {
  forbidden: [
    {
      name: "no-cross-slice-internals",
      comment:
        "Import from the slice's index/barrel file, not its internals. " +
        "Matches Sliced Bread check #1 and #5.",
      severity: "error",
      from: { path: "^src/domains/([^/]+)/" },
      to: {
        path: "^src/domains/([^/]+)/(?!index\\.)",
        pathNot: "^src/domains/$1/",
      },
    },
    {
      name: "no-domain-to-adapter",
      comment:
        "Domain code must not import from adapters or app layers. " +
        "Matches Sliced Bread check #2 and #3.",
      severity: "error",
      from: { path: "^src/domains/" },
      to: { path: "^src/(adapters|app)/" },
    },
    {
      name: "no-common-to-domain",
      comment:
        "common/ is a leaf — it imports nothing from sibling domain slices. " +
        "Matches Sliced Bread check #7.",
      severity: "error",
      from: { path: "^src/domains/common/" },
      to: {
        path: "^src/domains/(?!common/)",
      },
    },
  ],
  options: {
    doNotFollow: {
      path: "node_modules",
    },
    tsPreCompilationDeps: true,
    enhancedResolveOptions: {
      exportsFields: ["exports"],
      conditionNames: ["import", "require", "node", "default"],
    },
    reporterOptions: {
      json: {
        includeMetrics: true,
      },
    },
  },
};
