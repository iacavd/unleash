
FIREWALL_ANCHOR="com.unleash/mdm"
FIREWALL_CONF="/etc/pf.conf"
FIREWALL_ANCHOR_DIR="/etc/pf.anchors"

pf_backup_anchor() {
	local root="$1"
	local anchor_file="${root}${FIREWALL_ANCHOR_DIR}/${FIREWALL_ANCHOR}"
	[ ! -f "$anchor_file" ] && return 0
	local backup="${anchor_file}.backup.$(date +%s)"
	cp "$anchor_file" "$backup" && info "Backed up pf anchor: $backup"
}

pf_backup_conf() {
	local root="$1"
	local pf_conf="${root}${FIREWALL_CONF}"
	[ ! -f "$pf_conf" ] && return 0
	local backup="${pf_conf}.backup.$(date +%s)"
	cp "$pf_conf" "$backup" && info "Backed up pf.conf: $backup"
}

# Selective mode: resolves specific MDM IPs and blocks only those
# This is the SAFE default — iCloud, App Store, and updates still work
install_pf_mdm_block_selective() {
	local data_mount="$1"
	local root=""
	[ -n "$data_mount" ] && root="$data_mount"

	step "Installing pf anchor for selective MDM IP block..."
	pf_backup_conf "$root"

	local anchor_dir="${root}${FIREWALL_ANCHOR_DIR}"
	local anchor_file="${anchor_dir}/${FIREWALL_ANCHOR}"

	pf_backup_anchor "$root"
	mkdir -p "$(dirname "$anchor_file")"

	# Resolve specific MDM domain IPs using fallback chain
	> "$anchor_file"
	echo "# Unleash MDM block — selective mode (iCloud-safe)" >> "$anchor_file"
	echo "# Blocks only resolved MDM infrastructure IPs" >> "$anchor_file"

	local domains="deviceenrollment.apple.com mdmenrollment.apple.com iprofiles.apple.com"
	local total=0
	for d in $domains; do
		local ips
		ips=$(_resolve_dns "$d" "A" 2>/dev/null || true)
		if [ -n "$ips" ]; then
			while IFS= read -r ip; do
				[ -n "$ip" ] || continue
				echo "block drop out proto {tcp,udp} to {$ip}" >> "$anchor_file"
				total=$((total + 1))
			done <<< "$ips"
		fi
	done

	# If DNS failed entirely, fall back to narrow Apple MDM ranges
	if [ "$total" -eq 0 ]; then
		warn "DNS resolution failed — using known MDM IP fallbacks"
		for ip in "${MDM_FALLBACK_IPV4[@]}"; do
			echo "block drop out proto {tcp,udp} to {$ip}" >> "$anchor_file"
		done
	fi

	chmod 644 "$anchor_file"
	success "Selective anchor written: $anchor_file ($total resolved IPs)"

	_install_pf_anchor "$root" "$anchor_file"

	info "Selective mode: only MDM IPs are blocked."
	info "iCloud, App Store, and Apple updates should still work."
}

# Broad mode: blocks entire Apple IP range (17.0.0.0/8)
# This is AGGRESSIVE — blocks ALL Apple services including iCloud
install_pf_mdm_block_broad() {
	local data_mount="$1"
	local root=""
	[ -n "$data_mount" ] && root="$data_mount"

	step "Installing pf anchor for BROAD MDM IP block..."
	pf_backup_conf "$root"

	local anchor_dir="${root}${FIREWALL_ANCHOR_DIR}"
	local anchor_file="${anchor_dir}/${FIREWALL_ANCHOR}"

	pf_backup_anchor "$root"
	mkdir -p "$(dirname "$anchor_file")"

	cat > "$anchor_file" << 'ANCHOR'
# Unleash MDM block — BROAD mode (blocks ALL Apple services)
# These ranges host deviceenrollment.apple.com, mdmenrollment.apple.com, etc.
# Blocking at pf level is immune to DNS-over-HTTPS bypass.
# WARNING: This blocks iCloud, App Store, and Apple updates.
block drop out proto {tcp,udp} to {17.0.0.0/8}
block drop out proto {tcp,udp} to {17.128.0.0/10}
ANCHOR
	chmod 644 "$anchor_file"
	success "Broad anchor written: $anchor_file"

	_install_pf_anchor "$root" "$anchor_file"

	warn "BROAD MODE: This blocks ALL Apple services (iCloud, App Store, updates)."
	warn "Use 'firewall' (selective) instead if you need Apple services."
}

# Default: selective mode
install_pf_mdm_block() {
	install_pf_mdm_block_selective "$@"
}

_install_pf_anchor() {
	local root="$1"
	local anchor_file="$2"

	local pf_conf="${root}${FIREWALL_CONF}"
	local anchor_line="anchor \"${FIREWALL_ANCHOR}\""
	local load_line="load anchor \"${FIREWALL_ANCHOR}\" from \"${anchor_file}\""

	if [ -f "$pf_conf" ]; then
		if grep -q "com.unleash" "$pf_conf" 2>/dev/null; then
			info "pf.conf already has Unleash anchor"
		else
			echo "" >> "$pf_conf"
			echo "# Added by unleash — MDM block" >> "$pf_conf"
			echo "$anchor_line" >> "$pf_conf"
			echo "$load_line" >> "$pf_conf"
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

	step "Loading pf rules..."
	if command -v pfctl &>/dev/null; then
		pfctl -e -f "$pf_conf" 2>/dev/null && success "pf enabled and rules loaded" \
			|| warn "pfctl failed — try: sudo pfctl -e -f $pf_conf"
	else
		warn "pfctl not available"
	fi
}

remove_pf_mdm_block() {
	local data_mount="$1"
	local root=""
	[ -n "$data_mount" ] && root="$data_mount"

	step "Removing Unleash pf anchor..."

	local anchor_file="${root}${FIREWALL_ANCHOR_DIR}/${FIREWALL_ANCHOR}"
	if [ -f "$anchor_file" ]; then
		pf_backup_anchor "$root"
		rm -f "$anchor_file"
		success "Anchor file removed"
	fi

	local pf_conf="${root}${FIREWALL_CONF}"
	if [ -f "$pf_conf" ]; then
		sed -i '' '/# Added by unleash/d' "$pf_conf" 2>/dev/null || true
		sed -i '' '/com\.unleash/d' "$pf_conf" 2>/dev/null || true
		success "pf.conf cleaned"
	fi

	step "Flushing pf anchor..."
	if command -v pfctl &>/dev/null; then
		pfctl -a "$FIREWALL_ANCHOR" -F all 2>/dev/null || true
		success "pf anchor flushed"
	else
		warn "pfctl not available"
	fi
}

pf_status() {
	step "pf firewall status..."
	if command -v pfctl &>/dev/null; then
		pfctl -si 2>/dev/null | grep -E "Status|Enabled" || echo "  pf not enabled"
		echo ""
		local rules=""
		rules=$(pfctl -a "$FIREWALL_ANCHOR" -s rules 2>/dev/null || true)
		local sel_rules=""
		sel_rules=$(pfctl -a "com.unleash.selective" -s rules 2>/dev/null || true)
		if [ -n "$rules" ]; then
			info "Unleash MDM anchor rules ($FIREWALL_ANCHOR):"
			echo "$rules" | sed 's/^/  /'
			if echo "$rules" | grep -q "17.0.0.0/8"; then
				info "Mode: BROAD (all Apple IPs blocked)"
			else
				info "Mode: SELECTIVE (only MDM IPs blocked)"
			fi
		elif [ -n "$sel_rules" ]; then
			info "Unleash selective anchor rules (com.unleash.selective):"
			echo "$sel_rules" | sed 's/^/  /'
			info "Mode: SELECTIVE (whitelist mode — MDM endpoints blocked, iCloud safe)"
		else
			info "No Unleash MDM anchor loaded"
		fi
	else
		warn "pfctl not available"
	fi
}
