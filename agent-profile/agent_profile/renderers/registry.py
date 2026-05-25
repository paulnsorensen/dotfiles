"""registry.py — barrel that wires the five harness renderers into the CLI.

The CLI ships an empty :data:`agent_profile.cli.RENDERERS` so tests can inject
stubs via ``set_renderers``. This barrel builds the production registry from the
five renderer classes and installs it; ``__main__`` calls :func:`install`
before dispatching ``cli.main``.
"""

from __future__ import annotations

from agent_profile import cli
from agent_profile.renderers.base import Renderer
from agent_profile.renderers.claude import ClaudeRenderer
from agent_profile.renderers.codex import CodexRenderer
from agent_profile.renderers.copilot import CopilotRenderer
from agent_profile.renderers.cursor import CursorRenderer
from agent_profile.renderers.opencode import OpencodeRenderer


def build_registry() -> dict[str, Renderer]:
    """Return the harness-name -> renderer map for the five production renderers."""
    renderers: list[Renderer] = [
        ClaudeRenderer(),
        CodexRenderer(),
        OpencodeRenderer(),
        CursorRenderer(),
        CopilotRenderer(),
    ]
    return {renderer.name: renderer for renderer in renderers}


def install() -> None:
    """Install the production registry into the CLI's renderer map."""
    cli.set_renderers(build_registry())
