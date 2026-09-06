
harden_live_os() {
	step "Removing residual MDM profiles..."
	if command -v profiles &>/dev/null; then
		local installed
		installed=$(profiles -C -output=xml 2>/dev/null | grep -c "ProfileDisplayName" || true)
		if [ "$installed" -gt 0 ]; then
			sudo profiles -D -F 2>/dev/null && success "Forced profile removal" \
				|| warn "Profile removal failed"
		else
			info "No installed profiles to remove"
		fi
	else
		warn "profiles command not available"
	fi

	step "Resetting DEP cloud configuration markers..."
	local cfg="/private/var/db/ConfigurationProfiles/Settings"
	if [ -d "$cfg" ]; then
		sudo rm -f "$cfg/.cloudConfigHasActivationRecord" \
		      "$cfg/.cloudConfigRecordFound" \
		      "$cfg/.cloudConfigTimerCheck" \
		      "$cfg/.cloudConfigProfileInstalled" \
		      "$cfg/com.apple.mdm.depnag.plist" \
		      "$cfg/com.apple.mdm.prelogin.plist" 2>/dev/null || true
		sudo touch "$cfg/.cloudConfigRecordNotFound" 2>/dev/null || true
		if [ -f "$cfg/.cloudConfigRecordFound" ]; then
			info "Active System Integrity Protection (SIP) protects .cloudConfigRecordFound from live deletion."
			info "To delete the on-disk file record, boot into Recovery and run: ./unleash recovery"
		else
			success "DEP cached records cleared; bypass markers set"
		fi
	else
		info "No DEP configuration markers found"
	fi

	step "Disabling enrollment daemons in launchd overrides..."
	local ldp="/private/var/db/com.apple.xpc.launchd/disabled.plist"
	local pb="/usr/libexec/PlistBuddy"
	if [ -x "$pb" ]; then
		sudo mkdir -p "$(dirname "$ldp")" 2>/dev/null || true
		if [ ! -f "$ldp" ]; then
			printf '<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0"><dict/></plist>\n' | sudo tee "$ldp" >/dev/null 2>&1 || true
		fi
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
			sudo "$pb" -c "Add :$label bool true" "$ldp" 2>/dev/null \
				|| sudo "$pb" -c "Set :$label true" "$ldp" 2>/dev/null || true
		done
		success "Enrollment daemons disabled in launchd overrides"
	fi

	step "Cleaning user LaunchAgents..."
	local home
	for home in /Users/*/; do
		[ -d "$home/Library/LaunchAgents" ] || continue
		local cleaned=0
		for agent in "$home/Library/LaunchAgents/"*; do
			[ -f "$agent" ] || continue
			if grep -qiE "(mdm|enrollment|managedclient|depnotify)" "$agent" 2>/dev/null; then
				rm -f "$agent"
				cleaned=$((cleaned + 1))
			fi
		done
		[ "$cleaned" -gt 0 ] && success "$(basename "$home"): removed $cleaned agent(s)" \
			|| info "$(basename "$home"): clean"
	done

	step "Flushing DNS cache..."
	if command -v dscacheutil &>/dev/null; then
		sudo dscacheutil -flushcache && success "DNS cache flushed"
	fi
	if command -v killall &>/dev/null; then
		sudo killall -HUP mDNSResponder 2>/dev/null && success "mDNSResponder restarted" || true
	fi

	step "Checking for MDM keychain items..."
	if command -v security &>/dev/null; then
		local identities
		identities=$(sudo security find-identity -p basic 2>/dev/null | grep -ci mdm || true)
		if [ "$identities" -gt 0 ]; then
			warn "$identities MDM-related identity(ies) found in keychain"
			warn "Manual review recommended: security find-identity -p basic | grep -i mdm"
		else
			info "No MDM identities found in keychain"
		fi
	else
		warn "security command not available"
	fi

	step "Checking for JAMF/Intune/Workspace ONE agents..."
	for agent_bin in /usr/local/bin/jamf /usr/local/bin/intune /opt/cisco/anyconnect/bin/*; do
		if [ -f "$agent_bin" ]; then
			warn "MDM agent binary found: $agent_bin"
		fi
	done

	step "Disabling iCloud Private Relay (DoH source)..."
	if command -v defaults &>/dev/null; then
		sudo defaults write /Library/Preferences/com.apple.networkextensions.plist PrivateRelayEnabled -bool false 2>/dev/null \
			&& success "Private Relay disabled" \
			|| info "Private Relay not configurable (expected on some configs)"
	fi

	step "Ensuring packet filter (pf) firewall is active..."
	if [ -f "/etc/pf.conf" ] && grep -q "com.unleash" "/etc/pf.conf" 2>/dev/null; then
		if command -v pfctl &>/dev/null; then
			sudo pfctl -e -f /etc/pf.conf 2>/dev/null && success "PF firewall re-loaded and active" \
				|| info "PF status unchanged"
		fi
	fi

	step "Terminating MDM daemons and processes..."
	local mdm_services=(
		"com.apple.ManagedClient"
		"com.apple.ManagedClient.enroll"
		"com.apple.ManagedClient.cloudConfiguration"
		"com.apple.ManagedClientAgent"
		"com.apple.ManagedClientAgent.agent"
		"com.apple.mdmclient"
		"com.apple.mdmclient.daemon"
		"com.apple.mdmclient.daemon.runatboot"
		"com.apple.mdmclient.agent"
	)

	if command -v launchctl &>/dev/null; then
		local console_uid
		console_uid=$(stat -f "%u" /dev/console 2>/dev/null || echo "501")
		for svc in "${mdm_services[@]}"; do
			sudo launchctl bootout "system/$svc" 2>/dev/null || true
			sudo launchctl kill SIGKILL "system/$svc" 2>/dev/null || true
			sudo launchctl disable "system/$svc" 2>/dev/null || true

			sudo launchctl bootout "gui/$console_uid/$svc" 2>/dev/null || true
			sudo launchctl kill SIGKILL "gui/$console_uid/$svc" 2>/dev/null || true
			sudo launchctl disable "gui/$console_uid/$svc" 2>/dev/null || true
		done
	fi

	for p in ManagedClient mdmclient; do
		if pgrep -fi "$p" >/dev/null 2>&1; then
			sudo pkill -9 -fi "$p" 2>/dev/null || true
		fi
	done
	sleep 0.2
	if pgrep -fi "ManagedClient|mdmclient" >/dev/null 2>&1; then
		sudo pkill -9 -fi "ManagedClient" 2>/dev/null || true
		sudo pkill -9 -fi "mdmclient" 2>/dev/null || true
	fi
	if pgrep -fi "ManagedClient|mdmclient" >/dev/null 2>&1; then
		warn "Some MDM processes still running"
	else
		success "All MDM daemons terminated"
	fi

	echo ""
	echo -e "${GRN}============================================${NC}"
	echo -e "${GRN}      Live-OS Hardening Complete             ${NC}"
	echo -e "${GRN}============================================${NC}"
	echo ""
	echo -e "${YEL}Reboot recommended to verify all changes.${NC}"
	echo -e "${YEL}For per-app blocking: install Little Snitch or LuLu.${NC}"
}

harden_status() {
	step "System extension status..."
	if command -v systemextensionsctl &>/dev/null; then
		systemextensionsctl list 2>/dev/null | head -20 || true
	else
		info "systemextensionsctl not available"
	fi

	step "MDM-related LaunchDaemons loaded..."
	launchctl list 2>/dev/null | grep -iE "mdm|managedclient" || info "None loaded"

	step "Running MDM processes..."
	ps aux 2>/dev/null | grep -iE "(ManagedClient\.app|/mdmclient|com\.apple\.ManagedClient)" | grep -v grep || info "None running"
}
