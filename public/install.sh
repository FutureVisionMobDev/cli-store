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

  local URL VERSION EXPECTED ARGS EXT DEST ACTUAL
  IFS='|' read -r URL VERSION EXPECTED ARGS <<<"$PARSED"
  EXPECTED="$(printf '%s' "$EXPECTED" | tr '[:upper:]' '[:lower:]')"
  EXT="${URL##*.}"
  DEST="/tmp/${APP}-${VERSION}.${EXT}"

  echo "  [*] Downloading $APP $VERSION..."
  curl -fsSL# -o "$DEST" "$URL"

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
      local MOUNT APP_BUNDLE
      MOUNT="$(hdiutil attach "$DEST" -nobrowse | awk 'END {print $NF}')"
      APP_BUNDLE="$(find "$MOUNT" -maxdepth 2 -name '*.app' -type d | head -n 1 || true)"
      if [[ -z "$APP_BUNDLE" ]]; then
        hdiutil detach "$MOUNT" >/dev/null || true
        rm -f "$DEST"
        echo "  [!] No .app found inside DMG." >&2
        exit 1
      fi
      sudo cp -R "$APP_BUNDLE" /Applications/
      hdiutil detach "$MOUNT" >/dev/null || true
      local APP_NAME
      APP_NAME="$(basename "$APP_BUNDLE")"
      open -a "/Applications/$APP_NAME" 2>/dev/null || true
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

  while true; do
    printf "  select app # (or Q): "
    read -r choice
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
    exit 0
  done
}

if [[ -z "$APP" ]]; then
  show_menu
else
  install_app "$APP"
fi
