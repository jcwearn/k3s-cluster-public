# TrueNAS: "Unable to determine default interface" Docker Fix

Troubleshooting guide for the `Unable to determine default interface` error that
prevents Docker/Applications from starting on TrueNAS SCALE.

## Symptoms

- Applications show as **FAILED** in the TrueNAS UI
- Critical alert: `Failed to configure docker for Applications: Unable to determine default interface`
- Docker service is `inactive (dead)`:

    ```bash
    sudo systemctl status docker
    # Active: inactive (dead)
    ```

- Middleware confirms the failure:

    ```bash
    midclt call docker.status
    # {"description": "Application(s) have failed to start:\n[EFAULT] Unable to determine default interface", "status": "FAILED"}
    ```

## Root cause

TrueNAS determines the default network interface by reading `/proc/net/route`
and looking for a route with flags `0x0003` (UP + GATEWAY). The relevant code
lives in the middleware:

- `/usr/lib/python3/dist-packages/middlewared/utils/interface.py`
- `/usr/lib/python3/dist-packages/middlewared/plugins/docker/state_setup.py`

The check can fail when:

1. **No persisted IPv4 gateway** -- The gateway is provided by DHCP at runtime
   but not stored in TrueNAS's configuration. The middleware may not find it
   during early boot.
2. **Multiple NICs with DHCP** -- Two interfaces both configured for DHCP with
   no static aliases makes it ambiguous which is "default."
3. **Boot timing** -- The default route may not be established when Docker tries
   to start at boot.

In the specific case encountered (TrueNAS **25.04** on an Intel N150 Mini):

- `ipv4gateway: ""` in stored config (even though runtime state had
  `${LAN_PREFIX}.1` from DHCP)
- Two physical interfaces (`enp1s0`, `enp2s0`) both set to `ipv4_dhcp: true`
  with empty `aliases`
- The initial failure at boot became a **stale cached status** that persisted
  even after the route was available

## Diagnosis

```bash
# Check Docker/apps status
midclt call docker.status

# View stored network config vs runtime state
midclt call network.configuration.config | python3 -m json.tool

# Verify the route exists (should show "default via <gateway> dev <interface>")
ip route show default
cat /proc/net/route

# Test the interface detection function directly
sudo python3 -c "from middlewared.utils.interface import get_default_interface; print(get_default_interface())"

# Test the full validation check
midclt call docker.setup.validate_interfaces
```

## Resolution

### Step 1 -- Persist the IPv4 gateway

If `ipv4gateway` is empty in the stored config but present at runtime, set it
explicitly:

```bash
midclt call network.configuration.update '{"ipv4gateway": "${LAN_PREFIX}.1"}'
```

Replace `${LAN_PREFIX}.1` with your actual gateway address (check `ip route show default`).

### Step 2 -- Verify the interface detection works

```bash
sudo python3 -c "from middlewared.utils.interface import get_default_interface; print(get_default_interface())"
# Should print: enp1s0 (or your primary interface)

midclt call docker.setup.validate_interfaces
# Should return: null (no error)
```

### Step 3 -- Restart the Docker/apps subsystem

Re-applying the pool via `midclt call docker.update '{"pool": "pool"}'` does
**not** trigger a restart if the config hasn't changed. Call `status_change`
directly instead:

```bash
midclt call docker.setup.status_change
```

This mounts the ix-apps dataset and starts the Docker service, running all
validation checks fresh.

### Step 4 -- Verify

```bash
midclt call docker.status
# Should show: {"description": "...", "status": "RUNNING"}
```

## Key takeaways

- **`docker.update` is a no-op if config unchanged** -- The update code checks
  `if old_config != config` and skips the restart path. Use
  `midclt call docker.setup.status_change` to force a fresh start.
- **Stored config vs runtime state** -- TrueNAS maintains both a stored
  configuration and a runtime state. DHCP-provided values appear in `state` but
  not in the stored config. Docker's interface detection depends on
  `/proc/net/route` (runtime), but boot-time failures can produce a stale cached
  status.
- **`validate_interfaces` is the gatekeeper** -- Before Docker starts, TrueNAS
  calls `docker.setup.validate_fs` which calls `validate_interfaces`. If this
  check fails, Docker never attempts to start.

## References

- Middleware source: `/usr/lib/python3/dist-packages/middlewared/plugins/docker/`
- Interface detection: `/usr/lib/python3/dist-packages/middlewared/utils/interface.py`
- [TrueNAS Community Forums](https://forums.truenas.com) -- search for "Unable to determine default interface"
