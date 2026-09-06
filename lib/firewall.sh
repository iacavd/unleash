# shellcheck shell=bash

FIREWALL_ANCHOR="com.unleash/mdm"
FIREWALL_LIVE_CONF="/etc/pf.conf"
FIREWALL_LIVE_ANCHOR="/etc/pf.anchors/com.unleash/mdm"

MDM_BLOCKLIST="deviceenrollment.apple.com mdmenrollment.apple.com iprofiles.apple.com"

# Recovery: $DATA/private/etc. Live: /private/etc (firmlink of /etc).
_fw_root() {
	local root="${DATA_ROOT-}"
	if [ -z "$root" ] && [ -n "${1-}" ]; then
		root="$1"
	fi
	printf '%s' "$root"
}

_fw_conf_path() {
	printf '%s/private/etc/pf.conf' "$(_fw_root "${1-}")"
}

_fw_anchor_path() {
	printf '%s/private/etc/pf.anchors/%s' "$(_fw_root "${1-}")" "$FIREWALL_ANCHOR"
}

# Recovery pfctl -f would load Recovery's kernel, not the target volume.
_fw_kernel_load() {
	if type is_recovery >/dev/null 2>&1 && is_recovery; then
		return 1
	fi
	local conf="$1"
	[ "$conf" = "/private/etc/pf.conf" ] || [ "$conf" = "/etc/pf.conf" ]
}

_mdm_ips_tsv() {
	if [ -n "${SCRIPT_DIR:-}" ] && [ -f "$SCRIPT_DIR/data/mdm-ips.tsv" ]; then
		printf '%s\n' "$SCRIPT_DIR/data/mdm-ips.tsv"
		return 0
	fi
	local root=""
	if type unleash_root >/dev/null 2>&1; then
		root=$(unleash_root)
	else
		root="${DATA_ROOT-}/Library/Unleash"
	fi
	if [ -f "$root/data/mdm-ips.tsv" ]; then
		printf '%s\n' "$root/data/mdm-ips.tsv"
		return 0
	fi
	return 1
}

_tsv_ips_for_domain() {
	local domain="$1"
	local kind="${2:-ipv4}"
	local tsv col
	tsv=$(_mdm_ips_tsv) || return 1
	[ -f "$tsv" ] || return 1
	if [ "$kind" = "ipv6" ]; then
		col=3
	else
		col=2
	fi
	awk -F '\t' -v d="$domain" -v c="$col" '
		/^#/ { next }
		NF < 2 { next }
		$1 == d && $c != "" { print $c }
	' "$tsv"
}

_resolve_dns() {
	local domain="$1"
	local record_type="${2:-A}"
	local ips=""

	if command -v host >/dev/null 2>&1; then
		if [ "$record_type" = "A" ]; then
			ips=$(host -t a "$domain" 2>/dev/null | awk '/has address/{print $NF}')
		else
			ips=$(host -t aaaa "$domain" 2>/dev/null | awk '/has IPv6 addr/{print $NF}')
		fi
		if [ -n "$ips" ]; then
			printf '%s\n' "$ips"
			return 0
		fi
	fi

	if command -v nslookup >/dev/null 2>&1; then
		if [ "$record_type" = "A" ]; then
			ips=$(nslookup -type=a "$domain" 2>/dev/null \
				| awk '/^Address: / && !/#/{print $2}' \
				| grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' || true)
		else
			ips=$(nslookup -type=aaaa "$domain" 2>/dev/null \
				| awk '/^Address: / && !/#/{print $2}' \
				| grep -E ':' || true)
		fi
		if [ -n "$ips" ]; then
			printf '%s\n' "$ips"
			return 0
		fi
	fi

	if command -v dig >/dev/null 2>&1; then
		if [ "$record_type" = "A" ]; then
			ips=$(dig +short "$domain" A 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' || true)
		else
			ips=$(dig +short "$domain" AAAA 2>/dev/null | grep -E ':' || true)
		fi
		if [ -n "$ips" ]; then
			printf '%s\n' "$ips"
			return 0
		fi
	fi

	return 1
}

# DNS first, then TSV for that domain. No hardcoded IPs here.
_fw_ips_for_domain() {
	local domain="$1"
	local record_type="${2:-A}"
	local kind="ipv4"
	local ips=""
	[ "$record_type" = "AAAA" ] && kind="ipv6"
	ips=$(_resolve_dns "$domain" "$record_type" 2>/dev/null || true)
	if [ -z "$ips" ]; then
		ips=$(_tsv_ips_for_domain "$domain" "$kind" 2>/dev/null || true)
	fi
	if [ -n "$ips" ]; then
		printf '%s\n' "$ips"
		return 0
	fi
	return 1
}

pf_backup_anchor() {
	local root
	root="$(_fw_root "${1-}")"
	local anchor_file
	anchor_file="$(_fw_anchor_path "$root")"
	[ -f "$anchor_file" ] || return 0
	local backup="${anchor_file}.backup.$(date +%s)"
	cp "$anchor_file" "$backup" && info "Backed up pf anchor: $backup"
}

pf_backup_conf() {
	local root
	root="$(_fw_root "${1-}")"
	local pf_conf
	pf_conf="$(_fw_conf_path "$root")"
	[ -f "$pf_conf" ] || return 0
	local backup="${pf_conf}.backup.$(date +%s)"
	cp "$pf_conf" "$backup" && info "Backed up pf.conf: $backup"
}

_fw_drop_selective_leftover() {
	local root="$1"
	rm -f "${root}/private/etc/pf.anchors/com.unleash.selective"
	rm -f "${root}/etc/pf.anchors/com.unleash.selective"
	local pf_conf
	pf_conf="$(_fw_conf_path "$root")"
	[ -f "$pf_conf" ] || return 0
	sed -i '' '/com\.unleash\.selective/d' "$pf_conf" 2>/dev/null || true
}

_install_pf_anchor() {
	local root="$1"
	local pf_conf
	pf_conf="$(_fw_conf_path "$root")"
	mkdir -p "$(dirname "$pf_conf")"

	local anchor_line="anchor \"${FIREWALL_ANCHOR}\""
	local load_line="load anchor \"${FIREWALL_ANCHOR}\" from \"${FIREWALL_LIVE_ANCHOR}\""

	_fw_drop_selective_leftover "$root"

	if [ -f "$pf_conf" ]; then
		if grep -q "com.unleash/mdm" "$pf_conf" 2>/dev/null; then
			info "pf.conf already has Unleash anchor"
		else
			sed -i '' '/# Added by unleash/d' "$pf_conf" 2>/dev/null || true
			sed -i '' '/com\.unleash/d' "$pf_conf" 2>/dev/null || true
			printf '\n# Added by unleash — MDM block\n%s\n%s\n' "$anchor_line" "$load_line" >> "$pf_conf"
			success "pf.conf updated"
		fi
	else
		cat > "$pf_conf" <<- EOF
		# pf.conf — restored by unleash
		#
		# Default macOS pf.conf
		scrub-anchor "com.apple/*"
		nat-anchor "com.apple/*"
		rdr-anchor "com.apple/*"
		dummynet-anchor "com.apple/*"
		fwd-anchor "com.apple/*"
		anchor "com.apple/*"
		load anchor "com.apple" from "/etc/pf.anchors/com.apple"

		# Added by unleash — MDM block
		${anchor_line}
		${load_line}
		EOF
		success "pf.conf created with Unleash anchor"
	fi

	if ! _fw_kernel_load "$pf_conf"; then
		if type is_recovery >/dev/null 2>&1 && is_recovery; then
			result_skip S_PF_RECOVERY firewall pf "files written, kernel load skipped"
		else
			result_ok firewall pf "files written (kernel load skipped)"
		fi
		return 0
	fi

	step "Loading pf rules..."
	local pfctl="${PFCTL:-/sbin/pfctl}"
	if [ ! -x "$pfctl" ]; then
		result_fail E_PFCTL_FAIL firewall load "pfctl not available"
		return 1
	fi
	if ! "$pfctl" -e -f "$pf_conf" >/dev/null 2>&1; then
		result_fail E_PFCTL_FAIL firewall load "pfctl -e -f failed"
		return 1
	fi
	result_ok firewall load "pf enabled and rules loaded"
	success "pf enabled and rules loaded"
}

install_pf_mdm_block_selective() {
	local data_mount="${1-}"
	if [ -n "$data_mount" ]; then
		DATA_ROOT="$data_mount"
	fi
	local root
	root="$(_fw_root "$data_mount")"

	step "Installing pf anchor for selective MDM IP block..."
	pf_backup_conf "$root"

	local anchor_file
	anchor_file="$(_fw_anchor_path "$root")"
	pf_backup_anchor "$root"

	local rules=""
	local total=0
	local d ip ips
	for d in $MDM_BLOCKLIST; do
		ips=$(_fw_ips_for_domain "$d" "A" || true)
		if [ -n "$ips" ]; then
			while IFS= read -r ip; do
				[ -n "$ip" ] || continue
				rules="${rules}block drop out proto {tcp,udp} to {${ip}}"$'\n'
				total=$((total + 1))
			done <<EOF
$ips
EOF
		fi
		ips=$(_fw_ips_for_domain "$d" "AAAA" || true)
		if [ -n "$ips" ]; then
			while IFS= read -r ip; do
				[ -n "$ip" ] || continue
				rules="${rules}block drop out proto {tcp,udp} to {${ip}}"$'\n'
				total=$((total + 1))
			done <<EOF
$ips
EOF
		fi
	done

	if [ "$total" -eq 0 ]; then
		result_skip E_DNS_FAIL firewall selective "no MDM IPs from DNS or TSV; not writing empty anchor"
		return 0
	fi

	mkdir -p "$(dirname "$anchor_file")"
	{
		echo "# Unleash MDM block — selective mode (iCloud-safe)"
		echo "# Blocks only resolved MDM infrastructure IPs"
		echo "# Stale TSV IPs can miss MDM; DNS is tried first."
		printf '%s' "$rules"
	} > "$anchor_file"
	chmod 644 "$anchor_file"
	success "Selective anchor written: $anchor_file ($total resolved IPs)"

	_install_pf_anchor "$root" "$anchor_file"

	info "Selective mode: only MDM IPs are blocked."
	info "iCloud, App Store, and Apple updates should still work."
}

install_pf_mdm_block_broad() {
	local data_mount="${1-}"
	if [ -n "$data_mount" ]; then
		DATA_ROOT="$data_mount"
	fi
	local root
	root="$(_fw_root "$data_mount")"

	step "Installing pf anchor for BROAD MDM IP block..."
	pf_backup_conf "$root"

	local anchor_file
	anchor_file="$(_fw_anchor_path "$root")"
	pf_backup_anchor "$root"
	mkdir -p "$(dirname "$anchor_file")"

	cat > "$anchor_file" << 'ANCHOR'
# Unleash MDM block — BROAD mode (blocks ALL Apple services)
# These ranges host deviceenrollment.apple.com, mdmenrollment.apple.com, etc.
# Blocking at pf level is immune to DNS-over-HTTPS bypass.
# WARNING: This blocks iCloud, App Store, and Apple updates.
block drop out proto {tcp,udp} to {17.0.0.0/8}
ANCHOR
	chmod 644 "$anchor_file"
	success "Broad anchor written: $anchor_file"

	_install_pf_anchor "$root" "$anchor_file"

	warn "BROAD MODE: This blocks ALL Apple services (iCloud, App Store, updates)."
	warn "Use 'firewall' (selective) instead if you need Apple services."
}

install_pf_mdm_block() {
	install_pf_mdm_block_selective "$@"
}

remove_pf_mdm_block() {
	local data_mount="${1-}"
	if [ -n "$data_mount" ]; then
		DATA_ROOT="$data_mount"
	fi
	local root
	root="$(_fw_root "$data_mount")"

	step "Removing Unleash pf anchor..."

	local anchor_file
	anchor_file="$(_fw_anchor_path "$root")"
	if [ -f "$anchor_file" ]; then
		pf_backup_anchor "$root"
		rm -f "$anchor_file"
		success "Anchor file removed"
	fi
	_fw_drop_selective_leftover "$root"

	local pf_conf
	pf_conf="$(_fw_conf_path "$root")"
	if [ -f "$pf_conf" ]; then
		sed -i '' '/# Added by unleash/d' "$pf_conf" 2>/dev/null || true
		sed -i '' '/com\.unleash/d' "$pf_conf" 2>/dev/null || true
		success "pf.conf cleaned"
	fi

	if _fw_kernel_load "$pf_conf"; then
		step "Flushing pf anchor..."
		local pfctl="${PFCTL:-/sbin/pfctl}"
		if [ -x "$pfctl" ]; then
			"$pfctl" -a "$FIREWALL_ANCHOR" -F all >/dev/null 2>&1 || true
			success "pf anchor flushed"
		fi
	fi
}

pf_status() {
	step "pf firewall status..."
	local pfctl="${PFCTL:-/sbin/pfctl}"
	if [ -x "$pfctl" ]; then
		"$pfctl" -si 2>/dev/null | grep -E "Status|Enabled" || echo "  pf not enabled"
		echo ""
		local rules=""
		rules=$("$pfctl" -a "$FIREWALL_ANCHOR" -s rules 2>/dev/null || true)
		if [ -n "$rules" ]; then
			info "Unleash MDM anchor rules ($FIREWALL_ANCHOR):"
			echo "$rules" | sed 's/^/  /'
			if echo "$rules" | grep -q "17.0.0.0/8"; then
				info "Mode: BROAD (all Apple IPs blocked)"
			else
				info "Mode: SELECTIVE (only MDM IPs blocked)"
			fi
		else
			info "No Unleash MDM anchor loaded"
		fi
	else
		warn "pfctl not available"
	fi
}
