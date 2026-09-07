# shellcheck shell=bash

BACKUP_RETENTION=5
SNAPSHOT_ID="${SNAPSHOT_ID:-}"
# Empty unless tests/callers override. Default path is computed by _snapshot_root.
BACKUP_DIR="${BACKUP_DIR:-}"

# BACKUP_DIR override (tests / callers). Default is $DATA/Library/Unleash/state/snapshots.
_snapshot_root() {
	if [ -n "${BACKUP_DIR:-}" ]; then
		printf '%s\n' "$BACKUP_DIR"
	else
		printf '%s\n' "$(unleash_root)/state/snapshots"
	fi
}

_legacy_backup_dir() {
	printf '%s\n' "${SCRIPT_DIR:-.}/.unleash-backup"
}

_backup_available_kb() {
	local mount="$1"
	"${DF:-/bin/df}" -k "$mount" | awk 'NR==2 {print $4; exit}'
}

# Unattended / non-TTY: fail closed. Interactive TTY may confirm.
check_disk_space() {
	local data_mount="$1"
	local needed_kb=10240
	local available_kb
	available_kb=$(_backup_available_kb "$data_mount")
	available_kb="${available_kb%%[$'\n\r']*}"
	case "$available_kb" in
		''|*[!0-9]*)
			if [ "${UNLEASH_UNATTENDED:-0}" = 1 ] || [ ! -t 0 ]; then
				result_fail E_DISK_FULL backup disk "cannot determine free space on ${data_mount}"
				return 1
			fi
			return 0
			;;
	esac
	if [ "$available_kb" -lt "$needed_kb" ]; then
		if [ "${UNLEASH_UNATTENDED:-0}" = 1 ] || [ ! -t 0 ]; then
			result_fail E_DISK_FULL backup disk "less than 10 MiB free on ${data_mount}"
			return 1
		fi
		warn "Low disk space: $(echo "$available_kb" | awk '{printf "%.0f MB", $1/1024}') available"
		printf 'Continue anyway? [y/N] ' >&2
		read -r answer
		if [ "$answer" != "y" ] && [ "$answer" != "Y" ]; then
			result_fail E_DISK_FULL backup disk "aborted: low disk space"
			return 1
		fi
	fi
	return 0
}

_backup_timestamp() {
	date +%Y-%m-%d_%H-%M-%S
}

_snapshot_dir_for() {
	local id="$1"
	local root legacy
	if [ -n "$id" ] && [ -d "$id" ]; then
		printf '%s\n' "$id"
		return 0
	fi
	root=$(_snapshot_root)
	if [ -n "$id" ] && [ -d "${root}/${id}" ]; then
		printf '%s\n' "${root}/${id}"
		return 0
	fi
	legacy=$(_legacy_backup_dir)
	if [ -n "$id" ] && [ -d "${legacy}/${id}" ]; then
		printf '%s\n' "${legacy}/${id}"
		return 0
	fi
	return 1
}

_snapshot_fail() {
	local dir="$1"
	local msg="$2"
	rm -rf "$dir"
	result_fail E_DISK_FULL backup snapshot "$msg"
}

_backup_find_pf_conf() {
	local root="$1"
	if [ -f "$root/private/etc/pf.conf" ]; then
		printf '%s\n' "$root/private/etc/pf.conf"
	elif [ -f "$root/etc/pf.conf" ]; then
		printf '%s\n' "$root/etc/pf.conf"
	fi
}

_backup_find_pf_anchors() {
	local root="$1"
	if [ -d "$root/private/etc/pf.anchors" ]; then
		printf '%s\n' "$root/private/etc/pf.anchors"
	elif [ -d "$root/etc/pf.anchors" ]; then
		printf '%s\n' "$root/etc/pf.anchors"
	fi
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
	local f name size cksum
	for f in "$backup_path"/*; do
		[ -f "$f" ] || continue
		name=$(basename "$f")
		[ "$name" = "manifest.json" ] && continue
		size=$(wc -c < "$f" | tr -d ' ')
		if command -v shasum >/dev/null 2>&1; then
			cksum=$(shasum -a 256 "$f" | awk '{print $1}')
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
	local ts snapshot_dir cfg_src ldp_src pf_conf anchor_dir anchor copied_anchor

	check_disk_space "$data_mount" || return 1

	ts=$(_backup_timestamp)
	snapshot_dir="$(_snapshot_root)/${ts}"
	mkdir -p "$snapshot_dir" || {
		result_fail E_DISK_FULL backup snapshot "cannot create $snapshot_dir"
		return 1
	}
	step "Saving backup to $snapshot_dir"

	if [ -f "$data_mount/private/etc/hosts" ]; then
		cp "$data_mount/private/etc/hosts" "$snapshot_dir/hosts.backup" || {
			_snapshot_fail "$snapshot_dir" "copy hosts failed"
			return 1
		}
		success "hosts saved"
	fi

	cfg_src="$data_mount/private/var/db/ConfigurationProfiles/Settings"
	if [ -d "$cfg_src" ]; then
		mkdir -p "$snapshot_dir/ConfigurationProfiles" || {
			_snapshot_fail "$snapshot_dir" "mkdir ConfigurationProfiles failed"
			return 1
		}
		# Include dotfiles (.cloudConfigRecordFound); snapshot is DEP rollback source of truth.
		cp -R "$cfg_src/." "$snapshot_dir/ConfigurationProfiles/" || {
			_snapshot_fail "$snapshot_dir" "copy DEP dir failed"
			return 1
		}
		success "config profiles saved"
	fi

	ldp_src="$data_mount/private/var/db/com.apple.xpc.launchd/disabled.plist"
	if [ -f "$ldp_src" ]; then
		mkdir -p "$snapshot_dir/launchd" || {
			_snapshot_fail "$snapshot_dir" "mkdir launchd failed"
			return 1
		}
		cp "$ldp_src" "$snapshot_dir/launchd/disabled.plist.backup" || {
			_snapshot_fail "$snapshot_dir" "copy disabled.plist failed"
			return 1
		}
		success "launchd override saved"
	fi

	pf_conf=$(_backup_find_pf_conf "$data_mount")
	if [ -n "$pf_conf" ] && [ -f "$pf_conf" ]; then
		mkdir -p "$snapshot_dir/pf" || {
			_snapshot_fail "$snapshot_dir" "mkdir pf failed"
			return 1
		}
		cp "$pf_conf" "$snapshot_dir/pf/pf.conf.backup" || {
			_snapshot_fail "$snapshot_dir" "copy pf.conf failed"
			return 1
		}
		if [ "$pf_conf" = "$data_mount/private/etc/pf.conf" ]; then
			printf '%s\n' "private/etc/pf.conf" > "$snapshot_dir/pf/dest"
		else
			printf '%s\n' "etc/pf.conf" > "$snapshot_dir/pf/dest"
		fi
		success "pf.conf saved"
	fi

	anchor_dir=$(_backup_find_pf_anchors "$data_mount")
	if [ -n "$anchor_dir" ] && [ -d "$anchor_dir" ]; then
		copied_anchor=0
		for anchor in "$anchor_dir"/com.unleash*; do
			[ -e "$anchor" ] || continue
			mkdir -p "$snapshot_dir/pf/anchors" || {
				_snapshot_fail "$snapshot_dir" "mkdir pf anchors failed"
				return 1
			}
			cp -R "$anchor" "$snapshot_dir/pf/anchors/" || {
				_snapshot_fail "$snapshot_dir" "copy pf anchor failed"
				return 1
			}
			copied_anchor=1
		done
		if [ -d "$anchor_dir/com.unleash" ]; then
			mkdir -p "$snapshot_dir/pf/anchors/com.unleash" || {
				_snapshot_fail "$snapshot_dir" "mkdir pf anchor com.unleash failed"
				return 1
			}
			cp -R "$anchor_dir/com.unleash/." "$snapshot_dir/pf/anchors/com.unleash/" || {
				_snapshot_fail "$snapshot_dir" "copy pf anchor tree failed"
				return 1
			}
			copied_anchor=1
		fi
		if [ "$copied_anchor" -eq 1 ]; then
			mkdir -p "$snapshot_dir/pf" || {
				_snapshot_fail "$snapshot_dir" "mkdir pf failed"
				return 1
			}
			if [ "$anchor_dir" = "$data_mount/private/etc/pf.anchors" ]; then
				printf '%s\n' "private/etc/pf.anchors" > "$snapshot_dir/pf/anchors_dest"
			else
				printf '%s\n' "etc/pf.anchors" > "$snapshot_dir/pf/anchors_dest"
			fi
			success "pf anchors saved"
		fi
	fi

	echo "$ts" >"$snapshot_dir/timestamp" || {
		_snapshot_fail "$snapshot_dir" "write timestamp failed"
		return 1
	}
	echo "$data_mount" >"$snapshot_dir/data_volume_path" || {
		_snapshot_fail "$snapshot_dir" "write data_volume_path failed"
		return 1
	}
	echo "$ts" >"$(_snapshot_root)/timestamp"
	echo "$data_mount" >"$(_snapshot_root)/data_volume_path"

	_generate_manifest "$snapshot_dir"

	backup_rotate

	SNAPSHOT_ID="$ts"
	success "Backup complete: $ts"
	return 0
}

rollback_hosts() {
	local snap_id="$1"
	local data_mount="$2"
	local snap dest
	snap=$(_snapshot_dir_for "$snap_id") || return 1
	[ -f "$snap/hosts.backup" ] || return 0
	dest="$data_mount/private/etc/hosts"
	mkdir -p "$(dirname "$dest")" || return 1
	cp "$snap/hosts.backup" "$dest" || return 1
	return 0
}

rollback_plist() {
	local snap_id="$1"
	local data_mount="$2"
	local snap dest
	snap=$(_snapshot_dir_for "$snap_id") || return 1
	[ -f "$snap/launchd/disabled.plist.backup" ] || return 0
	dest="$data_mount/private/var/db/com.apple.xpc.launchd/disabled.plist"
	mkdir -p "$(dirname "$dest")" || return 1
	cp "$snap/launchd/disabled.plist.backup" "$dest" || return 1
	return 0
}

rollback_dep() {
	local snap_id="$1"
	local data_mount="$2"
	local snap dest parent tmp bak
	snap=$(_snapshot_dir_for "$snap_id") || return 1
	[ -d "$snap/ConfigurationProfiles" ] || return 0
	parent="$data_mount/private/var/db/ConfigurationProfiles"
	dest="$parent/Settings"
	tmp="$parent/Settings.unleash-new.$$"
	bak="$parent/Settings.unleash-old.$$"
	mkdir -p "$parent" || return 1
	rm -rf "$tmp" "$bak"
	mkdir -p "$tmp" || return 1
	if ! "${CP:-cp}" -R "$snap/ConfigurationProfiles/." "$tmp/"; then
		rm -rf "$tmp"
		return 1
	fi
	if [ -e "$dest" ]; then
		if ! mv "$dest" "$bak"; then
			rm -rf "$tmp"
			return 1
		fi
	fi
	if ! mv "$tmp" "$dest"; then
		[ -e "$bak" ] && mv "$bak" "$dest"
		rm -rf "$tmp"
		return 1
	fi
	rm -rf "$bak"
	return 0
}

rollback_pf() {
	local snap_id="$1"
	local data_mount="$2"
	local snap dest rel anchor_dest anchor_rel
	snap=$(_snapshot_dir_for "$snap_id") || return 1
	if [ -f "$snap/pf/pf.conf.backup" ]; then
		rel=$(cat "$snap/pf/dest" 2>/dev/null || echo "etc/pf.conf")
		dest="$data_mount/$rel"
		mkdir -p "$(dirname "$dest")" || return 1
		cp "$snap/pf/pf.conf.backup" "$dest" || return 1
	fi
	if [ -d "$snap/pf/anchors" ]; then
		anchor_rel=$(cat "$snap/pf/anchors_dest" 2>/dev/null || echo "etc/pf.anchors")
		anchor_dest="$data_mount/$anchor_rel"
		mkdir -p "$anchor_dest" || return 1
		cp -R "$snap/pf/anchors/." "$anchor_dest/" || return 1
	fi
	return 0
}

restore_state() {
	local snapshot_dir=""
	local want="${UNLEASH_SNAPSHOT:-}"
	local root legacy data_mount ts

	if [ -n "$want" ]; then
		snapshot_dir=$(_snapshot_dir_for "$want") || error_exit "No backup found for snapshot $want"
	else
		root=$(_snapshot_root)
		if [ -d "$root" ]; then
			snapshot_dir=$(ls -1d "$root"/????-??-??_??-??-?? 2>/dev/null | sort -r | head -1)
		fi
		if [ -z "$snapshot_dir" ] || [ ! -d "$snapshot_dir" ]; then
			legacy=$(_legacy_backup_dir)
			if [ -d "$legacy" ]; then
				snapshot_dir=$(ls -1d "$legacy"/????-??-??_??-??-?? 2>/dev/null | sort -r | head -1)
			fi
			if [ -z "$snapshot_dir" ] || [ ! -d "$snapshot_dir" ]; then
				if [ -f "$legacy/timestamp" ]; then
					snapshot_dir="$legacy"
				elif [ -n "${BACKUP_DIR:-}" ] && [ -f "$BACKUP_DIR/timestamp" ]; then
					snapshot_dir="$BACKUP_DIR"
				else
					error_exit "No backup found at $root"
				fi
			fi
		fi
	fi

	if [ -f "$snapshot_dir/data_volume_path" ]; then
		data_mount=$(cat "$snapshot_dir/data_volume_path")
		if [ ! -d "$data_mount/private/var" ]; then
			warn "Saved path unavailable — re-detecting..."
			data_mount=$(resolve_data_volume)
		fi
	else
		data_mount=$(resolve_data_volume)
	fi

	ts=$(cat "$snapshot_dir/timestamp" 2>/dev/null || echo "unknown")
	step "Restoring from backup ($ts)"
	echo -e "${YEL}Target: $data_mount${NC}"

	if [ -f "$snapshot_dir/hosts.backup" ]; then
		rollback_hosts "$snapshot_dir" "$data_mount"
		success "hosts restored"
	fi
	if [ -d "$snapshot_dir/ConfigurationProfiles" ]; then
		rollback_dep "$snapshot_dir" "$data_mount"
		success "config profiles restored"
	fi
	if [ -f "$snapshot_dir/launchd/disabled.plist.backup" ]; then
		rollback_plist "$snapshot_dir" "$data_mount"
		success "launchd override restored"
	fi
	if [ -f "$snapshot_dir/pf/pf.conf.backup" ] || [ -d "$snapshot_dir/pf/anchors" ]; then
		rollback_pf "$snapshot_dir" "$data_mount"
		success "pf restored"
	fi

	success "Restore complete"
}

# Newest-first snapshot directories, one path per line (paths may contain spaces).
_snapshot_list_newest_first() {
	local root="$1"
	[ -d "$root" ] || return 0
	ls -1d "$root"/????-??-??_??-??-?? 2>/dev/null | sort -r
}

backup_list() {
	header "Available Backups"
	local found=0
	local root snapshot ts vol file_count legacy

	root=$(_snapshot_root)
	if [ -d "$root" ]; then
		while IFS= read -r snapshot; do
			[ -n "$snapshot" ] || continue
			[ -d "$snapshot" ] || continue
			ts=$(cat "$snapshot/timestamp" 2>/dev/null || basename "$snapshot")
			vol=$(cat "$snapshot/data_volume_path" 2>/dev/null || echo "unknown")
			file_count=$(find "$snapshot" -type f 2>/dev/null | wc -l | tr -d ' ')
			echo -e "  ${GRN}$ts${NC}  volume=$vol  files=$file_count"
			found=$((found + 1))
		done <<EOF
$(_snapshot_list_newest_first "$root")
EOF
	fi

	legacy=$(_legacy_backup_dir)
	if [ -f "$legacy/timestamp" ] && [ "$found" -eq 0 ]; then
		ts=$(cat "$legacy/timestamp")
		echo -e "  ${YEL}$ts${NC}  (legacy format)"
		found=1
	fi

	if [ -n "${BACKUP_DIR:-}" ] && [ -f "$BACKUP_DIR/timestamp" ] && [ "$found" -eq 0 ]; then
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
	local root snapshot count
	root=$(_snapshot_root)
	count=0
	while IFS= read -r snapshot; do
		[ -n "$snapshot" ] || continue
		[ -d "$snapshot" ] || continue
		count=$((count + 1))
		if [ "$count" -gt "$max" ]; then
			debug "Rotating old backup: $snapshot"
			rm -rf "$snapshot"
		fi
	done <<EOF
$(_snapshot_list_newest_first "$root")
EOF
}

has_backup() {
	local root latest legacy
	root=$(_snapshot_root)
	if [ -d "$root" ]; then
		latest=$(ls -1d "$root"/????-??-??_??-??-?? 2>/dev/null | sort -r | head -1 || true)
		[ -n "$latest" ] && [ -d "$latest" ] && return 0
	fi
	legacy=$(_legacy_backup_dir)
	[ -f "$legacy/timestamp" ] && return 0
	[ -n "${BACKUP_DIR:-}" ] && [ -f "$BACKUP_DIR/timestamp" ]
}
