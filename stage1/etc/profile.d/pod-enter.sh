if [ -z "${POD_STAGE1_STAY:-}" ]; then
    target_pid=""
    active_count=0

    for unit_path in /run/systemd/transient/*.service /etc/systemd/system/*.service; do
        if [ ! -f "$unit_path" ]; then
            continue
        fi
        unit_name="${unit_path##*/}"
        case "$unit_name" in
            dbus.service|systemd-*|container-*|pod-os-release-*) continue ;;
        esac

        root_dir="$(systemctl show -p RootDirectory --value "$unit_name" 2>/dev/null || true)"
        main_pid="$(systemctl show -p MainPID --value "$unit_name" 2>/dev/null || true)"

        if [ -n "$root_dir" ]; then
            if [ "$root_dir" != "/" ]; then
                if [ -n "$main_pid" ]; then
                    if [ "$main_pid" -gt 0 ] 2>/dev/null; then
                        if [ -n "${POD_APP:-}" ]; then
                            if [ "$unit_name" = "${POD_APP}.service" ] || [ "$unit_name" = "pod-app-${POD_APP}.service" ] || [ "$unit_name" = "${POD_APP}" ] || [ "$root_dir" = "/opt/stage2/${POD_APP}/rootfs" ]; then
                                target_pid="$main_pid"
                                active_count=1
                                break
                            fi
                        else
                            target_pid="$main_pid"
                            active_count=$((active_count + 1))
                        fi
                    fi
                fi
            fi
        fi
    done

    if [ "$active_count" -eq 1 ]; then
        if [ -n "$target_pid" ]; then
            export POD_STAGE1_STAY=1
            if [ -x /proc/"$target_pid"/root/bin/bash ]; then
                target_shell=/bin/bash
            else
                target_shell=/bin/sh
            fi
            exec /usr/bin/nsenter --target="$target_pid" --mount --uts --ipc --net --pid --root --wd "$target_shell" -l
        fi
    fi
fi
