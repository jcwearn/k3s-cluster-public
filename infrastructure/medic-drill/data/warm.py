"""Warm an in-memory cache, then serve from it until stopped."""

import time

CACHE_MIB = 200

# Touch every page, so the cache is resident rather than lazily zeroed.
cache = b"a" * (CACHE_MIB * 1024 * 1024)
print(f"cache warm: {len(cache) >> 20} MiB", flush=True)

while True:
    time.sleep(3600)
