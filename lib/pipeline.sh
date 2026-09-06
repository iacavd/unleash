# shellcheck shell=bash
# WAL journal + lock. Values are percent-encoded so awk NF / first-= split stays safe.
# pipeline_run is the single mutator. Helpers always return 0 (D20).

JOURNAL_RUN="${JOURNAL_RUN:-}"
JOURNAL_DEGRADED="${JOURNAL_DEGRADED:-0}"

_state_dir() {
	printf '%s\n' "$(unleash_root)/state"
}

_journal_path() {
	printf '%s\n' "$(_state_dir)/journal"
}

_lock_dir() {
	printf '%s\n' "$(_state_dir)/lock.d"
}

# Spec kv file (pid= ts=). Mutex is lock.d via mkdir.
_lock_path() {
	printf '%s\n' "$(_state_dir)/lock"
}

# space=%20 %= %25 ==%3D newline=%0A quote=%22 slash=%2F tab=%09 CR=%0D.
_kv_encode() {
	local s="${1-}"
	local i=0
	local c
	local out=""
	local len=${#s}
	while [ "$i" -lt "$len" ]; do
		c="${s:i:1}"
		case "$c" in
			%) out="${out}%25" ;;
			' ') out="${out}%20" ;;
			=) out="${out}%3D" ;;
			$'\n') out="${out}%0A" ;;
			$'\t') out="${out}%09" ;;
			$'\r') out="${out}%0D" ;;
			'"') out="${out}%22" ;;
			/) out="${out}%2F" ;;
			*) out="${out}${c}" ;;
		esac
		i=$((i + 1))
	done
	printf '%s' "$out"
}

_kv_decode() {
	local s="${1-}"
	local i=0
	local c hex
	local out=""
	local len=${#s}
	local j
	while [ "$i" -lt "$len" ]; do
		c="${s:i:1}"
		if [ "$c" = "%" ] && [ $((i + 2)) -lt "$len" ]; then
			j=$((i + 1))
			hex="${s:j:2}"
			case "$hex" in
				20) out="${out} " ;;
				25) out="${out}%" ;;
				3D|3d) out="${out}=" ;;
				0A|0a) out="${out}"$'\n' ;;
				09) out="${out}"$'\t' ;;
				0D|0d) out="${out}"$'\r' ;;
				22) out="${out}\"" ;;
				2F|2f) out="${out}/" ;;
				*)
					out="${out}%"
					i=$((i + 1))
					continue
					;;
			esac
			i=$((i + 3))
			continue
		fi
		out="${out}${c}"
		i=$((i + 1))
	done
	printf '%s' "$out"
}

# First '=' splits key/value. Values never contain space after encode.
_kv_get() {
	local line="$1"
	local want="$2"
	local rest tok key val
	rest="$line"
	while [ -n "$rest" ]; do
		tok="${rest%% *}"
		if [ "$tok" = "$rest" ]; then
			rest=""
		else
			rest="${rest#* }"
		fi
		[ -n "$tok" ] || continue
		key="${tok%%=*}"
		val="${tok#*=}"
		if [ "$key" = "$want" ]; then
			_kv_decode "$val"
			return 0
		fi
	done
	return 0
}

_journal_new_run_id() {
	printf '%s-%04x' "$(date -u +%Y%m%dT%H%M%SZ)" $(( $$ & 0xffff ))
}

_journal_write() {
	local dir journal ts line tok
	dir="$(_state_dir)"
	mkdir -p "$dir" || return 1
	journal="$dir/journal"
	ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
	line="ts=$(_kv_encode "$ts") run=$(_kv_encode "${JOURNAL_RUN:-}")"
	for tok in "$@"; do
		line="${line} ${tok}"
	done
	printf '%s\n' "$line" >> "$journal" || return 1
}

journal_begin() {
	local cmd="${1:-apply}"
	local volume="${2:-}"
	JOURNAL_RUN=$(_journal_new_run_id)
	JOURNAL_DEGRADED=0
	_journal_write op=BEGIN "cmd=$(_kv_encode "$cmd")" "volume=$(_kv_encode "$volume")"
}

# WAL: status=start before mutate; status=ok|fail|skip after.
journal_step() {
	local name="${1:-}"
	local status="${2:-}"
	local reason="${3:-}"
	if [ -n "$reason" ]; then
		_journal_write op=STEP "name=$(_kv_encode "$name")" "status=$(_kv_encode "$status")" "reason=$(_kv_encode "$reason")"
	else
		_journal_write op=STEP "name=$(_kv_encode "$name")" "status=$(_kv_encode "$status")"
	fi
}

journal_snap() {
	local id="${1:-}"
	_journal_write op=SNAP "id=$(_kv_encode "$id")"
}

# WAL-close. Clears state/degraded only on success (no skip-class reasons this run).
# Degraded apply: journal_degraded reasons next; journal_commit — file stays for heal.
journal_commit() {
	_journal_write op=COMMIT
	if [ "${JOURNAL_DEGRADED:-0}" != 1 ]; then
		journal_degraded_clear
	fi
}

journal_rollback() {
	_journal_write op=ROLLBACK
}

journal_abort() {
	_journal_write op=ABORT
}

journal_degraded() {
	local reasons="${1:-}"
	local next="${2:-}"
	JOURNAL_DEGRADED=1
	_journal_write op=DEGRADED "reasons=$(_kv_encode "$reasons")"
	journal_degraded_write "$reasons" "$next"
}

# Print-only. Caller: JOURNAL_RUN=$(journal_resume_scan)
# Last op=BEGIN whose run= has no later COMMIT/ROLLBACK/ABORT. Empty if none.
journal_resume_scan() {
	local journal closed last line op run
	journal="$(_journal_path)"
	if [ ! -f "$journal" ]; then
		printf ''
		return 0
	fi
	closed=" "
	last=""
	while IFS= read -r line || [ -n "$line" ]; do
		[ -n "$line" ] || continue
		op=$(_kv_get "$line" op)
		run=$(_kv_get "$line" run)
		case "$op" in
			COMMIT|ROLLBACK|ABORT)
				[ -n "$run" ] && closed="${closed}${run} "
				;;
		esac
	done < "$journal"
	while IFS= read -r line || [ -n "$line" ]; do
		[ -n "$line" ] || continue
		op=$(_kv_get "$line" op)
		run=$(_kv_get "$line" run)
		[ "$op" = "BEGIN" ] || continue
		[ -n "$run" ] || continue
		case "$closed" in
			*" ${run} "*) ;;
			*) last="$run" ;;
		esac
	done < "$journal"
	printf '%s' "$last"
}

# Atomic replace on the same volume (write temp + mv).
journal_last_good_write() {
	local volume="${1:-}"
	shift
	local dir dest tmp ts line
	dir="$(_state_dir)"
	mkdir -p "$dir" || return 1
	dest="$dir/last-good"
	tmp="${dest}.tmp.$$"
	ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
	{
		printf 'ts=%s\n' "$(_kv_encode "$ts")"
		printf 'volume=%s\n' "$(_kv_encode "$volume")"
		for line in "$@"; do
			printf '%s\n' "$line"
		done
	} > "$tmp" || { rm -f "$tmp"; return 1; }
	mv "$tmp" "$dest"
}

journal_degraded_write() {
	local reasons="${1:-}"
	local next="${2:-}"
	local dir dest tmp ts
	dir="$(_state_dir)"
	mkdir -p "$dir" || return 1
	dest="$dir/degraded"
	tmp="${dest}.tmp.$$"
	ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
	{
		printf 'ts=%s\n' "$(_kv_encode "$ts")"
		printf 'run=%s\n' "$(_kv_encode "${JOURNAL_RUN:-}")"
		printf 'reasons=%s\n' "$(_kv_encode "$reasons")"
		printf 'next=%s\n' "$(_kv_encode "$next")"
	} > "$tmp" || { rm -f "$tmp"; return 1; }
	mv "$tmp" "$dest"
}

journal_degraded_clear() {
	rm -f "$(_state_dir)/degraded"
}

_lock_pid() {
	local lock="$1"
	local line
	[ -f "$lock" ] || return 0
	line=$(tr '\n' ' ' < "$lock")
	_kv_get "$line" pid
}

pipeline_lock_acquire() {
	local dir lockd lock pid ts
	dir="$(_state_dir)"
	mkdir -p "$dir" || {
		result_fail E_DISK_FULL pipeline lock "cannot create state dir $dir"
		return 1
	}
	lockd="$dir/lock.d"
	lock="$dir/lock"
	if [ -d "$lockd" ] || [ -f "$lock" ]; then
		pid=$(_lock_pid "$lock")
		case "$pid" in
			''|*[!0-9]*) ;;
			*)
				if kill -0 "$pid" 2>/dev/null; then
					result_fail E_LOCKED pipeline lock "heal/apply already running pid=$pid"
					return 1
				fi
				;;
		esac
		rm -rf "$lockd"
		rm -f "$lock"
	fi
	# mkdir without -p is the exclusive token. Dispatcher already installs EXIT release.
	if ! mkdir "$lockd"; then
		if [ -d "$lockd" ]; then
			result_fail E_LOCKED pipeline lock "heal/apply already running"
			return 1
		fi
		result_fail E_DISK_FULL pipeline lock "cannot create lock dir $lockd"
		return 1
	fi
	ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
	if ! printf 'pid=%s ts=%s\n' "$$" "$(_kv_encode "$ts")" > "$lock"; then
		rm -rf "$lockd"
		rm -f "$lock"
		result_fail E_DISK_FULL pipeline lock "cannot write lock"
		return 1
	fi
	return 0
}

pipeline_lock_release() {
	local lock lockd pid
	lock="$(_lock_path)"
	lockd="$(_lock_dir)"
	[ -f "$lock" ] || return 0
	pid=$(_lock_pid "$lock")
	[ "$pid" = "$$" ] || return 0
	rm -f "$lock"
	rm -rf "$lockd"
	return 0
}

# File-copy rollback only (hosts, DEP dir, disabled.plist, pf). No dscl/persist/launchctl undo.
pipeline_rollback_files() {
	local snap_id="$1"
	local data_mount="$2"
	local rc=0
	rollback_hosts "$snap_id" "$data_mount" || rc=1
	rollback_dep "$snap_id" "$data_mount" || rc=1
	rollback_plist "$snap_id" "$data_mount" || rc=1
	rollback_pf "$snap_id" "$data_mount" || rc=1
	return "$rc"
}

PIPELINE_DEGRADED="${PIPELINE_DEGRADED:-0}"
PIPELINE_SKIP_REASONS="${PIPELINE_SKIP_REASONS:-}"
PIPELINE_NEXT="${PIPELINE_NEXT:-}"
PIPELINE_VOLUME="${PIPELINE_VOLUME:-}"
PIPELINE_HAD_BEGIN="${PIPELINE_HAD_BEGIN:-0}"

_pipeline_is_dry_run() {
	[ "${UNLEASH_DRY_RUN:-0}" = 1 ] || [ "${DRY_RUN:-false}" = true ]
}

_pipeline_need_root() {
	if _pipeline_is_dry_run; then
		return 0
	fi
	if is_root; then
		return 0
	fi
	# Writable fixture trees (tests) are not the live Data volume.
	if [ -n "${UNLEASH_VOLUME:-}" ] && [ -d "${UNLEASH_VOLUME}" ]; then
		case "${UNLEASH_VOLUME}" in
			/|/Volumes/*|/System/*) ;;
			*)
				if [ -d "${UNLEASH_VOLUME}/private/var/db/dslocal/nodes/Default" ]; then
					return 0
				fi
				;;
		esac
	fi
	result_fail E_NOT_ROOT pipeline preflight "mutate requires root"
	return 1
}

_pipeline_preflight() {
	local du pb
	du="${DISKUTIL:-/usr/sbin/diskutil}"
	pb="${PLISTBUDDY:-/usr/libexec/PlistBuddy}"
	if [ ! -x "$du" ] && ! command -v diskutil >/dev/null 2>&1; then
		result_fail E_PREFLIGHT_TOOLS pipeline preflight "diskutil not available"
		return 1
	fi
	if [ ! -x "$pb" ] && [ ! -x /usr/libexec/PlistBuddy ]; then
		result_fail E_PREFLIGHT_TOOLS pipeline preflight "PlistBuddy not available"
		return 1
	fi

	if [ "${UNLEASH_UNATTENDED:-0}" = 1 ] && [ "${UNLEASH_CREATE_ADMIN:-0}" = 1 ]; then
		if ! require_create_admin_creds; then
			return 1
		fi
		if ! password_from_file "$UNLEASH_PASSWORD_FILE" >/dev/null; then
			return 1
		fi
	fi

	if ! _pipeline_need_root; then
		return 1
	fi
	return 0
}

_pipeline_fill_next() {
	case "${RESULT_REASON:-}" in
		E_INTENT_MISSING)
			PIPELINE_NEXT="create I_OWN_THIS_DEVICE next to unleash or run: unleash apply --unattended --i-own-this-device"
			;;
		E_CREDS_REQUIRED)
			PIPELINE_NEXT="unleash apply --unattended --create-admin --username NAME --password-file FILE"
			;;
		E_DEFAULT_PASSWORD)
			PIPELINE_NEXT="use a password other than 1234 (min 8) in --password-file"
			;;
		E_NOT_ROOT)
			PIPELINE_NEXT="sudo ./unleash ${UNLEASH_CMD:-apply}"
			;;
		E_VOLUME_AMBIGUOUS)
			PIPELINE_NEXT="unleash ${UNLEASH_CMD:-apply} --volume \"/Volumes/Macintosh HD - Data\""
			;;
		E_VOLUME_NOT_FOUND|E_VOLUME_RO)
			PIPELINE_NEXT="pass --volume to a writable macOS Data volume"
			;;
		S_SIP_LIVE)
			PIPELINE_NEXT="Boot Recovery and run: unleash recovery --unattended"
			;;
		E_VERIFY_FAIL)
			PIPELINE_NEXT="re-run: unleash apply --unattended"
			;;
		E_PERSIST_PATH)
			PIPELINE_NEXT="fix copy target then: unleash persist"
			;;
		*)
			[ -n "${PIPELINE_NEXT:-}" ] || PIPELINE_NEXT="see stderr logs"
			;;
	esac
}

_pipeline_exit() {
	local code="$1"
	local reason="${RESULT_REASON:-}"
	local msg="${RESULT_MSG:-}"
	_pipeline_fill_next
	if [ "$code" -ne 0 ]; then
		[ -n "$msg" ] || msg="pipeline stopped"
		log ERROR pipeline exit "ERROR ${reason}: ${msg}. Next: ${PIPELINE_NEXT}"
	fi
	if [ "${UNLEASH_JSON:-0}" = 1 ]; then
		emit_json "$code" "$PIPELINE_NEXT" "$PIPELINE_VOLUME"
	fi
	pipeline_lock_release || true
	exit "$code"
}

# Skip-class that does not degrade: S_ALREADY_OK S_FV_ADD S_PF_RECOVERY S_NO_PROFILES_CMD S_NO_DSCACHEUTIL
_pipeline_note_skip() {
	local reason="$1"
	case "$reason" in
		S_ALREADY_OK|S_FV_ADD|S_PF_RECOVERY|S_NO_PROFILES_CMD|S_NO_DSCACHEUTIL)
			return 0
			;;
	esac
	PIPELINE_DEGRADED=1
	if [ -n "$reason" ]; then
		if [ -n "${PIPELINE_SKIP_REASONS:-}" ]; then
			PIPELINE_SKIP_REASONS="${PIPELINE_SKIP_REASONS},${reason}"
		else
			PIPELINE_SKIP_REASONS="$reason"
		fi
	fi
}

_pipeline_handle_fail() {
	local name="$1"
	case "${RESULT_REASON:-}" in
		E_PERSIST_PATH|E_PFCTL_FAIL|E_DNS_FAIL|E_LAUNCHCTL)
			_pipeline_note_skip "$RESULT_REASON"
			return 0
			;;
	esac
	if [ -n "${SNAPSHOT_ID:-}" ] && [ -n "${DATA_ROOT:-}" ]; then
		pipeline_rollback_files "$SNAPSHOT_ID" "$DATA_ROOT" || true
	fi
	journal_rollback || true
	_pipeline_exit 1
}

_pipeline_run_step() {
	local name="$1"
	shift
	journal_step "$name" start
	RESULT_STATUS=ok
	RESULT_REASON=""
	"$@"
	case "$RESULT_STATUS" in
		ok)
			journal_step "$name" ok
			;;
		skip)
			journal_step "$name" skip "$RESULT_REASON"
			_pipeline_note_skip "$RESULT_REASON"
			;;
		fail)
			journal_step "$name" fail "$RESULT_REASON"
			_pipeline_handle_fail "$name"
			;;
	esac
}

_pipeline_step_dscl() {
	local node username password realname uid
	if _pipeline_is_dry_run; then
		info "[DRY RUN] Would create admin user"
		result_ok dscl create "dry-run"
		return 0
	fi
	node=$(dscl_node "$DATA_ROOT")
	if [ "${UNLEASH_UNATTENDED:-0}" = 1 ]; then
		username="${UNLEASH_USERNAME}"
		realname="${UNLEASH_REALNAME:-$username}"
		password=$(password_from_file "$UNLEASH_PASSWORD_FILE") || {
			# password_from_file already set RESULT_*
			return 0
		}
	else
		username="${UNLEASH_USERNAME:-}"
		if [ -z "$username" ]; then
			prompt_username username
		fi
		realname="${UNLEASH_REALNAME:-$username}"
		if [ -n "${UNLEASH_PASSWORD_FILE:-}" ]; then
			password=$(password_from_file "$UNLEASH_PASSWORD_FILE") || return 0
		else
			prompt_password password
		fi
	fi
	if check_user_exists "$node" "$username"; then
		result_skip S_ALREADY_OK dscl create "user $username already exists"
		return 0
	fi
	uid=$(find_available_uid "$node") || {
		[ -n "${RESULT_REASON:-}" ] || result_fail E_DSCL_FAIL dscl uid "no UniqueID"
		return 0
	}
	create_admin_user "$node" "$DATA_ROOT" "$username" "$realname" "$password" "$uid" || true
	password=""
	if [ "$RESULT_STATUS" = "ok" ]; then
		touch "$DATA_ROOT/private/var/db/.AppleSetupDone" 2>/dev/null || true
		add_to_filevault "$username" || true
		if [ "$RESULT_STATUS" = "skip" ] && [ "$RESULT_REASON" = "S_FV_ADD" ]; then
			result_ok dscl create "admin $username created"
		fi
	fi
	return 0
}

_pipeline_step_hosts() {
	suppress_hosts "$DATA_ROOT"
	return 0
}

_pipeline_step_dep_wipe() {
	if _pipeline_is_dry_run; then
		info "[DRY RUN] Would wipe DEP records on $DATA_ROOT"
		result_ok suppress dep_wipe "dry-run"
		return 0
	fi
	wipe_dep_records "$DATA_ROOT"
	return 0
}

_pipeline_step_daemons() {
	suppress_daemons "$DATA_ROOT"
	return 0
}

_pipeline_step_ma_clean() {
	if _pipeline_is_dry_run; then
		info "[DRY RUN] Would clean user_mdm_artifacts"
		result_ok pipeline ma_clean "dry-run"
		return 0
	fi
	clean_ma_artifacts "$DATA_ROOT"
	result_ok pipeline ma_clean "user_mdm_artifacts cleaned"
	return 0
}

_pipeline_step_pf() {
	if _pipeline_is_dry_run; then
		info "[DRY RUN] Would install pf mode=${UNLEASH_FIREWALL_MODE:-selective}"
		result_ok firewall pf "dry-run"
		return 0
	fi
	case "${UNLEASH_FIREWALL_MODE:-selective}" in
		off)
			remove_pf_mdm_block "$DATA_ROOT"
			result_ok firewall pf "firewall off"
			;;
		broad)
			install_pf_mdm_block_broad "$DATA_ROOT"
			;;
		*)
			install_pf_mdm_block_selective "$DATA_ROOT"
			;;
	esac
	return 0
}

_pipeline_step_persist() {
	if [ "${UNLEASH_PERSIST:-1}" = 0 ]; then
		result_skip S_ALREADY_OK persist copy "persist step not eligible"
		return 0
	fi
	if persist_probe_ok; then
		result_skip S_ALREADY_OK persist probe "binary and plist already live-path"
		return 0
	fi
	if _pipeline_is_dry_run; then
		info "[DRY RUN] Would copy persist binary and plist"
		result_ok persist copy "dry-run"
		return 0
	fi
	persist_copy "$DATA_ROOT" || true
	return 0
}

_pipeline_step_harden() {
	if _pipeline_is_dry_run; then
		info "[DRY RUN] Would harden live OS"
		result_ok pipeline harden "dry-run"
		return 0
	fi
	if type is_recovery >/dev/null 2>&1 && is_recovery; then
		result_skip S_ALREADY_OK pipeline harden "harden is live-OS only"
		return 0
	fi
	harden_live_os
	result_ok pipeline harden "harden complete"
	return 0
}

_pipeline_probe_hosts() {
	local hosts="${DATA_ROOT}/private/etc/hosts"
	[ -f "$hosts" ] || return 1
	grep -q "iprofiles.apple.com" "$hosts" || return 1
	grep -q "deviceenrollment.apple.com" "$hosts" || return 1
	return 0
}

_pipeline_probe_dep() {
	local cfg="${DATA_ROOT}/private/var/db/ConfigurationProfiles/Settings"
	[ ! -f "$cfg/.cloudConfigRecordFound" ]
}

_pipeline_probe_plist() {
	local ldp="${DATA_ROOT}/private/var/db/com.apple.xpc.launchd/disabled.plist"
	local pb="${PLISTBUDDY:-/usr/libexec/PlistBuddy}"
	[ -f "$ldp" ] || return 1
	"$pb" -c "Print :com.apple.ManagedClient.enroll" "$ldp" 2>/dev/null | grep -q true
}

_pipeline_file_probes_ok() {
	_pipeline_probe_hosts || return 1
	_pipeline_probe_plist || return 1
	if ! _pipeline_probe_dep; then
		return 1
	fi
	return 0
}

_pipeline_probes() {
	journal_step probes start
	if _pipeline_is_dry_run; then
		journal_step probes skip S_ALREADY_OK
		result_ok pipeline probes "dry-run"
		return 0
	fi
	if ! _pipeline_probe_hosts; then
		result_fail E_VERIFY_FAIL pipeline probes "hosts missing MDM sinkhole"
		journal_step probes fail E_VERIFY_FAIL
		return 1
	fi
	if ! _pipeline_probe_plist; then
		result_fail E_VERIFY_FAIL pipeline probes "disabled.plist missing enrollment overrides"
		journal_step probes fail E_VERIFY_FAIL
		return 1
	fi
	if ! _pipeline_probe_dep; then
		if [ "${PIPELINE_DEGRADED:-0}" = 1 ]; then
			journal_step probes skip S_SIP_LIVE
			result_skip S_SIP_LIVE pipeline probes "DEP file remains under SIP"
			return 0
		fi
		result_fail E_VERIFY_FAIL pipeline probes "DEP record still present"
		journal_step probes fail E_VERIFY_FAIL
		return 1
	fi
	journal_step probes ok
	result_ok pipeline probes "file-level checks passed"
	return 0
}

_pipeline_finish() {
	if ! _pipeline_probes; then
		journal_degraded "${RESULT_REASON:-E_VERIFY_FAIL}" "$PIPELINE_NEXT" || true
		journal_commit || true
		_pipeline_exit 4
	fi
	if [ "${PIPELINE_DEGRADED:-0}" = 1 ]; then
		RESULT_REASON="${PIPELINE_SKIP_REASONS%%,*}"
		RESULT_MSG="required work skipped after mutation"
		_pipeline_fill_next
		journal_degraded "$PIPELINE_SKIP_REASONS" "$PIPELINE_NEXT" || true
		journal_commit || true
		# No COMPLETE when required steps skip/fail.
		_pipeline_exit 3
	fi
	journal_commit || true
	result_ok pipeline commit "apply complete"
	pipeline_lock_release || true
	_pipeline_exit 0
}

# Reads UNLEASH_* globals. No second flag parser.
pipeline_run() {
	local vol_out rc

	PIPELINE_DEGRADED=0
	PIPELINE_SKIP_REASONS=""
	PIPELINE_NEXT=""
	PIPELINE_VOLUME=""
	PIPELINE_HAD_BEGIN=0
	JOURNAL_DEGRADED=0

	if ! _pipeline_preflight; then
		_pipeline_exit 2
	fi

	vol_out=$(mktemp)
	rc=0
	resolve_data_volume >"$vol_out" || rc=$?
	PIPELINE_VOLUME=$(cat "$vol_out")
	rm -f "$vol_out"
	# RESULT_* must come from resolve in this shell (no $() capture of the function).
	if [ "$rc" -ne 0 ] || [ -z "$PIPELINE_VOLUME" ]; then
		_pipeline_exit 2
	fi
	DATA_ROOT="$PIPELINE_VOLUME"

	if [ -z "${UNLEASH_LOG_FILE:-}" ] && [ -z "${LOG_FILE:-}" ]; then
		mkdir -p "$DATA_ROOT/Library/Unleash/logs" 2>/dev/null || true
		if [ -d "$DATA_ROOT/Library/Unleash/logs" ]; then
			LOG_FILE="$DATA_ROOT/Library/Unleash/logs/unleash.log"
		fi
	fi

	if ! check_or_consume_intent "$DATA_ROOT"; then
		_pipeline_exit 2
	fi

	if _pipeline_is_dry_run; then
		if [ "${UNLEASH_CREATE_ADMIN:-0}" = 1 ]; then
			_pipeline_step_dscl
		fi
		_pipeline_step_hosts
		_pipeline_step_dep_wipe
		_pipeline_step_daemons
		if type clean_ma_artifacts >/dev/null 2>&1; then
			_pipeline_step_ma_clean
		fi
		_pipeline_step_pf
		_pipeline_step_persist
		result_ok pipeline dry-run "no files written"
		_pipeline_exit 0
	fi

	if ! pipeline_lock_acquire; then
		_pipeline_exit 2
	fi

	if [ "${UNLEASH_RESUME:-0}" = 1 ]; then
		if persist_probe_ok && _pipeline_file_probes_ok; then
			result_skip S_ALREADY_OK pipeline resume "suppression already intact"
			pipeline_lock_release
			_pipeline_exit 0
		fi
	fi

	if ! journal_begin "${UNLEASH_CMD:-apply}" "$PIPELINE_VOLUME"; then
		result_fail E_DISK_FULL pipeline journal "cannot write journal"
		_pipeline_exit 2
	fi
	PIPELINE_HAD_BEGIN=1

	journal_step snapshot start
	if backup_state "$DATA_ROOT"; then
		journal_snap "$SNAPSHOT_ID"
		journal_step snapshot ok
	else
		journal_step snapshot fail "${RESULT_REASON:-E_DISK_FULL}"
		journal_abort || true
		_pipeline_exit 2
	fi

	if [ "${UNLEASH_CREATE_ADMIN:-0}" = 1 ]; then
		_pipeline_run_step dscl _pipeline_step_dscl
	fi
	_pipeline_run_step hosts _pipeline_step_hosts
	_pipeline_run_step dep_wipe _pipeline_step_dep_wipe
	_pipeline_run_step daemons _pipeline_step_daemons
	if type clean_ma_artifacts >/dev/null 2>&1; then
		_pipeline_run_step ma_clean _pipeline_step_ma_clean
	fi
	_pipeline_run_step pf _pipeline_step_pf
	_pipeline_run_step persist _pipeline_step_persist
	if [ "${UNLEASH_HARDEN:-0}" = 1 ]; then
		_pipeline_run_step harden _pipeline_step_harden
	fi

	_pipeline_finish
}

# Heal is the same mutator list. Do not set UNLEASH_PERSIST=0.
pipeline_run_heal() {
	UNLEASH_RESUME=1
	pipeline_run
}

cmd_apply() {
	pipeline_run
}

cmd_heal() {
	# Persist stays eligible; the persist step runs iff the probe is dirty.
	pipeline_run_heal
}
