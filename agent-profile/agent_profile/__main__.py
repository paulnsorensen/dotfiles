"""python -m agent_profile entrypoint."""

from agent_profile.cli import main
from agent_profile.renderers.registry import install

if __name__ == "__main__":
    install()
    raise SystemExit(main())
