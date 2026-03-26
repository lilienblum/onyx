# AGENTS.md

This file provides guidance to agents when working with code in this repository.

## Build and Test

```bash
zig build                          # debug build
zig build -Doptimize=ReleaseSmall  # optimized, <1MB
zig build test                     # run all tests
```

Zig 0.15+ required. This is Zig 0.15 which uses newer APIs (`std.Io.Writer.Allocating`, `std.Io.Reader.fixed`, `std.compress.zstd.Decompress`). Don't use `std.io.getStdOut()` — it doesn't exist in 0.15. For stdout output, use `std.posix.write(std.posix.STDOUT_FILENO, ...)`.

## Architecture

Onyx is a package manager with two install paths: **registry packages** (resolved via Onyx registry, fetched from the Nix binary cache) and **third-party packages** (GitHub/domain sources with `onyx.toml` manifests, installed directly).

### Source files

- **main.zig** — CLI entry point, all command implementations (`cmdInstall`, `cmdExec`, `cmdUninstall`, `cmdUse`, `cmdGc`, `cmdUpgrade`, `cmdInit`, `cmdImplode`)
- **cli.zig** — argument parsing, `PackageRef` (name@version), `Command` union
- **resolver.zig** — registry alias resolution, Nixhub API calls, index caching with TTL
- **fetcher.zig** — NAR closure fetching, parallel download (thread pool), hash verification
- **source.zig** — third-party package resolution (GitHub, domain), TOML manifest parsing, meta tag discovery
- **store.zig** — `Database` struct: state.json load/save, version management, symlink install/remove
- **nar.zig** — NAR archive format unpacker (regular files, directories, symlinks)
- **ui.zig** — output functions. Data output (`print`, `ok`, `pkg`, `listPackage`) goes to stdout. Errors/warnings (`err`, `warn`, `status`, `dim`) go to stderr.
- **xdg.zig** — XDG paths (`~/.local/share/onyx/`, `~/.cache/onyx/`, `~/.local/bin/`)

### Two install paths

**Nix path**: `resolveAlias` (registry index) → `resolve` (Nixhub API) → `fetchClosure` (cache.nixos.org, parallel NARs) → unpack to `/nix/store/` → symlink to `~/.local/bin/`

**Third-party path**: `resolveGithub`/`resolveDomain` → download binary/tarball → install to `~/.local/share/onyx/packages/{name}/{version}/` → symlink to `~/.local/bin/`

Both paths store state in `~/.local/share/onyx/state.json` and create symlinks in `~/.local/bin/`.

### Key patterns

- **Locking**: `acquireLock`/`releaseLock` via file lock on `~/.local/share/onyx/lock`. Commands that mutate state (`install`, `uninstall`, `use`, `gc`, `upgrade`) must hold the lock. `cmdInstall` wraps `cmdInstallInner` to avoid recursive lock acquisition when installing dependencies.
- **Alias resolution**: `resolveAlias` checks `~/.cache/onyx/index.json`. Fast commands (`exec`, `use`, `list`) use cached index forever. Slow commands (`install`, `upgrade`) refresh if >1 day old via `resolveAliasFresh`.
- **Ephemeral packages**: `exec` auto-installs packages marked `ephemeral: true` with `last_used` timestamp. These are hidden from `list` and cleaned by `gc` after 30 days.
- **Symlink ownership**: `removeSymlinks` uses `readLink` to verify the symlink points to `/nix/store/` or `/onyx/packages/` before deleting — never removes files owned by other tools.
- **exec fast path**: `cmdExec` checks state.json first. If the package is already installed, it skips all network calls and directly `execv`s into the binary.

### Registry

The registry lives on the `registry/v0` branch. `index.json` maps aliases (e.g., `nodejs` → nixpkgs attribute). Per-package `.toml` files contain cleanup metadata (paths to delete on uninstall, extracted from Homebrew).
