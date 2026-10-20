# topsap-nosudo

Run the **TopSAP (天融信) SSL-VPN client on Linux without sudo** — no root, no
host changes — and get a plain `ssh` into the hosts behind the gateway.

The vendor ships a `.deb` whose engine writes to `/opt`, creates a `tun`
device and talks to a system-wide SysV shared-memory segment. All three
normally require root. This project runs the **unmodified vendor binaries**
inside a private user + network + mount + IPC namespace, with user-mode
networking, so it works as an ordinary user on a machine you do not control.

```
                        no sudo
                            |
   topsap up   ->   unshare -Urnm -i   ->   sandbox.sh
                            |                  |
                            |                  +-- fresh sysfs
                            |                  +-- private /etc/{hosts,resolv.conf,passwd}
                            |                  +-- vendor engine (sv_websrv)
                            |                  +-- tmux + control socket
                            |
                 slirp4netns tap0   (host netns, still unprivileged)
                            |
                         tun0   <- created inside the namespace
                            |
                    the hosts you actually want
```

## What you need

* Linux with **unprivileged user namespaces** enabled — check with
  `unshare -Ur true && echo ok`
* `socat`, `tmux`, `python3` (3.6+), `iproute2`, `openssh-client`, a C compiler
* `slirp4netns` (`apt install slirp4netns`, `dnf install slirp4netns`,
  `pacman -S slirp4netns`)
* The vendor `.deb` for your gateway (`TopSAP-<version>-x86_64.deb`). It is
  **not** included here.

Nothing runs as root at any point, and nothing outside `~/topsap` is written.

## Install

```sh
git clone https://github.com/<you>/topsap-nosudo
cd topsap-nosudo
./setup.sh /path/to/TopSAP-<version>-x86_64.deb
```

`setup.sh` copies the scripts to `~/topsap`, extracts the engine from the
`.deb`, compiles `svctl`, wires up `slirp4netns`, checks the dependencies and
creates `~/topsap/topsap.env`. It never touches anything outside
`~/topsap` and never needs root. Use `TOPSAP_ROOT=/somewhere/else` to change
the location.

Then:

```sh
$EDITOR ~/topsap/topsap.env     # gateway address/port, VPN account
```

and put the hosts you want to reach in `~/.ssh/config` — there is a template
in `~/topsap/state/ssh/config.example`:

```
Host vpn-login
  HostName 10.0.0.4
  User your-vpn-account
```

`~/topsap/topsap.env` only needs the gateway for the first login; the ssh
aliases are what `topsap ssh` uses afterwards.

## Use

```sh
~/topsap/bin/vpnup.sh                  # log in: password + Google-Authenticator code
~/topsap/bin/topsap ssh vpn-login      # interactive ssh, inside the tunnel
~/topsap/bin/topsap shell              # a shell inside the tunnel
~/topsap/bin/topsap run 'ip route'     # one command inside the tunnel
~/topsap/bin/topsap status             # what is running
~/topsap/bin/topsap down               # disconnect
```

The password is taken from `TOPSAP_PWD`, else `~/topsap/.pwd` (mode 600), else
prompted for. The TOTP is always prompted for — it is good for about 30
seconds, so run `vpnup.sh` with the authenticator already open.

`vpnup.sh` prints every step of the handshake (`get_auth_param` →
`login_by_pwd` → `chk_sms(otp)` → `get_config_info` → `query_status`), so a
failed login tells you which step failed.

| command | |
|---|---|
| `topsap up` / `down` | start / stop the sandbox |
| `topsap status` | state, tun address, routes |
| `topsap shell` | interactive shell inside the tunnel (tmux) |
| `topsap ssh [ARGS]` | `ssh` inside the tunnel, using your `~/.ssh/config` |
| `topsap windows` | list the sandbox's tmux windows |
| `topsap run CMD` | run one command inside the tunnel |
| `topsap vpn` / `logout` | engine status / log out |
| `topsap probe` | connectivity checks inside the tunnel |
| `topsap fwd` | publish a far-side port on this machine (below) |
| `topsap proxy` / `pxcheck` | lend this machine's proxy to the far side (below) |
| `topsap log [N]` | tail the engine log |

## Reaching a far-side port from this machine

The tunnel's hosts are reachable from inside the sandbox and nowhere else.
`topsap fwd` puts a loopback listener **on this machine** whose connections
are dialled from inside the tunnel, so any ordinary client here can use it:

```sh
~/topsap/bin/topsap fwd 19022 vpn-login:22     # that host's sshd on 127.0.0.1:19022
~/topsap/bin/topsap fwd 19080 10.0.0.1:8443    # any address, any port

ssh -p 19022 your-vpn-account@127.0.0.1        # plain ssh, topsap not involved
```

Syntax: `topsap fwd LPORT [ALIAS:]HOST[:PORT] [BIND-ADDR]`; `PORT` defaults to
`22`, `BIND-ADDR` to `127.0.0.1`. `ALIAS` is a `~/.ssh/config` name, so the
destination can be named the way you name it in ssh. `fwd ls` lists forwards,
`fwd check N` makes one real connection and shows what each half says,
`fwd rm N|all` stops them, and `topsap down` stops every one.

Worth knowing:

* The two halves live in different namespaces and meet at a unix socket in
  `~/topsap/run/fwd/` — nothing is installed, and no port is bound on the far
  side. The connection appears there as an ordinary one from your tunnel
  address.
* The listener is loopback-only by default. On a shared machine any local user
  can reach the far-side service while it is up, so keep only the forwards you
  are using. Pass a different `BIND-ADDR` only if you mean it.
* An alias that needs a `ProxyCommand` is dialled **through ssh**, which logs
  in to the jump host for every connection through the forward (roughly 17 s
  before the first byte). Use it occasionally, not for bulk traffic.

This is also how you use the VPN host as a jump box for other machines:
forward its `:22`, then put `ProxyJump` in front of that listener from
anywhere that can reach it.

## Lending this machine's proxy to the far side

If an `~/.ssh/config` host carries

```
RemoteForward 18438 127.0.0.1:7897
```

then **while a connection to that host is open**, anything on the far side can
use `127.0.0.1:18438` as an HTTP(S) proxy:

```sh
# on the far side
export http_proxy=http://127.0.0.1:18438 https_proxy=http://127.0.0.1:18438
curl https://example.com
```

`topsap proxy up` keeps such a connection alive in the background,
`topsap proxy down` ends it, and `topsap pxcheck` runs the checks over there
and prints what it sees. The right-hand address is the proxy **as this machine
sees it**, because it is dialled from inside the sandbox.

Set `TOPSAP_PROXY_TARGET` to the alias that carries the `RemoteForward` and
`TOPSAP_PROXY_PORT` to its first argument (default `18438`).

Two things to watch:

* The port is a single slot on the far side. If someone else already holds it,
  ssh says `remote port forwarding failed` and the far side keeps whichever
  proxy got there first.
* Traffic exits at this machine's proxy, so the far side sees your egress
  address, not the cluster's.

## Troubleshooting

* **`topsap up` fails immediately** — run `unshare -Ur true`; if that fails,
  the kernel or your distribution disables unprivileged user namespaces.
* **`tun0` appears but nothing routes** — check `topsap run 'ip route'`.
  `tstate_id` in `topsap vpn` sometimes stays `0` even when the tunnel is
  fine; trust the interface and the routes over that field.
* **Login errors** — `-40190`/`-40192` mean 2FA required, `-40026` wrong
  password, `-40020` locked out, `-40077` already logged in, `0` fine.
* **`2FA rejected` with a fresh code** — the code expired in transit; re-run
  `vpnup.sh`.
* **`topsap ssh` prints `[exited]` and nothing else** — the target port is not
  reachable from inside the tunnel; `topsap run 'ip route'` shows whether the
  route exists. Raise the preflight timeout with `TOPSAP_CONNECT_TIMEOUT`.
* **`fwd` says the far side sent nothing** — the service speaks second (like
  ssh). That is not a failure. `topsap fwd check N` tells the two apart.
* **`vpnssh: cannot reach <alias>:22 ...`** where `<alias>` is the name you
  typed — ssh never read `~/.ssh/config`, so the alias went to DNS. The sandbox
  binds a generated `/etc/passwd` that points uid 0 at your real home (OpenSSH
  finds `~/.ssh/config` through `getpwuid`, not `$HOME`), and that bind can
  disappear from a live namespace. `bin/assert-mounts.sh` re-creates it on every
  `topsap run` / `topsap ssh`, so this repairs itself; the message says so if the
  generated copy is gone too.
* **`bind /etc/hosts FAILED` / `cat: /etc/redhat-release: No such file`** —
  cosmetic; the vendor library probes for RHEL and the host is not RHEL.

More detail, including why each namespace and mount is needed, is in
[docs/HOW-IT-WORKS.md](docs/HOW-IT-WORKS.md).

## Layout

| path | |
|---|---|
| `bin/topsap` | driver: `up`, `down`, `status`, `ssh`, `shell`, `run`, `fwd`, `proxy`, … |
| `bin/sandbox.sh` | runs *inside* the namespaces; sysfs, `/etc`, engine, tmux |
| `bin/vpnup.sh` | one-shot login (password + TOTP) |
| `bin/vpnssh.sh` | ssh entry point that re-enters the namespace with the real `HOME` |
| `bin/assert-mounts.sh` | re-asserts the sandbox's `/etc/passwd` mapping on each entry |
| `bin/svmk.py` | builds the engine's request JSON (credential encoding, RSA) |
| `bin/svjson.py` | repairs the engine's bare-key replies into strict JSON |
| `src/svctl.c` | SHM client for the engine's control channel |
| `state/ssh/config.example` | ssh config template |
| `state/pxcheck.sh` | what `topsap pxcheck` runs on the far side |
| `setup.sh` | assembles `~/topsap` from this repo + the vendor `.deb` |
| `bin/pack.sh` | builds a portable, secret-free tarball of an installed tree |
| `dev/` | reverse-engineering probes used to derive the protocol (not needed to run) |

## Scope

Use it with an account you are entitled to use, against your own gateway. It
authenticates with that account's own password and 2FA; it does not bypass
authentication, does not grant anything the account does not already have, and
does not modify the host. The VPN engine and protocol are the vendor's; the
`.deb` is not redistributed here.

MIT licensed — see [LICENSE](LICENSE).

---

### 中文简要

在 Linux 上**免 sudo** 运行天融信（TopSAP）SSL-VPN 客户端：厂商的引擎二进制原样放进
私有的 user/network/mount/IPC namespace 里跑，用 `slirp4netns` 做用户态网络，因此普通
用户即可使用，且不修改宿主机。

```sh
./setup.sh /path/to/TopSAP-<版本>-x86_64.deb   # 解包引擎、编译 svctl、检查依赖
$EDITOR ~/topsap/topsap.env                    # 填网关地址/端口、账号
~/topsap/bin/vpnup.sh                          # 输入密码 + 动态口令
~/topsap/bin/topsap ssh <你的别名>              # 隧道内 ssh
```

密码可放在环境变量 `TOPSAP_PWD` 或 `~/topsap/.pwd`（600）。动态口令每次都现场输入。
`topsap fwd 端口 别名:端口` 可把隧道内主机的端口映射到本机 `127.0.0.1`，配合
`ProxyJump` / `-J` 即可把它当作跳板机使用。
