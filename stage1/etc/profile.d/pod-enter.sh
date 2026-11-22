if [ -z "${POD_STAGE1_STAY:-}" ]; then
    _pod_target_pid=""
    _pod_active_count=0
    _pod_cgroup_slice=""

    if [ -d /sys/fs/cgroup/system.slice ]; then
        _pod_cgroup_slice="/sys/fs/cgroup/system.slice"
    elif [ -d /sys/fs/cgroup/systemd/system.slice ]; then
        _pod_cgroup_slice="/sys/fs/cgroup/systemd/system.slice"
    fi

    if [ -n "$_pod_cgroup_slice" ]; then
        for _pod_unit_dir in "${_pod_cgroup_slice}"/*.service; do
            if [ ! -d "$_pod_unit_dir" ]; then
                continue
            fi
            _pod_unit_name="${_pod_unit_dir##*/}"
            case "$_pod_unit_name" in
                dbus.service|systemd-*|container-*|pod-os-release-*|pod-stage2-post@*|run-*.service) continue ;;
            esac

            _pod_pid=""
            if [ -r "${_pod_unit_dir}/cgroup.procs" ]; then
                while IFS= read -r _pod_cand_pid; do
                    if [ -n "$_pod_cand_pid" ] && [ -e "/proc/${_pod_cand_pid}/root" ] && [ ! "/proc/${_pod_cand_pid}/root" -ef / ]; then
                        _pod_pid="$_pod_cand_pid"
                        break
                    fi
                done < "${_pod_unit_dir}/cgroup.procs" 2>/dev/null || true
            fi
            if [ -z "$_pod_pid" ]; then
                continue
            fi

            if [ -n "${POD_APP:-}" ]; then
                _pod_match=0
                case "$_pod_unit_name" in
                    "${POD_APP}"|"${POD_APP}.service"|"pod-app-${POD_APP}.service") _pod_match=1 ;;
                esac
                if [ "$_pod_match" -eq 0 ] && [ -d "/opt/stage2/${POD_APP}/rootfs" ] && [ "/proc/${_pod_pid}/root" -ef "/opt/stage2/${POD_APP}/rootfs" ]; then
                    _pod_match=1
                fi
                if [ "$_pod_match" -eq 1 ]; then
                    _pod_target_pid="$_pod_pid"
                    _pod_active_count=1
                    break
                fi
            else
                _pod_target_pid="$_pod_pid"
                _pod_active_count=$((_pod_active_count + 1))
            fi
        done
    fi

    if [ "$_pod_active_count" -eq 1 ] && [ -n "$_pod_target_pid" ]; then
        export POD_STAGE1_STAY=1
        if [ -x "/proc/${_pod_target_pid}/root/bin/bash" ]; then
            _pod_target_shell=/bin/bash
        else
            _pod_target_shell=/bin/sh
        fi
        exec /usr/bin/nsenter --target="$_pod_target_pid" --mount --uts --ipc --net --pid --root --wd "$_pod_target_shell" -l
    fi

    unset _pod_target_pid _pod_active_count _pod_cgroup_slice \
          _pod_unit_dir _pod_unit_name _pod_pid _pod_cand_pid _pod_match \
          _pod_target_shell
fi
