if [ "${SHLVL:-1}" -eq 1 ] && [ -z "${_POD_ENTER_DONE:-}" ]; then
    _POD_ENTER_DONE=1
    _pod_req_user="${USER:-root}"
    if [ "$_pod_req_user" != "root" ]; then
        export USER=root LOGNAME=root
    fi

    if [ "$_pod_req_user" != "stage1" ]; then
        _pod_target_pid=""
        _pod_active_count=0
        _pod_active_apps=""
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
                    dbus.service|systemd-*|container-*|pod-os-release-*|pod-stage2-post@*|pod-stdio@*|run-*.service) continue ;;
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

                _pod_app_name="${_pod_unit_name%.service}"

                if [ "$_pod_req_user" != "root" ]; then
                    if [ "$_pod_app_name" = "$_pod_req_user" ] || { [ -d "/opt/stage2/${_pod_req_user}/rootfs" ] && [ "/proc/${_pod_pid}/root" -ef "/opt/stage2/${_pod_req_user}/rootfs" ]; }; then
                        _pod_target_pid="$_pod_pid"
                        _pod_active_count=1
                        break
                    fi
                else
                    _pod_target_pid="$_pod_pid"
                    _pod_active_count=$((_pod_active_count + 1))
                    _pod_active_apps="${_pod_active_apps:+${_pod_active_apps}, }${_pod_app_name}"
                fi
            done
        fi

        if [ "$_pod_active_count" -eq 1 ] && [ -n "$_pod_target_pid" ]; then
            if [ -x "/proc/${_pod_target_pid}/root/bin/bash" ]; then
                _pod_target_shell=/bin/bash
            else
                _pod_target_shell=/bin/sh
            fi
            exec /usr/bin/nsenter --target="$_pod_target_pid" --mount --uts --ipc --net --pid --root --wd "$_pod_target_shell" -l
        elif [ "$_pod_req_user" != "root" ]; then
            printf "pod-enter: Stage 2 app '%s' is not running; staying in Stage 1.\n" "$_pod_req_user" >&2
        elif [ "$_pod_active_count" -gt 1 ]; then
            printf "pod-enter: multiple Stage 2 apps active (%s); use: machinectl shell <app>@<pod>\n" "$_pod_active_apps" >&2
        fi

        unset _pod_target_pid _pod_active_count _pod_active_apps _pod_cgroup_slice \
              _pod_unit_dir _pod_unit_name _pod_pid _pod_cand_pid _pod_app_name \
              _pod_target_shell
    fi
    unset _pod_req_user
fi
