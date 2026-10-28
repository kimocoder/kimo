# Security Policy

## Supported versions

kimo is a single script released from `master`. Security fixes land on `master`
and in the next version; older versions are not patched.

| Version                    | Supported          |
| -------------------------- | ------------------ |
| latest `master` / `1.1.x`  | :white_check_mark: |
| anything older             | :x:                |

`kimo version` prints the version you run. After `make install`, update with
`git pull && make install`.

## Reporting a vulnerability

Please report privately through GitHub:
**[Report a vulnerability](https://github.com/kimocoder/kimo/security/advisories/new)**
(the repository's *Security* tab, then *Report a vulnerability*).

Please do not open a public issue or pull request for a vulnerability before a
fix is released.

A useful report includes:

- the kimo version or commit, and the OS
- the command you ran and what happened, with any secrets replaced by
  placeholders
- what an attacker gains (for example: reads a key, runs code, reaches a
  service it should not)

You will get an acknowledgement once the report has been read, and updates
while a fix is prepared. Reporters are credited in the advisory unless they ask
not to be.

## Scope

kimo handles API keys, OAuth tokens and bridge tokens for many providers, and
edits other tools' configuration files. Reports are especially welcome for:

- a key or token sent to a host other than the one it belongs to, written to
  a world-readable file, a log, a URL, or a process's command line
- local services kimo starts (the Gemini shim, tunnels) being usable by other
  users or processes
- configuration edits that lose credentials or other user data
- installers or updates running code that was not verified

Out of scope: vulnerabilities in the third-party CLIs, models or services kimo
launches (please report those to their maintainers), and attacks that already
require control of your user account.
