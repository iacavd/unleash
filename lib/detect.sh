# shellcheck shell=bash

# Recovery: DATA_ROOT="$data_mount". Live OS: empty so "${DATA_ROOT}/Library" == "/Library".
# Set DATA_ROOT in the caller after resolve_data_volume — command substitution is a subshell.
DATA_ROOT="${DATA_ROOT-}"

unleash_root() { echo "${DATA_ROOT}/Library/Unleash"; }

_detect_du() { "${DISKUTIL:-diskutil}" "$@"; }
_detect_pb() {
	if [ -n "${PLISTBUDDY:-}" ]; then
		"$PLISTBUDDY" "$@"
	elif [ -x /usr/libexec/PlistBuddy ]; then
		/usr/libexec/PlistBuddy "$@"
	else
		command PlistBuddy "$@"
	fi
}
_detect_mn() { "${MOUNT:-mount}" "$@"; }

is_recovery() {
	[ -d "/System/Installation" ] && return 0

	local vol
	vol=$(_detect_du info / 2>/dev/null | awk -F': *' '/Volume Name/{print $2}' | xargs)
	case "$vol" in
		"Recovery"*|"macOS Base"*|"macOS Installer"*) return 0 ;;
	esac
	return 1
}

is_root() {
	[[ $EUID -eq 0 ]]
}

detect_boot_mode() {
	if [ -d "/System/Installation" ]; then
		echo "recovery"
		return 0
	fi
	local vol
	vol=$(_detect_du info / 2>/dev/null | awk -F': *' '/Volume Name/{print $2}' | xargs 2>/dev/null || true)
	case "$vol" in
		"Recovery"*|"macOS Base"*) echo "recovery"; return 0 ;;
		"macOS Installer"*) echo "installer"; return 0 ;;
	esac
	echo "normal"
}

detect_macos_version() {
	local ver
	ver=$(sw_vers -productVersion 2>/dev/null || echo "0.0.0")
	echo "$ver"
}

detect_macos_major() {
	local ver
	ver=$(detect_macos_version)
	echo "${ver%%.*}"
}

# Trim leading/trailing whitespace. bash 3.2, no namerefs.
_detect_trim() {
	local s="${1-}"
	s="${s#"${s%%[![:space:]]*}"}"
	s="${s%"${s##*[![:space:]]}"}"
	printf '%s' "$s"
}

_detect_list_data_devs_text() {
	local ids
	ids=$(_detect_du apfs list 2>/dev/null | awk '
		/APFS Volume Disk \(Role\):/ && /\(Data\)/ {
			if (match($0, /disk[0-9]+s[0-9]+/)) print substr($0, RSTART, RLENGTH)
		}
	')
	if [ -z "$ids" ]; then
		ids=$(_detect_du list 2>/dev/null | awk '
			/[[:space:]]Data[[:space:]]/ {
				for (i = 1; i <= NF; i++) if ($i ~ /^disk[0-9]+s[0-9]+$/) print $i
			}
		')
	fi
	printf '%s\n' "$ids" | sed '/^$/d'
}

# Print one device identifier per Data-role volume. Plist first, text awk fallback.
_detect_list_data_devs() {
	local plist i j ridx role dev got
	plist=$(mktemp) || return 1
	got=0
	if _detect_du apfs list -plist >"$plist" 2>/dev/null; then
		i=0
		while _detect_pb -c "Print :Containers:$i" "$plist" >/dev/null 2>&1; do
			j=0
			while _detect_pb -c "Print :Containers:$i:Volumes:$j:DeviceIdentifier" "$plist" >/dev/null 2>&1; do
				ridx=0
				while role=$(_detect_pb -c "Print :Containers:$i:Volumes:$j:Roles:$ridx" "$plist" 2>/dev/null); do
					if [ "$role" = "Data" ]; then
						dev=$(_detect_pb -c "Print :Containers:$i:Volumes:$j:DeviceIdentifier" "$plist" 2>/dev/null) || dev=""
						if [ -n "$dev" ]; then
							printf '%s\n' "$dev"
							got=1
						fi
						break
					fi
					ridx=$((ridx + 1))
				done
				j=$((j + 1))
			done
			i=$((i + 1))
		done
	fi
	rm -f "$plist"
	if [ "$got" -eq 0 ]; then
		_detect_list_data_devs_text
	fi
}

_detect_mount_point() {
	local dev="$1" mp
	mp=$(_detect_du info "$dev" 2>/dev/null \
		| awk -F': *' '/^[[:space:]]*Mount Point:/{print $2; exit}')
	mp="$(_detect_trim "${mp:-}")"
	case "$mp" in
		""|"Not Mounted") return 1 ;;
	esac
	[ -d "$mp" ] || return 1
	printf '%s\n' "$mp"
}

_detect_is_locked() {
	local info
	info=$(_detect_du info "$1" 2>/dev/null || true)
	printf '%s\n' "$info" | grep -qiE '^[[:space:]]*Locked:[[:space:]]*Yes' && return 0
	printf '%s\n' "$info" | grep -qiE '^[[:space:]]*FileVault:[[:space:]]*Yes[[:space:]]*\(Locked\)' && return 0
	return 1
}

# Personal recovery key is a passphrase; -recoverykeyfile is not a diskutil flag.
# Never put the secret on argv (-passphrase). Unlock chatter goes to stderr, not resolver stdout.
# FAT32/exFAT USB: chmod 600 is a no-op or fails. Do not treat that as a secret-store;
# physical control of the stick is the store. Still attempt chmod 600 on APFS/HFS.
_detect_unlock_stdin() {
	local dev="$1" file="$2" line
	chmod 600 "$file" 2>/dev/null || true
	IFS= read -r line < "$file" || true
	line="${line%$'\r'}"
	# Here-doc is a redirect, not a pipe: unlockVolume's exit is this function's
	# even without pipefail. Never put the secret on argv.
	_detect_du apfs unlockVolume "$dev" -stdinpassphrase >/dev/null <<EOF
${line}
EOF
}

_detect_unlock() {
	local dev="$1"
	if [ -n "${UNLEASH_FV_PASSWORD_FILE:-}" ]; then
		if [ ! -f "$UNLEASH_FV_PASSWORD_FILE" ]; then
			result_fail E_FV_UNLOCK_FAILED detect unlock "FileVault password file not found"
			return 1
		fi
		if ! _detect_unlock_stdin "$dev" "$UNLEASH_FV_PASSWORD_FILE"; then
			result_fail E_FV_UNLOCK_FAILED detect unlock "FileVault unlock failed"
			return 1
		fi
		return 0
	fi
	if [ -n "${UNLEASH_FV_KEY_FILE:-}" ]; then
		if [ ! -f "$UNLEASH_FV_KEY_FILE" ]; then
			result_fail E_FV_UNLOCK_FAILED detect unlock "FileVault recovery key file not found"
			return 1
		fi
		if ! _detect_unlock_stdin "$dev" "$UNLEASH_FV_KEY_FILE"; then
			result_fail E_FV_UNLOCK_FAILED detect unlock "FileVault unlock failed"
			return 1
		fi
		return 0
	fi
	if [ -t 0 ] && [ "${UNLEASH_UNATTENDED:-0}" = 0 ]; then
		info detect unlock "FileVault locked — enter password or recovery key"
		if ! _detect_du apfs unlockVolume "$dev" >/dev/null; then
			result_fail E_FV_UNLOCK_FAILED detect unlock "FileVault unlock failed"
			return 1
		fi
		return 0
	fi
	result_fail E_FV_LOCKED detect unlock "FileVault locked and no secret"
	return 1
}

# Sets _DETECT_MOUNT. Must not run in a command-substitution subshell (result_fail).
_detect_ensure_mounted() {
	local dev="$1" mp mount_rc
	_DETECT_MOUNT=""

	mp=$(_detect_mount_point "$dev") || mp=""
	if [ -z "$mp" ]; then
		mount_rc=0
		_detect_du mount "$dev" >/dev/null || mount_rc=$?
		if [ "$mount_rc" -ne 0 ]; then
			if _detect_is_locked "$dev"; then
				_detect_unlock "$dev" || return 1
				mp=$(_detect_mount_point "$dev") || mp=""
				if [ -z "$mp" ]; then
					if ! _detect_du mount "$dev" >/dev/null; then
						result_fail E_VOLUME_NOT_FOUND detect mount "diskutil mount failed"
						return 1
					fi
					mp=$(_detect_mount_point "$dev") || mp=""
				fi
			else
				result_fail E_VOLUME_NOT_FOUND detect mount "diskutil mount failed"
				return 1
			fi
		else
			mp=$(_detect_mount_point "$dev") || mp=""
		fi
	fi

	if [ -z "$mp" ] || [ ! -d "$mp" ]; then
		result_fail E_VOLUME_NOT_FOUND detect mount "diskutil mount failed"
		return 1
	fi
	_DETECT_MOUNT="$mp"
	return 0
}

_detect_ensure_writable() {
	local mount="$1"
	local probe="$mount/Library/Unleash/state/.write-test"
	mkdir -p "$mount/Library/Unleash/state" || true
	if ! touch "$probe" 2>/tmp/unleash-touch.err; then
		# No || true: remount failure is not fatal if the next touch succeeds.
		if _detect_mn -uw "$mount"; then
			:
		fi
		if ! touch "$probe"; then
			result_fail E_VOLUME_RO detect remount "Data volume is read-only after mount -uw"
			return 1
		fi
	fi
	rm -f "$probe"
	return 0
}

_detect_dump_candidates() {
	local dev mp name
	for dev in "$@"; do
		[ -n "$dev" ] || continue
		mp=$(_detect_mount_point "$dev") || mp="(unmounted)"
		name=$(_detect_du info "$dev" 2>/dev/null \
			| awk -F': *' '/Volume Name/{print $2; exit}')
		name="$(_detect_trim "${name:-}")"
		info detect resolve "$dev ${name:+$name }${mp}"
	done
}

# RESULT_* is set here (result_ok / result_fail). $(resolve_data_volume) is a subshell,
# so callers that need RESULT_REASON must redirect stdout instead of capturing with $().
# Fail still returns 1 with empty stdout so $() callers can detect it.
resolve_data_volume() {
	step detect resolve "Locating Data volume"

	local devs pick spec count line mp
	_DETECT_MOUNT=""

	devs=$(_detect_list_data_devs) || devs=""
	devs=$(printf '%s\n' "$devs" | sed '/^$/d')

	if [ -n "${UNLEASH_VOLUME:-}" ]; then
		spec="$(_detect_trim "$UNLEASH_VOLUME")"
		if [ -d "$spec" ]; then
			pick=$(_detect_du info "$spec" 2>/dev/null \
				| awk -F': *' '/Device Identifier/{print $2; exit}')
			pick="$(_detect_trim "${pick:-}")"
			if [ -z "$pick" ]; then
				# Path-only override when diskutil info cannot map it.
				if [ ! -d "$spec/private/var/db/dslocal/nodes/Default" ]; then
					result_fail E_VOLUME_NOT_FOUND detect resolve "no APFS Data volume"
					return 1
				fi
				_DETECT_MOUNT="$spec"
				_detect_ensure_writable "$_DETECT_MOUNT" || return 1
				result_ok detect resolve "Data volume $_DETECT_MOUNT"
				printf '%s\n' "$_DETECT_MOUNT"
				return 0
			fi
		else
			pick="${spec#/dev/}"
			case "$pick" in
				disk[0-9]*s[0-9]*) ;;
				*)
					result_fail E_VOLUME_NOT_FOUND detect resolve "no APFS Data volume"
					return 1
					;;
			esac
		fi
	else
		count=0
		while IFS= read -r line; do
			[ -n "$line" ] || continue
			count=$((count + 1))
		done <<EOF
$devs
EOF
		if [ "$count" -eq 0 ]; then
			_detect_du list >&2 || true
			result_fail E_VOLUME_NOT_FOUND detect resolve "no APFS Data volume"
			return 1
		fi
		if [ "$count" -gt 1 ]; then
			info detect resolve "multiple Data volumes"
			while IFS= read -r line; do
				[ -n "$line" ] || continue
				_detect_dump_candidates "$line"
			done <<EOF
$devs
EOF
			if [ -t 0 ] && [ "${UNLEASH_UNATTENDED:-0}" = 0 ]; then
				printf 'Enter Data volume identifier (e.g. disk3s5): ' >&2
				IFS= read -r pick || pick=""
				pick="$(_detect_trim "${pick#/dev/}")"
				if [ -z "$pick" ]; then
					result_fail E_VOLUME_AMBIGUOUS detect resolve "multiple Data volumes"
					return 1
				fi
			else
				result_fail E_VOLUME_AMBIGUOUS detect resolve "multiple Data volumes"
				return 1
			fi
		else
			pick="$devs"
			pick="$(_detect_trim "$pick")"
		fi
	fi

	_detect_ensure_mounted "$pick" || return 1
	mp="$_DETECT_MOUNT"

	if [ ! -d "$mp/private/var/db/dslocal/nodes/Default" ]; then
		result_fail E_VOLUME_NOT_FOUND detect resolve "Not a macOS Data volume (no dslocal node)"
		return 1
	fi

	_detect_ensure_writable "$mp" || return 1

	result_ok detect resolve "Data volume $mp"
	printf '%s\n' "$mp"
	return 0
}

resolve_all_volumes() {
	# Scans for ALL mounted APFS containers with (Data) role
	# Returns newline-separated list of mount points
	local ids mount_pt found=0

	ids=$(_detect_du apfs list 2>/dev/null \
		| awk '/(Data)/ && match($0, /disk[0-9]+s[0-9]+/) {print substr($0, RSTART, RLENGTH)}')

	if [ -z "$ids" ]; then
		ids=$(_detect_du list 2>/dev/null \
			| awk '/[[:space:]]Data[[:space:]]/{for(i=1;i<=NF;i++) if($i ~ /^disk[0-9]+s[0-9]+$/) print $i}')
	fi

	if [ -n "$ids" ]; then
		local id
		for id in $ids; do
			local data_dev="/dev/$id"
			_detect_du info "$data_dev" >/dev/null 2>&1 || continue

			mount_pt=$(_detect_du info "$data_dev" 2>/dev/null \
				| awk -F': *' '/Mount Point/{print $2}' | sed 's/[[:space:]]*$//')

			if [ -z "$mount_pt" ] || [ ! -d "$mount_pt" ]; then
				_detect_du mount "$data_dev" 2>/dev/null || continue
				mount_pt=$(_detect_du info "$data_dev" 2>/dev/null \
					| awk -F': *' '/Mount Point/{print $2}' | sed 's/[[:space:]]*$//')
			fi

			if [ -n "$mount_pt" ] && [ -d "$mount_pt" ]; then
				if [ -d "$mount_pt/private/var/db/dslocal/nodes/Default" ]; then
					echo "$mount_pt"
					found=$((found + 1))
				fi
			fi
		done
	fi

	# Fallback directory scan if APFS list returned nothing
	if [ "$found" -eq 0 ]; then
		for v in /Volumes/*; do
			[ -d "$v" ] || continue
			case "$(basename "$v")" in
				"Recovery"*|"macOS Base"*|"macOS Installer"*|"Shared"*|"Preboot"*|"VM"*) continue ;;
			esac
			if [ -d "$v/private/var/db/dslocal/nodes/Default" ]; then
				echo "$v"
				found=$((found + 1))
			fi
		done
	fi

	[ "$found" -gt 0 ] || return 1
}

detect_system_volume() {
	local data_mount="$1"
	local vol

	for vol in /Volumes/*; do
		if [ -d "$vol/System" ] && [ "$vol" != "$data_mount" ]; then
			basename "$vol"
			return 0
		fi
	done

	echo ""
}

resolve_target_volumes() {
	local base_name data_name

	read -p "Enter target system volume name (default 'Macintosh HD'): " base_name
	base_name="${base_name:=Macintosh HD}"
	read -p "Enter target data volume name (default 'Macintosh HD - Data'): " data_name
	data_name="${data_name:=Macintosh HD - Data}"

	local sys_path="/Volumes/$base_name"
	local data_path="/Volumes/$data_name"

	[ -d "$sys_path" ] || error_exit "System volume not found: $sys_path"
	[ -d "$data_path" ] || error_exit "Data volume not found: $data_path"

	echo "$sys_path|$data_path"
}
