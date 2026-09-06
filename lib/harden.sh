# shellcheck shell=bash
# Live-OS extra cleanup. Not default on apply (needs --harden).
# D17: profiles -D -F is data-loss; only with --remove-all-profiles.

if ! type result_ok >/dev/null 2>&1; then
	result_ok() { return 0; }
	result_skip() { return 0; }
	result_fail() { return 0; }
fi

_harden_enrollment_labels() {
	printf '%s\n' \
		com.apple.ManagedClient \
		com.apple.ManagedClient.enroll \
		com.apple.ManagedClient.cloudConfiguration \
		com.apple.ManagedClientAgent \
		com.apple.ManagedClientAgent.agent \
		com.apple.mdmclient \
		com.apple.mdmclient.daemon \
		com.apple.mdmclient.daemon.runatboot \
		com.apple.mdmclient.agent \
		com.apple.activationd
}

_harden_is_recovery() {
	if type is_recovery >/dev/null 2>&1 && is_recovery; then
		return 0
	fi
	return 1
}

_harden_dry_run() {
	[ "${UNLEASH_DRY_RUN:-0}" = 1 ] || [ "${DRY_RUN:-false}" = true ]
}

_harden_root() {
	printf '%s' "${DATA_ROOT-}"
}

# Live kernel pkill/launchctl only when targeting this OS, not a fixture/Recovery volume.
_harden_is_live_os() {
	_harden_is_recovery && return 1
	case "${DATA_ROOT:-}" in
		""|"/") return 0 ;;
	esac
	return 1
}

# $1=label. Deletes every configuration profile on the Mac. Opt-in only.
_harden_remove_all_profiles() {
	local installed
	if [ ! -x "${PROFILES:-/usr/bin/profiles}" ] && ! command -v profiles >/dev/null 2>&1; then
		info "profiles command not available; skip profile removal"
		return 0
	fi
	installed=$(profiles -C 2>/dev/null | grep -c "ProfileDisplayName" || true)
	if [ "${installed:-0}" -eq 0 ]; then
		info "No installed profiles to remove"
		return 0
	fi
	warn "Removing ALL configuration profiles ($installed). This is irreversible without a backup."
	if profiles -D -F; then
		success "Forced profile removal finished"
	else
		warn "ERROR E_PROFILES_FAIL: profiles -D -F failed. SIP or user approval may block it. Next: boot Recovery and run ./unleash apply"
	fi
}

# Fail-closed: every label must Print true. Sets RESULT_*.
_harden_disable_daemons() {
	local root ldp pb label val
	root=$(_harden_root)
	ldp="${root}/private/var/db/com.apple.xpc.launchd/disabled.plist"
	pb="${PLISTBUDDY:-/usr/libexec/PlistBuddy}"

	if [ ! -x "$pb" ]; then
		result_fail E_PLIST_FAIL harden daemons "PlistBuddy not available at $pb"
		return 0
	fi
	if ! mkdir -p "$(dirname "$ldp")"; then
		result_fail E_PLIST_FAIL harden daemons "cannot create $(dirname "$ldp")"
		return 0
	fi
	if [ ! -f "$ldp" ]; then
		if ! printf '<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0"><dict/></plist>\n' > "$ldp"; then
			result_fail E_PLIST_FAIL harden daemons "cannot create $ldp"
			return 0
		fi
	fi
	while IFS= read -r label || [ -n "$label" ]; do
		[ -n "$label" ] || continue
		"$pb" -c "Add :$label bool true" "$ldp" 2>/dev/null \
			|| "$pb" -c "Set :$label true" "$ldp" 2>/dev/null || true
		val=$("$pb" -c "Print :$label" "$ldp" 2>/dev/null || true)
		case "$val" in
			true|1) ;;
			*)
				result_fail E_PLIST_FAIL harden daemons "label $label is not true in $ldp"
				return 0
				;;
		esac
	done <<EOF
$(_harden_enrollment_labels)
EOF
	result_ok harden daemons "Enrollment daemons disabled in launchd overrides"
	success "Enrollment daemons disabled in launchd overrides"
	return 0
}

harden_live_os() {
	step "Live-OS harden"

	# Live-OS extra: Recovery ramdisk /private is not the Data volume.
	if _harden_is_recovery; then
		result_skip S_LIVE_ONLY harden live "harden is live-OS only"
		info "Skipping harden in Recovery. Next: boot macOS and sudo ./unleash harden"
		return 0
	fi

	if _harden_dry_run; then
		info "[DRY RUN] Would kill MDM agents, disable enrollment labels, flush DNS"
		if [ "${UNLEASH_REMOVE_ALL_PROFILES:-0}" = 1 ]; then
			info "[DRY RUN] Would also run profiles -D -F (deletes every profile)"
		fi
		result_ok harden dry-run "dry-run"
		return 0
	fi

	if [ "${UNLEASH_REMOVE_ALL_PROFILES:-0}" = 1 ]; then
		step "Removing all configuration profiles (--remove-all-profiles)"
		_harden_remove_all_profiles
	else
		info "Skipping profiles -D -F (deletes every profile). Pass --remove-all-profiles to opt in."
	fi

	step "Resetting DEP cloud configuration markers"
	local root cfg
	root=$(_harden_root)
	cfg="${root}/private/var/db/ConfigurationProfiles/Settings"
	if [ -d "$cfg" ]; then
		rm -f "$cfg/.cloudConfigHasActivationRecord" \
		      "$cfg/.cloudConfigRecordFound" \
		      "$cfg/.cloudConfigTimerCheck" \
		      "$cfg/.cloudConfigProfileInstalled" \
		      "$cfg/com.apple.mdm.depnag.plist" \
		      "$cfg/com.apple.mdm.prelogin.plist" 2>/dev/null || true
		touch "$cfg/.cloudConfigRecordNotFound" 2>/dev/null || true
		if [ -f "$cfg/.cloudConfigRecordFound" ]; then
			info "SIP disabled is required to delete .cloudConfigRecordFound on a live volume."
			info "SIP enabled — on-disk DEP wipe needs Recovery. Next: ./unleash recovery"
		else
			success "DEP cached records cleared; bypass markers set"
		fi
	else
		info "No DEP configuration markers found"
	fi

	step "Disabling enrollment daemons in launchd overrides"
	_harden_disable_daemons
	if [ "${RESULT_STATUS:-ok}" = "fail" ]; then
		return 0
	fi

	if ! _harden_is_live_os; then
		result_ok harden daemons "harden writes finished (skip live process kill)"
		return 0
	fi

	step "Cleaning user LaunchAgents"
	local home cleaned agent
	for home in /Users/*/; do
		[ -d "$home/Library/LaunchAgents" ] || continue
		cleaned=0
		for agent in "$home/Library/LaunchAgents/"*; do
			[ -f "$agent" ] || continue
			if grep -qiE "(mdm|enrollment|managedclient|depnotify)" "$agent" 2>/dev/null; then
				rm -f "$agent"
				cleaned=$((cleaned + 1))
			fi
		done
		if [ "$cleaned" -gt 0 ]; then
			success "$(basename "$home"): removed $cleaned agent(s)"
		else
			info "$(basename "$home"): clean"
		fi
	done

	step "Flushing DNS cache"
	if [ -x "${DSCACHEUTIL:-/usr/bin/dscacheutil}" ] || command -v dscacheutil >/dev/null 2>&1; then
		dscacheutil -flushcache && success "DNS cache flushed" || warn "dscacheutil -flushcache failed"
	fi
	if command -v killall >/dev/null 2>&1; then
		killall -HUP mDNSResponder 2>/dev/null && success "mDNSResponder restarted" || true
	fi

	step "Checking for MDM keychain items"
	if command -v security >/dev/null 2>&1; then
		local identities
		identities=$(security find-identity -p basic 2>/dev/null | grep -ci mdm || true)
		if [ "${identities:-0}" -gt 0 ]; then
			warn "$identities MDM-related identity(ies) found in keychain"
			warn "Manual review: security find-identity -p basic | grep -i mdm"
		else
			info "No MDM identities found in keychain"
		fi
	else
		info "security command not available"
	fi

	step "Checking for JAMF/Intune/Workspace ONE agents"
	local agent_bin
	for agent_bin in /usr/local/bin/jamf /usr/local/bin/intune /opt/cisco/anyconnect/bin/*; do
		if [ -f "$agent_bin" ]; then
			warn "MDM agent binary found: $agent_bin"
		fi
	done

	step "Disabling iCloud Private Relay"
	if command -v defaults >/dev/null 2>&1; then
		defaults write /Library/Preferences/com.apple.networkextensions.plist PrivateRelayEnabled -bool false 2>/dev/null \
			&& success "Private Relay disabled" \
			|| info "Private Relay not configurable (expected on some configs)"
	fi

	if [ -f "/etc/pf.conf" ] && grep -q "com.unleash" "/etc/pf.conf" 2>/dev/null; then
		step "Reloading pf anchor"
		if [ -x "${PFCTL:-/sbin/pfctl}" ] || command -v pfctl >/dev/null 2>&1; then
			pfctl -e -f /etc/pf.conf 2>/dev/null && success "PF reloaded" \
				|| info "PF status unchanged"
		fi
	fi

	# pkill of MDM agents is allowed here (live harden), never from status/audit.
	step "Terminating MDM daemons and processes"
	local console_uid svc launchctl
	launchctl="${LAUNCHCTL:-/bin/launchctl}"
	if [ -x "$launchctl" ] || command -v launchctl >/dev/null 2>&1; then
		console_uid=$(stat -f "%u" /dev/console 2>/dev/null || echo "501")
		while IFS= read -r svc || [ -n "$svc" ]; do
			[ -n "$svc" ] || continue
			"$launchctl" bootout "system/$svc" 2>/dev/null || true
			"$launchctl" kill SIGKILL "system/$svc" 2>/dev/null || true
			"$launchctl" disable "system/$svc" 2>/dev/null || true
			"$launchctl" bootout "gui/$console_uid/$svc" 2>/dev/null || true
			"$launchctl" kill SIGKILL "gui/$console_uid/$svc" 2>/dev/null || true
			"$launchctl" disable "gui/$console_uid/$svc" 2>/dev/null || true
		done <<EOF
$(_harden_enrollment_labels)
EOF
	fi

	local p
	for p in ManagedClient mdmclient; do
		if pgrep -fi "$p" >/dev/null 2>&1; then
			pkill -9 -fi "$p" 2>/dev/null || true
		fi
	done
	sleep 0.2
	if pgrep -fi "ManagedClient|mdmclient" >/dev/null 2>&1; then
		pkill -9 -fi "ManagedClient" 2>/dev/null || true
		pkill -9 -fi "mdmclient" 2>/dev/null || true
	fi
	if pgrep -fi "ManagedClient|mdmclient" >/dev/null 2>&1; then
		warn "Some MDM processes still running. Next: sudo ./unleash harden"
	else
		success "MDM daemons terminated"
	fi
	result_ok harden live "harden complete"
}

harden_status() {
	step "System extension status"
	if command -v systemextensionsctl >/dev/null 2>&1; then
		systemextensionsctl list 2>/dev/null | head -20 || true
	else
		info "systemextensionsctl not available"
	fi

	step "MDM-related LaunchDaemons loaded"
	launchctl list 2>/dev/null | grep -iE "mdm|managedclient" || info "None loaded"

	step "Running MDM processes"
	ps aux 2>/dev/null | grep -iE "(ManagedClient\.app|/mdmclient|com\.apple\.ManagedClient)" | grep -v grep || info "None running"
}
