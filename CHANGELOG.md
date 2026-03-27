# Changelog

## [0.2.0](https://github.com/lilienblum/onyx/compare/onyx-v0.1.0...onyx-v0.2.0) (2026-03-27)


### Features

* add info command with platform-aware routing ([91a7fc6](https://github.com/lilienblum/onyx/commit/91a7fc63cd55db932b2804c0f2fff74633ccebff))
* move third-party packages to /opt/onyx ([1245217](https://github.com/lilienblum/onyx/commit/1245217b35fa2b871a4c53c86eee322a502f2d9b))
* version pinning and /opt/onyx init fix ([5364333](https://github.com/lilienblum/onyx/commit/53643336f961c08819f8245a8db1485a3534f327))

## 0.1.0 (2026-03-26)


### Features

* initial commit — Onyx package manager ([5b5ac71](https://github.com/lilienblum/onyx/commit/5b5ac712c9edc30cfc0e743b487568f3dd5aa42e))


### Bug Fixes

* chown /nix/store on macOS after mkdir ([6a66673](https://github.com/lilienblum/onyx/commit/6a66673493a85c8f725f5f1b197496c08640dbd1))
* create parent directories recursively to avoid FileNotFound on fresh systems ([8fb7b21](https://github.com/lilienblum/onyx/commit/8fb7b2128f2c08478677fee253dc22830c92a3dd))
* resolve username before sudo in onyx init --exec ([43981bb](https://github.com/lilienblum/onyx/commit/43981bb31580ea7ab4b7c5e48d2abc99af29d371))
* use onyx init --exec for nix store setup in CI ([11564d5](https://github.com/lilienblum/onyx/commit/11564d5fe20df32578b144ff0cf93ed71881e1cc))
