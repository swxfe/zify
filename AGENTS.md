# AGENTS.md — zify

zify manages Zapret on OpenWrt. Changes must preserve router management access,
recover from failed operations and fit devices with limited Flash and RAM.

## 1. Development

- Develop, build and run all tests in Linux or WSL2. In WSL, keep the checkout
  on the Linux filesystem. Do not work in the old Windows snapshot.
- Application logic lives in `src/lib/*.uc`. `src/main.uc`, `src/worker.uc` and
  `src/atom.uc` are entry points. Shell provides the transaction supervisor,
  package operations and system primitives.
- `tools/bundle.uc` assembles the standalone executable from source. Edit source
  files, then rebuild `dist/`; do not hand-edit generated releases.
- Upstream strategy scripts are data sources. Parse their definitions on the
  build host; never execute downloaded scripts to import strategies.

## 2. Managed paths and networking

Direct application writes are restricted to:

- `/opt/zapret/` — Zapret files, lists, fakes and integration hooks.
- `/etc/zify/` — manager state, resources, caches and backups.
- `/tmp/` — temporary files, transaction snapshots, locks and runtime logs.
- `/etc/config/zapret` and `/etc/config/zify`.
- `/usr/bin/zify` and `/usr/bin/zify.previous`.
- Lines ending in `# zify:zapret` in `/etc/crontabs/root`; preserve other lines.
- Named `firewall.zify_*` rules and `@defaults[0].flow_offloading` /
  `@defaults[0].flow_offloading_hw` in `/etc/config/firewall`.

Never modify `/etc/config/network`, `/etc/config/dhcp`, `/etc/hosts`, Dropbear
configuration, credentials or Wi-Fi configuration. Preserve LAN access to SSH
(port 22) and LuCI (ports 80/443), including during service or network failures.

Use UCI for firewall changes. Do not patch system firewall templates or ruleset
files. Device exclusions belong in Zapret's managed hook under `/opt/zapret/`.
Reload the firewall for rule changes. A full restart is permitted only when
changing the system flow-offloading flags, which recreate flowtable hooks.

## 3. Transactions and resources

- Run configuration changes through `src/shell/transaction.sh`. Snapshot all
  affected managed files and service state before writing. Roll back on failure,
  exceptions, SIGINT, SIGHUP and SIGTERM; clean staged payloads on abort.
- Publish direct file updates with Copy-on-Write: prepare a temporary file on
  the destination filesystem, validate its size/content and syntax where
  applicable, then atomically rename it. Do not truncate live files or use
  `sed -i`. Empty lists are valid; executables must not be empty.
- Use standard UCI operations for UCI configuration. Keep them inside the same
  transaction and preserve unrelated sections and options.
- Keep operations idempotent: deduplicate domains and ports, avoid adjacent
  `--new` delimiters and empty strategy blocks, and skip unchanged writes or
  unnecessary service restarts.
- Package managers modify external package databases. Validate dependencies and
  space before running `opkg`/`apk`, outside configuration transactions. Do not
  claim that configuration rollback undoes package installation or removal.
- Before downloading or installing payloads, check free space on `/overlay`,
  falling back to `/` when `/overlay` is absent. Require at least twice the
  payload size plus 5120 KiB. Unknown capacity is an error; stop when less than
  5120 KiB remains. `df -k` reports KiB, not MiB.
- Store logs and temporary data in `/tmp/`, never persistent Flash. Stream large
  lists or use `/tmp/`-backed processing instead of splitting huge strings in
  ucode. Enforce limits before allocating, downloading or unpacking data.

## 4. Verification

- Shell entry points use POSIX `/bin/sh` / BusyBox ash with `set -eu`; sourced
  fragments inherit it. No Bashisms, unquoted paths or dependencies on optional
  applets such as standalone `stat`.
- Shell files must pass `sh -n` and the project's ShellCheck checks with no
  warnings or errors.
- After every code change, run `make test`. All checks must pass. Do not delete,
  disable or weaken assertions to obtain a passing result; update expectations
  only when the required behavior changes and retain the underlying coverage.
- `make dist` runs local tests and builds code plus resources. For release
  validation run `E2E_WORKERS=4 make test-e2e` and `make test-matrix`.
  `make emulator-setup` prepares the ignored QEMU assets. `make help` lists targets.
- Run `make clean` separately from builds/tests. It removes `dist/`, `.test-tmp/`
  and `.build-tmp/`, while preserving the prepared `.emulator/`.

## 5. Commit Messages

Use `<type>: <short description>` for every commit. An optional scope is allowed:
`<type>(<scope>): <short description>`.

Allowed types:

- `feat` — new functionality.
- `bug` — bug fixes.
- `refactor` — code changes without changing behavior.
- `perf` — performance improvements.
- `test` — tests and test tooling.
- `docs` — documentation.
- `build` — build tooling and dependencies.
- `ci` — automated checks and release workflows.
- `chore` — repository maintenance.
- `release` — a release; use its version as the description, e.g. `release: 1.0`.

Keep the subject concise and specific, without a trailing period. Do not use
messages such as `update`, `changes` or `fix stuff`. Commit only work authorized
by the user; these naming rules do not authorize creating commits on their own.
