# How it works, and why

The vendor client assumes it is the only thing on the machine and that it may
write wherever it likes. This project keeps the binaries but removes those
assumptions one by one. Nothing here is a patch: the shipped engine runs
unmodified, and every constraint is met by the environment around it.

## Namespaces

```
unshare -Urnm -i -- sandbox.sh
```

* `-U` maps your uid to 0 inside (needed because the engine writes to `/opt`
  and to a SysV SHM segment).
* `-n` gives a private network namespace, so the `tun0` device and its routes
  exist nowhere else.
* `-m` gives a private mount namespace, so every bind mount below is local.
* `-i` gives a private IPC namespace.
* There is deliberately **no pid namespace**: the host has to be able to reach
  into the network namespace to start `slirp4netns` on it, and pid 1 in a new
  pid namespace cannot be joined that way without more machinery.

Inside, `sandbox.sh` makes `/` private (`mount --make-rprivate /`) before doing
anything else, so no mount can propagate back to the host.

## A fresh sysfs is mandatory

`unshare -m` alone does **not** give you a new `sysfs`. `/sys` stays the host's
superblock, still tagged with the initial network namespace, so
`/sys/class/net/` lists the host's interfaces. `libtopsec_vpn.so` creates
`tun0`, then fails to find it:

```
cannot create /sys/class/net/tun0/mtu: Directory nonexistent
```

`sandbox.sh` therefore mounts a fresh `sysfs` over `/sys`. (`/proc/net/*` needs
no such help — the kernel makes it netns-aware for the reader.)

## ssh needs `getpwuid`, not `$HOME`

OpenSSH locates `~/.ssh/config` and `~/.ssh/id_*` through
`getpwuid(getuid())`, not through `$HOME`. Inside the sandbox uid 0's passwd
entry points at `/root`, which the namespace cannot even traverse, so ssh would
never see the config and keys you already have.

`sandbox.sh` generates a copy of `/etc/passwd` with uid 0's home replaced by
your real home, and bind-mounts it over `/etc/passwd` **inside the namespace
only**. The file on disk is never modified.

## Networking

```
slirp4netns --configure -m 65520 <netns-pid> tap0      # runs in the HOST netns
```

`slirp4netns` is an unprivileged user-mode network stack: it creates a tap
device inside the target namespace and moves packets between it and ordinary
sockets in the host namespace. The engine then opens `/dev/net/tun`,
configures `tun0` with the address the gateway assigns and installs routes —
all inside the private namespace. The host's routing table is untouched, which
also means the host cannot reach the VPN subnets. That is the point, and it is
why `topsap fwd` exists.

## Mounts the engine expects

The vendor engine writes to `/opt` and to `/tmp/TopSAP_ELE`. Inside the
sandbox:

* `/opt` becomes an **overlay** with the host's `/opt` as a read-only lower
  layer and a private upper layer in `~/topsap/run/`. Writes land in the upper
  layer and vanish with the sandbox; the host's `/opt` is never modified.
* `/tmp` is usually a tmpfs already private to the mount namespace; the
  sandbox only creates the `TopSAP_ELE/.BUFF` directory there.
* `/etc/hosts` and `/etc/resolv.conf` are binds of files under
  `~/topsap/state/`, so DNS inside the tunnel can differ from the host without
  touching it.

## Control plane

The engine's only interface is a SysV shared-memory segment:

```
ftok("/tmp/TopSAP_ELE/.BUFF", 0x17)   ->  key
shmget(key, 0x80030, IPC_CREAT|0666)
  +0x00  int32 flag: 0 idle | 1 command ready | 2 taken | 3 response ready
  +0x30  char[0x80000] request JSON in, response JSON out
```

`src/svctl.c` is a small client for that channel. The fixed key is why only
**one** engine can run on a machine at a time: a second one would find the
live segment and corrupt it. `topsap up` therefore stops the sandbox first.

`topsap` reaches the namespace from outside through a `socat` unix socket
running *inside* it (`~/topsap/run/ctl.sock` over a private tmpfs), so you
never have to be in the namespace yourself. Interactive `ssh` needs a real
pty, so it gets a `tmux` window instead of the socket.

`svjson.py` exists because the engine replies with bare keys rather than strict
JSON; it repairs the reply before anything parses it.

## Credential encoding

Recovered from the shipped client and verified against the real library:

```
user = encodeURIComponent(base64(utf8(username)))
pwd  = base64( RSA_PKCS1_v1_5(password, vendor_public_key) )   with '+' -> %2B
```

`bin/svmk.py` builds those requests. The public key is the vendor's, embedded
in the client, not a secret.

## Credentials never travel in the tarball

`bin/pack.sh` builds a portable tarball and excludes `.pwd`, `keys/`, `run/`
and the development probes. The password is read from `TOPSAP_PWD`, else from
`~/topsap/.pwd` (mode 600), else prompted for. SSH keys stay in `~/.ssh` and
are never copied by this project.

## Forwarding: why two processes and a unix socket

A port on this machine is only visible in the host network namespace; `tun0` is
only visible in the sandbox. No single process may do both, so `topsap fwd`
runs two unprivileged halves:

```
host netns                                   sandbox netns
socat TCP-LISTEN:LPORT,bind=127.0.0.1   <->  socat UNIX-LISTEN:LPORT.sock
      UNIX-CONNECT:$RUN/fwd/LPORT.sock            TCP:far:port
```

A unix socket is the only kind of object that is the *same* object in both
namespaces, because the filesystem is shared while the network stacks are not.
The socket lives under `~/topsap/run/fwd/` (mode 600, and `run/` is private).

When the destination is an `~/.ssh/config` alias whose `ProxyCommand` is not
`none`, the far half runs `ssh -W host:port <alias>` instead of a direct TCP
connect. Because `socat`'s address parser splits its own command string on
whitespace, `-W 127.0.0.1 2734` would arrive torn; the far half therefore dials
through a generated wrapper (`LPORT.dial`) rather than inline text.

## Why `topsap ssh` uses tmux

`unshare`'s namespaces belong to the process tree that created them; a new
process cannot simply "enter" them without `nsenter` (which needs privileges).
The control socket has no pty, so interactive sessions are started as a tmux
window **inside** the namespaces. The server is started there and is guarded by
a keeper window: if the server dies, the next `topsap ssh` would silently fall
back to the host namespace, where the tunnel does not exist.

## Failure modes that cost the most time

* `topsap ssh` sitting for ~2 minutes and then printing `[exited]`: the tmux
  server had ended up in the host netns, and ssh had no connect timeout, so the
  kernel's TCP retries were the only clock. The server is now verified to be in
  the sandbox, ssh has `ConnectTimeout=30`, and the target port is preflighted.
* Silence from `fwd`: the gateway *drops* packets to an unroutable port instead
  of refusing them, so "nothing yet" and "nothing ever" look identical. `fwd
  check` makes a real connection and reports both halves.
* `tstate_id` staying at `0`: the engine's own status field is unreliable.
  Interface and routes are the truth.
