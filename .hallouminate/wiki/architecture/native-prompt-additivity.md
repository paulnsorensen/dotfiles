# Native prompt additivity

Status: proposed in `fix/harness-additive-prompts`; not merged or deployed.

Claude's `--append-system-prompt-file` preserves the vendor system prompt.[^1]
Codex's `developer_instructions` adds guidance; `model_instructions_file` replaces built-in instructions.[^2]
Shared preferences therefore use additive channels by default.
An explicit custom replacement remains a user choice.

The proposed Codex installer marks its managed block inside `developer_instructions`.
Markers let later runs update shared text without duplicate blocks or removal of user text.
Migration removes only the model path owned by the retired installer.
A custom model path remains unchanged.

Isolated Codex profiles without `system_prompt` receive the repository preamble through `developer_instructions`.[^3]
Profiles with an explicit `system_prompt` retain `model_instructions_file` replacement to honor that profile choice.[^4]

[^1]: <https://code.claude.com/docs/en/cli-reference#system-prompt-flags>
[^2]: <https://learn.chatgpt.com/docs/config-file/config-reference>
[^3]: agent-profile/agent_profile/overlay.py:390-409
[^4]: agent-profile/agent_profile/overlay.py:410-418
