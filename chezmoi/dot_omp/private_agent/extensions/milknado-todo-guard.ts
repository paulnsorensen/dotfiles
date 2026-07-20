import type { ExtensionAPI } from "@earendil-works/pi-coding-agent"

const TODO_COMMAND = /^\/todo(?:\s|$)/
const MESSAGE = "Native /todo is disabled. Use Milknado MCP for work tracking."

export default function (pi: ExtensionAPI) {
  // `todo.enabled` removes the model tool, but OMP still registers `/todo`.
  pi.on("input", (event, ctx) => {
    if (!TODO_COMMAND.test(event.text)) return { action: "continue" }

    ctx.ui.notify(MESSAGE, "warning")
    return { action: "handled" }
  })
}
