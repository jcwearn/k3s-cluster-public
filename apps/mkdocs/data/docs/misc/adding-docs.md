# Adding Docs to MkDocs  
*(How many docs could MkDocs dock if MkDocs could dock docs?)*

This quick guide walks through the **four touchpoints** you need to update
when adding new documentation pages to the homelab site.

---

## 1 Write the markdown

1. Pick (or create) the right folder under `docs/`  
   *Top-level doc?* → `docs/new-doc.md`  
   *Part of a section?* → `docs/apps/thing.md`, `docs/infrastructure/foo.md`, etc.
2. Use standard **Git-friendly Markdown** (no special extensions needed).

---

## 2 Expose it in `mkdocs.yml`

Edit the **`nav:`** section so MkDocs can route to the file:

```yaml
nav:
  - Home: 'index.md'
  - Apps: 'apps/index.md'
  - Infra: 'infrastructure/index.md'
  - Misc:
      - Guides index: 'misc/index.md'
      - Bootstrapping k3s: 'misc/bootstrapping-k3s.md'
      - **Your New Doc**: 'misc/adding-docs.md'   # ← new line
```

* Adding an entire **new top-level** menu? Give it an `index.md` as an
  entry point so visitors see a landing page, not a 404.

---

## 3 Update Kustomize ConfigMaps

Open `apps/mkdocs/kustomization.yaml` and either:

* **Append** the file to an existing `configMapGenerator` (`mkdocs-apps`,
  `mkdocs-infra`, `mkdocs-misc`, …), **or**
* **Create** a new ConfigMap if you're starting a fresh section:

```yaml
configMapGenerator:
  - name: mkdocs-misc
    namespace: mkdocs
    files:
      - data/docs/misc/index.md
      - data/docs/misc/adding-docs.md     # ← new file
```

> Remember: the generator paths must match whatever you mount in the Pod.

---

## 4 Mount the ConfigMap in the Deployment

*If you reused an existing ConfigMap*, you're done—the `Deployment` already
mounts it.
*If you added a brand-new ConfigMap* (e.g. `mkdocs-cheats`), add both a
`volume` and a matching `volumeMount`:

```yaml
# deployment.yaml (snippet)
volumeMounts:
  - name: mkdocs-cheats
    mountPath: /docs/docs/cheats
    readOnly: true

volumes:
  - name: mkdocs-cheats
    configMap:
      name: mkdocs-cheats
      defaultMode: 0444
```

MkDocs sees the file at build time → HTML lands in `/usr/share/nginx/html`.

---

## 5 Commit & admire

```bash
git add .
git commit -m "docs: add misc/adding-docs"
git push
```

Flux reconciles → the init-container rebuilds the site →
your shiny new page appears at
`https://docs.${DOMAIN}/misc/adding-docs/` (or whatever base URL you host).

---

> **Need inspiration?** Check out the [Bootstrapping k3s](bootstrapping-k3s.md)
> doc for structure ideas—and don't worry, MkDocs *can* dock more docs
> if you keep adding them. 😉