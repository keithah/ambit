# Ambit: rules for anyone (human or agent) working in this repo

Read [docs/05-plan.md](docs/05-plan.md) and [docs/decisions.md](docs/decisions.md) first. The first attempt
produced 352 commits and no release ([docs/01-evaluation.md](docs/01-evaluation.md)). These rules exist to
stop that from happening again.

## Guardrails

1. **Every week ends in a tagged, notarized release** a stranger can download. If a week ends without one,
   the next task is cutting scope, not extending the week.
2. **A blocker on the release path is always the next task.** Never route around it with other work.
3. **v1 scope is frozen** in [docs/02-product.md](docs/02-product.md). Changing it needs a dated line in
   `docs/decisions.md` written by Keith.
4. **Banned until v1 has external users:** plugin or manifest systems, rules/automation engines, contexts,
   multi-engine or relay work, iOS, Linux support, capability taxonomies, generic card composers.
5. **Rule of three:** no shared abstraction until the third concrete use. Each device gets a hand-written
   SwiftUI view. Duplication is fine.
6. **Never disable or delete a working user-visible feature** without a shipped replacement.
7. **Docs cap:** one page per document. No per-milestone spec-and-plan pairs.
8. **No migrations, golden fixtures or parity tests** before the first external user. Test device parsers,
   probe logic and the diagnosis matrix; nothing else is mandatory.
9. **`archive/v0` is read-only.** Copy files out of it per [docs/06-harvest.md](docs/06-harvest.md); never
   merge it, never port its tests wholesale.
10. **User-facing words** come from [docs/03-design.md](docs/03-design.md). No "entity", "slot", "provider",
    "context" or raw IDs in the UI.

## Build

`make test` (AmbitKit unit tests), `make build` (XcodeGen + xcodebuild), `make run`, `make release VERSION=x.y.z`
(see [docs/releasing.md](docs/releasing.md)). `Ambit.xcodeproj` and `App/Info.plist` are generated from `project.yml`;
never edit or commit them.
