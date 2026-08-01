# Architecture and boundaries

Z Codex Router has three intentionally separate layers:

1. The release/bootstrap installer verifies source assets and registers the
   plugin cache.
2. The stable `zcr` launchers resolve only an installer-managed source pointer.
3. `routerctl` applies transactional lifecycle operations to the Codex home.

The launcher contains no routing policy. The active policy, stable profile
selection, receipt protocol, runtime observability, and authorization boundary
remain in [core/router.md](../plugins/z-codex-router/core/router.md) and
[portable/default.toml](../plugins/z-codex-router/profiles/portable/default.toml).

![Chinese architecture](images/z-codex-router-architecture-zh.png)

![English architecture](images/z-codex-router-architecture-en.png)

Lifecycle tooling must not modify those policy/mapping files. Security details
and disclosure instructions are in [SECURITY.md](../SECURITY.md); privacy and
terms are in [privacy.md](privacy.md) and [terms.md](terms.md).
