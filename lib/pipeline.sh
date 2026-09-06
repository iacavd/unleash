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

# Last SNAP id= for run=$1. Empty if the unfinished run never snapshotted.
_journal_snap_id_for_run() {
	local want="${1:-}"
	local journal line op run id last=""
	journal="$(_journal_path)"
	[ -f "$journal" ] || return 0
	[ -n "$want" ] || return 0
	while IFS= read -r line || [ -n "$line" ]; do
		[ -n "$line" ] || continue
		op=$(_kv_get "$line" op)
		run=$(_kv_get "$line" run)
		[ "$op" = "SNAP" ] || continue
		[ "$run" = "$want" ] || continue
		id=$(_kv_get "$line" id)
		[ -n "$id" ] && last="$id"
	done < "$journal"
	printf '%s' "$last"
}

# Last STEP status= for name=$1 in JOURNAL_RUN. Empty if never started.
_pipeline_journal_step_status() {
	local want="${1:-}"
	local journal line op name status run last=""
	journal="$(_journal_path)"
	[ -f "$journal" ] || return 0
	while IFS= read -r line || [ -n "$line" ]; do
		[ -n "$line" ] || continue
		run=$(_kv_get "$line" run)
		[ "$run" = "${JOURNAL_RUN:-}" ] || continue
		op=$(_kv_get "$line" op)
		[ "$op" = "STEP" ] || continue
		name=$(_kv_get "$line" name)
		[ "$name" = "$want" ] || continue
		status=$(_kv_get "$line" status)
		last="$status"
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
	# Creds before doctor so E_CREDS_REQUIRED / E_DEFAULT_PASSWORD win over E_NOT_ROOT.
	if [ "${UNLEASH_CREATE_ADMIN:-0}" = 1 ]; then
		if [ "${UNLEASH_UNATTENDED:-0}" = 1 ]; then
			if ! require_create_admin_creds; then
				return 1
			fi
		fi
		if [ -n "${UNLEASH_PASSWORD_FILE:-}" ]; then
			# Redirect is not a subshell; RESULT_* stays in this shell.
			if ! password_from_file "$UNLEASH_PASSWORD_FILE" >/dev/null; then
				return 1
			fi
		fi
	fi

	if type run_doctor >/dev/null 2>&1; then
		if ! run_doctor --gate; then
			return 1
		fi
	else
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
		if ! _pipeline_need_root; then
			return 1
		fi
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
		emit_json "$code" "$PIPELINE_NEXT" "${PIPELINE_VOLUME:-${UNLEASH_VOLUME:-}}"
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

# Read password file in this shell (no $() so RESULT_* is not dropped).
_pipeline_password_from_file() {
	local path="$1"
	local tmp rc
	PIPELINE_PASSWORD=""
	tmp=$(mktemp) || {
		result_fail E_CREDS_REQUIRED validate password-file "cannot create temp"
		return 1
	}
	rc=0
	password_from_file "$path" >"$tmp" || rc=$?
	if [ "$rc" -ne 0 ]; then
		rm -f "$tmp"
		return 1
	fi
	IFS= read -r PIPELINE_PASSWORD < "$tmp" || true
	PIPELINE_PASSWORD="${PIPELINE_PASSWORD%$'\r'}"
	rm -f "$tmp"
	return 0
}

_pipeline_step_dscl() {
	local node username password realname uid uid_out rc
	if _pipeline_is_dry_run; then
		info "[DRY RUN] Would create admin user"
		result_ok dscl create "dry-run"
		return 0
	fi
	node=$(dscl_node "$DATA_ROOT")
	if [ "${UNLEASH_UNATTENDED:-0}" = 1 ]; then
		username="${UNLEASH_USERNAME}"
		realname="${UNLEASH_REALNAME:-$username}"
		if ! _pipeline_password_from_file "$UNLEASH_PASSWORD_FILE"; then
			return 0
		fi
		password="$PIPELINE_PASSWORD"
		PIPELINE_PASSWORD=""
	else
		username="${UNLEASH_USERNAME:-}"
		if [ -z "$username" ]; then
			prompt_username username
		fi
		realname="${UNLEASH_REALNAME:-$username}"
		if [ -n "${UNLEASH_PASSWORD_FILE:-}" ]; then
			if ! _pipeline_password_from_file "$UNLEASH_PASSWORD_FILE"; then
				return 0
			fi
			password="$PIPELINE_PASSWORD"
			PIPELINE_PASSWORD=""
		else
			prompt_password password
		fi
	fi
	if check_user_exists "$node" "$username"; then
		result_skip S_ALREADY_OK dscl create "user $username already exists"
		return 0
	fi
	uid_out=$(mktemp) || {
		result_fail E_DSCL_FAIL dscl uid "cannot create temp"
		return 0
	}
	rc=0
	find_available_uid "$node" >"$uid_out" || rc=$?
	if [ "$rc" -ne 0 ]; then
		rm -f "$uid_out"
		[ -n "${RESULT_REASON:-}" ] || result_fail E_DSCL_FAIL dscl uid "no UniqueID"
		return 0
	fi
	IFS= read -r uid < "$uid_out" || true
	rm -f "$uid_out"
	create_admin_user "$node" "$DATA_ROOT" "$username" "$realname" "$password" "$uid" || true
	password=""
	if [ "$RESULT_STATUS" = "ok" ]; then
		touch "$DATA_ROOT/private/var/db/.AppleSetupDone" 2>/dev/null || true
		add_to_filevault "$username" || true
		# Leave S_FV_ADD skip on the dscl step (must not degrade).
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
	if [ ! -d "${DATA_ROOT}/Users" ]; then
		result_skip S_ALREADY_OK pipeline ma_clean "no Users on target volume"
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
	probe_hosts
	[ "$RESULT_STATUS" = "ok" ] || [ "$RESULT_STATUS" = "skip" ]
}

_pipeline_probe_dep() {
	probe_dep
	[ "$RESULT_STATUS" = "ok" ] || [ "$RESULT_STATUS" = "skip" ]
}

_pipeline_probe_plist() {
	probe_daemons
	[ "$RESULT_STATUS" = "ok" ] || [ "$RESULT_STATUS" = "skip" ]
}

_pipeline_probe_pf() {
	probe_pf
	[ "$RESULT_STATUS" = "ok" ] || [ "$RESULT_STATUS" = "skip" ]
}

_pipeline_file_probes_ok() {
	_pipeline_probe_hosts || return 1
	_pipeline_probe_plist || return 1
	_pipeline_probe_dep || return 1
	persist_probe_ok || return 1
	_pipeline_probe_pf || return 1
	return 0
}

_pipeline_layer_probe() {
	case "$1" in
		hosts) _pipeline_probe_hosts ;;
		dep_wipe) _pipeline_probe_dep ;;
		daemons) _pipeline_probe_plist ;;
		persist) persist_probe_ok ;;
		pf) _pipeline_probe_pf ;;
		snapshot|dscl|ma_clean|harden|probes) return 0 ;;
		*) return 1 ;;
	esac
}

_pipeline_rollback_layer() {
	[ -n "${SNAPSHOT_ID:-}" ] || return 0
	case "$1" in
		hosts) rollback_hosts "$SNAPSHOT_ID" "$DATA_ROOT" || true ;;
		dep_wipe) rollback_dep "$SNAPSHOT_ID" "$DATA_ROOT" || true ;;
		daemons) rollback_plist "$SNAPSHOT_ID" "$DATA_ROOT" || true ;;
		pf) rollback_pf "$SNAPSHOT_ID" "$DATA_ROOT" || true ;;
	esac
}

_pipeline_probes() {
	journal_step probes start
	if _pipeline_is_dry_run; then
		journal_step probes skip S_ALREADY_OK
		result_ok pipeline probes "dry-run"
		return 0
	fi
	run_probes
	case "$RESULT_STATUS" in
		ok|skip)
			journal_step probes ok
			result_ok pipeline probes "required probes passed"
			return 0
			;;
	esac
	journal_step probes fail "${RESULT_REASON:-E_VERIFY_FAIL}"
	return 1
}

_pipeline_finish() {
	if ! _pipeline_probes; then
		# Exit 4: probes disagree after mutate. Do not write state/degraded (exit 3 only).
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

_pipeline_begin_and_snapshot() {
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
}

_pipeline_enable_logs() {
	if [ -n "${UNLEASH_LOG_FILE:-}" ] || [ -n "${LOG_FILE:-}" ]; then
		return 0
	fi
	mkdir -p "$DATA_ROOT/Library/Unleash/logs" 2>/dev/null || return 0
	if [ -d "$DATA_ROOT/Library/Unleash/logs" ]; then
		LOG_FILE="$DATA_ROOT/Library/Unleash/logs/unleash.log"
	fi
}

# $1 = _pipeline_run_step | _pipeline_replay_step | _pipeline_run_if_dirty
_pipeline_each_mutate_step() {
	local runner="$1"
	if [ "${UNLEASH_CREATE_ADMIN:-0}" = 1 ]; then
		"$runner" dscl _pipeline_step_dscl
	fi
	"$runner" hosts _pipeline_step_hosts
	"$runner" dep_wipe _pipeline_step_dep_wipe
	"$runner" daemons _pipeline_step_daemons
	if type clean_ma_artifacts >/dev/null 2>&1; then
		"$runner" ma_clean _pipeline_step_ma_clean
	fi
	"$runner" pf _pipeline_step_pf
	"$runner" persist _pipeline_step_persist
	if [ "${UNLEASH_HARDEN:-0}" = 1 ]; then
		"$runner" harden _pipeline_step_harden
	fi
}

# Unfinished run: skip ok+probe, retry start from original SNAP, run remaining.
_pipeline_replay_step() {
	local name="$1"
	shift
	local st
	st=$(_pipeline_journal_step_status "$name")
	case "$st" in
		ok)
			if _pipeline_layer_probe "$name"; then
				journal_step "$name" skip S_ALREADY_OK
				return 0
			fi
			_pipeline_run_step "$name" "$@"
			;;
		start)
			_pipeline_rollback_layer "$name"
			_pipeline_run_step "$name" "$@"
			;;
		*)
			_pipeline_run_step "$name" "$@"
			;;
	esac
}

_pipeline_run_if_dirty() {
	local name="$1"
	shift
	if _pipeline_layer_probe "$name"; then
		journal_step "$name" skip S_ALREADY_OK
		return 0
	fi
	_pipeline_run_step "$name" "$@"
}

_pipeline_replay_unfinished() {
	SNAPSHOT_ID=$(_journal_snap_id_for_run "$JOURNAL_RUN")
	if [ -z "$SNAPSHOT_ID" ]; then
		journal_step snapshot start
		if backup_state "$DATA_ROOT"; then
			journal_snap "$SNAPSHOT_ID"
			journal_step snapshot ok
		else
			journal_step snapshot fail "${RESULT_REASON:-E_DISK_FULL}"
			journal_abort || true
			_pipeline_exit 2
		fi
	fi
	_pipeline_each_mutate_step _pipeline_replay_step
}

# Reads UNLEASH_* globals. No second flag parser.
pipeline_run() {
	local vol_out rc unfinished

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
	_pipeline_enable_logs

	if [ "${UNLEASH_RESUME:-0}" = 1 ]; then
		unfinished=$(journal_resume_scan)
		if [ -n "$unfinished" ]; then
			JOURNAL_RUN="$unfinished"
			PIPELINE_HAD_BEGIN=1
			_pipeline_replay_unfinished
			_pipeline_finish
		fi
		if persist_probe_ok && _pipeline_file_probes_ok; then
			result_skip S_ALREADY_OK pipeline resume "suppression already intact"
			pipeline_lock_release
			_pipeline_exit 0
		fi
		_pipeline_begin_and_snapshot
		_pipeline_each_mutate_step _pipeline_run_if_dirty
		_pipeline_finish
	fi

	_pipeline_begin_and_snapshot
	_pipeline_each_mutate_step _pipeline_run_step
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
