PB=/usr/libexec/PlistBuddy

# Overlay callers may not load result.sh; pipeline always does.
if ! type result_ok >/dev/null 2>&1; then
	result_ok() { return 0; }
	result_skip() { return 0; }
	result_fail() { return 0; }
fi

wipe_dep_records() {
	local data_mount="${1:-}"
	local cfg="${data_mount}/private/var/db/ConfigurationProfiles/Settings"
	local store="${data_mount}/private/var/db/ConfigurationProfiles/Store"
	local cp="${data_mount}/private/var/db/ConfigurationProfiles"

	if [ "$DRY_RUN" = true ]; then
		info "[DRY RUN] Would wipe all DEP markers and profile cache in $cfg"
		return 0
	fi

	step "Wiping DEP activation records and profile cache..."
	mkdir -p "$cfg" 2>/dev/null || true

	# Clear file flags (immutable/restricted locks) if present
	chflags -R noschg,nouchg "$cp" 2>/dev/null || true

	# Erase all cloud config artifacts, enrollment plists, and profile flags
	rm -rf "$cfg/.cloudConfig"* 2>/dev/null || true
	rm -rf "$cfg/com.apple.mdm"* 2>/dev/null || true
	rm -f "$cfg/.profilesAreInstalled" "$cfg/.mcxFlagFileEvaluated" 2>/dev/null || true
	rm -f "$cp/.profilesAreInstalled" 2>/dev/null || true
	rm -rf "$store"/* 2>/dev/null || true

	# Set the bypass marker
	touch "$cfg/.cloudConfigRecordNotFound" 2>/dev/null || true

	if [ -f "$cfg/.cloudConfigRecordFound" ]; then
		if is_recovery; then
			result_fail E_PLIST_FAIL suppress dep_wipe "Could not remove .cloudConfigRecordFound at $cfg"
			return 0
		fi
		result_skip S_SIP_LIVE suppress dep_wipe "DEP file remains under SIP; boot Recovery to wipe on-disk record"
		return 0
	fi
	result_ok suppress dep_wipe "DEP activation record erased from disk"
	return 0
}

_suppress_mdm_domains() {
	printf '%s\n' \
		iprofiles.apple.com \
		deviceenrollment.apple.com \
		mdmenrollment.apple.com \
		acmdm.apple.com \
		axm-adm-mdm.apple.com \
		albert.apple.com \
		gdmf.apple.com \
		ax.init-content.apple.com \
		init-content.apple.com \
		configuration.apple.com \
		xp.apple.com \
		gs.apple.com \
		tb.apple.com \
		vpp.itunes.apple.com
}

# Hosts sinkhole only. Pipeline journals this as step hosts.
suppress_hosts() {
	local data_mount="$1"
	local hosts="$data_mount/private/etc/hosts"
	local cfg="$data_mount/private/var/db/ConfigurationProfiles/Settings"
	local mdm_host="" d

	if [ "${UNLEASH_DRY_RUN:-0}" = 1 ] || [ "${DRY_RUN:-false}" = true ]; then
		info "[DRY RUN] Would block MDM domains in $hosts"
		result_ok suppress hosts "dry-run"
		return 0
	fi

	if [ -f "$cfg/.cloudConfigRecordFound" ]; then
		mdm_host=$(plutil -convert xml1 -o - "$cfg/.cloudConfigRecordFound" 2>/dev/null \
			| grep -ioE 'https?://[a-z0-9._-]+' | sed -E 's#https?://##' \
			| sort -u | grep -viE '(^|\.)apple\.com$' | head -1 || true)
	fi

	mkdir -p "$(dirname "$hosts")" || {
		result_fail E_HOSTS_PERM suppress hosts "cannot create $(dirname "$hosts")"
		return 0
	}
	[ -f "$hosts" ] || touch "$hosts" || {
		result_fail E_HOSTS_PERM suppress hosts "cannot create $hosts"
		return 0
	}
	grep -q "Added by unleash" "$hosts" 2>/dev/null || {
		printf '\n# Added by unleash — DEP enrollment block\n' >>"$hosts" || {
			result_fail E_HOSTS_PERM suppress hosts "cannot write $hosts"
			return 0
		}
	}

	while IFS= read -r d || [ -n "$d" ]; do
		[ -n "$d" ] || continue
		grep -qiE "[[:space:]]$d(\$|[[:space:]])" "$hosts" 2>/dev/null && continue
		printf '0.0.0.0 %s\n::      %s\n' "$d" "$d" >>"$hosts" || {
			result_fail E_HOSTS_PERM suppress hosts "cannot write $hosts"
			return 0
		}
	done <<EOF
$(_suppress_mdm_domains)
${mdm_host}
EOF

	result_ok suppress hosts "MDM domains sinkholed in $hosts"
	return 0
}

# disabled.plist overrides. PlistBuddy failure is a hard fail (rollback, exit 1).
suppress_daemons() {
	local data_mount="$1"
	local ldp="$data_mount/private/var/db/com.apple.xpc.launchd/disabled.plist"
	local setupdone="$data_mount/private/var/db/.AppleSetupDone"
	local pb="${PLISTBUDDY:-${PB:-/usr/libexec/PlistBuddy}}"
	local label ok disabled_count=0

	if [ "${UNLEASH_DRY_RUN:-0}" = 1 ] || [ "${DRY_RUN:-false}" = true ]; then
		info "[DRY RUN] Would disable enrollment daemons in $ldp"
		result_ok suppress daemons "dry-run"
		return 0
	fi

	mkdir -p "$(dirname "$ldp")" || {
		result_fail E_PLIST_FAIL suppress daemons "cannot create $(dirname "$ldp")"
		return 0
	}
	[ -f "$ldp" ] || printf '<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0"><dict/></plist>\n' >"$ldp" || {
		result_fail E_PLIST_FAIL suppress daemons "cannot create $ldp"
		return 0
	}

	for label in \
		com.apple.ManagedClient \
		com.apple.ManagedClient.enroll \
		com.apple.ManagedClient.cloudConfiguration \
		com.apple.ManagedClientAgent \
		com.apple.ManagedClientAgent.agent \
		com.apple.mdmclient \
		com.apple.mdmclient.daemon \
		com.apple.mdmclient.daemon.runatboot \
		com.apple.mdmclient.agent \
		com.apple.activationd; do
		ok=0
		if "$pb" -c "Add :$label bool true" "$ldp" 2>/dev/null; then
			ok=1
		elif "$pb" -c "Set :$label true" "$ldp"; then
			ok=1
		fi
		if [ "$ok" -eq 0 ]; then
			result_fail E_PLIST_FAIL suppress daemons "PlistBuddy failed for $label on $ldp"
			return 0
		fi
		disabled_count=$((disabled_count + 1))
	done

	touch "$setupdone" 2>/dev/null || true
	result_ok suppress daemons "Enrollment daemons disabled ($disabled_count overrides)"
	return 0
}

suppress_enrollment() {
	local data_mount="$1"

	if [ "$DRY_RUN" = true ]; then
		info "[DRY RUN] Would suppress MDM enrollment on $data_mount"
		info "[DRY RUN]   - Clear DEP markers in ConfigurationProfiles/Settings"
		info "[DRY RUN]   - Block 13+ Apple MDM domains in /etc/hosts"
		info "[DRY RUN]   - Disable 4 enrollment daemons in launchd disabled.plist"
		info "[DRY RUN]   - Clean MDM artifacts from /Users/*/Library"
		return 0
	fi

	local cfg="$data_mount/private/var/db/ConfigurationProfiles/Settings"

	step "Reading DEP activation record..."
	local org=""
	if [ -f "$cfg/.cloudConfigRecordFound" ]; then
		org=$(plutil -convert xml1 -o - "$cfg/.cloudConfigRecordFound" 2>/dev/null \
			| grep -iA1 OrganizationName | tail -1 | sed -E 's/.*<string>(.*)<\/string>.*/\1/' || true)
		[ -n "$org" ] && info "Device assigned in ABM to: $org"
	else
		info "No DEP activation record present."
	fi

	step "Blocking enrollment domains (Data volume hosts)..."
	suppress_hosts "$data_mount"

	step "Resetting DEP markers..."
	wipe_dep_records "$data_mount"

	step "Cleaning user-level MDM artifacts..."
	local home
	for home in "$data_mount/Users/"*/; do
		[ -d "$home/Library" ] || continue
		local user
		user=$(basename "$home")
		info "Cleaning: $user"
		rm -rf "$home/Library/Preferences/com.apple.mdm"* 2>/dev/null || true
		rm -rf "$home/Library/Preferences/com.apple.ManagedClient"* 2>/dev/null || true
		rm -rf "$home/Library/Application Support/com.apple.ManagedClient"* 2>/dev/null || true
		rm -rf "$home/Library/LaunchAgents/com.apple.mdm"* 2>/dev/null || true
		for agent in "$home/Library/LaunchAgents/"*; do
			[ -f "$agent" ] || continue
			if grep -qi mdm "$agent" 2>/dev/null || grep -qi enrollment "$agent" 2>/dev/null; then
				rm -f "$agent"
				info "  removed LaunchAgent: $(basename "$agent")"
			fi
		done
	done
	success "User-level MDM artifacts removed"

	step "Disabling enrollment daemons..."
	suppress_daemons "$data_mount"
}

suppress_only_mode() {
	local data_mount="$1"
	echo ""
	info "Suppress-only mode: no user will be created."
	suppress_enrollment "$data_mount"
	echo ""
	echo -e "${GRN}============================================${NC}"
	echo -e "${GRN}     Enrollment Suppressed                   ${NC}"
	echo -e "${GRN}============================================${NC}"
	echo ""
	echo -e "${CYAN}Reboot to apply.${NC}"
	echo -e "${YEL}After a macOS update: re-run.${NC}"
	echo -e "${YEL}Never run 'profiles renew' or Erase All Content & Settings.${NC}"
}

full_bypass_mode() {
	local data_mount="$1"

	if [ "$DRY_RUN" = true ]; then
		info "[DRY RUN] Would perform full MDM bypass on $data_mount"
		info "[DRY RUN]   - Create admin user"
		info "[DRY RUN]   - Skip Setup Assistant (.AppleSetupDone)"
		info "[DRY RUN]   - Then run suppress_enrollment"
		return 0
	fi

	local node
	node=$(dscl_node "$data_mount")

	echo ""
	step "Creating temporary admin account"

	prompt_default realName "Full name" "Apple"

	local username
	while true; do
		prompt_username username
		if check_user_exists "$node" "$username"; then
			warn "User '$username' already exists."
			if confirm "Delete and recreate?"; then
				delete_user "$node" "$data_mount" "$username"
				break
			else
				echo -e "${YEL}Choose a different username.${NC}"
			fi
		else
			break
		fi
	done

	local passw
	prompt_password passw

	local uid
	uid=$(find_available_uid "$node")
	info "Using UID $uid"

	create_admin_user "$node" "$data_mount" "$username" "$realName" "$passw" "$uid"

	touch "$data_mount/private/var/db/.AppleSetupDone"
	success "Setup Assistant will be skipped"

	add_to_filevault "$username"

	suppress_enrollment "$data_mount"

	echo ""
	echo -e "${GRN}============================================${NC}"
	echo -e "${GRN}      MDM Bypass Complete                     ${NC}"
	echo -e "${GRN}============================================${NC}"
	echo ""
	echo -e "${CYAN}Login:${NC} ${YEL}$username${NC} / ${YEL}$passw${NC}"
	echo -e "${YEL}After macOS update: re-run. Never 'profiles renew'.${NC}"
}

auto_recovery_mode() {
	local data_mount="${1:-}"
	if [ -z "$data_mount" ]; then
		if is_recovery; then
			data_mount=$(resolve_data_volume)
		else
			data_mount="/"
		fi
	fi

	if [ "$DRY_RUN" = true ]; then
		info "[DRY RUN] Would execute auto-recovery DEP wipe and suppression on $data_mount"
		return 0
	fi

	echo ""
	info "Auto-recovery: wipe DEP records and apply suppression on $data_mount"
	echo ""

	# Ensure target filesystem is mounted read-write
	if [ -n "$data_mount" ] && [ "$data_mount" != "/" ]; then
		mount -uw "$data_mount" 2>/dev/null || true
	fi

	# Run complete suppression (reads org, blocks domains, wipes DEP files, disables daemons, cleans artifacts)
	suppress_enrollment "$data_mount"

	echo ""
	info "Suppression applied on $data_mount. Verify with: ./unleash status"
	echo ""

	if [ -t 0 ] && confirm "Reboot now?"; then
		info "Rebooting into normal macOS..."
		reboot
	fi
}

