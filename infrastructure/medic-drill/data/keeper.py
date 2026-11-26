"""A single-instance worker that guards itself with a lock file.

It refuses to start while /state/lock exists, so two copies never run at
once. After CRASH_AFTER seconds it dies without releasing the lock, the way
a worker killed mid-job would. The container restarts into the same pod and
the same emptyDir, finds the stale lock, and crash loops. A fresh pod (a new
emptyDir) starts clean, until the next crash.
"""

import os
import sys
import time

LOCK = "/state/lock"
CRASH_AFTER = int(os.environ.get("CRASH_AFTER", "900"))

if os.path.exists(LOCK):
    with open(LOCK, encoding="utf-8") as f:
        holder = f.read().strip()
    print(f"lock-keeper: {LOCK} is held ({holder}); another instance may be running, refusing to start",
          file=sys.stderr, flush=True)
    sys.exit(1)

with open(LOCK, "w", encoding="utf-8") as f:
    f.write(f"pid {os.getpid()} on {os.environ.get('HOSTNAME', '?')} since {time.strftime('%H:%M:%S')}")
print("lock-keeper: lock taken, processing jobs", flush=True)

time.sleep(CRASH_AFTER)
print("lock-keeper: worker died mid-job; exiting without releasing the lock", file=sys.stderr, flush=True)
os._exit(1)
