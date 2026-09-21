#!/usr/bin/env bash
set -euo pipefail

# Edit this default if your store is on a different domain.
DEFAULT_STORE="https://appstore.fvcloud.online"

STORE="${STORE:-$DEFAULT_STORE}"
STORE="${STORE%/}"
APP="${1:-}"

banner() {
  printf '\n'
  cat <<'EOF'
       _ _  ______ _____ ___  ____  _____ 
     | | |/ / ___|_   _/ _ \|  _ \| ____|
  _  | | ' /\___ \ | || | | | |_) |  _|  
 | |_| | . \ ___) || || |_| |  _ <| |___ 
  \___/|_|\_\____/ |_| \___/|_| \_\_____|
EOF
  printf '  self-hosted app store  ·  pick an app to install\n\n'
}

install_app() {
  local APP="$1"
  banner
  echo "  [*] Fetching manifest from $STORE/apps.json"
  local MANIFEST
  MANIFEST="$(curl -fsSL "$STORE/apps.json")"

  set +e
  local PARSED RC
  PARSED="$(printf '%s' "$MANIFEST" | python3 -c '
import json, sys
app = sys.argv[1]
data = json.load(sys.stdin)
if app not in data:
    keys = ", ".join(sorted(data.keys())) or "(none)"
    print("MISSING|" + keys)
    sys.exit(2)
mac = data[app].get("mac")
if not mac:
    keys = ", ".join(sorted(data.keys())) or "(none)"
    print("NOMAC|" + keys)
    sys.exit(3)
print("|".join([
    mac.get("url", ""),
    mac.get("version", ""),
    mac.get("sha256", ""),
    mac.get("args") or "",
    str(int(mac.get("size") or 0)),
]))
' "$APP")"
  RC=$?
  set -e

  if [[ $RC -eq 2 ]]; then
    avail="${PARSED#MISSING|}"
    echo "  [!] App '$APP' not found. Available: $avail" >&2
    exit 1
  fi
  if [[ $RC -eq 3 ]]; then
    echo "  [!] App '$APP' has no Mac installer." >&2
    exit 1
  fi
  if [[ $RC -ne 0 ]]; then
    echo "  [!] Failed to parse manifest." >&2
    exit 1
  fi

  local URL VERSION EXPECTED ARGS EXPECTED_SIZE EXT DEST ACTUAL GOT
  IFS='|' read -r URL VERSION EXPECTED ARGS EXPECTED_SIZE <<<"$PARSED"
  EXPECTED="$(printf '%s' "$EXPECTED" | tr '[:upper:]' '[:lower:]')"
  EXPECTED_SIZE="${EXPECTED_SIZE:-0}"
  # Force https for our store host (manifest may still emit http behind proxy)
  case "$URL" in
    http://appstore.fvcloud.online/*) URL="https://${URL#http://}" ;;
  esac
  EXT="${URL##*.}"
  DEST="/tmp/${APP}-${VERSION}.${EXT}"

  echo "  [*] Downloading $APP $VERSION..."
  if [[ "$EXPECTED_SIZE" =~ ^[1-9][0-9]*$ ]]; then
    echo "  · expected size: $EXPECTED_SIZE bytes"
  fi
  # Real progress bar (-#). No -s (silent kills the bar).
  # Cloudflare / proxies often cut big files — resume with -C - until size matches.
  rm -f "$DEST"
  local try=0
  while true; do
    try=$((try + 1))
    if (( try > 40 )); then
      echo "  [!] Download incomplete after $try tries." >&2
      rm -f "$DEST"
      exit 1
    fi
    set +e
    curl -fL --retry 2 --retry-delay 2 -C - --progress-bar -o "$DEST" "$URL"
    local curl_rc=$?
    set -e
    GOT="$(wc -c <"$DEST" | tr -d '[:space:]')"
    if [[ "$EXPECTED_SIZE" =~ ^[1-9][0-9]*$ ]]; then
      if [[ "$GOT" == "$EXPECTED_SIZE" ]]; then
        echo
        break
      fi
      echo
      echo "  [*] Partial ($GOT / $EXPECTED_SIZE) — resume try $try..."
      sleep 1
      continue
    fi
    if [[ $curl_rc -eq 0 && "$GOT" -gt 0 ]]; then
      echo
      break
    fi
    echo
    echo "  [*] Download interrupted (got $GOT bytes) — retry $try..."
    sleep 1
  done

  echo "  [*] Verifying SHA256..."
  ACTUAL="$(shasum -a 256 "$DEST" | awk '{print tolower($1)}')"
  if [[ "$ACTUAL" != "$EXPECTED" ]]; then
    rm -f "$DEST"
    echo "  [!] Checksum mismatch. Expected $EXPECTED got $ACTUAL. Aborting." >&2
    exit 1
  fi

  echo "  [*] Installing..."
  case "$EXT" in
    pkg)
      # shellcheck disable=SC2086
      sudo installer -pkg "$DEST" -target / $ARGS
      ;;
    dmg)
      # Support: drag-drop .app DMG, flat .pkg DMG, or nested Setup.dmg → .pkg
      # (e.g. Adobe Acrobat pack: outer DMG → Setup.dmg → Acrobat … Installer.pkg + Patch.pkg)
      local -a DMG_MOUNTS=()
      detach_dmg_mounts() {
        local m
        if ((${#DMG_MOUNTS[@]})); then
          for m in "${DMG_MOUNTS[@]}"; do
            hdiutil detach "$m" >/dev/null 2>&1 || true
          done
        fi
        DMG_MOUNTS=()
      }
      mount_dmg() {
        local path="$1" mp out
        # Fixed mountpoint — volume names with spaces break "awk NF" parsing of hdiutil output
        mp="/tmp/jkstore-mnt-$$-${#DMG_MOUNTS[@]}"
        mkdir -p "$mp"
        if ! out="$(hdiutil attach "$path" -nobrowse -owners on -mountpoint "$mp" 2>&1)"; then
          echo "  [!] Failed to mount $(basename "$path")" >&2
          printf '%s\n' "$out" >&2
          rmdir "$mp" 2>/dev/null || true
          return 1
        fi
        if [[ ! -d "$mp" ]]; then
          echo "  [!] Mountpoint missing after attach: $mp" >&2
          printf '%s\n' "$out" >&2
          return 1
        fi
        DMG_MOUNTS+=("$mp")
        printf '%s\n' "$mp"
      }
      install_pkgs_in_volume() {
        local vol="$1"
        local -a pkgs=() patches=() mains=()
        local p
        while IFS= read -r p; do
          [[ -n "$p" ]] || continue
          pkgs+=("$p")
        done < <(find "$vol" -maxdepth 5 -name '*.pkg' -type f 2>/dev/null | sort)
        ((${#pkgs[@]})) || return 1
        for p in "${pkgs[@]}"; do
          case "$(basename "$p")" in
            [Pp]atch*) patches+=("$p") ;;
            *) mains+=("$p") ;;
          esac
        done
        if ((${#mains[@]})); then
          for p in "${mains[@]}"; do
            echo "  [*] Installing package: $(basename "$p")"
            # shellcheck disable=SC2086
            sudo installer -pkg "$p" -target / $ARGS
          done
        fi
        if ((${#patches[@]})); then
          for p in "${patches[@]}"; do
            echo "  [*] Applying patch: $(basename "$p")"
            # shellcheck disable=SC2086
            sudo installer -pkg "$p" -target / $ARGS
          done
        fi
        return 0
      }
      try_dmg_volume() {
        local vol="$1"
        local depth="${2:-0}"
        local APP_BUNDLE nested inner

        APP_BUNDLE="$(find "$vol" -maxdepth 3 -name '*.app' -type d 2>/dev/null | head -n 1 || true)"
        if [[ -n "$APP_BUNDLE" ]]; then
          echo "  [*] Copying $(basename "$APP_BUNDLE") → /Applications"
          sudo cp -R "$APP_BUNDLE" /Applications/
          open -a "/Applications/$(basename "$APP_BUNDLE")" 2>/dev/null || true
          return 0
        fi

        # Nested installer DMG (Setup.dmg) before outer Patch.pkg alone
        if (( depth < 2 )); then
          nested="$(find "$vol" -maxdepth 3 -name '*.dmg' -type f 2>/dev/null | head -n 1 || true)"
          if [[ -n "$nested" ]]; then
            echo "  [*] Opening nested DMG: $(basename "$nested")"
            # Copy off the outer volume — attach-from-mounted-DMG often fails on macOS
            local nested_copy="/tmp/jkstore-nested-$$.dmg"
            cp -f "$nested" "$nested_copy"
            inner="$(mount_dmg "$nested_copy")" || {
              rm -f "$nested_copy"
              return 1
            }
            if try_dmg_volume "$inner" $((depth + 1)); then
              # Outer Patch.pkg often sits beside Setup.dmg
              install_pkgs_in_volume "$vol" || true
              rm -f "$nested_copy"
              return 0
            fi
            rm -f "$nested_copy"
          fi
        fi

        if install_pkgs_in_volume "$vol"; then
          return 0
        fi
        return 1
      }

      trap detach_dmg_mounts EXIT
      local OUTER
      echo "  [*] Mounting DMG..."
      OUTER="$(mount_dmg "$DEST")" || {
        trap - EXIT
        rm -f "$DEST"
        exit 1
      }
      if ! try_dmg_volume "$OUTER" 0; then
        detach_dmg_mounts
        trap - EXIT
        rm -f "$DEST"
        echo "  [!] No .app / .pkg / nested installer found in DMG." >&2
        exit 1
      fi
      detach_dmg_mounts
      trap - EXIT
      ;;
    zip)
      local EXTRACT_ROOT LAUNCH
      EXTRACT_ROOT="/tmp/${APP}-${VERSION}-extracted"
      rm -rf "$EXTRACT_ROOT"
      mkdir -p "$EXTRACT_ROOT"
      echo "  [*] Extracting zip..."
      unzip -q "$DEST" -d "$EXTRACT_ROOT"
      rm -f "$DEST"

      LAUNCH=""
      if [[ -n "$ARGS" ]]; then
        if [[ -e "$EXTRACT_ROOT/$ARGS" ]]; then
          LAUNCH="$EXTRACT_ROOT/$ARGS"
        fi
      fi
      if [[ -z "$LAUNCH" ]]; then
        LAUNCH="$(find "$EXTRACT_ROOT" -maxdepth 3 -name '*.app' -type d | head -n 1 || true)"
      fi
      if [[ -z "$LAUNCH" ]]; then
        LAUNCH="$(find "$EXTRACT_ROOT" -type f -perm +111 ! -name '.*' | head -n 1 || true)"
      fi
      if [[ -z "$LAUNCH" ]]; then
        echo "  [!] Nothing to launch inside zip. Extracted to: $EXTRACT_ROOT" >&2
        exit 1
      fi
      echo "  [*] Launching $(basename "$LAUNCH")..."
      if [[ "$LAUNCH" == *.app ]]; then
        open "$LAUNCH"
      else
        open "$LAUNCH" 2>/dev/null || "$LAUNCH" &
      fi
      echo "  [+] Done. $APP $VERSION extracted + launched."
      echo "  · files stay at: $EXTRACT_ROOT"
      echo
      return 0
      ;;
    *)
      echo "  [!] Unsupported installer type .$EXT" >&2
      rm -f "$DEST"
      exit 1
      ;;
  esac

  rm -f "$DEST"
  echo "  [+] Done. $APP $VERSION installed."
  echo
}

show_menu() {
  banner
  echo "  [*] fetching catalog..."
  local MANIFEST
  MANIFEST="$(curl -fsSL "$STORE/apps.json")"

  local MENU
  MENU="$(printf '%s' "$MANIFEST" | python3 -c '
import json, sys
data = json.load(sys.stdin)
slugs = sorted(data.keys())
if not slugs:
    print("EMPTY")
    sys.exit(0)
print("HDR")
for i, slug in enumerate(slugs, 1):
    e = data[slug]
    osbits = []
    if e.get("win"): osbits.append("win")
    if e.get("mac"): osbits.append("mac")
    os_label = "+".join(osbits) if osbits else "-"
    name = e.get("name") or slug
    print(f"{i}|{slug}|{os_label}|{name}")
')"

  if [[ "$MENU" == "EMPTY" ]]; then
    echo "  [!] catalog empty — nothing to install yet."
    echo "      admin: $STORE/admin"
    exit 0
  fi

  echo "  ────────────────────────────────────────"
  printf "  %-4s %-18s %-10s %s\n" "#" "APP" "OS" "NAME"
  echo "  ────────────────────────────────────────"

  local -a SLUGS=()
  while IFS= read -r line; do
    [[ "$line" == "HDR" ]] && continue
    [[ -z "$line" ]] && continue
    IFS='|' read -r num slug os_label name <<<"$line"
    printf "  %-4s %-18s %-10s %s\n" "$num" "$slug" "$os_label" "$name"
    SLUGS+=("$slug")
  done <<<"$MENU"

  echo "  ────────────────────────────────────────"
  printf "  %-4s %s\n" "Q" "quit"
  echo
  echo "  tip: direct install → curl -fsSL $STORE/install.sh | bash -s -- <slug>"
  echo

  # curl|bash pipes script on stdin — menu must read from real TTY or it exits immediately
  local TTY_IN="/dev/tty"
  if [[ ! -r "$TTY_IN" ]]; then
    echo "  [!] no TTY (non-interactive). Pass slug:" >&2
    echo "      curl -fsSL $STORE/install.sh | bash -s -- <slug>" >&2
    exit 1
  fi

  while true; do
    printf "  select app # (or Q): "
    if ! read -r choice <"$TTY_IN"; then
      echo
      echo "  [!] input closed."
      exit 1
    fi
    choice="$(printf '%s' "$choice" | tr -d '[:space:]')"
    if [[ -z "$choice" ]]; then
      continue
    fi
    if [[ "$choice" =~ ^[Qq]$ ]]; then
      echo "  bye."
      exit 0
    fi
    if [[ ! "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#SLUGS[@]} )); then
      echo "  [!] invalid pick — enter a number from the list."
      continue
    fi
    install_app "${SLUGS[$((choice - 1))]}"
    printf "  press Enter to close… "
    read -r _ <"$TTY_IN" || true
    exit 0
  done
}

if [[ -z "$APP" ]]; then
  show_menu
else
  install_app "$APP"
fi
