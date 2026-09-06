

PB=/usr/libexec/PlistBuddy

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
			warn "Could not remove .cloudConfigRecordFound at $cfg (check if volume is mounted read-only)"
			return 1
		else
			info "Active System Integrity Protection (SIP) protects .cloudConfigRecordFound from live deletion."
			info "To delete the on-disk file record, boot into Recovery and run: ./unleash recovery"
			return 0
		fi
	else
		success "DEP activation record (.cloudConfigRecordFound) erased from disk"
		return 0
	fi
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

	local hosts="$data_mount/private/etc/hosts"
	local cfg="$data_mount/private/var/db/ConfigurationProfiles/Settings"
	local ldp="$data_mount/private/var/db/com.apple.xpc.launchd/disabled.plist"
	local setupdone="$data_mount/private/var/db/.AppleSetupDone"

	step "Reading DEP activation record..."
	local mdm_host="" org=""
	if [ -f "$cfg/.cloudConfigRecordFound" ]; then
		mdm_host=$(plutil -convert xml1 -o - "$cfg/.cloudConfigRecordFound" 2>/dev/null \
			| grep -ioE 'https?://[a-z0-9._-]+' | sed -E 's#https?://##' \
			| sort -u | grep -viE '(^|\.)apple\.com$' | head -1 || true)
		org=$(plutil -convert xml1 -o - "$cfg/.cloudConfigRecordFound" 2>/dev/null \
			| grep -iA1 OrganizationName | tail -1 | sed -E 's/.*<string>(.*)<\/string>.*/\1/' || true)
		[ -n "$org" ] && info "Device assigned in ABM to: $org"
		[ -n "$mdm_host" ] && info "Org MDM host: $mdm_host"
	else
		info "No DEP activation record present."
	fi

	step "Blocking enrollment domains (Data volume hosts)..."
	[ -f "$hosts" ] || { mkdir -p "$(dirname "$hosts")"; touch "$hosts"; }
	grep -q "Added by unleash" "$hosts" 2>/dev/null || {
		echo "" >>"$hosts"
		echo "# Added by unleash — DEP enrollment block" >>"$hosts"
	}

	local domains=(
		iprofiles.apple.com
		deviceenrollment.apple.com
		mdmenrollment.apple.com
		acmdm.apple.com
		axm-adm-mdm.apple.com
		albert.apple.com
		gdmf.apple.com
		ax.init-content.apple.com
		init-content.apple.com
		configuration.apple.com
		xp.apple.com
		gs.apple.com
		tb.apple.com
		vpp.itunes.apple.com
	)
	[ -n "$mdm_host" ] && domains+=("$mdm_host")

	local d
	for d in "${domains[@]}"; do
		grep -qiE "[[:space:]]$d(\$|[[:space:]])" "$hosts" 2>/dev/null \
			&& { info "$d already blocked"; continue; }
		printf '0.0.0.0 %s\n::      %s\n' "$d" "$d" >>"$hosts"
		success "blocked $d"
	done

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
	mkdir -p "$(dirname "$ldp")"
	[ -f "$ldp" ] || printf '<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0"><dict/></plist>\n' >"$ldp"
	local disabled_count=0
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
		$PB -c "Add :$label bool true" "$ldp" 2>/dev/null \
			|| $PB -c "Set :$label true" "$ldp" 2>/dev/null || true
		info "disabled $label"
		disabled_count=$((disabled_count + 1))
	done
	success "Enrollment daemons disabled ($disabled_count overrides)"

	touch "$setupdone" 2>/dev/null || true
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
	echo -e "${CYAN}╔══════════════════════════════════════════════════════════╗${NC}"
	echo -e "${CYAN}║         Unleash Auto-Recovery & DEP Eradication          ║${NC}"
	echo -e "${CYAN}╚══════════════════════════════════════════════════════════╝${NC}"
	echo ""

	# Ensure target filesystem is mounted read-write
	if [ -n "$data_mount" ] && [ "$data_mount" != "/" ]; then
		mount -uw "$data_mount" 2>/dev/null || true
	fi

	# Run complete suppression (reads org, blocks domains, wipes DEP files, disables daemons, cleans artifacts)
	suppress_enrollment "$data_mount"

	echo ""
	echo -e "${GRN}============================================================${NC}"
	echo -e "${GRN}       DEP Eradication & MDM Suppression Complete           ${NC}"
	echo -e "${GRN}============================================================${NC}"
	echo ""
	echo -e "  ${GRN}✔${NC} .cloudConfigRecordFound erased from disk"
	echo -e "  ${GRN}✔${NC} MDM enrollment domains sinkholed in /etc/hosts"
	echo -e "  ${GRN}✔${NC} Enrollment daemons disabled in launchd overrides"
	echo -e "  ${GRN}✔${NC} Setup Assistant cloud-check suppressed (.AppleSetupDone)"
	echo -e "  ${GRN}✔${NC} User accounts and personal data preserved intact"
	echo ""
	echo -e "${CYAN}Your Mac is now ready to reboot normally.${NC}"
	echo ""

	if [ -t 0 ] && confirm "Reboot now?"; then
		info "Rebooting into normal macOS..."
		reboot
	fi
}

