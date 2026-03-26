# Onyx

Onyx is a package manager that combines a curated registry with the Nix binary cache. The registry provides name resolution and cleanup metadata; the Nix cache provides 80,000+ prebuilt packages. Third-party packages skip Nix entirely — they publish an onyx.toml with download URLs and install directly to `~/.local/bin`.


```bash
onyx install nodejs@22
onyx install go
onyx install username:repo
onyx install example.com
onyx x ruby -- script.rb
```

**Tiny static binary.** Zero dependencies. Works on Linux and macOS.

## Why

| | Onyx | Homebrew | Nix | apt |
|---|---|---|---|---|
| Install speed | Seconds (prebuilt) | Minutes (often builds) | Seconds | Seconds |
| Packages | 80,000+ | ~7,000 | 80,000+ | Distro-dependent |
| Multi-version | `onyx use node@20` | No | Manual | No |
| Cross-platform | Linux + macOS | macOS-first | Linux + macOS | Linux only |
| Binary size | <1MB | 12MB+ Ruby runtime | 30MB+ | System package |
| Deterministic | Yes (content-addressed) | No | Yes | No |
| Cleanup metadata | Yes (from Homebrew) | Yes | No | `dpkg --purge` |

Onyx takes the best of each world:
- **Nix's binary cache** — 80k+ packages, content-addressed, reproducible
- **Homebrew's cleanup metadata** — knows where apps scatter files
- **None of their complexity** — no Ruby, no Nix language, no learning curve

## Quickstart

### Install Onyx

```bash
curl -fsSL https://raw.githubusercontent.com/lilienblum/onyx/master/install.sh | sh
```

Or build from source:
```bash
zig build -Doptimize=ReleaseSmall
cp zig-out/bin/onyx ~/.local/bin/
```

### Setup

```bash
onyx init            # show setup commands
onyx init --exec     # or just run them
```

### Use it

```bash
# Install packages
onyx install nodejs@22
onyx install python
onyx install go@1.22

# Multiple versions coexist
onyx install nodejs@20
onyx use nodejs@20        # switch active version

# Run without installing (auto-fetched, cleaned up by gc after 30 days)
onyx exec jq -- '.name' package.json
onyx x ruby -- script.rb  # x, run are aliases for exec

# Manage
onyx list                 # show installed packages
onyx uninstall python     # remove a package
onyx upgrade              # upgrade all packages + onyx itself
onyx gc                   # clean up unused store paths + expired exec packages
```

Third-party packages (`user:repo`, `domain.com`) skip the nix store entirely and install directly to `~/.local/bin`.

## How it works

```mermaid
flowchart LR
    A[onyx install nodejs@22] --> B

    subgraph B[Registry]
        direction TB
        B1[Resolve alias] --> B2{Onyx package?}
    end

    B2 -->|yes| D[Install to ~/.local/share/onyx/]
    B2 -->|no| C[Nixhub API]
    C --> E[cache.nixos.org]
    E --> F[Install to /nix/store/]
    D -->|symlink| G[~/.local/bin/]
    F -->|symlink| G
```

The [Onyx registry](https://github.com/lilienblum/onyx/tree/registry/v0) is checked first. If it has a direct package definition, the binary is downloaded and installed. Otherwise, the name is resolved through the Nix path — Nixhub API, dependency closure from `cache.nixos.org`, parallel download, unpack, and symlink into `~/.local/bin/`.

Third-party packages (`user:repo`, `domain.com`) fetch an `onyx.toml` manifest, download the binary for your platform, verify SHA256, and install directly — no nix store involved.

## Commands

```
onyx install   <pkg>[@version]     Install a package
onyx uninstall <pkg>[@version]     Remove a package (or a specific version)
onyx exec      <pkg> [-- args]     Fetch + run without permanent install
onyx use       <pkg>@<version>     Switch active version
onyx list                          Show installed packages
onyx upgrade   [pkg | --self]      Upgrade packages or onyx itself
onyx gc                            Free disk space
onyx init      [--exec]            One-time /nix/store setup
onyx implode   [--exec]            Remove everything
```

Aliases: `i` install, `rm` uninstall, `x` exec, `ls` list.

## Architecture

```
~/.local/bin/node     →  /nix/store/abc123-nodejs-22.0.0/bin/node
~/.local/bin/my-tool  →  ~/.local/share/onyx/packages/my-tool/1.0.0/bin/my-tool

/nix/store/abc123-nodejs-22.0.0/           nix packages + closures
/nix/store/def456-glibc-2.39/
~/.local/share/onyx/packages/my-tool/      third-party packages

~/.local/share/onyx/state.json             package state
~/.cache/onyx/index.json                   registry index
```

## Third-party packages

Packages can publish an `onyx.toml` manifest:

```toml
[package]
name = "my-tool"

["1.0.0".macos]
url = "https://example.com/my-tool-darwin.tar.gz"
sha256 = "abc123..."
bin = ["my-tool"]

["1.0.0".linux-x64]
url = "https://example.com/my-tool-linux.tar.gz"
sha256 = "def456..."
bin = ["my-tool"]
```

Domain-based discovery via HTML meta tag:
```html
<meta name="onyx" content="git https://github.com/user/repo">
```

## Registry

The registry provides two things:

1. **Aliases** — maps friendly names like `nodejs` to nixpkgs attributes
2. **Cleanup metadata** — extracted from Homebrew, tells onyx what files to remove on uninstall

```toml
# registry/firefox.toml
[cleanup.macos]
paths = [
  "~/Library/Application Support/Firefox",
  "~/Library/Caches/org.mozilla.firefox",
  "~/Library/Preferences/org.mozilla.firefox.plist",
]

[cleanup.linux]
paths = [
  "~/.mozilla/firefox",
  "~/.cache/mozilla/firefox",
]
```

## Building

Requires [Zig](https://ziglang.org/) 0.15+.

```bash
zig build                          # debug build
zig build -Doptimize=ReleaseSmall  # optimized, <1MB
zig build test                     # run tests
```

Cross-compile for any target:
```bash
zig build -Dtarget=x86_64-linux-musl -Doptimize=ReleaseSmall
zig build -Dtarget=aarch64-linux-musl -Doptimize=ReleaseSmall
zig build -Dtarget=x86_64-macos -Doptimize=ReleaseSmall
zig build -Dtarget=aarch64-macos -Doptimize=ReleaseSmall
```

## License

MIT
