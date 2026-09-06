# shellcheck shell=bash
# OpenDirectory admin create. Never fall back to UniqueID 501 after a failed scan.
# FileVault add: unattended MVAC skips (S_FV_ADD). Password never on argv.

_dscl() { "${DSCL:-dscl}" "$@"; }
_dscl_fde() { "${FDESETUP:-fdesetup}" "$@"; }

dscl_node() {
	local data_mount="$1"
	echo "$data_mount/private/var/db/dslocal/nodes/Default"
}

check_user_exists() {
	local node="$1"
	local username="$2"
	_dscl -f "$node" localhost -read "/Local/Default/Users/$username" >/dev/null 2>&1
}

# True if listing (dscl -list UniqueID) already has UniqueID $2.
_dscl_listing_has_uid() {
	local listing="$1"
	local want="$2"
	local line last
	while IFS= read -r line || [ -n "$line" ]; do
		[ -n "$line" ] || continue
		last=""
		# word-split: last field is UniqueID
		for last in $line; do
			:
		done
		if [ "$last" = "$want" ]; then
			return 0
		fi
	done <<EOF
$listing
EOF
	return 1
}

# First free UniqueID in 501-599. Empty stdout + result_fail if none or scan fails.
# Never echo 501 as a last resort (that collides when 501 is taken).
find_available_uid() {
	local node="$1"
	local uid=501
	local listing

	if ! command -v "${DSCL:-dscl}" >/dev/null 2>&1; then
		result_fail E_DSCL_FAIL dscl uid "dscl not available"
		return 1
	fi

	listing=$(_dscl -f "$node" localhost -list /Local/Default/Users UniqueID) || {
		result_fail E_DSCL_FAIL dscl uid "dscl UniqueID list failed"
		return 1
	}

	while [ "$uid" -lt 600 ]; do
		if ! _dscl_listing_has_uid "$listing" "$uid"; then
			printf '%s\n' "$uid"
			return 0
		fi
		uid=$((uid + 1))
	done

	result_fail E_DSCL_FAIL dscl uid "no UniqueID available in 501-599"
	return 1
}

delete_user() {
	local node="$1"
	local data_mount="$2"
	local username="$3"
	_dscl -f "$node" localhost -delete "/Local/Default/Users/$username" 2>/dev/null || true
	rm -rf "$data_mount/Users/$username" 2>/dev/null || true
}

create_admin_user() {
	local node="$1"
	local data_mount="$2"
	local username="$3"
	local realname="$4"
	local password="$5"
	local uid="$6"
	local path got

	info dscl create "Creating admin account: $username"

	if check_user_exists "$node" "$username"; then
		result_fail E_DSCL_FAIL dscl create "User account '$username' already exists"
		return 1
	fi

	path="/Local/Default/Users/$username"

	if ! _dscl -f "$node" localhost -create "$path"; then
		result_fail E_DSCL_FAIL dscl create "Failed to create user '$username'"
		return 1
	fi
	# Record leftover account; never delete on later attr/password fail.
	if type _journal_write >/dev/null 2>&1 && [ -n "${JOURNAL_RUN:-}" ]; then
		_journal_write op=STEP "name=dscl" "user_created=$(_kv_encode "$username")"
	fi

	if ! _dscl -f "$node" localhost -create "$path" UserShell "/bin/zsh"; then
		result_fail E_DSCL_FAIL dscl create "Failed to set UserShell for '$username'"
		return 1
	fi
	if ! _dscl -f "$node" localhost -create "$path" RealName "$realname"; then
		result_fail E_DSCL_FAIL dscl create "Failed to set RealName for '$username'"
		return 1
	fi
	if ! _dscl -f "$node" localhost -create "$path" UniqueID "$uid"; then
		result_fail E_DSCL_FAIL dscl create "Failed to set UniqueID for '$username'"
		return 1
	fi
	if ! _dscl -f "$node" localhost -create "$path" PrimaryGroupID "20"; then
		result_fail E_DSCL_FAIL dscl create "Failed to set PrimaryGroupID for '$username'"
		return 1
	fi
	if ! _dscl -f "$node" localhost -create "$path" NFSHomeDirectory "/Users/$username"; then
		result_fail E_DSCL_FAIL dscl create "Failed to set NFSHomeDirectory for '$username'"
		return 1
	fi

	# Password on stdin, never argv (ps).
	if ! _dscl -f "$node" localhost -passwd "$path" <<EOF
${password}
EOF
	then
		result_fail E_DSCL_FAIL dscl create "Failed to set password for '$username'"
		return 1
	fi
	if ! _dscl -f "$node" localhost -append "/Local/Default/Groups/admin" GroupMembership "$username"; then
		result_fail E_DSCL_FAIL dscl create "Failed to grant admin group membership to '$username'"
		return 1
	fi

	mkdir -p "$data_mount/Users/$username"

	if ! check_user_exists "$node" "$username"; then
		result_fail E_DSCL_FAIL dscl create "User '$username' missing after create"
		return 1
	fi

	got=$(_dscl -f "$node" localhost -read "$path" UniqueID) || got=""
	if ! printf '%s\n' "$got" | grep -qE "(^|[[:space:]])${uid}([[:space:]]|$)"; then
		result_fail E_DSCL_FAIL dscl create "UniqueID mismatch after create (want $uid)"
		return 1
	fi

	result_ok dscl create "Admin '$username' created (UID $uid)"
	return 0
}

# Unattended MVAC: skip immediately. Interactive may prompt. Never password on argv.
add_to_filevault() {
	local username="$1"
	local skip_msg="user may not unlock FileVault after reboot; run sudo fdesetup add -usertoadd ${username}"

	if [ "${UNLEASH_UNATTENDED:-0}" = 1 ]; then
		result_skip S_FV_ADD dscl filevault "$skip_msg"
		return 0
	fi

	if ! command -v "${FDESETUP:-fdesetup}" >/dev/null 2>&1; then
		result_skip S_FV_ADD dscl filevault "$skip_msg"
		return 0
	fi

	if _dscl_fde add -usertoadd "$username"; then
		result_ok dscl filevault "added $username to FileVault"
		return 0
	fi
	result_skip S_FV_ADD dscl filevault "$skip_msg"
	return 0
}
