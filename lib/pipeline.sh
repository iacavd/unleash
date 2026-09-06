# shellcheck shell=bash
# WAL journal + lock. Values are percent-encoded so awk NF / first-= split stays safe.
# Skeleton only: no mutator switch (hosts/persist/suppress live in later PRs).

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
