# ADR-003: Separate mutation approval from the agent session

## ADR-003: Separate mutation approval from the agent session [status: accepted]

- **Context:** A confirmation prompt inside the agent's own terminal is forgeable by the adversarial process. Blanket approval windows also let a pending call substitute different arguments.
- **Decision:** Accept approvals only on a control socket restricted to a separate operator identity. Bind approval to consumer, tool, canonical arguments, nonce, and a 60-second expiry; consume it once.
- **Alternatives:** In-session prompts; time-window approval; approve by tool name alone. Each lets the agent impersonate approval or substitute/replay a write.
- **Consequences:** Reads stay unattended while writes require deliberate operator action. Operators must use a separate authenticated session, and exact requests may need reapproval after any argument change or timeout.
