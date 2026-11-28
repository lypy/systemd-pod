# Example pod runtime with systemd-nspawn and machinectl

This project mirrors the [rkt](https://github.com/rkt) style two-stage pod container architecture using `systemd-nspawn` and `machinectl`. `rkt` is end-of-life, while `systemd-nspawn` and `systemd-networkd` operate a layer below the pod abstraction.

A shared immutable Stage 1 image (`/var/lib/machines/stage1-debian` -> `.store/stage1-debian_<version>`) provides the inner `systemd` PID 1 supervisor for each pod, while Stage 2 application images in `/var/lib/machines/<image>` run inside the pod with isolated per-instance ephemeral OverlayFS root filesystems (`RootDirectory=/opt/stage2/<app>/rootfs`) and shared pod namespaces (`net`, `ipc`, `pid`, and `cgroup`) with private per-application UTS namespaces (`ProtectHostname=yes`).

Manifest metadata (`user.pod.unit`, `user.pod.env`, `user.pod.version`, and `user.xdg.origin.url`) is stored as extended attributes on immutable versioned image directories under `/var/lib/machines/.store/<image>_<version>`, keeping Stage 2 root filesystems unmodified (including `scratch` images with no `/etc` directory). `SetCredential=` (introduced in systemd 247) passes declarative parameters from the unit file to the host runtime:

1. `host/usr/lib/systemd/pod-runtime` (`start`, `stop`, and `inspect <image>`) unifies host-networked and private-namespace networking (`PrivateNetwork=yes` with `net.if.*` VLAN/veth/macvlan/ipvlan interfaces and 802.1Q teardown retry), resolves versioned Stage 1 and Stage 2 symlinks via `readlink -f`, materialises `user.pod.unit` and `user.pod.env` extended attributes into Stage 1 unit drop-ins (`10-image.conf`) and `/etc/systemd/system/<app>.env`, isolates Stage 2 rootless identities via numeric `pod-uid-<uid>`/`pod-gid-<gid>` entries, registers UID 0 `<app>@<pod>` and `stage1@<pod>` shell aliases, unregisters stale `systemd-machined` entries via `UnregisterMachine`, and executes `systemd-nspawn --notify-ready=yes`.
2. `host/usr/lib/systemd/pod-image-seal` seals OCI and non-OCI rootfs trees into immutable `/var/lib/machines/.store/<image>_<version>` directories (`chattr +i`), writes `user.pod.unit`, `user.pod.env`, `user.pod.version`, and `user.xdg.origin.url` extended attributes (using `0s` base64 encoding and an `ext4` 4 KiB budget check), refuses to overwrite active OverlayFS lowerdirs, and atomically flips `/var/lib/machines/<image>`.
3. `host/usr/lib/systemd/pod-import-oci` imports unmodified Docker and OCI images using `skopeo`, `umoci`, and `jq`, generates unit and environment metadata outside the rootfs, derives a content-digest version tag, and seals them via `pod-image-seal`.
4. `host/usr/lib/systemd/pod-image-gc` (`--status`, `--dry-run`, `--inspect <image>`) reports active, pinned, and unused `.store/` image versions, inspects sealed image extended attributes, and safely reclaims unreferenced versions.
5. `stage1/usr/bin/pod-exec` runs inside Stage 1 so one-off host commands (`systemd-run -M <pod> -q --collect --pipe --wait pod-exec <app> <cmd> ...`) join a running Stage 2 service's live namespaces directly via `nsenter` without repeating `RootDirectory=` or `BindPaths=`.
6. `stage1/etc/systemd/system/pod-stage2-post@.service` and `stage1/usr/lib/systemd/pod-stage2-post` run inside Stage 1 after each Stage 2 service starts or restarts, stamping each Stage 2 private UTS namespace and `/etc/hostname` with its own `InvocationID` and synchronising `/etc/os-release` under `flock` before `pod-idle.target` signals readiness to the host.
7. `stage1/etc/systemd/system/pod-stdio@.service` provides a per-application FIFO bridge to `systemd-journald` so OCI applications that call `open("/dev/stdout")` or `open("/dev/stderr")` (such as `nginx` or `httpd`) do not encounter `ENXIO` on a `journald` stream socket while still streaming all output to the pod journal with `POD_UNIT=` metadata.

---

## Repository structure

```text
.
├── README.md
├── host
│   └── usr
│       └── lib
│           └── systemd
│               ├── pod-image-gc
│               ├── pod-image-seal
│               ├── pod-import-oci
│               └── pod-runtime
└── stage1
    ├── etc
    │   ├── profile.d
    │   │   └── pod-enter.sh
    │   └── systemd
    │       └── system
    │           ├── container-shell@.service.d
    │           │   └── 10-no-deps.conf
    │           ├── dbus.service.d
    │           │   └── 10-no-deps.conf
    │           ├── dbus.socket.d
    │           │   └── 10-no-deps.conf
    │           ├── pod-idle.target
    │           ├── pod-os-release-sync.path
    │           ├── pod-os-release-sync.service
    │           ├── pod-stage2-post@.service
    │           ├── pod-stdio@.service
    │           ├── systemd-journald-dev-log.socket.d
    │           │   └── 10-no-deps.conf
    │           ├── systemd-journald.service.d
    │           │   └── 10-no-deps.conf
    │           └── systemd-journald.socket.d
    │               └── 10-no-deps.conf
    └── usr
        ├── bin
        │   └── pod-exec
        └── lib
            └── systemd
                ├── pod-os-release-sync
                └── pod-stage2-post
```

---

## Host prerequisites and script installation

Install `attr` (`setfattr` and `getfattr`) on the host, plus `skopeo`, `umoci`, and `jq` if importing OCI/Docker images:

```sh
sudo apt-get update
sudo apt-get install -y --no-install-recommends attr skopeo umoci jq
```

Install the four host scripts from [`host/usr/lib/systemd/`](host/usr/lib/systemd/) into `/usr/lib/systemd/`:

* [`host/usr/lib/systemd/pod-runtime`](host/usr/lib/systemd/pod-runtime)
* [`host/usr/lib/systemd/pod-image-seal`](host/usr/lib/systemd/pod-image-seal)
* [`host/usr/lib/systemd/pod-import-oci`](host/usr/lib/systemd/pod-import-oci)
* [`host/usr/lib/systemd/pod-image-gc`](host/usr/lib/systemd/pod-image-gc)

```sh
sudo install -m 0755 \
  host/usr/lib/systemd/pod-runtime \
  host/usr/lib/systemd/pod-image-seal \
  host/usr/lib/systemd/pod-import-oci \
  host/usr/lib/systemd/pod-image-gc \
  /usr/lib/systemd/
```

---

## Building the Stage 1 image with debootstrap

The Stage 1 supervisor image resides at `/var/lib/machines/stage1-debian` (a symlink to `/var/lib/machines/.store/stage1-debian_<version>`). It requires `systemd`, `systemd-sysv`, and `dbus` so that `systemctl --machine`, `systemd-run --machine`, and `machinectl shell` can communicate with the inner PID 1 over D-Bus, along with `DefaultDependencies=no` drop-ins so that `pod-idle.target` starts only the supervisor sockets, journal, D-Bus daemon, and pre-generated Stage 2 units.

### 1. Bootstrap a minimal Debian Bookworm root filesystem

Include `dbus`, `systemd`, `systemd-sysv`, `util-linux` (for `/usr/bin/nsenter` and `flock`), and `bash` in a temporary staging directory on the `/var/lib/machines` filesystem:

```sh
STAGE_ROOT="$(sudo mktemp -d /var/lib/machines/.build-stage1.XXXXXX)"
sudo debootstrap \
  --variant=minbase \
  --include=systemd,systemd-sysv,dbus,util-linux,bash \
  bookworm \
  "${STAGE_ROOT}" \
  http://deb.debian.org/debian
```

### 2. Install Stage 1 units, helpers, and shell entry hooks

Copy the files from [`stage1/`](stage1/) into `"${STAGE_ROOT}"`:

* [`stage1/etc/systemd/system/pod-idle.target`](stage1/etc/systemd/system/pod-idle.target)
* [`stage1/etc/systemd/system/pod-os-release-sync.path`](stage1/etc/systemd/system/pod-os-release-sync.path)
* [`stage1/etc/systemd/system/pod-os-release-sync.service`](stage1/etc/systemd/system/pod-os-release-sync.service)
* [`stage1/etc/systemd/system/pod-stage2-post@.service`](stage1/etc/systemd/system/pod-stage2-post@.service)
* [`stage1/etc/systemd/system/pod-stdio@.service`](stage1/etc/systemd/system/pod-stdio@.service)
* [`stage1/etc/systemd/system/container-shell@.service.d/10-no-deps.conf`](stage1/etc/systemd/system/container-shell@.service.d/10-no-deps.conf)
* [`stage1/etc/systemd/system/dbus.socket.d/10-no-deps.conf`](stage1/etc/systemd/system/dbus.socket.d/10-no-deps.conf)
* [`stage1/etc/systemd/system/dbus.service.d/10-no-deps.conf`](stage1/etc/systemd/system/dbus.service.d/10-no-deps.conf)
* [`stage1/etc/systemd/system/systemd-journald.socket.d/10-no-deps.conf`](stage1/etc/systemd/system/systemd-journald.socket.d/10-no-deps.conf)
* [`stage1/etc/systemd/system/systemd-journald-dev-log.socket.d/10-no-deps.conf`](stage1/etc/systemd/system/systemd-journald-dev-log.socket.d/10-no-deps.conf)
* [`stage1/etc/systemd/system/systemd-journald.service.d/10-no-deps.conf`](stage1/etc/systemd/system/systemd-journald.service.d/10-no-deps.conf)
* [`stage1/usr/bin/pod-exec`](stage1/usr/bin/pod-exec)
* [`stage1/usr/lib/systemd/pod-os-release-sync`](stage1/usr/lib/systemd/pod-os-release-sync)
* [`stage1/usr/lib/systemd/pod-stage2-post`](stage1/usr/lib/systemd/pod-stage2-post)
* [`stage1/etc/profile.d/pod-enter.sh`](stage1/etc/profile.d/pod-enter.sh)

```sh
sudo cp -r stage1/etc/* "${STAGE_ROOT}/etc/"
sudo cp -r stage1/usr/* "${STAGE_ROOT}/usr/"
sudo chmod 0755 \
  "${STAGE_ROOT}/usr/bin/pod-exec" \
  "${STAGE_ROOT}/usr/lib/systemd/pod-os-release-sync" \
  "${STAGE_ROOT}/usr/lib/systemd/pod-stage2-post"
sudo chmod 0644 "${STAGE_ROOT}/etc/profile.d/pod-enter.sh"
```

### 3. Configure `default.target`, prune `base-passwd`, and seal

Hook `/etc/bash.bashrc` to source `/etc/profile.d/pod-enter.sh` (`pod-enter.sh` guards against double execution across `/etc/profile` and `/etc/bash.bashrc` with `_POD_ENTER_DONE`), prune unused Debian `base-passwd` stub accounts so Stage 2 app names such as `list`, `proxy`, `mail`, or `www-data` do not collide with UID 0 `<app>@<pod>` shell aliases, and seal the directory with `pod-image-seal`:

```sh
sudo ln -sf /etc/systemd/system/pod-idle.target \
  "${STAGE_ROOT}/etc/systemd/system/default.target"

if ! sudo grep -q "pod-enter.sh" "${STAGE_ROOT}/etc/bash.bashrc"; then
    sudo tee -a "${STAGE_ROOT}/etc/bash.bashrc" << 'EOF'

if [ -f /etc/profile.d/pod-enter.sh ]; then
    . /etc/profile.d/pod-enter.sh
fi
EOF
fi

sudo mkdir -p "${STAGE_ROOT}/opt/stage2" "${STAGE_ROOT}/vol"
sudo truncate -s 0 "${STAGE_ROOT}/etc/machine-id"
sudo truncate -s 0 "${STAGE_ROOT}/etc/hostname"
sudo rm -f "${STAGE_ROOT}/etc/resolv.conf"
sudo touch "${STAGE_ROOT}/etc/resolv.conf"
sudo ln -sf ../proc/self/mounts "${STAGE_ROOT}/etc/mtab"

sudo awk -F: '$1 == "root" || $1 == "nobody" || $1 == "messagebus" || $1 ~ /^systemd-/' \
  "${STAGE_ROOT}/etc/passwd" | sudo tee "${STAGE_ROOT}/etc/passwd.tmp" >/dev/null
sudo chmod 0644 "${STAGE_ROOT}/etc/passwd.tmp"
sudo mv -f "${STAGE_ROOT}/etc/passwd.tmp" "${STAGE_ROOT}/etc/passwd"

if sudo test -f "${STAGE_ROOT}/etc/shadow"; then
    sudo awk -F: '$1 == "root" || $1 == "nobody" || $1 == "messagebus" || $1 ~ /^systemd-/' \
      "${STAGE_ROOT}/etc/shadow" | sudo tee "${STAGE_ROOT}/etc/shadow.tmp" >/dev/null
    sudo chmod 0640 "${STAGE_ROOT}/etc/shadow.tmp"
    sudo mv -f "${STAGE_ROOT}/etc/shadow.tmp" "${STAGE_ROOT}/etc/shadow"
fi

sudo /usr/lib/systemd/pod-image-seal "${STAGE_ROOT}" stage1-debian \
  --origin="debootstrap:bookworm"
```

---

## Importing and sealing Stage 2 application images

Stage 2 images are immutable versioned directories under `/var/lib/machines/.store/<image>_<version>` referenced by atomic symlinks at `/var/lib/machines/<image>`. Extended attributes on the versioned directory inode hold the image execution contract:

| Extended attribute | Purpose | Materialised inside Stage 1 |
| --- | --- | --- |
| `user.pod.unit` | Default `[Unit]` and `[Service]` directives (`ExecStart=`, `User=`, `WorkingDirectory=`, `KillSignal=`, etc.) | `/etc/systemd/system/<app>.service.d/10-image.conf` |
| `user.pod.env` | Newline-delimited `KEY="VALUE"` environment declarations | `/etc/systemd/system/<app>.env` (`EnvironmentFile=`) |
| `user.pod.version` | Content digest or release version tag | `/opt/stage2/<app>/version` |
| `user.xdg.origin.url` | Source OCI reference, tarball name, or build identifier | Displayed by `pod-runtime inspect <image>` |

Each Stage 2 application unit is assembled inside Stage 1 from native `systemd` layers:

1. Base unit (`/etc/systemd/system/<app>.service`): runtime defaults (`Type=exec`, `NotifyAccess=all`, `Restart=always`, `RestartSec=2s`, `TimeoutStartSec=30s`, `MountAPIVFS=yes`, `ProtectHostname=yes`, `RootDirectory=/opt/stage2/<app>/rootfs`, `LogExtraFields=POD_UNIT=<machine>`, `Wants=pod-stage2-post@<app>.service`, `Before=pod-idle.target shutdown.target`, `Conflicts=shutdown.target`), plus `EnvironmentFile=-/etc/systemd/system/<app>.env` when `user.pod.env` is set.
2. Identity environment drop-in (`05-identity-env.conf`): emitted when the service sets a numeric or symbolic `User=`, setting genuine Stage 2 `USER`, `LOGNAME`, and `HOME` before image and credential overrides.
3. Image drop-in (`10-image.conf`): extracted from the image's `user.pod.unit` extended attribute.
4. Credential drop-in (`20-credential.conf`): generated from native `systemd.unit(5)` and `systemd.service(5)` directives in `SetCredential=pod.app.<app>:image=<image>,<Key>=<Value>,...`.
5. Identity override drop-in (`30-identity.conf`): replaces symbolic or numeric `User=`, `Group=`, and `SupplementaryGroups=` with resolved numeric IDs backed by hidden `pod-uid-<uid>` and `pod-gid-<gid>` Stage 1 entries, leaving Stage 1 `/etc/passwd` free for `<app>@<pod>` shell aliases even for rootless containers.

### Sealing a root filesystem tarball or custom build

Unpack a tarball (or build a rootfs with `mmdebstrap` / `debootstrap`) into a staging directory on `/var/lib/machines` and seal it with `pod-image-seal`:

```sh
TMP_ROOT="$(sudo mktemp -d /var/lib/machines/.import-test-ping.XXXXXX)"
sudo tar -C "${TMP_ROOT}" -xzf alpine-minirootfs-3.18.4-riscv64.tar.gz
sudo /usr/lib/systemd/pod-image-seal "${TMP_ROOT}" test-ping \
  --exec="/bin/ping 127.0.0.1" \
  --version="3.18.4" \
  --origin="alpine-minirootfs-3.18.4-riscv64.tar.gz"
```

When `user.pod.unit` declares `ExecStart=`, a concise credential such as `SetCredential=pod.app.ping:test-ping` (or `SetCredential=pod.app.ping:image=test-ping,MemoryMax=64M,TasksMax=16`) launches the image default with any native `systemd` overrides applied in `20-credential.conf`:

* `image=<image>` selects the Stage 2 image at `/var/lib/machines/<image>` (canonicalised via `readlink -f` to `.store/<image>_<version>` so live updates never unlink active OverlayFS lowerdirs).
* `[Unit]` directives (`After=`, `Before=`, `Wants=`, `Requires=`, `BindsTo=`, `PartOf=`, `Conflicts=`, `Condition*=`, `Assert*=`, etc.) are written under `[Unit]` in `20-credential.conf`.
* `[Service]` directives (`ExecStart=`, `Type=`, `User=`, `Group=`, `SupplementaryGroups=`, `BindPaths=`, `BindReadOnlyPaths=`, `CapabilityBoundingSet=`, `AmbientCapabilities=`, `ExecStartPre=`, `ExecStartPost=`, `ExecStopPost=`, `MemoryMax=`, `CPUQuota=`, `TasksMax=`, `SystemCallFilter=`, `Environment=`, `WorkingDirectory=`, etc.) are written under `[Service]` in `20-credential.conf`. `ExecStart=` emits a reset line before the first credential override, and `BindPaths=` / `BindReadOnlyPaths=` pre-create destination mountpoints inside the Stage 2 overlay.
* Pod-wide capabilities passed to `systemd-nspawn` are configured via `SetCredential=pod.caps:CAP_NET_ADMIN,CAP_NET_RAW,...`. When any Stage 2 service sets `User=`, `Group=`, or `SupplementaryGroups=`, `pod-runtime` ensures `CAP_SETUID` and `CAP_SETGID` are granted to Stage 1.

### Importing unmodified Docker and OCI images with `pod-import-oci`

`pod-import-oci` fetches an OCI or Docker reference (for example `docker://...` or `docker-archive:/path/to/image.tar`), unpacks OCI layers and `.wh.*` whiteouts via `umoci`, merges `Entrypoint` and `Cmd`, resolves `argv[0]` against the container `PATH`, escapes `systemd` specifiers and quotes, wires `pod-stdio@%N.service` when `/dev/stdout` or `/dev/stderr` logging is detected, and delegates to `pod-image-seal` to store `user.pod.unit` and `user.pod.env` as extended attributes outside the rootfs:

```sh
sudo /usr/lib/systemd/pod-import-oci \
  docker://docker.io/library/redis:7-alpine \
  redis-alpine

sudo /usr/lib/systemd/pod-import-oci \
  docker://docker.io/library/nginx:1.27-alpine \
  nginx-alpine
```

Optional flags supported by `pod-import-oci`: `--arch=<arch>`, `--os=<os>`, `--variant=<variant>`, `--creds=<user:pass>`, and `--tls-verify=<bool>`.

Run both imported images side by side in a shared pod (include `CAP_SETUID,CAP_SETGID,CAP_CHOWN,CAP_DAC_OVERRIDE` in `pod.caps` when root-started entrypoints such as `redis` or `nginx` drop privileges with `su-exec` or `gosu`; non-root OCI images such as `nginxinc/nginx-unprivileged` work with a bare `SetCredential=pod.app.nginx:nginx-unpriv-alpine` and no custom `pod.caps`):

```sh
sudo systemd-run --collect \
  --unit=pod-webstack.service \
  --slice=machine.slice \
  --property=Type=notify \
  --property=Delegate=yes \
  --property=PrivateNetwork=yes \
  --property=PrivateIPC=yes \
  --property="RuntimeDirectory=pods/%N" \
  --property="SetCredential=pod.stage1:stage1-debian" \
  --property="SetCredential=pod.caps:CAP_NET_ADMIN,CAP_NET_RAW,CAP_NET_BIND_SERVICE,CAP_SYS_ADMIN,CAP_SETUID,CAP_SETGID,CAP_CHOWN,CAP_DAC_OVERRIDE" \
  --property="SetCredential=vol.run:mode=0775,uid=0,gid=0" \
  --property="SetCredential=pod.app.redis:image=redis-alpine,BindPaths=/vol/run:/run/redis,MemoryMax=128M" \
  --property="SetCredential=pod.app.nginx:image=nginx-alpine,After=redis.service,BindPaths=/vol/run:/run/redis,MemoryMax=128M" \
  --property="ExecStopPost=-/usr/lib/systemd/pod-runtime stop" \
  /usr/lib/systemd/pod-runtime start
```

To override the command of an imported OCI image for one pod while preserving its `WorkingDirectory=`, `User=`, `KillSignal=`, and `user.pod.env` defaults, pass `ExecStart=` in the credential:

```sh
--property="SetCredential=pod.app.redis:image=redis-alpine,ExecStart=/usr/local/bin/docker-entrypoint.sh redis-server --port 6380"
```

### Inspecting and garbage-collecting sealed images

Inspect any image's resolved `.store/` path, version, origin, pin status, `user.pod.unit`, and `user.pod.env`:

```sh
sudo /usr/lib/systemd/pod-runtime inspect redis-alpine
# Equivalent alias:
sudo /usr/lib/systemd/pod-image-gc --inspect redis-alpine
```

View active, pinned (still mounted by a running pod), and unused image versions, or reclaim unused versions safely:

```sh
sudo /usr/lib/systemd/pod-image-gc --status
sudo /usr/lib/systemd/pod-image-gc --dry-run
sudo /usr/lib/systemd/pod-image-gc
```

---

## Running a pod with host networking

When a pod runs with `PrivateNetwork=no`, `pod-runtime start` detects that `/proc/self/ns/net` matches `/proc/1/ns/net` (failing fast if any `net.if.*` credential is present), resolves the versioned Stage 1 and Stage 2 symlinks, materialises `user.pod.unit` and `user.pod.env` into the ephemeral Stage 1 overlay, unregisters any stale `systemd-machined` record, and executes `systemd-nspawn --notify-ready=yes`:

```sh
sudo systemd-run --collect \
  --slice=machine.slice \
  --property=Type=notify \
  --property=Delegate=yes \
  --property=PrivateNetwork=no \
  --property=PrivateIPC=yes \
  --property="RuntimeDirectory=pods/%N" \
  --property="SetCredential=pod.stage1:stage1-debian" \
  --property="SetCredential=pod.app.ping:test-ping" \
  --property="ExecStopPost=-/usr/lib/systemd/pod-runtime stop" \
  /usr/lib/systemd/pod-runtime start
```

---

## Running a pod with private networking and a VLAN-assigned NIC

When a pod runs with `PrivateNetwork=yes`, `systemd` allocates a new network namespace before executing `pod-runtime start`. `pod-runtime start` brings up `lo` inside the pod network namespace and creates each `SetCredential=net.if.<name>:ifname=<ifname>,master=<master>,kind=vlan,vlan_id=<id>[,addr=<cidr>][,gw=<ip>]` interface (or `kind=veth,peer=<host_veth>[,master=<bridge>]`, `kind=macvlan`, `kind=ipvlan`) from the host network namespace (`nsenter --net=/proc/1/ns/net`), retrying transiently if the kernel is still finishing an 802.1Q teardown from a rapid restart:

```sh
sudo systemd-run --collect \
  --slice=machine.slice \
  --property=Type=notify \
  --property=Delegate=yes \
  --property=PrivateNetwork=yes \
  --property=PrivateIPC=yes \
  --property="RuntimeDirectory=pods/%N" \
  --property="SetCredential=pod.stage1:stage1-debian" \
  --property="SetCredential=net.dns:1.1.1.1,8.8.8.8" \
  --property="SetCredential=net.if.vlan100:ifname=eth0,master=enp1s0,kind=vlan,vlan_id=100,addr=192.0.2.10/24,gw=192.0.2.1" \
  --property="SetCredential=pod.app.ping:image=test-ping,ExecStart=/bin/ping 192.0.2.1" \
  --property="ExecStopPost=-/usr/lib/systemd/pod-runtime stop" \
  /usr/lib/systemd/pod-runtime start
```

---

## Declarative systemd unit example

Persistent pods are standard systemd units with no hardcoded UUIDs or `ExecStartPost=` orchestration hooks. The unit name (`pod-bgp.service`) becomes the `machinectl` machine name (`pod-bgp`), `INVOCATION_ID` becomes the Stage 1 hostname on each activation (overridable via `SetCredential=pod.hostname:<name>`), each Stage 2 service receives its own `InvocationID` UTS hostname, and `/etc/machine-id` is derived deterministically from the host `/etc/machine-id` and machine name so `journalctl -M pod-bgp` spans restarts. When images carry `ExecStart=` and capability defaults in `user.pod.unit`, pod credentials stay concise:

```ini
[Unit]
Description=BGP routing pod (zebra and bgpd)
After=network.target

[Service]
Type=notify
Slice=machine.slice
Delegate=yes
KillMode=mixed
Restart=always
RestartSec=5s

PrivateNetwork=no
PrivateIPC=yes

RuntimeDirectory=pods/%N

SetCredential=pod.stage1:stage1-debian
SetCredential=pod.caps:CAP_NET_ADMIN,CAP_NET_RAW,CAP_NET_BIND_SERVICE,CAP_SYS_ADMIN
SetCredential=vol.run:mode=0775,uid=104,gid=107
SetCredential=host.bind.conf:src=/etc/frr,dst=/vol/conf,ro=true
SetCredential=pod.app.zebra:image=frr-zebra,BindPaths=/vol/run:/run/frr,BindReadOnlyPaths=/vol/conf:/etc/frr,MemoryMax=256M,TasksMax=64
SetCredential=pod.app.bgpd:image=frr-bgpd,After=zebra.service,BindPaths=/vol/run:/run/frr,BindReadOnlyPaths=/vol/conf:/etc/frr,MemoryMax=256M,TasksMax=64

ExecStart=/usr/lib/systemd/pod-runtime start
ExecStopPost=-/usr/lib/systemd/pod-runtime stop

[Install]
WantedBy=multi-user.target
```

---

## Inspecting and entering pods with `machinectl`, `systemd-run`, and `journalctl`

### View running pods and active images

```sh
sudo machinectl list
sudo machinectl list-images
```

### View container logs from the host

Query a specific pod by machine name (spanning restarts, with each activation stamped by its `INVOCATION_ID` hostname), filter across all machine IDs by `POD_UNIT=`, or search merged host and pod journals:

```sh
sudo journalctl -M pod-bgp -u bgpd.service
sudo journalctl -m POD_UNIT=pod-bgp
sudo journalctl -m -u ping.service
```

### Inspect Stage 1 and Stage 2 OverlayFS mounts inside a running pod

Because `SetCredential=` executes the pod supervisor inside a private mount namespace (`CLONE_NEWNS`), the per-pod Stage 1 and per-instance Stage 2 OverlayFS mounts do not appear in the host `mount` table. Inspect them inside the container namespace with `nsenter`:

```sh
MACHINE_PID="$(machinectl show --property=Leader --value pod-bgp)"
sudo nsenter --target "${MACHINE_PID}" --mount --root --pid mount
```

### Enter a Stage 2 application shell

* Enter the active application in a single-application pod automatically:
  ```sh
  sudo machinectl shell pod-strongswan
  ```
* Target a specific application in a multi-application pod:
  ```sh
  sudo machinectl shell zebra@pod-bgp
  ```
* Remain in the Stage 1 Debian supervisor shell without entering Stage 2:
  ```sh
  sudo machinectl shell stage1@pod-bgp
  ```

### Execute a one-off management command inside a Stage 2 application

Use `pod-exec` inside Stage 1 via `systemd-run -M` to join the live Stage 2 service's namespaces directly (inheriting its root filesystem, mounted `/vol/*` bind paths, and network/PID namespaces without repeating `RootDirectory=` or `BindPaths=`):

```sh
sudo systemd-run -M pod-bgp -q --collect --pipe --wait \
  pod-exec bgpd vtysh -c "show bgp summary"

sudo systemd-run -M pod-strongswan -q --collect --pipe --wait \
  pod-exec strongswan swanctl --list-sas
```

For interactive terminal tools (such as `vtysh` without `-c`), replace `--pipe` with `--pty`.

### Restart or stop a pod

```sh
sudo systemctl restart pod-bgp.service
sudo systemctl stop pod-bgp.service
```

### Operational notes

* Do not restart `systemd-machined.service` on the host while registered pods (`--register=yes`) are running, as restarting `systemd-machined` drops machine registrations and disrupts active host-networked `systemd-nspawn` instances.
* On systemd 252 and newer, `systemctl --machine=pod-bgp cat <unit>` is rejected across container buses; use `systemctl --machine=pod-bgp is-active <unit>` or `show` properties for non-interactive readiness checks.
* When invoking `systemd-run --property=RootDirectory=...` directly from the host against `/var/lib/machines/<image>`, canonicalise the symlink first with `$(readlink -f /var/lib/machines/<image>)` because `systemd 252` rejects symlinks in `RootDirectory=` with `226/NAMESPACE`.
