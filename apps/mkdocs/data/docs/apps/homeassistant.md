# Home Assistant (external)

Home Assistant actually runs on separate hardware, but an
`ExternalName` Service + Ingress makes it feel native to the cluster.

| URL | Where it really runs |
|---|---|
| `https://home.${DOMAIN}` | Home Assistant Yellow @ `${MGMT_PREFIX}.52` |
