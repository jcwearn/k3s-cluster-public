# Miscellaneous Guides

This section collects “grab-and go” reference documents that don't fit under
Infrastructure or Application workloads—handy for quick look-ups while working
on the homelab.

| Guide | What it covers | Docs |
|-------|----------------|------|
| **Adding Docs** | Step-by-step from new docs to mkdocs | [Read more](adding-docs.md) |
| **Bootstrapping a 3-Node k3s Cluster** | Step-by-step from fresh Ubuntu 24.04 installs to a fully GitOps-driven, HA k3s control-plane with Flux. | [Read more](bootstrapping-k3s.md) |
| **Updating kube-vip** | Quick guide for pulling the latest kube-vip manifest, recreating the symlink, and notes on better long-term management patterns. | [Read more](kube-vip-update.md) |
| **Reinitializing Tailscale Machine** | Quick guide on how to refresh/reinitialize a tailscale machine that has gotten in a bad state. | [Read more](refreshing-tailscale-machines.md) |
| **Flux GitHub App Authentication** | How Flux authenticates to GitHub via a GitHub App, and how to rotate the private key | [Read more](rotating-flux-github-pat.md) |
| **Proxmox Kernel Maintenance** | Why `autoremove` never prunes kernels on the hypervisors, and how to do it safely by hand. | [Read more](proxmox-kernel-maintenance.md) |
| **Security Hardening** | Security Hardening Guide and Checklist | [Read more](security-hardening.md) |
| **TrueNAS Docker Default Interface Fix** | Troubleshooting "Unable to determine default interface" Docker/Apps failure on TrueNAS | [Read more](truenas-docker-default-interface.md) |
| **Updating flux** | Quick guide for updating to the latest version of flux | [Read more](updating-flux.md) |
| **kubectl Cheat Sheet** | *Coming soon* — common commands, JSONPath tricks, log tailing, and context juggling. | |
| **Flux Cheat Sheet** | *Coming soon* — reconciling Kustomizations, suspending HelmReleases, and debugging drift. | |

> **Tip**  
> Have another snippet you reference often? Drop it in this folder and add a
> row to the table so you’ll never hunt for it again.