# Changelog

The app follows [semantic versioning](https://semver.org). The version is `MARKETING_VERSION` in `project.yml`.

## 0.1.0 (unreleased)

First release as an OpenAsy app, with a fresh history.

- Connections to PostgreSQL, Redshift, MySQL, MariaDB and SQLite; SSH tunnels (Ed25519, RSA, ECDSA keys or a password,
  fingerprint confirmed on first use); TLS off, required or verified, with a custom certificate authority and a client
  certificate; passwords in the macOS keychain; a window per connection with tabs.
- SQL editor with colouring, completion from the schema, the statement under the cursor, several results and a JSON
  cell viewer; transactions; confirmation before changes on production connections; read-only connections.
- Table data editing with pending changes shown as SQL; table structure changes as `ALTER` statements previewed first.
- Users and grants, EXPLAIN as a tree, schema compare with risk, a script and apply.
- History, saved queries, export to CSV, JSON and SQL `INSERT`, CSV import, share.
- The connection list shared with OpenAsy Schema (app group and keychain group `47QC6LXXDZ.com.openasy.db`), "Open in
  OpenAsy Schema" and `openasy-database-client://` links.
- Backups without passwords, 11 languages, light and dark themes from OpenAsy's tokens, About with the licence, the
  source code and the open-source software it is built on.
