GPG_KEY_URL="https://raw.githubusercontent.com/mateussiqueira/unleash/main/.github/unleash.gpg"

import_gpg_key() {
  local tmp_key
  tmp_key=$(mktemp)
  if curl -sL "$GPG_KEY_URL" -o "$tmp_key" 2>/dev/null; then
    gpg --import "$tmp_key" 2>/dev/null || true
  fi
  rm -f "$tmp_key"
}

verify_gpg_signature() {
  local file="$1"
  local sig="$2"
  if ! command -v gpg &>/dev/null; then
    warn "GPG not available — cannot verify signature"
    if [ "${UNLEASH_INSECURE_UPDATE:-0}" = "1" ]; then
      warn "UNLEASH_INSECURE_UPDATE=1 — proceeding without GPG verification"
      return 0
    fi
    error_exit "Install GPG or set UNLEASH_INSECURE_UPDATE=1 to skip verification"
  fi
  import_gpg_key
  if gpg --verify "$sig" "$file" 2>/dev/null; then
    info "GPG signature valid"
    return 0
  else
    warn "GPG signature verification FAILED"
    if [ "${UNLEASH_INSECURE_UPDATE:-0}" = "1" ]; then
      warn "UNLEASH_INSECURE_UPDATE=1 — proceeding despite failed verification"
      return 0
    fi
    error_exit "GPG signature invalid. Set UNLEASH_INSECURE_UPDATE=1 to bypass (NOT recommended)"
  fi
}

verify_sha256_checksum() {
  local file="$1"
  local checksum_file="$2"

  if [ ! -s "$checksum_file" ]; then
    debug "No checksum file available"
    return 1
  fi

  local expected actual
  expected=$(awk '{print $1}' "$checksum_file" 2>/dev/null | head -1)
  if [ -z "$expected" ]; then
    debug "Checksum file empty or malformed"
    return 1
  fi

  if command -v shasum &>/dev/null; then
    actual=$(shasum -a 256 "$file" 2>/dev/null | awk '{print $1}')
  elif command -v sha256sum &>/dev/null; then
    actual=$(sha256sum "$file" 2>/dev/null | awk '{print $1}')
  else
    warn "No SHA-256 tool available (shasum or sha256sum)"
    return 1
  fi

  if [ "$expected" = "$actual" ]; then
    info "SHA-256 checksum valid"
    return 0
  else
    warn "SHA-256 checksum mismatch"
    warn "  Expected: $expected"
    warn "  Actual:   $actual"
    return 1
  fi
}

do_self_update() {
  header "Unleash Update"

  if ! command -v curl &>/dev/null; then
    error_exit "curl required for update"
  fi

  local repo="mateussiqueira/unleash"
  local api_url="https://api.github.com/repos/${repo}/releases/latest"
  local tmp_dir
  tmp_dir=$(mktemp -d)

  begin "Checking latest release"
  local release_data
  release_data=$(curl -s "$api_url" 2>/dev/null || true)
  local latest_tag
  latest_tag=$(echo "$release_data" | grep '"tag_name"' | head -1 | sed -E 's/.*"v?([^"]+)".*/\1/')

  if [ -z "$latest_tag" ]; then
    end_fail; echo "     No network or invalid response"
    rm -rf "$tmp_dir"
    return 1
  fi
  end_ok; echo "     Latest: v$latest_tag"

  if [ "v$latest_tag" = "$(echo "v$VERSION")" ]; then
    success "Already up to date (v$VERSION)"
    rm -rf "$tmp_dir"
    return 0
  fi

  info "Updating from v$VERSION to v$latest_tag..."

  begin "Downloading latest unleash"
  local dl_url="https://raw.githubusercontent.com/${repo}/main/unleash"
  local sig_url="${dl_url}.sig"
  local sha_url="${dl_url}.sha256"
  local tmp="$tmp_dir/unleash"
  local sig_tmp="$tmp_dir/unleash.sig"
  local sha_tmp="$tmp_dir/unleash.sha256"
  if curl -sL "$dl_url" -o "$tmp" && [ -s "$tmp" ]; then
    curl -sL "$sig_url" -o "$sig_tmp" 2>/dev/null || true
    curl -sL "$sha_url" -o "$sha_tmp" 2>/dev/null || true
    end_ok
  else
    end_fail; error_exit "Download failed"
  fi

  # Verification strategy:
  # 1. If GPG sig exists → verify GPG (fail-closed unless UNLEASH_INSECURE_UPDATE=1)
  # 2. Else if SHA-256 exists → verify checksum (fail-closed unless UNLEASH_INSECURE_UPDATE=1)
  # 3. Else → fail unless UNLEASH_INSECURE_UPDATE=1
  local verified=false

  if [ -s "$sig_tmp" ]; then
    begin "Verifying GPG signature"
    verify_gpg_signature "$tmp" "$sig_tmp"
    verified=true
    end_ok
  fi

  if [ "$verified" = false ] && [ -s "$sha_tmp" ]; then
    begin "Verifying SHA-256 checksum"
    if verify_sha256_checksum "$tmp" "$sha_tmp"; then
      verified=true
      end_ok
    else
      end_fail
      if [ "${UNLEASH_INSECURE_UPDATE:-0}" != "1" ]; then
        rm -rf "$tmp_dir"
        error_exit "Checksum verification failed. Set UNLEASH_INSECURE_UPDATE=1 to bypass"
      fi
      warn "UNLEASH_INSECURE_UPDATE=1 — proceeding despite failed checksum"
      verified=true
    fi
  fi

  if [ "$verified" = false ]; then
    warn "No signature or checksum available for verification"
    if [ "${UNLEASH_INSECURE_UPDATE:-0}" != "1" ]; then
      rm -rf "$tmp_dir"
      error_exit "Cannot verify update integrity. Set UNLEASH_INSECURE_UPDATE=1 to bypass"
    fi
    warn "UNLEASH_INSECURE_UPDATE=1 — proceeding without any verification"
  fi

  begin "Verifying syntax"
  if bash -n "$tmp" 2>/dev/null; then
    end_ok
  else
    end_fail; error_exit "Downloaded script has syntax errors"
  fi

  local target="${0:-unleash}"
  if [ ! -w "$target" ]; then
    info "$target not writable, trying sudo..."
    cp "$tmp" "$target" 2>/dev/null || sudo cp "$tmp" "$target" 2>/dev/null || {
      error_exit "Cannot write to $target (run with sudo)"
    }
  else
    cp "$tmp" "$target"
  fi
  chmod +x "$target" 2>/dev/null || sudo chmod +x "$target" 2>/dev/null || true

  rm -rf "$tmp_dir"
  success "Updated to v$latest_tag"
  info "Run again to use new version"
}
