
PERSIST_SENTINEL=".unleash-persist-installed"

heal_suppress() {
	local data_mount="$1"
	[ -z "$data_mount" ] && data_mount=""

	step "Checking current MDM suppression state..."
	local cfg="${data_mount}/private/var/db/ConfigurationProfiles/Settings"
	local hosts="${data_mount}/private/etc/hosts"
	local ldp="${data_mount}/private/var/db/com.apple.xpc.launchd/disabled.plist"

	local needs_heal=false

	# 1. DEP Activation Record Check
	if [ -f "$cfg/.cloudConfigRecordFound" ] || [ -f "$cfg/.cloudConfigHasActivationRecord" ]; then
		local org="" mdm_host=""
		if [ -f "$cfg/.cloudConfigRecordFound" ]; then
			org=$(plutil -convert xml1 -o - "$cfg/.cloudConfigRecordFound" 2>/dev/null \
				| grep -iA1 OrganizationName | tail -1 | sed -E 's/.*<string>(.*)<\/string>.*/\1/' || true)
			mdm_host=$(plutil -convert xml1 -o - "$cfg/.cloudConfigRecordFound" 2>/dev/null \
				| grep -ioE 'https?://[a-z0-9._-]+' | sed -E 's#https?://##' \
				| sort -u | grep -viE '(^|\.)apple\.com$' | head -1 || true)
		fi
		if [ -n "$org" ] || [ -n "$mdm_host" ] || ! plutil -p "$cfg/.cloudConfigRecordFound" 2>/dev/null | grep -q "CloudConfigFetchError"; then
			warn "DEP activation record found at $cfg"
			[ -n "$org" ] && warn "  Organization: $org"
			[ -n "$mdm_host" ] && warn "  MDM Server:   $mdm_host"
			needs_heal=true
		else
			info "DEP cloud check blocked (CloudConfigFetchError logged — domain block active)"
		fi
	else
		info "DEP activation record markers are clean"
	fi

	# 2. Hosts Block & Live DNS Resolution Check
	local hosts_blocked=false
	if [ -f "$hosts" ] && grep -q "iprofiles.apple.com" "$hosts" 2>/dev/null; then
		hosts_blocked=true
	fi

	# Perform actual local DNS resolution check if on booted system
	local live_resolved=false
	if [ -z "$data_mount" ] || [ "$data_mount" = "/" ]; then
		local resolved_ip=""
		resolved_ip=$(dscacheutil -q host -a name iprofiles.apple.com 2>/dev/null | awk '/ip_address:/{print $2; exit}' || true)
		if [ -z "$resolved_ip" ] && command -v host >/dev/null 2>&1; then
			resolved_ip=$(host -W 1 iprofiles.apple.com 2>/dev/null | awk '/has address/{print $NF; exit}' || true)
		fi

		if [ -n "$resolved_ip" ] && [[ "$resolved_ip" != "0.0.0.0" && "$resolved_ip" != "127.0.0.1" ]]; then
			live_resolved=true
		fi
	fi

	if [ "$hosts_blocked" = true ] && [ "$live_resolved" = false ]; then
		info "Domain block active in $hosts (and resolving to sinkhole 0.0.0.0)"
	elif [ "$hosts_blocked" = true ] && [ "$live_resolved" = true ]; then
		warn "Hosts contains block rules, but live DNS still resolves iprofiles.apple.com -> $resolved_ip (DNS-over-HTTPS or mDNSResponder cache active)"
		needs_heal=true
	elif [ "$hosts_blocked" = false ]; then
		warn "Domain block missing in $hosts (Apple MDM servers not redirected to 0.0.0.0)"
		[ "$live_resolved" = true ] && warn "  Live check: iprofiles.apple.com currently resolves to active Apple IP ($resolved_ip)"
		needs_heal=true
	fi

	# 3. LaunchDaemons Disabled Overrides Check
	local all_daemons=(
		"com.apple.ManagedClient"
		"com.apple.ManagedClient.enroll"
		"com.apple.ManagedClient.cloudConfiguration"
		"com.apple.ManagedClientAgent"
		"com.apple.ManagedClientAgent.agent"
		"com.apple.mdmclient"
		"com.apple.mdmclient.daemon"
		"com.apple.mdmclient.daemon.runatboot"
		"com.apple.mdmclient.agent"
		"com.apple.activationd"
	)
	if [ -f "$ldp" ]; then
		local missing_daemons=()
		for label in "${all_daemons[@]}"; do
			if ! $PB -c "Print :$label" "$ldp" 2>/dev/null | grep -q "true"; then
				missing_daemons+=("$label")
			fi
		done
		if [ "${#missing_daemons[@]}" -gt 0 ]; then
			warn "${#missing_daemons[@]} enrollment daemon(s) not disabled in $ldp:"
			for d in "${missing_daemons[@]}"; do
				warn "  - $d (enabled)"
			done
			needs_heal=true
		else
			info "All ${#all_daemons[@]} enrollment daemons disabled"
		fi
	else
		warn "Launchd disabled overrides plist missing ($ldp)"
		needs_heal=true
	fi

	if [ "$needs_heal" = false ]; then
		# Ensure PF firewall is active if configured
		if [ -z "$data_mount" ] || [ "$data_mount" = "/" ]; then
			if [ -f "/etc/pf.conf" ] && grep -q "com.unleash" "/etc/pf.conf" 2>/dev/null; then
				if command -v pfctl &>/dev/null; then
					pfctl -e -f /etc/pf.conf 2>/dev/null || true
				fi
			fi
		fi
		success "MDM suppression intact — no action needed."
		return 0
	fi

	echo ""
	info "Applying remediation to restore MDM suppression..."
	suppress_enrollment "$data_mount"

	# Ensure PF firewall is re-enabled if configured
	if [ -z "$data_mount" ] || [ "$data_mount" = "/" ]; then
		if [ -f "/etc/pf.conf" ] && grep -q "com.unleash" "/etc/pf.conf" 2>/dev/null; then
			if command -v pfctl &>/dev/null; then
				pfctl -e -f /etc/pf.conf 2>/dev/null || true
			fi
		fi
	fi
	success "MDM suppression restored successfully."
}

_persist_mount_root() {
	local dm="$1"
	if [ -z "$dm" ] || [ ! -d "$dm/Library" ]; then
		echo ""
	else
		echo "$dm"
	fi
}

is_persist_installed() {
	local data_mount="${1:-}"
	local root
	root="$(_persist_mount_root "$data_mount")"
	local plist_path="${root}/Library/LaunchDaemons/com.unleash.heal.plist"
	local sentinel="${root}/Library/LaunchDaemons/${PERSIST_SENTINEL}"
	[ -f "$plist_path" ] && [ -f "$sentinel" ]
}

install_persist_launchdaemon() {
	local data_mount="$1"
	local root
	root="$(_persist_mount_root "$data_mount")"

	local script_dir="${SCRIPT_DIR:-$(cd "$(dirname "$0")" && pwd)}"
	local unleash_src="$script_dir/unleash"

	step "Installing LaunchDaemon for boot-time persistence..."

	local plist_dir="${root}/Library/LaunchDaemons"
	local plist_path="${plist_dir}/com.unleash.heal.plist"
	local sentinel="${plist_dir}/${PERSIST_SENTINEL}"

	mkdir -p "$plist_dir" 2>/dev/null || true

	if [ ! -w "$plist_dir" ]; then
		warn "Cannot write to $plist_dir (requires root privileges)."
		return 0
	fi

	cat > "$plist_path" <<- PLIST
	<?xml version="1.0" encoding="UTF-8"?>
	<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
	<plist version="1.0">
	<dict>
		<key>Label</key>
		<string>com.unleash.heal</string>
		<key>ProgramArguments</key>
		<array>
			<string>/bin/bash</string>
			<string>-c</string>
			<string>${unleash_src} heal</string>
		</array>
		<key>RunAtLoad</key>
		<true/>
		<key>StartInterval</key>
		<integer>86400</integer>
		<key>Nice</key>
		<integer>1</integer>
		<key>KeepAlive</key>
		<false/>
		<key>StandardOutPath</key>
		<string>/var/log/unleash-heal.log</string>
		<key>StandardErrorPath</key>
		<string>/var/log/unleash-heal.err</string>
	</dict>
	</plist>
	PLIST

	chmod 644 "$plist_path"

	# Write sentinel file for clean state tracking
	echo "installed=$(date -u '+%Y-%m-%dT%H:%M:%SZ')" > "$sentinel"
	echo "source=$unleash_src" >> "$sentinel"

	success "LaunchDaemon written to $plist_path"

	step "Loading LaunchDaemon..."
	if command -v launchctl &>/dev/null; then
		launchctl load "$plist_path" 2>/dev/null \
			&& success "LaunchDaemon loaded (will run on next boot)" \
			|| info "LaunchDaemon will load on next boot"
	else
		info "launchctl not available (expected in Recovery) — will load on next boot"
	fi
}

remove_persist_launchdaemon() {
	local data_mount="$1"
	local root
	root="$(_persist_mount_root "$data_mount")"
	local plist_path="${root}/Library/LaunchDaemons/com.unleash.heal.plist"
	local sentinel="${root}/Library/LaunchDaemons/${PERSIST_SENTINEL}"

	if [ -f "$plist_path" ]; then
		step "Removing Unleash LaunchDaemon..."
		if command -v launchctl &>/dev/null; then
			launchctl unload "$plist_path" 2>/dev/null || true
		fi
		rm -f "$plist_path"
		rm -f "$sentinel"
		success "LaunchDaemon removed"
	else
		info "No Unleash LaunchDaemon installed"
	fi
}
