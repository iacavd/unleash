# shellcheck shell=bash

PERSIST_SENTINEL=".unleash-persist-installed"
PERSIST_LABEL="com.unleash.heal"

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

# Optional $1 is DATA_ROOT for legacy callers; cmd_persist sets DATA_ROOT first.
_persist_use_root() {
	if [ $# -ge 1 ]; then
		DATA_ROOT="$1"
	fi
}

_persist_run_id() {
	if [ -n "${JOURNAL_RUN:-}" ]; then
		printf '%s\n' "$JOURNAL_RUN"
	elif [ -n "${RUN_ID:-}" ]; then
		printf '%s\n' "$RUN_ID"
	else
		printf '%s-%s\n' "$(date -u +%Y%m%dT%H%M%SZ)" "$$"
	fi
}

_persist_cleanup_incomplete() {
	local dir="$1"
	local run="$2"
	local marker="${dir}/state/created_by_run"
	[ -f "$marker" ] || return 0
	[ "$(cat "$marker")" = "$run" ] || return 0
	rm -rf "$dir"
}

_persist_fail() {
	local dir="$1"
	local run="$2"
	local msg="$3"
	_persist_cleanup_incomplete "$dir" "$run"
	result_fail E_PERSIST_PATH persist copy "$msg"
	return 1
}

# launchctl only against the live system, never a Recovery/test DATA_ROOT.
_persist_is_live_os() {
	if type is_recovery >/dev/null 2>&1 && is_recovery; then
		return 1
	fi
	[ -z "${DATA_ROOT:-}" ] || [ "$DATA_ROOT" = "/" ]
}

_persist_chmod_tree() {
	local unleash_dir="$1"
	local plist_path="$2"
	local f
	chmod 755 "$unleash_dir" "$unleash_dir/lib" "$unleash_dir/data" || return 1
	chmod 700 "$unleash_dir/state" "$unleash_dir/logs" || return 1
	chmod 755 "$unleash_dir/unleash" || return 1
	for f in "$unleash_dir/lib/"*.sh; do
		[ -f "$f" ] || continue
		chmod 755 "$f" || return 1
	done
	for f in "$unleash_dir/state/"*; do
		[ -f "$f" ] || continue
		chmod 600 "$f" || return 1
	done
	for f in "$unleash_dir/logs/"*; do
		[ -f "$f" ] || continue
		chmod 600 "$f" || return 1
	done
	chmod 644 "$plist_path" || return 1
	if [ "${EUID:-$(id -u)}" -eq 0 ]; then
		chown -R root:wheel "$unleash_dir" || return 1
		chown root:wheel "$plist_path" || return 1
	fi
	return 0
}

is_persist_installed() {
	_persist_use_root "$@"
	local plist_path="${DATA_ROOT}/Library/LaunchDaemons/${PERSIST_LABEL}.plist"
	local sentinel="${DATA_ROOT}/Library/LaunchDaemons/${PERSIST_SENTINEL}"
	[ -f "$plist_path" ] && [ -f "$sentinel" ]
}

persist_copy() {
	_persist_use_root "$@"

	local script_dir="${SCRIPT_DIR:-}"
	if [ -z "$script_dir" ]; then
		script_dir="$(cd "$(dirname "$0")" && pwd)"
	fi

	local unleash_dir
	unleash_dir=$(unleash_root)
	local run_id
	run_id=$(_persist_run_id)
	local created=0
	local plist_dir="${DATA_ROOT}/Library/LaunchDaemons"
	local plist_path="${plist_dir}/${PERSIST_LABEL}.plist"
	local sentinel="${plist_dir}/${PERSIST_SENTINEL}"
	local src="${script_dir}/unleash"
	local monitor_plist="${plist_dir}/com.unleash.monitor.plist"

	step "Installing LaunchDaemon for boot-time persistence..."

	if [ ! -f "$src" ]; then
		_persist_fail "$unleash_dir" "$run_id" "source binary missing: $src"
		return 1
	fi

	[ -d "$unleash_dir" ] || created=1

	if ! mkdir -p "$unleash_dir/lib" "$unleash_dir/data" "$unleash_dir/logs" "$unleash_dir/state" "$plist_dir"; then
		_persist_fail "$unleash_dir" "$run_id" "cannot create $unleash_dir"
		return 1
	fi

	if [ "$created" = 1 ]; then
		if ! printf '%s\n' "$run_id" > "$unleash_dir/state/created_by_run"; then
			_persist_fail "$unleash_dir" "$run_id" "cannot write created_by_run marker"
			return 1
		fi
	fi

	if [ ! -w "$unleash_dir" ] || [ ! -w "$plist_dir" ]; then
		_persist_fail "$unleash_dir" "$run_id" "not writable: $unleash_dir"
		return 1
	fi

	if [ "$script_dir" != "$unleash_dir" ]; then
		if ! cp "$src" "$unleash_dir/unleash"; then
			_persist_fail "$unleash_dir" "$run_id" "cannot copy unleash binary"
			return 1
		fi
		local lib copied_lib=0
		for lib in "$script_dir/lib/"*.sh; do
			[ -f "$lib" ] || continue
			if ! cp "$lib" "$unleash_dir/lib/"; then
				_persist_fail "$unleash_dir" "$run_id" "cannot copy $lib"
				return 1
			fi
			copied_lib=1
		done
		if [ "$copied_lib" -eq 0 ]; then
			_persist_fail "$unleash_dir" "$run_id" "no lib/*.sh to copy"
			return 1
		fi
		local tsv
		for tsv in mdm-ips.tsv mdm-agents.tsv; do
			if [ -f "$script_dir/data/$tsv" ]; then
				if ! cp "$script_dir/data/$tsv" "$unleash_dir/data/"; then
					_persist_fail "$unleash_dir" "$run_id" "cannot copy data/$tsv"
					return 1
				fi
			fi
		done
	fi

	# ProgramArguments are always live paths; Recovery writes the file under $DATA.
	if ! cat > "$plist_path" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>com.unleash.heal</string>
	<key>ProgramArguments</key>
	<array>
		<string>/Library/Unleash/unleash</string>
		<string>heal</string>
		<string>--unattended</string>
		<string>--log-file</string>
		<string>/Library/Unleash/logs/heal.log</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>StartInterval</key>
	<integer>300</integer>
	<key>Nice</key>
	<integer>1</integer>
	<key>KeepAlive</key>
	<false/>
	<key>StandardOutPath</key>
	<string>/Library/Unleash/logs/heal.out</string>
	<key>StandardErrorPath</key>
	<string>/Library/Unleash/logs/heal.err</string>
</dict>
</plist>
PLIST
	then
		_persist_fail "$unleash_dir" "$run_id" "cannot write plist $plist_path"
		return 1
	fi

	if ! _persist_chmod_tree "$unleash_dir" "$plist_path"; then
		_persist_fail "$unleash_dir" "$run_id" "chmod/chown failed"
		return 1
	fi

	local sha
	sha=$(${SHASUM:-/usr/bin/shasum} -a 256 "$unleash_dir/unleash" | awk '{print $1}')
	if ! {
		printf 'installed=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
		printf 'sha256=%s\n' "$sha"
	} > "$sentinel"; then
		_persist_fail "$unleash_dir" "$run_id" "cannot write sentinel"
		return 1
	fi

	if _persist_is_live_os; then
		local launchctl="${LAUNCHCTL:-/bin/launchctl}"
		if [ -x "$launchctl" ]; then
			"$launchctl" bootout system/com.unleash.heal >/dev/null 2>&1 || \
				"$launchctl" unload "$plist_path" >/dev/null 2>&1 || true
			"$launchctl" bootstrap system "$plist_path" >/dev/null 2>&1 || \
				"$launchctl" load "$plist_path" >/dev/null 2>&1 || true
			"$launchctl" bootout system/com.unleash.monitor >/dev/null 2>&1 || \
				"$launchctl" unload "$monitor_plist" >/dev/null 2>&1 || true
		fi
	fi
	rm -f "$monitor_plist"

	result_ok persist copy "LaunchDaemon written to $plist_path"
	return 0
}

install_persist_launchdaemon() {
	persist_copy "$@"
}

remove_persist_launchdaemon() {
	_persist_use_root "$@"
	local unleash_dir
	unleash_dir=$(unleash_root)
	local plist_dir="${DATA_ROOT}/Library/LaunchDaemons"
	local plist_path="${plist_dir}/${PERSIST_LABEL}.plist"
	local sentinel="${plist_dir}/${PERSIST_SENTINEL}"
	local monitor_plist="${plist_dir}/com.unleash.monitor.plist"

	if _persist_is_live_os; then
		local launchctl="${LAUNCHCTL:-/bin/launchctl}"
		if [ -x "$launchctl" ]; then
			"$launchctl" bootout system/com.unleash.heal >/dev/null 2>&1 || \
				"$launchctl" unload "$plist_path" >/dev/null 2>&1 || true
			"$launchctl" bootout system/com.unleash.monitor >/dev/null 2>&1 || \
				"$launchctl" unload "$monitor_plist" >/dev/null 2>&1 || true
		fi
	fi

	if [ -f "$plist_path" ] || [ -f "$sentinel" ]; then
		step "Removing Unleash LaunchDaemon..."
		rm -f "$plist_path" "$sentinel" "$monitor_plist"
		success "LaunchDaemon removed"
	else
		info "No Unleash LaunchDaemon installed"
		rm -f "$monitor_plist"
	fi

	if [ -d "$unleash_dir" ] && [ "$unleash_dir" != "${SCRIPT_DIR:-}" ]; then
		rm -rf "$unleash_dir"
	fi
}
