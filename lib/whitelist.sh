MDM_BLOCKLIST="mdmenrollment.apple.com deviceenrollment.apple.com iprofiles.apple.com"

# Hardcoded fallback IPs for air-gapped / Recovery environments
# These are well-known Apple MDM infrastructure IPs (updated periodically)
MDM_FALLBACK_IPV4=(
  "17.253.34.253"   # deviceenrollment.apple.com
  "17.253.34.254"   # mdmenrollment.apple.com
  "17.253.34.252"   # iprofiles.apple.com
  "17.32.215.136"   # deviceenrollment.apple.com (alt)
  "17.110.228.136"  # mdmenrollment.apple.com (alt)
  "17.188.166.20"   # iprofiles.apple.com (alt)
)

_resolve_dns() {
  # Resolve a domain to IP addresses using a fallback chain:
  #   host → nslookup → dig → hardcoded fallbacks
  # Returns newline-separated IPs (both v4 and v6)
  local domain="$1"
  local record_type="${2:-A}"  # A or AAAA
  local ips=""

  # Strategy 1: host
  if command -v host &>/dev/null; then
    if [ "$record_type" = "A" ]; then
      ips=$(host -t a "$domain" 2>/dev/null | awk '/has address/{print $NF}')
    else
      ips=$(host -t aaaa "$domain" 2>/dev/null | awk '/has IPv6 addr/{print $NF}')
    fi
    if [ -n "$ips" ]; then
      echo "$ips"
      return 0
    fi
  fi

  # Strategy 2: nslookup
  if command -v nslookup &>/dev/null; then
    if [ "$record_type" = "A" ]; then
      ips=$(nslookup -type=a "$domain" 2>/dev/null \
        | awk '/^Address: / && !/#/{print $2}' \
        | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$')
    else
      ips=$(nslookup -type=aaaa "$domain" 2>/dev/null \
        | awk '/^Address: / && !/#/{print $2}' \
        | grep -E ':')
    fi
    if [ -n "$ips" ]; then
      echo "$ips"
      return 0
    fi
  fi

  # Strategy 3: dig
  if command -v dig &>/dev/null; then
    if [ "$record_type" = "A" ]; then
      ips=$(dig +short "$domain" A 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$')
    else
      ips=$(dig +short "$domain" AAAA 2>/dev/null | grep -E ':')
    fi
    if [ -n "$ips" ]; then
      echo "$ips"
      return 0
    fi
  fi

  # Strategy 4: hardcoded fallbacks (only for IPv4, only for known domains)
  if [ "$record_type" = "A" ]; then
    debug "DNS resolution failed for $domain — using hardcoded fallbacks"
    case "$domain" in
      deviceenrollment.apple.com)
        echo "17.253.34.253"
        echo "17.32.215.136"
        return 0
        ;;
      mdmenrollment.apple.com)
        echo "17.253.34.254"
        echo "17.110.228.136"
        return 0
        ;;
      iprofiles.apple.com)
        echo "17.253.34.252"
        echo "17.188.166.20"
        return 0
        ;;
    esac
  fi

  debug "Could not resolve $domain ($record_type) — no results"
  return 1
}

install_selective_block() {
  local data_mount="$1"
  local root=""
  [ -n "$data_mount" ] && root="$data_mount"

  step "Installing selective pf rules (block MDM only, allow Apple services)..."

  local anchor_dir="${root}/etc/pf.anchors"
  local anchor_file="${anchor_dir}/com.unleash.selective"
  mkdir -p "$anchor_dir"

  > "$anchor_file"

  local total_rules=0
  for d in $MDM_BLOCKLIST; do
    # IPv4 resolution with fallback chain
    local ipv4_list
    ipv4_list=$(_resolve_dns "$d" "A" 2>/dev/null || true)
    if [ -n "$ipv4_list" ]; then
      while IFS= read -r ip; do
        [ -n "$ip" ] || continue
        echo "block drop out proto {tcp,udp} to {$ip}" >> "$anchor_file"
        total_rules=$((total_rules + 1))
      done <<< "$ipv4_list"
    fi

    # IPv6 resolution with fallback chain
    local ipv6_list
    ipv6_list=$(_resolve_dns "$d" "AAAA" 2>/dev/null || true)
    if [ -n "$ipv6_list" ]; then
      while IFS= read -r ip; do
        [ -n "$ip" ] || continue
        echo "block drop out proto {tcp,udp} to {$ip}" >> "$anchor_file"
        total_rules=$((total_rules + 1))
      done <<< "$ipv6_list"
    fi
  done

  if [ "$total_rules" -eq 0 ]; then
    warn "No IPs resolved — using hardcoded fallback IPs"
    for ip in "${MDM_FALLBACK_IPV4[@]}"; do
      echo "block drop out proto {tcp,udp} to {$ip}" >> "$anchor_file"
    done
  fi

  chmod 644 "$anchor_file"
  success "Selective anchor written: $anchor_file ($total_rules rules)"

  local pf_conf="${root}/etc/pf.conf"
  local anchor_line="anchor \"com.unleash.selective\""
  local load_line="load anchor \"com.unleash.selective\" from \"${anchor_file}\""

  if [ -f "$pf_conf" ]; then
    if grep -q "com.unleash.selective" "$pf_conf" 2>/dev/null; then
      info "pf.conf already has selective anchor"
    else
      echo "" >> "$pf_conf"
      echo "# Added by unleash — selective MDM block (iCloud-safe)" >> "$pf_conf"
      echo "$anchor_line" >> "$pf_conf"
      echo "$load_line" >> "$pf_conf"
      success "pf.conf updated with selective rules"
    fi
  else
    cat > "$pf_conf" <<- EOF
scrub-anchor "com.apple/*"
nat-anchor "com.apple/*"
rdr-anchor "com.apple/*"
dummynet-anchor "com.apple/*"
fwd-anchor "com.apple/*"
anchor "com.apple/*"
load anchor "com.apple" from "/etc/pf.anchors/com.apple"
# Added by unleash — selective MDM block (iCloud-safe)
${anchor_line}
${load_line}
EOF
    success "pf.conf created"
  fi

  if command -v pfctl &>/dev/null; then
    pfctl -e -f "$pf_conf" 2>/dev/null && success "pf rules loaded (iCloud should work)" \
      || warn "pfctl failed"
  fi
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
