# database-client

[![CI](https://github.com/openasy/database-client/actions/workflows/ci.yml/badge.svg)](https://github.com/openasy/database-client/actions/workflows/ci.yml)
[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-000000?logo=apple&logoColor=white)](./project.yml)
[![License: AGPL-3.0](https://img.shields.io/badge/license-AGPL--3.0-blue)](./LICENSE)

OpenAsy Database Client: **a native Mac app to query, browse and change your databases**. PostgreSQL, Redshift,
MySQL, MariaDB and SQLite, directly or through an SSH tunnel, with TLS verified. Queries go straight from your Mac to
your database; there is no OpenAsy server in between and no account. It is a desktop app, separate from
[OpenAsy Database](https://github.com/openasy/database), the server product that watches PostgreSQL's performance.

```
OpenAsy Database Client ──TCP / TLS──────────▶ PostgreSQL, Redshift, MySQL, MariaDB
        │               ──SSH tunnel─▶ bastion ─▶ the same, on a private network
        ├── SQLite files on this Mac
        └── openasy-schema://  ◀──── the shared connection list ────▶  OpenAsy Schema
```

## What it does

- **Connections**: PostgreSQL, Redshift, MySQL, MariaDB, SQLite. SSH tunnels with Ed25519, RSA and ECDSA keys or a
  password, the server's fingerprint confirmed on first use. TLS off, required or verified, with your own certificate
  authority and a client certificate. Passwords in the macOS keychain. One window per connection, tabs inside.
- **SQL editor**: syntax colouring, completion from the schema (tables, aliases, columns), run the statement under the
  cursor, the selection or everything, stop, the error position underlined; several results; a JSON viewer for cells.
- **Transactions**: begin, commit, roll back, with the autocommit state shown. Connections tagged production ask before
  a statement that changes data; a connection can be read-only.
- **Table data**: filters, sorting, endless scrolling; edit in place, add and delete rows, see the pending changes as
  SQL, then commit them in one transaction or discard them.
- **Table structure**: columns, indexes and foreign keys, applied as `ALTER` statements you see first (on SQLite the
  table is rebuilt safely). The `CREATE` statement of any table.
- **Users and grants** (MySQL and MariaDB accounts, PostgreSQL roles, Redshift users), **EXPLAIN** as a tree, and
  **schema compare** between two connections or two schemas, with each difference's risk, a script and apply.
- **History and saved queries**; export to CSV, JSON or SQL `INSERT` and share; import CSV into a table.
- A sample database to try it on, backups of connections and settings (never passwords), 11 languages, light and dark.

## Privacy

The app talks only to the servers you add. It has no analytics, no telemetry and no account. Passwords stay in your
Mac's keychain; they are never written to the connection list or to a backup. The app runs in the macOS sandbox with
outgoing connections only: nothing listens, and the SSH tunnel is a channel inside the app, not an open local port.

## Install

Builds are not published yet. They will be Developer ID signed, notarized DMGs on
[GitHub Releases](https://github.com/openasy/database-client/releases). Until then, build it from source.

## Build

The app needs [macos-kit](https://github.com/openasy/macos-kit) next to it, Xcode and
[XcodeGen](https://github.com/yonaskolb/XcodeGen):

```bash
git clone https://github.com/openasy/macos-kit
git clone https://github.com/openasy/database-client
cd database-client
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer   # when xcode-select points at the Command Line Tools
xcodegen generate                                                 # DatabaseClient.xcodeproj from project.yml
xcodebuild -project DatabaseClient.xcodeproj -scheme DatabaseClient -destination 'platform=macOS' test
python3 tools/check-strings.py                                    # every language has every text
scripts/build.sh                                                  # Release build check (unsigned)
scripts/shot.sh welcome - dark en                                 # a screenshot of the debug build, in the background
```

- The debug build runs in its own container (`com.openasy.database-client.dev`, group
  `47QC6LXXDZ.com.openasy.db.dev`); a release build is `com.openasy.database-client` with the group
  `47QC6LXXDZ.com.openasy.db`.
- Xcode does not sign local builds (`CODE_SIGNING_ALLOWED=NO`); `scripts/adhoc-sign.sh` signs them ad hoc with the
  entitlements, because Xcode does not put an app group into a signature without a provisioning profile. The debug
  build uses `DatabaseClient-Debug.entitlements` without `keychain-access-groups` (macOS does not open an ad-hoc
  signed app with it; passwords then go to the keychain without a group). The release build's entitlements are
  complete, so the unsigned release build of `scripts/build.sh` is a check and does not open locally.
- Sandbox entitlements are in `project.yml` (XcodeGen writes the file).
- Database engines, schema reading, DDL and data editing SQL are in macos-kit's `OpenAsyMacDB`; the screens, tabs,
  history and backups are in this app.

## Release

A Developer ID build overrides the local signing: `CODE_SIGNING_ALLOWED=YES OA_ADHOC_SIGN=NO CODE_SIGN_STYLE=Manual
CODE_SIGN_IDENTITY="Developer ID Application" DEVELOPMENT_TEAM=47QC6LXXDZ PROVISIONING_PROFILE_SPECIFIER=<a Developer ID
profile with the app group and keychain group>`, then `notarytool` and a DMG. This is not automated yet; certificates
and notarization credentials never enter the repository.

## Shared connections and links

OpenAsy Database Client and [OpenAsy Schema](https://github.com/openasy/schema) keep one connection list
(`connections.json` in the app group container, macos-kit's `OADBConnectionStore`), with passwords in the keychain's
shared group (service `com.openasy.db`, accounts `conn:<id>:db` and `conn:<id>:ssh`). File bookmarks (SQLite files,
SSH keys, certificate authorities) belong to each app: `Application Support/OpenAsy Database Client/connection-bookmarks.json`
inside the sandbox container. A connection added in Schema asks for its file once when it is first opened here.

- **Open in OpenAsy Schema** (Connection menu, and a connection or schema in the sidebar) shows when Schema is
  installed and opens `openasy-schema://import?conn=<id>&schema=<name>`.
- Incoming: `openasy-database-client://open?conn=<id>[&schema=][&table=]` and
  `openasy-database-client://query?conn=<id>[&schema=](&file=<name in the group's inbox>|&sql=)`. A query from a link
  opens in a tab; it is never run by itself.
- Other data is in `Application Support/OpenAsy Database Client/` in the container (`history.json`, `saved.json`,
  `known_hosts.json`).

## Licence

AGPL-3.0-only. The open-source software the app is built on, and its licences, are listed in the About window.
