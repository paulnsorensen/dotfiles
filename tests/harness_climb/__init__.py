"""harness-climb suites. Point the session database at a missing file.

No test then ingests or reads the real database.
"""

import os
import tempfile

os.environ["SESSIONS_DB"] = os.path.join(
    tempfile.gettempdir(), "harness-climb-tests-absent.duckdb"
)
