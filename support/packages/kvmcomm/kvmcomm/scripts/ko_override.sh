# shellcheck shell=bash
# Sourced by kvmcomm_pre.sh and kvmcomm.sh; not run on its own.
#
# /kvmcomm/ko_<kver>/ holds per-kernel overrides of /kvmcomm/ko/ (build_kernel.sh
# deploys fresh modules there). An override must not replace a module the
# package ships newer: an old backup left in ko_<kver>/ used to shadow every
# lt6911_manage.ko update.
#
# ko_override_ok OVERRIDE SHIPPED
#   Succeeds when OVERRIDE should be used in place of SHIPPED: SHIPPED is
#   missing, either module has no MODULE_VERSION, or OVERRIDE's version is
#   the same or newer. Fails when OVERRIDE is missing or older.
ko_override_ok() {
    local override="$1" shipped="$2" v_over v_ship
    [ -f "$override" ] || return 1
    [ -f "$shipped" ] || return 0
    v_over=$(modinfo -F version "$override" 2>/dev/null)
    v_ship=$(modinfo -F version "$shipped" 2>/dev/null)
    [ -n "$v_over" ] && [ -n "$v_ship" ] || return 0
    [ "$v_over" = "$v_ship" ] && return 0
    # Newer of the two sorts last.
    [ "$(printf '%s\n%s\n' "$v_ship" "$v_over" | sort -V | tail -n 1)" = "$v_over" ]
}
