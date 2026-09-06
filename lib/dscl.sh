# shellcheck shell=bash
# OpenDirectory admin create. Never fall back to UniqueID 501 after a failed scan.
# FileVault add: no password on argv; unattended uses -inputplist or S_FV_ADD.

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

# First free UniqueID in 501-599. Empty stdout + result_fail if none or scan fails.
# Never echo 501 as a last resort (that collides when 501 is taken).
find_available_uid() {
	local node="$1"
	local uid=501
	local hit

	if ! command -v "${DSCL:-dscl}" >/dev/null 2>&1; then
		result_fail E_DSCL_FAIL dscl uid "dscl not available"
		return 1
	fi

	while [ "$uid" -lt 600 ]; do
		hit=$(_dscl -f "$node" localhost -search /Local/Default/Users UniqueID "$uid" 2>/dev/null || true)
		if ! printf '%s\n' "$hit" | grep -q "UniqueID"; then
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

	info dscl create "Creating admin account: $username"

	if check_user_exists "$node" "$username"; then
		result_fail E_DSCL_FAIL dscl create "User account '$username' already exists"
		return 1
	fi

	if ! _dscl -f "$node" localhost -create "/Local/Default/Users/$username"; then
		result_fail E_DSCL_FAIL dscl create "Failed to create user '$username'"
		return 1
	fi

	_dscl -f "$node" localhost -create "/Local/Default/Users/$username" UserShell "/bin/zsh" || true
	_dscl -f "$node" localhost -create "/Local/Default/Users/$username" RealName "$realname" || true
	_dscl -f "$node" localhost -create "/Local/Default/Users/$username" UniqueID "$uid" || true
	_dscl -f "$node" localhost -create "/Local/Default/Users/$username" PrimaryGroupID "20" || true
	_dscl -f "$node" localhost -create "/Local/Default/Users/$username" NFSHomeDirectory "/Users/$username" || true

	if ! _dscl -f "$node" localhost -passwd "/Local/Default/Users/$username" "$password"; then
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

	result_ok dscl create "Admin '$username' created (UID $uid)"
	return 0
}

_dscl_xml_escape() {
	local s="${1-}"
	s="${s//&/&amp;}"
	s="${s//</&lt;}"
	s="${s//>/&gt;}"
	s="${s//\"/&quot;}"
	printf '%s' "$s"
}

# Unattended: -inputplist (password on stdin, never argv). Fail → S_FV_ADD skip, not success.
add_to_filevault() {
	local username="$1"
	local password="${2-}"
	local fde plist rc eu ep
	local skip_msg="user may not unlock FileVault after reboot; run sudo fdesetup add -usertoadd ${username}"

	fde="${FDESETUP:-fdesetup}"
	if ! command -v "$fde" >/dev/null 2>&1; then
		result_skip S_FV_ADD dscl filevault "$skip_msg"
		return 0
	fi

	if [ "${UNLEASH_UNATTENDED:-0}" = 1 ]; then
		if [ -z "$password" ]; then
			result_skip S_FV_ADD dscl filevault "$skip_msg"
			return 0
		fi
		plist=$(mktemp) || {
			result_skip S_FV_ADD dscl filevault "$skip_msg"
			return 0
		}
		chmod 600 "$plist" 2>/dev/null || true
		eu=$(_dscl_xml_escape "$username")
		ep=$(_dscl_xml_escape "$password")
		cat > "$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Username</key>
	<string>${eu}</string>
	<key>Password</key>
	<string>${ep}</string>
	<key>AdditionalUsers</key>
	<array>
		<dict>
			<key>Username</key>
			<string>${eu}</string>
			<key>Password</key>
			<string>${ep}</string>
		</dict>
	</array>
</dict>
</plist>
EOF
		rc=0
		_dscl_fde add -usertoadd "$username" -inputplist < "$plist" || rc=$?
		rm -f "$plist"
		if [ "$rc" -ne 0 ]; then
			result_skip S_FV_ADD dscl filevault "$skip_msg"
			return 0
		fi
		result_ok dscl filevault "added $username to FileVault"
		return 0
	fi

	# Interactive may prompt; still no password on argv.
	if _dscl_fde add -usertoadd "$username"; then
		result_ok dscl filevault "added $username to FileVault"
		return 0
	fi
	result_skip S_FV_ADD dscl filevault "$skip_msg"
	return 0
}
