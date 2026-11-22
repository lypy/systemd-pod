# Example pod runtime with systemd-nspawn and machinectl

This project mirrors the [rkt](https://github.com/rkt) style two-stage pod container architecture using `systemd-nspawn`, `systemd-run`, and `machinectl`. `rkt` is end-of-life, while `systemd-nspawn` and `systemd-networkd` operate a layer below the pod abstraction.

A shared read-only stage 1 image (`/var/lib/machines/stage1-debian`) provides the inner `systemd` PID 1 supervisor for each pod, while stage 2 application images in `/var/lib/machines/<image>` run inside the pod with isolated per-instance ephemeral OverlayFS root filesystems (`RootDirectory=/opt/stage2/<app>/rootfs`) and shared pod namespaces (`net`, `ipc`, `uts`, `pid`, and `cgroup`).

Networking setup, container construction, and application dispatch are split into modular host scripts while leaving process supervision and namespace management to systemd. `SetCredential=` (introduced in systemd 247) passes declarative parameters from the unit file to the host scripts:

1. `host/usr/lib/systemd/pod-net-host-start` configures a pod to share the host network namespace and delegates container setup to `pod-container-start`.
2. `host/usr/lib/systemd/pod-net-vlan-start` configures an isolated network namespace (`PrivateNetwork=yes`), attaches VLAN or virtual interfaces from `SetCredential=net.if.*`, and delegates container setup to `pod-container-start`.
3. `host/usr/lib/systemd/pod-container-start` derives the machine name from the systemd unit name, sets the container hostname to `INVOCATION_ID` (unless `SetCredential=pod.hostname:` is specified), derives a deterministic `/etc/machine-id` per host and unit for persistent journaling across restarts, mounts the per-pod stage 1 overlay, shared `/vol/*` directories, stage 2 application overlays, declarative host bind mounts, and container journal directories before executing `systemd-nspawn --notify-ready=yes`.
4. `host/usr/lib/systemd/pod-wait-ready` verifies the inner stage 1 D-Bus socket is ready to accept connections (returning immediately when `systemd-nspawn --notify-ready=yes` is used, and also ensuring `pod-apps-start` runs as the second `ExecStartPost=` to avoid a systemd 252 bug where the first `ExecStartPost=` masks `/run/credentials` when `PrivateIPC=yes` and `SetCredential=` are combined).
5. `host/usr/lib/systemd/pod-apps-start` reads `SetCredential=pod.app.*` definitions and launches each stage 2 application inside the pod via `systemd-run --machine` with `ProtectHostname=yes` (so each stage 2 overlay receives its own UTS namespace and distinct stage 2 `InvocationID` hostname) and `LogExtraFields=POD_UNIT=<machine>`.

---

## Repository structure

```text
.
├── README.md
├── host
│   └── usr
│       └── lib
│           └── systemd
│               ├── pod-apps-start
│               ├── pod-container-start
│               ├── pod-net-host-start
│               ├── pod-net-start
│               ├── pod-net-stop
│               ├── pod-net-vlan-start
│               └── pod-wait-ready
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
    │           ├── systemd-journald-dev-log.socket.d
    │           │   └── 10-no-deps.conf
    │           ├── systemd-journald.service.d
    │           │   └── 10-no-deps.conf
    │           └── systemd-journald.socket.d
    │               └── 10-no-deps.conf
    └── usr
        └── lib
            └── systemd
                └── pod-os-release-sync
```

---

## Building the stage 1 image with debootstrap

The stage 1 supervisor image resides at `/var/lib/machines/stage1-debian`. It requires `systemd`, `systemd-sysv`, and `dbus` so that `systemd-run --machine` and `machinectl shell` can communicate with the inner PID 1 over D-Bus, along with `DefaultDependencies=no` drop-ins so that `pod-idle.target` starts only the supervisor sockets, journal, and D-Bus daemon.

### 1. Bootstrap a minimal Debian Bookworm root filesystem

Include `dbus`, `systemd`, `systemd-sysv`, `util-linux` (for `/usr/bin/nsenter` in `pod-enter.sh`), and `bash` in the `debootstrap` invocation:

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
* [`stage1/etc/systemd/system/container-shell@.service.d/10-no-deps.conf`](stage1/etc/systemd/system/container-shell@.service.d/10-no-deps.conf)
* [`stage1/etc/systemd/system/dbus.socket.d/10-no-deps.conf`](stage1/etc/systemd/system/dbus.socket.d/10-no-deps.conf)
* [`stage1/etc/systemd/system/dbus.service.d/10-no-deps.conf`](stage1/etc/systemd/system/dbus.service.d/10-no-deps.conf)
* [`stage1/etc/systemd/system/systemd-journald.socket.d/10-no-deps.conf`](stage1/etc/systemd/system/systemd-journald.socket.d/10-no-deps.conf)
* [`stage1/etc/systemd/system/systemd-journald-dev-log.socket.d/10-no-deps.conf`](stage1/etc/systemd/system/systemd-journald-dev-log.socket.d/10-no-deps.conf)
* [`stage1/etc/systemd/system/systemd-journald.service.d/10-no-deps.conf`](stage1/etc/systemd/system/systemd-journald.service.d/10-no-deps.conf)
* [`stage1/usr/lib/systemd/pod-os-release-sync`](stage1/usr/lib/systemd/pod-os-release-sync)
* [`stage1/etc/profile.d/pod-enter.sh`](stage1/etc/profile.d/pod-enter.sh)

```sh
sudo cp -r stage1/etc/* /var/lib/machines/stage1-debian/etc/
sudo cp -r stage1/usr/* /var/lib/machines/stage1-debian/usr/
sudo chmod 0755 /var/lib/machines/stage1-debian/usr/lib/systemd/pod-os-release-sync
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

Install the seven lifecycle scripts from [`host/usr/lib/systemd/`](host/usr/lib/systemd/) into `/usr/lib/systemd/`:

* [`host/usr/lib/systemd/pod-apps-start`](host/usr/lib/systemd/pod-apps-start)
* [`host/usr/lib/systemd/pod-container-start`](host/usr/lib/systemd/pod-container-start)
* [`host/usr/lib/systemd/pod-net-host-start`](host/usr/lib/systemd/pod-net-host-start)
* [`host/usr/lib/systemd/pod-net-vlan-start`](host/usr/lib/systemd/pod-net-vlan-start)
* [`host/usr/lib/systemd/pod-net-start`](host/usr/lib/systemd/pod-net-start)
* [`host/usr/lib/systemd/pod-wait-ready`](host/usr/lib/systemd/pod-wait-ready)
* [`host/usr/lib/systemd/pod-net-stop`](host/usr/lib/systemd/pod-net-stop)

```sh
sudo install -m 0755 \
  host/usr/lib/systemd/pod-apps-start \
  host/usr/lib/systemd/pod-container-start \
  host/usr/lib/systemd/pod-net-host-start \
  host/usr/lib/systemd/pod-net-vlan-start \
  host/usr/lib/systemd/pod-net-start \
  host/usr/lib/systemd/pod-wait-ready \
  host/usr/lib/systemd/pod-net-stop \
  /usr/lib/systemd/
```

---

## Importing a stage 2 application image

Stage 2 images are root filesystem directories stored in `/var/lib/machines/<app>` and marked read-only. To import an Alpine Linux root filesystem as `test-ping`:

```sh
sudo machinectl import-tar alpine-minirootfs-3.18.4-riscv64.tar.gz test-ping
```

`pod-apps-start` supports two ways of defining the command executed for each stage 2 application:

1. Passing `exec=` directly in the `SetCredential=pod.app.<name>:image=<image>,exec=<command>` credential on the pod unit.
2. Embedding a default command in `/var/lib/machines/<image>/etc/pod-entrypoint` before marking the image read-only:

```sh
echo "/bin/ping 127.0.0.1" | sudo tee /var/lib/machines/test-ping/etc/pod-entrypoint
sudo machinectl read-only test-ping yes
```

When `/etc/pod-entrypoint` is present inside the image, `SetCredential=pod.app.ping:test-ping` (or `SetCredential=pod.app.ping:image=test-ping`) launches the default command without needing `exec=` in the unit file.

Stage 2 images can also embed optional default files in `/etc/` (`pod-type`, `pod-user`, `pod-group`, `pod-wd`, `pod-caps`, and `pod-environment`), and any of these settings can be configured or overridden per application instance via comma-separated keys in `SetCredential=pod.app.<name>:...`:

* `image=<image>` selects the stage 2 image in `/var/lib/machines/<image>`.
* `exec=<cmd>` sets the application command line (falling back to `/etc/pod-entrypoint`).
* `type=<type>` sets the systemd service `Type=` (falling back to `/etc/pod-type`, and enabling `NotifyAccess=all` automatically when set to `notify` or `notify-reload`).
* `bind=<src>:<dst>` and `bind_ro=<src>:<dst>` mount pod `/vol/*` or stage 1 paths into the stage 2 root filesystem.
* `after=<unit>` orders startup after one or more sibling stage 2 units (across multi-tier dependency chains) or stage 1 units inside the pod.
* `user=<user>` and `group=<group>` set `User=` and `Group=` (falling back to `/etc/pod-user` and `/etc/pod-group`), while `sup_groups=<g1> <g2>` sets `SupplementaryGroups=`.
* `caps=<cap1> <cap2>` and `ambient_caps=<cap1> <cap2>` set `CapabilityBoundingSet=` (falling back to `/etc/pod-caps`) and `AmbientCapabilities=`. Pod-wide capabilities passed to `systemd-nspawn` can also be configured via `SetCredential=pod.caps:CAP_NET_ADMIN,CAP_NET_RAW,...`.
* `exec_pre=<cmd>`, `exec_post=<cmd>`, and `exec_stop=<cmd>` configure `ExecStartPre=`, `ExecStartPost=`, and `ExecStopPost=` hooks inside the stage 2 root filesystem.
* `memory_max=<bytes>`, `memory_high=<bytes>`, `cpu_quota=<pct>`, `cpu_weight=<weight>`, and `tasks_max=<n>` configure per-application cgroup resource limits.
* `syscall_filter=<set>` sets `SystemCallFilter=`, `env=<KEY=VAL>` sets `Environment=` (supplementing `/etc/pod-environment`), and `wd=<path>` sets `WorkingDirectory=` (falling back to `/etc/pod-wd`).

---

## Running a pod with host networking

When a pod runs with `PrivateNetwork=no`, `pod-net-host-start` (or `pod-net-start`) invokes `pod-container-start`. `systemd-run` generates a unique `run-r<32hex>.service` unit name automatically when `--unit=` is omitted; `RuntimeDirectory=pods/%N` allocates `/run/pods/<unit-name>`, `systemd-nspawn --notify-ready=yes` signals readiness once stage 1 finishes booting `pod-idle.target`, and `pod-apps-start` launches each `pod.app.*` credential inside the pod.

```sh
sudo systemd-run --collect \
  --slice=machine.slice \
  --property=Type=notify \
  --property=Delegate=yes \
  --property=PrivateNetwork=no \
  --property=PrivateIPC=yes \
  --property="RuntimeDirectory=pods/%N" \
  --property="SetCredential=pod.stage1:stage1-debian" \
  --property="SetCredential=pod.app.ping:image=test-ping,exec=/bin/ping 127.0.0.1" \
  --property="ExecStartPost=/usr/lib/systemd/pod-wait-ready" \
  --property="ExecStartPost=/usr/lib/systemd/pod-apps-start" \
  /usr/lib/systemd/pod-net-host-start
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
  --property="SetCredential=pod.app.ping:image=test-ping,exec=/bin/ping 192.0.2.1" \
  --property="ExecStartPost=/usr/lib/systemd/pod-wait-ready" \
  --property="ExecStartPost=/usr/lib/systemd/pod-apps-start" \
  /usr/lib/systemd/pod-net-vlan-start
```

---

## Declarative systemd unit example

Persistent pods can be managed as standard systemd units without hardcoded UUIDs. The unit name (`pod-bgp.service`) becomes the `machinectl` machine name (`pod-bgp`), `INVOCATION_ID` becomes the container hostname on each activation (overridable via `SetCredential=pod.hostname:<name>`), and `/etc/machine-id` is derived deterministically from the host `/etc/machine-id` and machine name so `journalctl -M pod-bgp` spans restarts:

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
SetCredential=pod.app.zebra:image=zebra-riscv64,exec=/usr/lib/quagga/zebra -A 127.0.0.1,bind=/vol/run:/run/quagga,bind_ro=/vol/conf:/etc/quagga,caps=CAP_NET_ADMIN CAP_NET_RAW CAP_SYS_ADMIN CAP_SETUID CAP_SETGID CAP_CHOWN CAP_DAC_OVERRIDE,memory_max=256M,tasks_max=64
SetCredential=pod.app.bgpd:image=bgpd-riscv64,exec=/usr/lib/quagga/bgpd -A 127.0.0.1,bind=/vol/run:/run/quagga,bind_ro=/vol/conf:/etc/quagga,after=zebra.service,caps=CAP_NET_ADMIN CAP_NET_RAW CAP_NET_BIND_SERVICE CAP_NET_BROADCAST CAP_SYS_ADMIN CAP_SETUID CAP_SETGID CAP_CHOWN CAP_DAC_OVERRIDE,memory_max=256M,tasks_max=64

ExecStart=/usr/lib/systemd/pod-net-start
ExecStartPost=/usr/lib/systemd/pod-wait-ready
ExecStartPost=/usr/lib/systemd/pod-apps-start

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
  sudo machinectl shell --setenv=POD_APP=zebra pod-bgp
  ```
* Remain in the stage 1 Debian supervisor shell without entering stage 2:
  ```sh
  sudo machinectl shell --setenv=POD_STAGE1_STAY=1 pod-bgp
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
