<div align="center">

# TablePlusPlus

**An open-source native macOS database GUI client.**

[![CI](https://github.com/ZQiannnn/tableplusplus/actions/workflows/ci.yml/badge.svg)](https://github.com/ZQiannnn/tableplusplus/actions/workflows/ci.yml)
[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](LICENSE)
![Platform](https://img.shields.io/badge/macOS-14%2B-black?logo=apple)

</div>

TablePlusPlus is a Swift 6 + SwiftUI database client built on native AppKit/SwiftUI
controls (no web UI layer). It talks to databases exclusively through a clean
driver SPI, so adding a new engine never touches the UI.

## Features

- **MySQL** connections with Keychain-backed passwords
- Table browsing with full row editing — `update` / `insert` / `delete` draft model,
  preview-SQL, single-transaction commit
- Rich context menu: Copy / Copy Row JSON|INSERT / Set NULL / Set Empty / Filter /
  Duplicate / Delete, multi-select batch edits
- SQL editor (`⌘R` to run) with a shared AppKit data grid
- Query history, recent objects
- Right-hand detail panel for any selected row (data / structure / query results)
- English / 简体中文 UI

See [`BACKLOG.md`](BACKLOG.md) for the roadmap (PostgreSQL, SSH tunneling, syntax
highlighting, …) and [`CLAUDE.md`](CLAUDE.md) for the architecture contract.

## Requirements

- macOS 14+
- Xcode 26 / Swift 6.2 (to build from source)

## Build & run from source

```bash
git clone https://github.com/ZQiannnn/tableplusplus.git
cd tableplusplus
./scripts/setup-cert.sh   # one-time: stable self-signed cert so Keychain stops prompting
./scripts/run.sh          # build + sign + launch
```

## Packaging a distributable .dmg

```bash
./scripts/package.sh --arch arm64     # → dist/TablePlusPlus-<version>-arm64.dmg
./scripts/package.sh --arch x86_64    # → dist/TablePlusPlus-<version>-x86_64.dmg
```

Tagging `vX.Y.Z` triggers the [release workflow](.github/workflows/release.yml),
which builds **both** Apple Silicon and Intel dmgs and attaches them to a GitHub Release.

> **Note on signing:** released dmgs are **self-signed, not notarized** (no Apple
> Developer ID yet). On first launch macOS Gatekeeper will block the app —
> right-click the app → **Open**, or run
> `xattr -dr com.apple.quarantine /Applications/TablePlusPlus.app`.

## License

[GPL-3.0](LICENSE).
