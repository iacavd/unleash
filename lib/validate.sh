# shellcheck shell=bash
# Username/password helpers. No default password 1234. No default username Apple.
# Unattended create-admin takes --username and --password-file (never argv).

validate_username() {
	local u="$1"
	[ -z "$u" ] && { echo "Username cannot be empty" >&2; return 1; }
	[ ${#u} -gt 31 ] && { echo "Username too long (max 31 chars)" >&2; return 1; }
	[[ "$u" =~ ^[a-zA-Z0-9_-]+$ ]] \
		|| { echo "Use only letters, numbers, underscore, hyphen" >&2; return 1; }
	[[ "$u" =~ ^[a-zA-Z_] ]] \
		|| { echo "Must start with a letter or underscore" >&2; return 1; }
	return 0
}

# Min 8. Contents exactly 1234 are refused unless UNLEASH_ALLOW_WEAK=1 (still warn).
validate_password() {
	local pw="${1-}"
	[ -z "$pw" ] && { echo "Password cannot be empty" >&2; return 1; }
	if [ "$pw" = "1234" ]; then
		if [ "${UNLEASH_ALLOW_WEAK:-0}" = 1 ]; then
			warn validate password "weak default password allowed by --allow-weak-password"
			return 0
		fi
		result_fail E_DEFAULT_PASSWORD validate password "default password 1234 is not allowed"
		return 1
	fi
	[ ${#pw} -lt 8 ] && { echo "Minimum 8 characters" >&2; return 1; }
	return 0
}

prompt_username() {
	local var_name="$1"
	local value
	while true; do
		read -p "Username: " value
		if [ -z "$value" ]; then
			echo "Username cannot be empty" >&2
			continue
		fi
		if validate_username "$value"; then
			# bash 3.2: no namerefs. \$value avoids eval of password-like input.
			eval "$var_name=\$value"
			return 0
		fi
	done
}

prompt_password() {
	local var_name="$1"
	local value
	while true; do
		# -s required: do not echo the secret. -r: keep backslashes.
		read -r -s -p "Password: " value
		printf '\n' >&2
		if [ -z "$value" ]; then
			echo "Password cannot be empty" >&2
			continue
		fi
		if validate_password "$value"; then
			eval "$var_name=\$value"
			return 0
		fi
	done
}

# Read PATH, trim the line terminator, reject empty.
# Exactly 1234 → E_DEFAULT_PASSWORD unless UNLEASH_ALLOW_WEAK=1 (still warn).
password_from_file() {
	local path="${1-}"
	local pw

	if [ -z "$path" ] || [ ! -f "$path" ]; then
		result_fail E_CREDS_REQUIRED validate password-file "password file missing"
		return 1
	fi

	# FAT32/exFAT: chmod 600 is a no-op or fails; physical control of the stick is the store.
	chmod 600 "$path" 2>/dev/null || true

	IFS= read -r pw < "$path" || true
	pw="${pw%$'\r'}"
	if [ -z "$pw" ]; then
		result_fail E_CREDS_REQUIRED validate password-file "password file empty"
		return 1
	fi

	if ! validate_password "$pw"; then
		# validate_password already set E_DEFAULT_PASSWORD for exact 1234.
		if [ "${RESULT_REASON:-}" != "E_DEFAULT_PASSWORD" ]; then
			result_fail E_CREDS_REQUIRED validate password-file "password does not meet policy"
		fi
		return 1
	fi

	printf '%s\n' "$pw"
	return 0
}

# Unattended create-admin preflight. Interactive prompts instead of flags.
require_create_admin_creds() {
	if [ "${UNLEASH_UNATTENDED:-0}" != 1 ]; then
		return 0
	fi
	if [ "${UNLEASH_CREATE_ADMIN:-0}" != 1 ]; then
		return 0
	fi
	if [ -z "${UNLEASH_USERNAME:-}" ]; then
		result_fail E_CREDS_REQUIRED validate creds "unattended create-admin requires --username"
		return 1
	fi
	if [ -z "${UNLEASH_PASSWORD_FILE:-}" ]; then
		result_fail E_CREDS_REQUIRED validate creds "unattended create-admin requires --password-file"
		return 1
	fi
	return 0
}
