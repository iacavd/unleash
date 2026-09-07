# shellcheck shell=bash

PERSIST_SENTINEL=".unleash-persist-installed"
PERSIST_LABEL="com.unleash.heal"

heal_suppress() {
	local data_mount="$1"
	[ -z "$data_mount" ] && data_mount=""
	DATA_ROOT="$data_mount"

	step "Checking current MDM suppression state..."
	local needs_heal=false

	probe_dep
	if [ "$RESULT_STATUS" = "fail" ]; then
		warn "${RESULT_MSG:-DEP markers dirty}"
		needs_heal=true
	fi
	probe_hosts
	if [ "$RESULT_STATUS" = "fail" ]; then
		warn "${RESULT_MSG:-hosts sinkhole missing}"
		needs_heal=true
	fi
	probe_dns
	if [ "$RESULT_STATUS" = "fail" ]; then
		warn "${RESULT_MSG:-live DNS still Apple 17/8}"
		needs_heal=true
	fi
	probe_daemons
	if [ "$RESULT_STATUS" = "fail" ]; then
		warn "${RESULT_MSG:-launchd overrides missing}"
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
	local plist_path="${3-}"
	local sentinel="${4-}"
	local marker="${dir}/state/created_by_run"
	[ -f "$marker" ] || return 0
	[ "$(cat "$marker")" = "$run" ] || return 0
	rm -rf "$dir"
	# created=1 only: drop plist/sentinel this run wrote, not a prior install.
	[ -n "$plist_path" ] && rm -f "$plist_path"
	[ -n "$sentinel" ] && rm -f "$sentinel"
}

_persist_fail() {
	local dir="$1"
	local run="$2"
	local msg="$3"
	local plist_path="${4-}"
	local sentinel="${5-}"
	_persist_cleanup_incomplete "$dir" "$run" "$plist_path" "$sentinel"
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

# Dirty if binary missing or plist is not live-path /Library/Unleash/unleash.
persist_probe_ok() {
	_persist_use_root "$@"
	local bin plist
	bin="$(unleash_root)/unleash"
	plist="${DATA_ROOT}/Library/LaunchDaemons/${PERSIST_LABEL}.plist"
	[ -f "$bin" ] || return 1
	[ -f "$plist" ] || return 1
	grep -F '<string>/Library/Unleash/unleash</string>' "$plist" >/dev/null || return 1
	if grep -E '/Volumes/' "$plist" >/dev/null 2>&1; then
		return 1
	fi
	return 0
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
		_persist_fail "$unleash_dir" "$run_id" "source binary missing: $src" "$plist_path" "$sentinel"
		return 1
	fi

	[ -d "$unleash_dir" ] || created=1

	if ! mkdir -p "$unleash_dir/lib" "$unleash_dir/data" "$unleash_dir/logs" "$unleash_dir/state" "$plist_dir"; then
		_persist_fail "$unleash_dir" "$run_id" "cannot create $unleash_dir" "$plist_path" "$sentinel"
		return 1
	fi

	if [ "$created" = 1 ]; then
		if ! printf '%s\n' "$run_id" > "$unleash_dir/state/created_by_run"; then
			_persist_fail "$unleash_dir" "$run_id" "cannot write created_by_run marker" "$plist_path" "$sentinel"
			return 1
		fi
	fi

	if [ ! -w "$unleash_dir" ] || [ ! -w "$plist_dir" ]; then
		_persist_fail "$unleash_dir" "$run_id" "not writable: $unleash_dir" "$plist_path" "$sentinel"
		return 1
	fi

	if [ "$script_dir" != "$unleash_dir" ]; then
		if ! cp "$src" "$unleash_dir/unleash"; then
			_persist_fail "$unleash_dir" "$run_id" "cannot copy unleash binary" "$plist_path" "$sentinel"
			return 1
		fi
		local lib copied_lib=0
		for lib in "$script_dir/lib/"*.sh; do
			[ -f "$lib" ] || continue
			if ! cp "$lib" "$unleash_dir/lib/"; then
				_persist_fail "$unleash_dir" "$run_id" "cannot copy $lib" "$plist_path" "$sentinel"
				return 1
			fi
			copied_lib=1
		done
		if [ "$copied_lib" -eq 0 ]; then
			_persist_fail "$unleash_dir" "$run_id" "no lib/*.sh to copy" "$plist_path" "$sentinel"
			return 1
		fi
		local tsv
		for tsv in mdm-ips.tsv mdm-agents.tsv; do
			if [ -f "$script_dir/data/$tsv" ]; then
				if ! cp "$script_dir/data/$tsv" "$unleash_dir/data/"; then
					_persist_fail "$unleash_dir" "$run_id" "cannot copy data/$tsv" "$plist_path" "$sentinel"
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
		_persist_fail "$unleash_dir" "$run_id" "cannot write plist $plist_path" "$plist_path" "$sentinel"
		return 1
	fi

	if ! _persist_chmod_tree "$unleash_dir" "$plist_path"; then
		_persist_fail "$unleash_dir" "$run_id" "chmod/chown failed" "$plist_path" "$sentinel"
		return 1
	fi

	local sha
	sha=$(${SHASUM:-/usr/bin/shasum} -a 256 "$unleash_dir/unleash" | awk '{print $1}')
	if ! {
		printf 'installed=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
		printf 'sha256=%s\n' "$sha"
	} > "$sentinel"; then
		_persist_fail "$unleash_dir" "$run_id" "cannot write sentinel" "$plist_path" "$sentinel"
		return 1
	fi

	if _persist_is_live_os; then
		local launchctl="${LAUNCHCTL:-/bin/launchctl}"
		local loaded=0
		local lc_err=""
		if [ -x "$launchctl" ]; then
			# bootout of a missing job is expected; bootstrap/load must succeed.
			"$launchctl" bootout system/com.unleash.heal >/dev/null 2>&1 || \
				"$launchctl" unload "$plist_path" >/dev/null 2>&1 || true
			lc_err=$("$launchctl" bootstrap system "$plist_path" 2>&1) && loaded=1 || true
			if [ "$loaded" -eq 0 ]; then
				lc_err=$("$launchctl" load "$plist_path" 2>&1) && loaded=1 || true
			fi
			"$launchctl" bootout system/com.unleash.monitor >/dev/null 2>&1 || \
				"$launchctl" unload "$monitor_plist" >/dev/null 2>&1 || true
		else
			lc_err="launchctl not available"
		fi
		rm -f "$monitor_plist"
		if [ "$loaded" -eq 0 ]; then
			# Files stay so launchd can pick the plist up at next boot; this run is not ok.
			result_fail E_LAUNCHCTL persist launchctl "launchctl bootstrap/load failed: ${lc_err}"
			return 1
		fi
	else
		rm -f "$monitor_plist"
	fi

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

# --- Probe table (heal --unattended verify + status --json). Never pkill. ---

PROBE_LINES="${PROBE_LINES:-}"

_probe_is_live_os() {
	if type is_recovery >/dev/null 2>&1 && is_recovery; then
		return 1
	fi
	[ -z "${DATA_ROOT:-}" ] || [ "$DATA_ROOT" = "/" ]
}

_probe_daemon_labels() {
	printf '%s\n' \
		com.apple.ManagedClient \
		com.apple.ManagedClient.enroll \
		com.apple.ManagedClient.cloudConfiguration \
		com.apple.ManagedClientAgent \
		com.apple.ManagedClientAgent.agent \
		com.apple.mdmclient \
		com.apple.mdmclient.daemon \
		com.apple.mdmclient.daemon.runatboot \
		com.apple.mdmclient.agent \
		com.apple.activationd
}

_mdm_agents_tsv() {
	if [ -n "${SCRIPT_DIR:-}" ] && [ -f "$SCRIPT_DIR/data/mdm-agents.tsv" ]; then
		printf '%s\n' "$SCRIPT_DIR/data/mdm-agents.tsv"
		return 0
	fi
	local root=""
	if type unleash_root >/dev/null 2>&1; then
		root=$(unleash_root)
	else
		root="${DATA_ROOT-}/Library/Unleash"
	fi
	if [ -f "$root/data/mdm-agents.tsv" ]; then
		printf '%s\n' "$root/data/mdm-agents.tsv"
		return 0
	fi
	return 1
}

_probe_cloudconfig_org() {
	local f="$1"
	local org=""
	if [ ! -f "$f" ]; then
		printf ''
		return 0
	fi
	if command -v plutil >/dev/null 2>&1; then
		org=$(plutil -convert xml1 -o - "$f" 2>/dev/null \
			| grep -iA1 OrganizationName | tail -1 | sed -E 's/.*<string>(.*)<\/string>.*/\1/' || true)
	else
		org=$(grep -A1 -i OrganizationName "$f" 2>/dev/null | tail -1 \
			| sed -E 's/.*<string>(.*)<\/string>.*/\1/' || true)
	fi
	case "$org" in
		*"<"*) org="" ;;
	esac
	printf '%s' "$org"
}

_probe_cloudconfig_fetch_error() {
	local f="$1"
	[ -f "$f" ] || return 1
	if command -v plutil >/dev/null 2>&1; then
		plutil -p "$f" 2>/dev/null | grep -q "CloudConfigFetchError" && return 0
	fi
	grep -q "CloudConfigFetchError" "$f" 2>/dev/null
}

# 17.0.0.0/8 except the sinkhole 0.0.0.0 (spec: fail iff in 17/8 AND not 0.0.0.0).
_probe_ipv4_apple_17() {
	local ip="$1"
	[ "$ip" = "0.0.0.0" ] && return 1
	case "$ip" in
		17.*) return 0 ;;
	esac
	return 1
}

_probe_hosts_domain() {
	local hosts="$1"
	local domain="$2"
	local esc
	esc=$(printf '%s' "$domain" | sed 's/\./\\./g')
	grep -Eq "^[[:space:]]*(0\\.0\\.0\\.0|::)[[:space:]]+${esc}([[:space:]]|$)" "$hosts" 2>/dev/null
}

_probe_exists_glob() {
	local pattern="$1"
	local dir base
	dir=$(dirname "$pattern")
	base=$(basename "$pattern")
	[ -d "$dir" ] || return 1
	case "$base" in
		*[\*\?]*)
			# glob only the basename so spaces in dirname stay intact
			for f in "$dir"/$base; do
				[ -e "$f" ] && return 0
			done
			return 1
			;;
		*)
			[ -e "$dir/$base" ]
			;;
	esac
}

_probe_record() {
	PROBE_LINES="${PROBE_LINES}${1}"$'\t'"${2}"$'\t'"${3:-}"$'\n'
}

# Convert a fail into skip when the mutate step already recorded skip-class.
_probe_fail_is_skip_class() {
	local name="$1"
	case "$name" in
		dep)
			[ "${PIPELINE_DEGRADED:-0}" = 1 ] && return 0
			;;
		persist)
			case ",${PIPELINE_SKIP_REASONS:-}," in
				*,E_PERSIST_PATH,*) return 0 ;;
			esac
			;;
		pf)
			case ",${PIPELINE_SKIP_REASONS:-}," in
				*,E_PFCTL_FAIL,*|*,E_DNS_FAIL,*|*,S_PF_RECOVERY,*) return 0 ;;
			esac
			;;
	esac
	return 1
}

probe_dep() {
	local cfg="${DATA_ROOT}/private/var/db/ConfigurationProfiles/Settings"
	local found="$cfg/.cloudConfigRecordFound"
	local notfound="$cfg/.cloudConfigRecordNotFound"
	local org=""

	if [ ! -f "$notfound" ]; then
		result_fail E_VERIFY_FAIL heal dep "DEP bypass sentinel missing at $cfg. Enrollment may be inactive, but a wipe can re-lock. Next: boot Recovery and run ./unleash apply --unattended"
		return 0
	fi
	if [ ! -f "$found" ]; then
		result_ok heal dep "DEP markers clean"
		return 0
	fi
	org=$(_probe_cloudconfig_org "$found")
	if [ -n "$org" ]; then
		result_fail E_VERIFY_FAIL heal dep "DEP OrganizationName still present: $org"
		return 0
	fi
	if _probe_cloudconfig_fetch_error "$found"; then
		result_ok heal dep "DEP CloudConfigFetchError only"
		return 0
	fi
	result_fail E_VERIFY_FAIL heal dep ".cloudConfigRecordFound present without CloudConfigFetchError"
	return 0
}

probe_hosts() {
	local hosts="${DATA_ROOT}/private/etc/hosts"
	local d
	if [ ! -f "$hosts" ]; then
		result_fail E_VERIFY_FAIL heal hosts "hosts file missing: $hosts"
		return 0
	fi
	for d in iprofiles.apple.com deviceenrollment.apple.com mdmenrollment.apple.com; do
		if ! _probe_hosts_domain "$hosts" "$d"; then
			result_fail E_VERIFY_FAIL heal hosts "$d not mapped to 0.0.0.0/:: in $hosts"
			return 0
		fi
	done
	result_ok heal hosts "MDM domains sinkholed in Data-volume hosts"
	return 0
}

probe_dns() {
	local dsc="${DSCACHEUTIL:-/usr/bin/dscacheutil}"
	local out="" key val ip

	if ! _probe_is_live_os; then
		result_skip S_NO_DSCACHEUTIL heal dns "live DNS skipped (Recovery or fixture)"
		return 0
	fi
	if [ ! -x "$dsc" ]; then
		result_skip S_NO_DSCACHEUTIL heal dns "dscacheutil not available"
		return 0
	fi
	out=$("$dsc" -q host -a name iprofiles.apple.com 2>/dev/null || true)
	while IFS= read -r line || [ -n "$line" ]; do
		key="${line%%:*}"
		val="${line#*:}"
		val="${val#"${val%%[![:space:]]*}"}"
		[ "$key" = "ip_address" ] || continue
		ip="$val"
		if _probe_ipv4_apple_17 "$ip"; then
			result_fail E_VERIFY_FAIL heal dns "iprofiles.apple.com resolves to Apple 17/8 $ip"
			return 0
		fi
	done <<EOF
$out
EOF
	result_ok heal dns "live DNS not Apple 17/8"
	return 0
}

probe_daemons() {
	local ldp="${DATA_ROOT}/private/var/db/com.apple.xpc.launchd/disabled.plist"
	local pb="${PLISTBUDDY:-/usr/libexec/PlistBuddy}"
	local label printed missing=0

	if [ ! -f "$ldp" ]; then
		result_fail E_VERIFY_FAIL heal daemons "disabled.plist missing: $ldp"
		return 0
	fi
	if [ ! -x "$pb" ] && [ -x /usr/libexec/PlistBuddy ]; then
		pb=/usr/libexec/PlistBuddy
	fi
	if [ ! -x "$pb" ]; then
		result_fail E_VERIFY_FAIL heal daemons "PlistBuddy not available"
		return 0
	fi
	while IFS= read -r label || [ -n "$label" ]; do
		[ -n "$label" ] || continue
		printed=$("$pb" -c "Print :$label" "$ldp" 2>/dev/null || true)
		if ! printf '%s\n' "$printed" | grep -q "true"; then
			missing=$((missing + 1))
		fi
	done <<EOF
$(_probe_daemon_labels)
EOF
	if [ "$missing" -gt 0 ]; then
		result_fail E_VERIFY_FAIL heal daemons "$missing enrollment label(s) not Print true"
		return 0
	fi
	result_ok heal daemons "10 launchd overrides Print true"
	return 0
}

probe_persist() {
	local bin plist
	if persist_probe_ok; then
		result_ok heal persist "binary and plist live-path"
		return 0
	fi
	_persist_use_root
	bin="$(unleash_root)/unleash"
	plist="${DATA_ROOT}/Library/LaunchDaemons/${PERSIST_LABEL}.plist"
	# Status/audit: not installed yet is skip, not a failed apply.
	if [ "${UNLEASH_PROBE_STATUS:-0}" = 1 ] && [ ! -f "$bin" ] && [ ! -f "$plist" ]; then
		result_skip S_NOT_INSTALLED heal persist "persist not installed. Next: sudo ./unleash persist"
		return 0
	fi
	result_fail E_VERIFY_FAIL heal persist "persist binary missing or plist not live-path. Next: sudo ./unleash persist"
	return 0
}

probe_pf() {
	local anchor="${DATA_ROOT}/private/etc/pf.anchors/com.unleash/mdm"
	local pfctl="${PFCTL:-/sbin/pfctl}"
	local rules=""

	if [ "${UNLEASH_FIREWALL_MODE:-selective}" = "off" ]; then
		result_skip S_ALREADY_OK heal pf "firewall-mode=off"
		return 0
	fi
	if [ ! -s "$anchor" ]; then
		if [ "${UNLEASH_PROBE_STATUS:-0}" = 1 ]; then
			result_skip S_NOT_INSTALLED heal pf "pf MDM anchor not installed. Next: sudo ./unleash firewall"
			return 0
		fi
		result_fail E_VERIFY_FAIL heal pf "pf anchor missing or empty: $anchor. Next: sudo ./unleash firewall"
		return 0
	fi
	if ! _probe_is_live_os; then
		# Recovery: files written, do not pfctl -f the target conf.
		result_skip S_PF_RECOVERY heal pf "anchor present; kernel load skipped"
		return 0
	fi
	if [ ! -x "$pfctl" ]; then
		result_fail E_VERIFY_FAIL heal pf "pfctl not available"
		return 0
	fi
	rules=$("$pfctl" -a com.unleash/mdm -s rules 2>/dev/null || true)
	if ! printf '%s\n' "$rules" | grep -q "block"; then
		result_fail E_VERIFY_FAIL heal pf "pfctl com.unleash/mdm rules lack block"
		return 0
	fi
	result_ok heal pf "anchor loaded with block"
	return 0
}

probe_processes() {
	local profiles="${PROFILES:-/usr/sbin/profiles}"
	local tsv="" id pat bins glob tok rest enroll=""
	local root="${DATA_ROOT:-}"

	if ! _probe_is_live_os; then
		result_skip S_ALREADY_OK heal processes "process probe is live-OS only"
		return 0
	fi

	tsv=$(_mdm_agents_tsv) || tsv=""
	if [ -z "$tsv" ] || [ ! -f "$tsv" ]; then
		result_fail E_VERIFY_FAIL heal processes "mdm-agents.tsv missing on live OS"
		return 0
	fi
	while IFS=$'\t' read -r id pat bins glob || [ -n "$id" ]; do
		case "$id" in
			''|\#*) continue ;;
		esac
		[ -n "$pat" ] || continue
		if command -v ps >/dev/null 2>&1; then
			if ps aux 2>/dev/null | grep -i "$pat" | grep -v grep | grep -v unleash | grep -q .; then
				result_fail E_VERIFY_FAIL heal processes "third-party agent running: $id"
				return 0
			fi
		fi
		rest="$bins"
		while [ -n "$rest" ]; do
			case "$rest" in
				*'|'*) tok="${rest%%|*}"; rest="${rest#*|}" ;;
				*) tok="$rest"; rest="" ;;
			esac
			[ -n "$tok" ] || continue
			if _probe_exists_glob "${root}${tok}"; then
				result_fail E_VERIFY_FAIL heal processes "third-party binary present: $tok"
				return 0
			fi
		done
		if [ -n "$glob" ] && _probe_exists_glob "${root}${glob}"; then
			result_fail E_VERIFY_FAIL heal processes "third-party launchd present: $glob"
			return 0
		fi
	done < "$tsv"

	if [ ! -x "$profiles" ]; then
		result_skip S_NO_PROFILES_CMD heal processes "profiles command missing"
		return 0
	fi
	enroll=$("$profiles" status -type enrollment 2>/dev/null || true)
	if printf '%s\n' "$enroll" | grep -qiE '(Enrolled via DEP|MDM enrollment):[[:space:]]*Yes'; then
		if command -v ps >/dev/null 2>&1; then
			if ps aux 2>/dev/null | grep -iE '(ManagedClient\.app|/mdmclient|com\.apple\.ManagedClient)' | grep -qv grep; then
				result_fail E_VERIFY_FAIL heal processes "Apple mdmclient running while enrollment Yes"
				return 0
			fi
		fi
	fi
	result_ok heal processes "no third-party agents; Apple helpers idle"
	return 0
}

# Always return 0 (D20). RESULT_STATUS=fail if a required probe failed.
run_probes() {
	PROBE_LINES=""
	RESULT_STATUS=ok
	RESULT_REASON=""
	RESULT_MSG=""
	local failed=0
	local fail_reason=""
	local fail_msg=""
	local name fn rec_status rec_reason

	for name in dep hosts dns daemons persist pf processes; do
		fn="probe_${name}"
		RESULT_STATUS=ok
		RESULT_REASON=""
		RESULT_MSG=""
		"$fn"
		rec_status="$RESULT_STATUS"
		rec_reason="${RESULT_REASON:-}"
		if [ "$rec_status" = "fail" ] && _probe_fail_is_skip_class "$name"; then
			rec_status=skip
			[ -n "$rec_reason" ] || rec_reason=S_ALREADY_OK
		fi
		case "$rec_status" in
			ok)
				_probe_record "$name" ok ""
				;;
			skip)
				_probe_record "$name" skip "$rec_reason"
				;;
			fail)
				_probe_record "$name" fail "${rec_reason:-E_VERIFY_FAIL}"
				failed=1
				fail_reason="${rec_reason:-E_VERIFY_FAIL}"
				fail_msg="${RESULT_MSG:-probe $name failed}"
				;;
		esac
	done

	if [ "$failed" -eq 1 ]; then
		result_fail "${fail_reason:-E_VERIFY_FAIL}" heal probes "$fail_msg"
		return 0
	fi
	result_ok heal probes "required probes passed"
	probes_write_last_good || true
	return 0
}

# Clean pass only. Never replace last-good with a dirty snapshot.
# Always return 0: last-good is best-effort and must not fail status/heal probes.
probes_write_last_good() {
	[ "${RESULT_STATUS:-}" = "fail" ] && return 0
	local volume="${PIPELINE_VOLUME:-${DATA_ROOT:-}}"
	local name st reason
	local lg=()
	while IFS=$'\t' read -r name st reason || [ -n "$name" ]; do
		[ -n "$name" ] || continue
		if [ -n "$reason" ]; then
			lg[${#lg[@]}]="probe=${name} status=${st} reason=${reason}"
		else
			lg[${#lg[@]}]="probe=${name} status=${st}"
		fi
	done <<EOF
${PROBE_LINES}
EOF
	if type journal_last_good_write >/dev/null 2>&1; then
		journal_last_good_write "$volume" "${lg[@]}" || true
		return 0
	fi
	local dir dest tmp ts line
	if type unleash_root >/dev/null 2>&1; then
		dir="$(unleash_root)/state"
	else
		dir="${DATA_ROOT}/Library/Unleash/state"
	fi
	mkdir -p "$dir" || return 0
	dest="$dir/last-good"
	tmp="${dest}.tmp.$$"
	ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
	{
		printf 'ts=%s\n' "$ts"
		printf 'volume=%s\n' "$volume"
		for line in "${lg[@]}"; do
			printf '%s\n' "$line"
		done
	} > "$tmp" || { rm -f "$tmp"; return 0; }
	mv "$tmp" "$dest" || { rm -f "$tmp"; return 0; }
	return 0
}

status_emit_json() {
	local exit_code="${1:-0}"
	local volume="${2:-${DATA_ROOT:-}}"
	local next="${3:-${PIPELINE_NEXT:-}}"
	local ok_json="true"
	local probes_json="" first=1
	local name st reason
	local reason_e msg_e next_e volume_e name_e st_e rs_e

	if [ "$RESULT_STATUS" = "fail" ]; then
		ok_json="false"
	fi
	while IFS=$'\t' read -r name st reason || [ -n "$name" ]; do
		[ -n "$name" ] || continue
		[ "$first" = 1 ] || probes_json="${probes_json},"
		first=0
		name_e=$(json_escape "$name")
		st_e=$(json_escape "$st")
		rs_e=$(json_escape "$reason")
		probes_json="${probes_json}{\"name\":\"${name_e}\",\"status\":\"${st_e}\",\"reason\":\"${rs_e}\"}"
	done <<EOF
${PROBE_LINES}
EOF
	reason_e=$(json_escape "${RESULT_REASON:-}")
	msg_e=$(json_escape "${RESULT_MSG:-}")
	next_e=$(json_escape "$next")
	volume_e=$(json_escape "$volume")
	printf '{"ok":%s,"exit":%s,"reason":"%s","message":"%s","next":"%s","volume":"%s","probes":[%s]}\n' \
		"$ok_json" "$exit_code" "$reason_e" "$msg_e" "$next_e" "$volume_e" "$probes_json"
}

