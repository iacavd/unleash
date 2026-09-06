# shellcheck shell=bash
# Thin alias of the merged firewall engine. One anchor: com.unleash/mdm.

install_selective_block() {
  install_pf_mdm_block_selective "$@"
}

restore_hosts_based_block() {
  local data_mount="$1"
  local root=""
  [ -n "$data_mount" ] && root="$data_mount"
  local hosts="${root}/private/etc/hosts"

  if [ -f "$hosts" ] && grep -q "Added by unleash" "$hosts" 2>/dev/null; then
    info "unleash hosts entries intact"
  fi
}
