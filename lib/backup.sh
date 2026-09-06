
BACKUP_DIR="$(dirname "$(dirname "$0")")/.unleash-backup"
BACKUP_RETENTION=5

check_disk_space() {
	local data_mount="$1"
	local needed_kb=10240
	local available_kb
	available_kb=$(df -k "$data_mount" 2>/dev/null | tail -1 | awk '{print $4}')
	if [ -n "$available_kb" ] && [ "$available_kb" -lt "$needed_kb" ]; then
		warn "Low disk space: $(echo "$available_kb" | awk '{printf "%.0f MB", $1/1024}') available"
		echo -n "Continue anyway? [y/N] "
		read -r answer
		[ "$answer" != "y" ] && [ "$answer" != "Y" ] && error_exit "Aborted by user"
	fi
}

_backup_timestamp() {
	date +%Y-%m-%d_%H-%M-%S
}

_generate_manifest() {
	local backup_path="$1"
	local manifest="${backup_path}/manifest.json"
	local ts
	ts=$(cat "${backup_path}/timestamp" 2>/dev/null || echo "unknown")
	local vol
	vol=$(cat "${backup_path}/data_volume_path" 2>/dev/null || echo "unknown")

	local files=""
	local count=0
	for f in "$backup_path"/*; do
		[ -f "$f" ] || continue
		local name
		name=$(basename "$f")
		[ "$name" = "manifest.json" ] && continue
		local size
		size=$(wc -c < "$f" 2>/dev/null | tr -d ' ')
		local cksum
		if command -v shasum &>/dev/null; then
			cksum=$(shasum -a 256 "$f" 2>/dev/null | awk '{print $1}')
		else
			cksum="unavailable"
		fi
		[ "$count" -gt 0 ] && files="${files},"
		files="${files}\n    {\"name\":\"${name}\",\"size\":${size:-0},\"sha256\":\"${cksum}\"}"
		count=$((count + 1))
	done

	cat > "$manifest" <<- MANIFEST
	{
	  "version": "${VERSION:-unknown}",
	  "timestamp": "$ts",
	  "data_volume": "$vol",
	  "file_count": $count,
	  "files": [${files}
	  ]
	}
	MANIFEST
}

backup_state() {
	local data_mount="$1"
	local ts
	ts=$(_backup_timestamp)
	local snapshot_dir="${BACKUP_DIR}/${ts}"
	mkdir -p "$snapshot_dir"
	check_disk_space "$data_mount"
	step "Saving backup to $snapshot_dir"

	# Hosts file
	if [ -f "$data_mount/private/etc/hosts" ]; then
		cp "$data_mount/private/etc/hosts" "$snapshot_dir/hosts.backup"
		success "hosts saved"
	fi

	# Configuration profiles
	local cfg_src="$data_mount/private/var/db/ConfigurationProfiles/Settings"
	if [ -d "$cfg_src" ]; then
		mkdir -p "$snapshot_dir/ConfigurationProfiles"
		cp -r "$cfg_src/"* "$snapshot_dir/ConfigurationProfiles/" 2>/dev/null || true
		success "config profiles saved"
	fi

	# Launchd disabled.plist
	local ldp_src="$data_mount/private/var/db/com.apple.xpc.launchd/disabled.plist"
	if [ -f "$ldp_src" ]; then
		mkdir -p "$snapshot_dir/launchd"
		cp "$ldp_src" "$snapshot_dir/launchd/disabled.plist.backup" 2>/dev/null || true
		success "launchd override saved"
	fi

	# pf.conf
	local pf_root=""
	[ -n "$data_mount" ] && pf_root="$data_mount"
	local pf_conf="${pf_root}/etc/pf.conf"
	if [ -f "$pf_conf" ]; then
		mkdir -p "$snapshot_dir/pf"
		cp "$pf_conf" "$snapshot_dir/pf/pf.conf.backup" 2>/dev/null || true
		success "pf.conf saved"
	fi

	# pf anchors
	local anchor_dir="${pf_root}/etc/pf.anchors"
	if [ -d "$anchor_dir" ]; then
		for anchor in "$anchor_dir"/com.unleash*; do
			[ -e "$anchor" ] || continue
			mkdir -p "$snapshot_dir/pf/anchors"
			cp -r "$anchor" "$snapshot_dir/pf/anchors/" 2>/dev/null || true
		done
		# Also copy com.unleash directory (for com.unleash/mdm)
		if [ -d "$anchor_dir/com.unleash" ]; then
			mkdir -p "$snapshot_dir/pf/anchors/com.unleash"
			cp -r "$anchor_dir/com.unleash/"* "$snapshot_dir/pf/anchors/com.unleash/" 2>/dev/null || true
		fi
		success "pf anchors saved"
	fi

	echo "$ts" >"$snapshot_dir/timestamp"
	echo "$data_mount" >"$snapshot_dir/data_volume_path"

	# Also write to legacy location for backward compat
	echo "$ts" >"$BACKUP_DIR/timestamp"
	echo "$data_mount" >"$BACKUP_DIR/data_volume_path"

	_generate_manifest "$snapshot_dir"

	# Rotate old backups
	backup_rotate

	success "Backup complete: $ts"
}

restore_state() {
	local snapshot_dir=""

	# Try latest snapshot first
	if [ -d "$BACKUP_DIR" ]; then
		snapshot_dir=$(ls -1d "$BACKUP_DIR"/????-??-??_??-??-?? 2>/dev/null | sort -r | head -1)
	fi

	# Fall back to legacy flat layout
	if [ -z "$snapshot_dir" ] || [ ! -d "$snapshot_dir" ]; then
		if [ -f "$BACKUP_DIR/timestamp" ]; then
			snapshot_dir="$BACKUP_DIR"
		else
			error_exit "No backup found at $BACKUP_DIR"
		fi
	fi

	local data_mount
	if [ -f "$snapshot_dir/data_volume_path" ]; then
		data_mount=$(cat "$snapshot_dir/data_volume_path")
		if [ ! -d "$data_mount/private/var" ]; then
			warn "Saved path unavailable — re-detecting..."
			data_mount=$(resolve_data_volume)
		fi
	else
		data_mount=$(resolve_data_volume)
	fi

	local ts
	ts=$(cat "$snapshot_dir/timestamp" 2>/dev/null || echo "unknown")
	step "Restoring from backup ($ts)"
	echo -e "${YEL}Target: $data_mount${NC}"

	# Hosts
	if [ -f "$snapshot_dir/hosts.backup" ]; then
		cp "$snapshot_dir/hosts.backup" "$data_mount/private/etc/hosts"
		success "hosts restored"
	fi

	# Configuration profiles
	if [ -d "$snapshot_dir/ConfigurationProfiles" ]; then
		local cfg="$data_mount/private/var/db/ConfigurationProfiles/Settings"
		mkdir -p "$cfg"
		cp -r "$snapshot_dir/ConfigurationProfiles/"* "$cfg/" 2>/dev/null || true
		success "config profiles restored"
	fi

	# Launchd override
	if [ -f "$snapshot_dir/launchd/disabled.plist.backup" ]; then
		local ldp="$data_mount/private/var/db/com.apple.xpc.launchd/disabled.plist"
		mkdir -p "$(dirname "$ldp")"
		cp "$snapshot_dir/launchd/disabled.plist.backup" "$ldp"
		success "launchd override restored"
	fi

	# pf.conf
	local pf_root=""
	[ -n "$data_mount" ] && pf_root="$data_mount"
	if [ -f "$snapshot_dir/pf/pf.conf.backup" ]; then
		cp "$snapshot_dir/pf/pf.conf.backup" "${pf_root}/etc/pf.conf"
		success "pf.conf restored"
	fi

	# pf anchors
	if [ -d "$snapshot_dir/pf/anchors" ]; then
		local anchor_dir="${pf_root}/etc/pf.anchors"
		mkdir -p "$anchor_dir"
		cp -r "$snapshot_dir/pf/anchors/"* "$anchor_dir/" 2>/dev/null || true
		success "pf anchors restored"
	fi

	success "Restore complete"
}

backup_list() {
	header "Available Backups"
	local found=0

	if [ -d "$BACKUP_DIR" ]; then
		local snapshot
		for snapshot in $(ls -1d "$BACKUP_DIR"/????-??-??_??-??-?? 2>/dev/null | sort -r); do
			[ -d "$snapshot" ] || continue
			local ts
			ts=$(cat "$snapshot/timestamp" 2>/dev/null || basename "$snapshot")
			local vol
			vol=$(cat "$snapshot/data_volume_path" 2>/dev/null || echo "unknown")
			local file_count=0
			file_count=$(find "$snapshot" -type f 2>/dev/null | wc -l | tr -d ' ')
			echo -e "  ${GRN}$ts${NC}  volume=$vol  files=$file_count"
			found=$((found + 1))
		done
	fi

	# Check legacy flat layout
	if [ -f "$BACKUP_DIR/timestamp" ] && [ "$found" -eq 0 ]; then
		local ts
		ts=$(cat "$BACKUP_DIR/timestamp")
		echo -e "  ${YEL}$ts${NC}  (legacy format)"
		found=1
	fi

	if [ "$found" -eq 0 ]; then
		info "No backups found"
	else
		info "$found backup(s) found"
	fi
}

backup_rotate() {
	local max="${BACKUP_RETENTION:-5}"
	local snapshots
	snapshots=$(ls -1d "$BACKUP_DIR"/????-??-??_??-??-?? 2>/dev/null | sort -r)
	local count=0
	for snapshot in $snapshots; do
		count=$((count + 1))
		if [ "$count" -gt "$max" ]; then
			debug "Rotating old backup: $snapshot"
			rm -rf "$snapshot"
		fi
	done
}

has_backup() {
	# Check for timestamped snapshots first
	if [ -d "$BACKUP_DIR" ]; then
		local latest
		latest=$(ls -1d "$BACKUP_DIR"/????-??-??_??-??-?? 2>/dev/null | sort -r | head -1)
		[ -n "$latest" ] && [ -d "$latest" ] && return 0
	fi
	# Fall back to legacy
	[ -f "$BACKUP_DIR/timestamp" ]
}
