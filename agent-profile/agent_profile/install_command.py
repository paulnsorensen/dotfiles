"""Command policy for the deprecated ``ap install`` path."""

INSTALL_MIGRATION_GUIDANCE = (
    "ap install is deprecated and no longer performs deployment.\n"
    "Use `dots sync` for live deployment.\n"
    "Use `ap compile <profile> --out <dir>` for staging."
)


def install_deprecation_message() -> str:
    return INSTALL_MIGRATION_GUIDANCE
