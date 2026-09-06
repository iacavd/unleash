
is_recovery() {
	[ -d "/System/Installation" ] && return 0

	local vol
	vol=$(diskutil info / 2>/dev/null | awk -F': *' '/Volume Name/{print $2}' | xargs)
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
	vol=$(diskutil info / 2>/dev/null | awk -F': *' '/Volume Name/{print $2}' | xargs 2>/dev/null || true)
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

resolve_data_volume() {
	step "Locating Data volume by APFS role..."

	local id mount_pt

	# 1. Try APFS Role matching
	id=$(diskutil apfs list 2>/dev/null \
		| awk '/(Data)/ && match($0, /disk[0-9]+s[0-9]+/) {print substr($0, RSTART, RLENGTH); exit}')

	# 2. Try Name-based diskutil list matching if APFS role lookup failed
	if [ -z "$id" ] || ! diskutil info "/dev/$id" >/dev/null 2>&1; then
		info "APFS role detection failed — trying name-based..."
		id=$(diskutil list 2>/dev/null \
			| awk '/[[:space:]]Data[[:space:]]/{for(i=1;i<=NF;i++) if($i ~ /^disk[0-9]+s[0-9]+$/) v=$i} END{print v}')
	fi

	# 3. Direct /Volumes directory scan (ignoring USB/Installer drives)
	if [ -z "$id" ]; then
		info "Diskutil lookup inconclusive — scanning mounted volumes in /Volumes..."
		for v in /Volumes/*; do
			[ -d "$v" ] || continue
			case "$(basename "$v")" in
				"Recovery"*|"macOS Base"*|"macOS Installer"*|"Shared"*|"Preboot"*|"VM"*) continue ;;
			esac
			if [ -d "$v/private/var/db/dslocal/nodes/Default" ]; then
				success "Discovered Data volume via directory scan: $v"
				echo "$v"
				return 0
			fi
		done
	fi

	if [ -z "$id" ] || ! diskutil info "/dev/$id" >/dev/null 2>&1; then
		warn "Auto-detection failed. Available disks:"
		diskutil list >&2
		echo ""
		read -p "Enter Data volume identifier (e.g. disk3s1): " id </dev/tty
		id="${id#/dev/}"
	fi

	[ -n "$id" ] || error_exit "No Data volume identifier provided."
	local data_dev="/dev/$id"
	diskutil info "$data_dev" >/dev/null 2>&1 || error_exit "Not a valid disk: $data_dev"
	info "Data volume device: $data_dev"

	_mount_point() {
		diskutil info "$data_dev" 2>/dev/null \
			| awk -F': *' '/Mount Point/{print $2}' | sed 's/[[:space:]]*$//'
	}

	mount_pt=$(_mount_point)

	if [ -z "$mount_pt" ] || [ ! -d "$mount_pt" ]; then
		info "Not mounted — mounting..."
		diskutil mount "$data_dev" 2>/dev/null || true
		mount_pt=$(_mount_point)
	fi

	if [ -z "$mount_pt" ] || [ ! -d "$mount_pt" ]; then
		warn "FileVault-locked — need to unlock."
		echo -e "${YEL}Enter password of a user on this Mac (or FileVault recovery key):${NC}" >&2
		diskutil apfs unlockVolume "$data_dev" 2>/dev/null \
			|| error_exit "Failed to unlock. Re-run with valid credentials."
		mount_pt=$(_mount_point)
	fi

	[ -d "$mount_pt" ] || error_exit "Mount point not found after mount/unlock."
	[ -d "$mount_pt/private/var/db/dslocal/nodes/Default" ] \
		|| error_exit "Not a macOS Data volume (no dslocal node at $mount_pt)."

	success "Data volume: $mount_pt"
	echo "$mount_pt"
}

resolve_all_volumes() {
	# Scans for ALL mounted APFS containers with (Data) role
	# Returns newline-separated list of mount points
	local ids mount_pt found=0

	ids=$(diskutil apfs list 2>/dev/null \
		| awk '/(Data)/ && match($0, /disk[0-9]+s[0-9]+/) {print substr($0, RSTART, RLENGTH)}')

	if [ -z "$ids" ]; then
		# Fallback: name-based scan
		ids=$(diskutil list 2>/dev/null \
			| awk '/[[:space:]]Data[[:space:]]/{for(i=1;i<=NF;i++) if($i ~ /^disk[0-9]+s[0-9]+$/) print $i}')
	fi

	if [ -n "$ids" ]; then
		local id
		for id in $ids; do
			local data_dev="/dev/$id"
			diskutil info "$data_dev" >/dev/null 2>&1 || continue

			mount_pt=$(diskutil info "$data_dev" 2>/dev/null \
				| awk -F': *' '/Mount Point/{print $2}' | sed 's/[[:space:]]*$//')

			if [ -z "$mount_pt" ] || [ ! -d "$mount_pt" ]; then
				diskutil mount "$data_dev" 2>/dev/null || continue
				mount_pt=$(diskutil info "$data_dev" 2>/dev/null \
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
