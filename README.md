# Example pod runtime with systemd-nspawn and machinectl

This project mirrors the [rkt](https://github.com/rkt) style two-stage pod container architecture using `systemd-nspawn` and `machinectl`. `rkt` is end-of-life, while `systemd-nspawn` and `systemd-networkd` operate a layer below the pod abstraction.

A shared read-only stage 1 image (`/var/lib/machines/stage1-debian`) provides the inner `systemd` PID 1 supervisor for each pod, while stage 2 application images in `/var/lib/machines/<image>` run inside the pod with isolated per-instance ephemeral OverlayFS root filesystems (`RootDirectory=/opt/stage2/<app>/rootfs`) and shared pod namespaces (`net`, `ipc`, `pid`, and `cgroup`) with private per-application UTS namespaces (`ProtectHostname=yes`).

Networking setup, container construction, and OCI image import are split into modular host scripts while leaving process supervision, dependency ordering, and namespace management to systemd. `SetCredential=` (introduced in systemd 247) passes declarative parameters from the unit file to the host scripts:

1. `host/usr/lib/systemd/pod-runtime` (`start` and `stop`) unifies host-networked and private-namespace networking (`PrivateNetwork=yes` with `net.if.*` VLAN/veth/macvlan/ipvlan interfaces and 802.1Q teardown retry), resolves versioned Stage 1 and Stage 2 symlinks via `readlink -f`, materialises `user.pod.unit` and `user.pod.env` extended attributes into Stage 1 unit drop-ins and `/etc/systemd/system/<app>.env`, isolates Stage 2 rootless identities via numeric `pod-uid-<uid>`/`pod-gid-<gid>` entries, registers UID 0 `<app>@<pod>` and `stage1@<pod>` shell aliases, unregisters stale `systemd-machined` records via `UnregisterMachine`, and executes `systemd-nspawn --notify-ready=yes`.
2. `host/usr/lib/systemd/pod-image-seal` seals OCI and non-OCI rootfs trees into immutable `/var/lib/machines/.store/<image>_<version>` directories (`chattr +i`), writes `user.pod.unit`, `user.pod.env`, `user.pod.version`, and `user.xdg.origin.url` extended attributes (using `0s` base64 encoding and an `ext4` 4 KiB budget check), and atomically flips `/var/lib/machines/<image>`.
3. `host/usr/lib/systemd/pod-import-oci` imports unmodified Docker and OCI images using `skopeo`, `umoci`, and `jq`, generates unit and environment metadata outside the rootfs, and seals them via `pod-image-seal`.
4. `host/usr/lib/systemd/pod-image-gc` (`--status`, `--dry-run`) reports active, pinned, and unused `.store/` image versions and safely reclaims unreferenced versions.
5. `stage1/etc/systemd/system/pod-stage2-post@.service` and `stage1/usr/lib/systemd/pod-stage2-post` run inside stage 1 after each stage 2 service starts or restarts, stamping each stage 2 private UTS namespace and `/etc/hostname` with its own `InvocationID` and synchronising `/etc/os-release` under `flock` before `pod-idle.target` signals readiness to the host.
6. `stage1/etc/systemd/system/pod-stdio@.service` provides a per-application FIFO bridge to `systemd-journald` so OCI applications that call `open("/dev/stdout")` or `open("/dev/stderr")` (such as `nginx` or `httpd`) do not encounter `ENXIO` on a `journald` stream socket while still streaming all output to the pod journal with `POD_UNIT=` metadata.

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
        └── lib
            └── systemd
                ├── pod-os-release-sync
                └── pod-stage2-post
```

---

## Building the stage 1 image with debootstrap

The stage 1 supervisor image resides at `/var/lib/machines/stage1-debian`. It requires `systemd`, `systemd-sysv`, and `dbus` so that `systemctl --machine`, `systemd-run --machine`, and `machinectl shell` can communicate with the inner PID 1 over D-Bus, along with `DefaultDependencies=no` drop-ins so that `pod-idle.target` starts only the supervisor sockets, journal, D-Bus daemon, and pre-generated stage 2 units.

### 1. Bootstrap a minimal Debian Bookworm root filesystem

Include `dbus`, `systemd`, `systemd-sysv`, `util-linux` (for `/usr/bin/nsenter` and `flock`), and `bash` in the `debootstrap` invocation:

```sh
sudo debootstrap \
  --variant=minbase \
  --include=systemd,systemd-sysv,dbus,util-linux,bash \
  bookworm \
  /var/lib/machines/stage1-debian \
  http://deb.debian.org/debian
```

### 2. Install the stage 1 systemd units, drop-ins, and shell entry hooks

Copy the files from [`stage1/`](stage1/) into `/var/lib/machines/stage1-debian`:

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
* [`stage1/usr/lib/systemd/pod-os-release-sync`](stage1/usr/lib/systemd/pod-os-release-sync)
* [`stage1/usr/lib/systemd/pod-stage2-post`](stage1/usr/lib/systemd/pod-stage2-post)
* [`stage1/etc/profile.d/pod-enter.sh`](stage1/etc/profile.d/pod-enter.sh)

```sh
sudo cp -r stage1/etc/* /var/lib/machines/stage1-debian/etc/
sudo cp -r stage1/usr/* /var/lib/machines/stage1-debian/usr/
sudo chmod 0755 \
  /var/lib/machines/stage1-debian/usr/lib/systemd/pod-os-release-sync \
  /var/lib/machines/stage1-debian/usr/lib/systemd/pod-stage2-post
sudo chmod 0644 /var/lib/machines/stage1-debian/etc/profile.d/pod-enter.sh
```

### 3. Point `default.target` to `pod-idle.target` and hook `/etc/bash.bashrc`

`machinectl shell` invokes `/bin/bash` as a non-login interactive shell, which reads `/etc/bash.bashrc` rather than `/etc/profile`. Hook `/etc/bash.bashrc` to source `/etc/profile.d/pod-enter.sh`, create the stage 2 mount directory, truncate `/etc/machine-id` and `/etc/hostname`, and mark the image read-only:

```sh
sudo ln -sf /etc/systemd/system/pod-idle.target \
  /var/lib/machines/stage1-debian/etc/systemd/system/default.target

if ! sudo grep -q "pod-enter.sh" /var/lib/machines/stage1-debian/etc/bash.bashrc; then
    sudo tee -a /var/lib/machines/stage1-debian/etc/bash.bashrc << 'EOF'

if [ -f /etc/profile.d/pod-enter.sh ]; then
    . /etc/profile.d/pod-enter.sh
fi
EOF
fi

sudo mkdir -p /var/lib/machines/stage1-debian/opt/stage2 \
              /var/lib/machines/stage1-debian/vol

sudo truncate -s 0 /var/lib/machines/stage1-debian/etc/machine-id
sudo truncate -s 0 /var/lib/machines/stage1-debian/etc/hostname
sudo rm -f /var/lib/machines/stage1-debian/etc/resolv.conf
sudo touch /var/lib/machines/stage1-debian/etc/resolv.conf
sudo ln -sf ../proc/self/mounts /var/lib/machines/stage1-debian/etc/mtab

sudo machinectl read-only stage1-debian yes
```

---

## Installing the host scripts

Install the six host scripts from [`host/usr/lib/systemd/`](host/usr/lib/systemd/) into `/usr/lib/systemd/`:

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

## Importing a stage 2 application image

Stage 2 images are root filesystem directories stored in `/var/lib/machines/<app>` and marked read-only. Each stage 2 application unit is assembled inside stage 1 from three standard `systemd` layers:

1. Base unit (`/etc/systemd/system/<app>.service`): runtime defaults (`Type=exec`, `NotifyAccess=all`, `Restart=always`, `RestartSec=2s`, `TimeoutStartSec=30s`, `MountAPIVFS=yes`, `ProtectHostname=yes`, `RootDirectory=/opt/stage2/<app>/rootfs`, `LogExtraFields=POD_UNIT=<machine>`, `Wants=pod-stage2-post@<app>.service`, `Before=pod-idle.target shutdown.target`, `Conflicts=shutdown.target`).
2. Image drop-in (`10-image.conf`): copied directly from `/var/lib/machines/<image>/etc/pod.service` when present.
3. Credential drop-in (`20-credential.conf`): generated directly from native `systemd.unit(5)` and `systemd.service(5)` directives in `SetCredential=pod.app.<app>:image=<image>,<Key>=<Value>,...`.

### Importing a root filesystem tarball manually

To import an Alpine Linux root filesystem as `test-ping` and embed default service settings in `/var/lib/machines/<image>/etc/pod.service`:

```sh
sudo machinectl import-tar alpine-minirootfs-3.18.4-riscv64.tar.gz test-ping
sudo tee /var/lib/machines/test-ping/etc/pod.service >/dev/null <<'EOF'
[Service]
ExecStart=/bin/ping 127.0.0.1
EOF
sudo machinectl read-only test-ping yes
```

When `/etc/pod.service` declares `ExecStart=`, `SetCredential=pod.app.ping:test-ping` (or `SetCredential=pod.app.ping:image=test-ping,MemoryMax=64M,TasksMax=16`) launches the image default with any native `systemd` overrides applied in `20-credential.conf`.

* `image=<image>` selects the stage 2 image in `/var/lib/machines/<image>`.
* `[Unit]` directives (`After=`, `Before=`, `Wants=`, `Requires=`, `BindsTo=`, `PartOf=`, `Conflicts=`, `Condition*=`, `Assert*=`, etc.) are written under `[Unit]` in `20-credential.conf`.
* `[Service]` directives (`ExecStart=`, `Type=`, `User=`, `Group=`, `SupplementaryGroups=`, `BindPaths=`, `BindReadOnlyPaths=`, `CapabilityBoundingSet=`, `AmbientCapabilities=`, `ExecStartPre=`, `ExecStartPost=`, `ExecStopPost=`, `MemoryMax=`, `CPUQuota=`, `TasksMax=`, `SystemCallFilter=`, `Environment=`, `WorkingDirectory=`, etc.) are written under `[Service]` in `20-credential.conf`. `ExecStart=` automatically emits a reset line before the first credential override, and `BindPaths=` and `BindReadOnlyPaths=` pre-create destination mountpoints inside the stage 2 overlay.
* Pod-wide capabilities passed to `systemd-nspawn` are configured via `SetCredential=pod.caps:CAP_NET_ADMIN,CAP_NET_RAW,...`. When any stage 2 service specifies `User=`, `Group=`, or `SupplementaryGroups=`, `pod-container-start` mirrors missing numeric or named identities into the ephemeral stage 1 `/etc/passwd` and `/etc/group` and ensures `CAP_SETUID` and `CAP_SETGID` are granted to stage 1.

### Importing unmodified Docker and OCI images with `pod-import-oci`

To run unmodified Docker or OCI images as stage 2 applications, install `skopeo`, `umoci`, and `jq` on the host:

```sh
sudo apt-get update
sudo apt-get install -y --no-install-recommends skopeo umoci jq
```

`pod-import-oci` fetches an OCI or Docker reference (for example `docker://...` or `docker-archive:/path/to/image.tar`), processes OCI layer ordering and `.wh.*` whiteouts via `umoci unpack`, merges `Entrypoint` and `Cmd`, resolves `argv[0]` against the container `PATH`, escapes `systemd` specifiers and quotes, writes `/etc/pod-environment` and `/etc/pod.service` (wired to `pod-stdio@%N.service` so `open("/dev/stdout")` and `open("/dev/stderr")` work cleanly alongside `journald` logging), and marks the image read-only:

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

To override the command of an imported OCI image for one pod while preserving its `WorkingDirectory=`, `User=`, `KillSignal=`, and `/etc/pod-environment` defaults, pass `ExecStart=` in the credential:

```sh
--property="SetCredential=pod.app.redis:image=redis-alpine,ExecStart=/usr/local/bin/docker-entrypoint.sh redis-server --port 6380"
```

---

## Running a pod with host networking

When a pod runs with `PrivateNetwork=no`, `pod-net-host-start` (or `pod-net-start`) invokes `pod-container-start`. `systemd-run` generates a unique `run-r<32hex>.service` unit name automatically when `--unit=` is omitted; `RuntimeDirectory=pods/%N` allocates `/run/pods/<unit-name>`, `pod-container-start` writes the stage 2 units into the ephemeral stage 1 overlay, and `systemd-nspawn --notify-ready=yes` signals readiness once stage 1 finishes starting all stage 2 units and reaching `pod-idle.target`.

```sh
sudo systemd-run --collect \
  --slice=machine.slice \
  --property=Type=notify \
  --property=Delegate=yes \
  --property=PrivateNetwork=no \
  --property=PrivateIPC=yes \
  --property="RuntimeDirectory=pods/%N" \
  --property="SetCredential=pod.stage1:stage1-debian" \
  --property="SetCredential=pod.app.ping:image=test-ping,ExecStart=/bin/ping 127.0.0.1" \
  --property="ExecStopPost=-/usr/lib/systemd/pod-runtime stop" \
  /usr/lib/systemd/pod-runtime start
```

---

## Running a pod with private networking and a VLAN-assigned NIC

When a pod runs with `PrivateNetwork=yes`, `systemd` allocates a new network namespace before executing `pod-net-vlan-start` (or `pod-net-start`). `pod-net-vlan-start` brings up `lo` inside the pod network namespace and creates each `SetCredential=net.if.<name>:ifname=<ifname>,master=<master>,kind=vlan,vlan_id=<id>[,addr=<cidr>][,gw=<ip>]` interface (or `kind=veth,peer=<host_veth>[,master=<bridge>]`) from the host network namespace (`nsenter --net=/proc/1/ns/net`) before execing `pod-container-start`. `systemd-nspawn` inherits that private network namespace directly, and the kernel destroys the network namespace, its virtual interfaces, and the private mount namespace overlays automatically when the pod exits.

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

Persistent pods are managed as standard systemd units without hardcoded UUIDs or `ExecStartPost=` orchestration hooks. The unit name (`pod-bgp.service`) becomes the `machinectl` machine name (`pod-bgp`), `INVOCATION_ID` becomes the stage 1 hostname on each activation (overridable via `SetCredential=pod.hostname:<name>`), each stage 2 service receives its own `InvocationID` UTS hostname, and `/etc/machine-id` is derived deterministically from the host `/etc/machine-id` and machine name so `journalctl -M pod-bgp` spans restarts:

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
SetCredential=host.bind.conf:src=/etc/quagga,dst=/vol/conf,ro=true
SetCredential=pod.app.zebra:image=zebra-riscv64,ExecStart=/usr/lib/quagga/zebra -A 127.0.0.1,BindPaths=/vol/run:/run/quagga,BindReadOnlyPaths=/vol/conf:/etc/quagga,CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_RAW CAP_SYS_ADMIN CAP_SETUID CAP_SETGID CAP_CHOWN CAP_DAC_OVERRIDE,MemoryMax=256M,TasksMax=64
SetCredential=pod.app.bgpd:image=bgpd-riscv64,After=zebra.service,ExecStart=/usr/lib/quagga/bgpd -A 127.0.0.1,BindPaths=/vol/run:/run/quagga,BindReadOnlyPaths=/vol/conf:/etc/quagga,CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_RAW CAP_NET_BIND_SERVICE CAP_NET_BROADCAST CAP_SYS_ADMIN CAP_SETUID CAP_SETGID CAP_CHOWN CAP_DAC_OVERRIDE,MemoryMax=256M,TasksMax=64

ExecStart=/usr/lib/systemd/pod-runtime start
ExecStopPost=-/usr/lib/systemd/pod-runtime stop

[Install]
WantedBy=multi-user.target
```

---

## Inspecting and entering pods with `machinectl` and `journalctl`

### View running pods and active stage 2 images

```sh
sudo machinectl list
```

### View container logs from the host

Query a specific pod by machine name (spanning restarts, with each activation stamped by its `INVOCATION_ID` hostname), filter across all machine IDs by `POD_UNIT=`, or search merged host and pod journals:

```sh
sudo journalctl -M pod-bgp -u bgpd.service
sudo journalctl -m POD_UNIT=pod-bgp
sudo journalctl -m -u ping.service
```

### Inspect stage 1 and stage 2 OverlayFS mounts inside a running pod

Because `SetCredential=` executes the pod supervisor inside a private mount namespace (`CLONE_NEWNS`), the per-pod stage 1 and per-instance stage 2 OverlayFS mounts do not appear in the host `mount` table. Inspect them inside the container namespace with `nsenter`:

```sh
MACHINE_PID="$(machinectl show --property=Leader --value pod-bgp)"
sudo nsenter --target "${MACHINE_PID}" --mount --root --pid mount
```

### Enter a stage 2 application shell

* Enter the active application in a single-application pod automatically:
  ```sh
  sudo machinectl shell pod-strongswan
  ```
* Target a specific application in a multi-application pod:
  ```sh
  sudo machinectl shell zebra@pod-bgp
  ```
* Remain in the stage 1 Debian supervisor shell without entering stage 2:
  ```sh
  sudo machinectl shell stage1@pod-bgp
  ```

### Execute a one-off management command inside a stage 2 application

Because each stage 2 unit runs with `MountAPIVFS=yes` and `RootDirectory=/opt/stage2/<app>/rootfs`, systemd mounts a private `/run` tmpfs inside that service unit. Daemons that expose Unix control sockets (such as FRR `vtysh` or strongSwan `swanctl` over VICI) should place their socket directory on a shared pod volume (`SetCredential=vol.run:...` bound into `/run/<subdir>`), and one-off host management commands should bind the same `/vol/*` paths:

```sh
sudo systemd-run --machine=pod-bgp --collect --pipe --wait \
  --property=RootDirectory=/opt/stage2/bgpd/rootfs \
  --property=BindPaths=/vol/run:/run/quagga \
  --property=BindReadOnlyPaths=/vol/conf:/etc/quagga \
  /usr/bin/vtysh -c "show bgp summary"
```

### Stop a pod

```sh
sudo machinectl stop pod-bgp
```

### Operational notes

* Do not restart `systemd-machined.service` on the host while registered pods (`--register=yes`) are running, as restarting `systemd-machined` drops machine registrations and disrupts active host-networked `systemd-nspawn` instances.
* On systemd 252 and newer, `systemctl --machine=pod-bgp cat <unit>` is rejected across container buses; use `systemctl --machine=pod-bgp is-active <unit>` or `show` properties for non-interactive readiness checks.
