---
name: hello-cheese
description: Example skill for cheese-flow plugin. Demonstrates skill structure with a TypeScript script.
version: 0.1.0
---

# Hello Cheese

Example skill that runs a TypeScript script via the plugin's scripts directory.

## Usage

Run the hello script to verify the TypeScript toolchain is working:

```bash
npx tsx ${CLAUDE_PLUGIN_ROOT}/scripts/src/hello.ts
```

Report the output to the user.
