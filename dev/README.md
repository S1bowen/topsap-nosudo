# Development probes

These scripts are how the protocol in this repository was worked out. They are
**not needed to use it**, and they talk to the engine directly (through
`bin/svdbg`, a tiny SHM client) rather than through `topsap`.

`setup.sh` compiles `svdbg` from `svdbg.c` into `$TOPSAP_ROOT/bin/` along with
`svctl`.

## Prerequisites

* an installed tree (`./setup.sh ...`) and a sandbox that is **up**
  (`~/topsap/bin/topsap up`); the probes run inside it via `topsap run`
* the request fixtures in `$TOPSAP_ROOT/req/`, which are not in git because
  they contain the password's RSA-encrypted blob

## Regenerating the fixtures

```sh
dev/genreq.sh HOST PORT USER          # password read from stdin
```

writes, with mode 600 and `req/` gitignored:

| file | method | why |
|---|---|---|
| `q.json` | `query_status` | cheapest possible request; proves the control channel |
| `cl.json` | `check_line` | line/reachability probe against `HOST:PORT` |
| `ap.json` | `get_auth_param` | first half of the login handshake |
| `lg.json` | `login_by_pwd` | second half, carrying the same encrypted password |

`HOST PORT` are the gateway the sandbox already talks to (use
`127.0.0.1 443` when the engine is relaying through the vendor helper).
`genreq.sh` never stores the password; only the vendor public key's RSA ciphertext
reaches disk.

## The probes

| script | |
|---|---|
| `handshake_test.sh` | drives `q → check_line → auth_param → login → q` through `svdbg`, one request per step, printing each raw reply. Shows exactly which step a failing login dies on. |
| `strace_authparam.sh` | traces the engine's syscalls while it handles `query_status` and then `get_auth_param`; this is what revealed the `/sys/class/net` and `/opt` requirements. |
| `fake443_test.sh` | binds a fake TLS endpoint on `127.0.0.1:443` inside the sandbox and points `ap.json` at it, to see what the engine sends before any real gateway is involved. |

Read them before running: `handshake_test.sh` performs a **real login** with the
account in `lg.json`, so it consumes a 2FA-free password login and may evict an
existing session for that account. Prefer `strace_authparam.sh` unless you
actually need the handshake.

## Why these are kept

They document the recovered protocol better than prose can, and they are the
quickest way to tell "the gateway changed" apart from "the sandbox broke" when
something stops working.
