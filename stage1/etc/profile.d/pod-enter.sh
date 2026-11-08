if [ -z "${POD_STAGE1_STAY:-}" ]; then
    _pod_target_pid=""
    _pod_active_count=0
    _pod_cgroup_slice=""

    if [ -d /sys/fs/cgroup/system.slice ]; then
        _pod_cgroup_slice="/sys/fs/cgroup/system.slice"
    elif [ -d /sys/fs/cgroup/systemd/system.slice ]; then
        _pod_cgroup_slice="/sys/fs/cgroup/systemd/system.slice"
    fi

    _pod_stage1_root="$(stat -Lc '%d:%i' / 2>/dev/null || true)"

    if [ -n "$_pod_cgroup_slice" ]; then
        for _pod_unit_dir in "${_pod_cgroup_slice}"/*.service; do
            if [ ! -d "$_pod_unit_dir" ]; then
                continue
            fi
            _pod_unit_name="${_pod_unit_dir##*/}"
            case "$_pod_unit_name" in
                dbus.service|systemd-*|container-*|pod-os-release-*|run-*.service) continue ;;
            esac

            _pod_pid=""
            if [ -r "${_pod_unit_dir}/cgroup.procs" ]; then
                IFS= read -r _pod_pid < "${_pod_unit_dir}/cgroup.procs" 2>/dev/null || true
            fi
            if [ -z "$_pod_pid" ] || [ ! -e "/proc/${_pod_pid}/root" ]; then
                continue
            fi

            _pod_proc_root="$(stat -Lc '%d:%i' "/proc/${_pod_pid}/root" 2>/dev/null || true)"
            if [ -z "$_pod_proc_root" ] || [ "$_pod_proc_root" = "$_pod_stage1_root" ]; then
                continue
            fi

            _pod_app_id=""
            _pod_cand="${_pod_unit_name%.service}"
            if [ -d "/opt/stage2/${_pod_cand}/rootfs" ]; then
                _pod_cand_root="$(stat -Lc '%d:%i' "/opt/stage2/${_pod_cand}/rootfs" 2>/dev/null || true)"
                if [ "$_pod_cand_root" = "$_pod_proc_root" ]; then
                    _pod_app_id="$_pod_cand"
                fi
            fi

            if [ -z "$_pod_app_id" ]; then
                for _pod_stage2_dir in /opt/stage2/*/rootfs; do
                    if [ ! -d "$_pod_stage2_dir" ]; then
                        continue
                    fi
                    _pod_cand_root="$(stat -Lc '%d:%i' "$_pod_stage2_dir" 2>/dev/null || true)"
                    if [ "$_pod_cand_root" = "$_pod_proc_root" ]; then
                        _pod_tmp="${_pod_stage2_dir#/opt/stage2/}"
                        _pod_app_id="${_pod_tmp%/rootfs}"
                        break
                    fi
                done
            fi

            if [ -n "${POD_APP:-}" ]; then
                if [ "$_pod_unit_name" = "${POD_APP}.service" ] || [ "$_pod_unit_name" = "pod-app-${POD_APP}.service" ] || [ "$_pod_unit_name" = "${POD_APP}" ] || { [ -n "$_pod_app_id" ] && [ "$_pod_app_id" = "${POD_APP}" ]; }; then
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

    unset _pod_target_pid _pod_active_count _pod_cgroup_slice _pod_stage1_root \
          _pod_unit_dir _pod_unit_name _pod_pid _pod_proc_root _pod_app_id \
          _pod_cand _pod_cand_root _pod_stage2_dir _pod_tmp _pod_target_shell
fi
