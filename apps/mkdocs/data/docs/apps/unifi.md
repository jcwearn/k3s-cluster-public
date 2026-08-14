# Unifi Dream Machine Pro (external)

Unifi Dream Machine Pro  actually runs on separate hardware, but an
`ExternalName` Service + Ingress makes it feel native to the cluster.

| URL | Where it really runs |
|---|---|
| `https://router.${DOMAIN}` | UDM Pro @ `${MGMT_PREFIX}.1` |
