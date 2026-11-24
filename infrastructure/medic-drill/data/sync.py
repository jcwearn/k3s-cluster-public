"""Sync a report from an upstream that is down, and fail."""

import sys

print("report-sync: fetching upstream report", flush=True)
print("drill: upstream unavailable (connection refused)", file=sys.stderr, flush=True)
sys.exit(1)
