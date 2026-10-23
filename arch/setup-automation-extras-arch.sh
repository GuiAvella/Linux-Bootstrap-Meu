#!/bin/bash
# ============================================================================
# setup-automation-extras-arch.sh   (X11 / Xorg version)
#
# ADD-ON for the existing Arch scripts. Contains ONLY what these don't do:
#   linux-setup.sh, configure-arch.sh, install-pacman-packages(-with-comments).sh
#
# Already handled by those (so NOT repeated here): xorg, Plasma/Klipper,
# flatpak, the Flathub remote, NormCap (Flatpak), git, curl, python.
#
# Adds: clipboard/window/OCR tools for X11, AUR helper, chezmoi, Espanso (X11),
#       Klipper history size, translate + Teams-toggle scripts, Obsidian.
#
# Run as your normal user (NOT sudo), AFTER configure-arch.sh. Safe to re-run;
# existing files (e.g. restored by chezmoi) are never overwritten.
# Optional: CHEZMOI_REPO=<git url> ./setup-automation-extras-arch.sh
# ============================================================================

set -e

if [ "$EUID" -eq 0 ]; then
    echo "Don't run this as root/sudo — it'll ask for sudo when it needs it."
    exit 1
fi

echo "=== 1/6: Extra pacman packages ==="
sudo pacman -S --needed --noconfirm \
    base-devel \
    xclip \
    xdotool \
    libnotify \
    tesseract \
    tesseract-data-eng \
    kate \
    qt6-tools \
    chezmoi \
    obsidian

# Newer Plasma versions ship the X11 session as a separate package.
# Only installed if it exists in your repos.
if pacman -Si plasma-x11-session &> /dev/null; then
    sudo pacman -S --needed --noconfirm plasma-x11-session
fi

echo "=== 2/6: AUR helper (yay) ==="
AUR_HELPER=""
for h in yay paru; do
    if command -v "$h" &> /dev/null; then AUR_HELPER="$h"; break; fi
done
if [ -z "$AUR_HELPER" ]; then
    tmpdir=$(mktemp -d)
    git clone https://aur.archlinux.org/yay-bin.git "$tmpdir/yay-bin"
    (cd "$tmpdir/yay-bin" && makepkg -si --noconfirm)
    rm -rf "$tmpdir"
    AUR_HELPER="yay"
fi
echo "  Using: $AUR_HELPER"

echo "=== 3/6: chezmoi (restore dotfiles BEFORE generating configs) ==="
if [ -n "$CHEZMOI_REPO" ] && [ ! -d "$HOME/.local/share/chezmoi" ]; then
    chezmoi init --apply "$CHEZMOI_REPO"
elif [ -d "$HOME/.local/share/chezmoi" ]; then
    echo "  chezmoi already initialised — run 'chezmoi apply' yourself if needed."
else
    echo "  Skipped (set CHEZMOI_REPO=<git url> to restore dotfiles automatically)."
fi

echo "=== 4/6: Klipper history size + qdbus detection ==="
kwriteconfig6 --file klipperrc --group General --key MaxClipItems 50 2>/dev/null || true

QDBUS_BIN=""
for candidate in qdbus6 qdbus-qt6 /usr/lib/qt6/bin/qdbus qdbus; do
    if command -v "$candidate" &> /dev/null || [ -x "$candidate" ]; then
        QDBUS_BIN="$candidate"
        break
    fi
done
if [ -z "$QDBUS_BIN" ]; then
    echo "  WARNING: no qdbus binary found. Fix the binary name in"
    echo "  ~/.config/espanso/match/clip-slots.yml before using :v1-:v9"
    QDBUS_BIN="qdbus6"
else
    echo "  Using: $QDBUS_BIN"
fi
"$QDBUS_BIN" org.kde.klipper /klipper org.kde.klipper.klipper.reloadConfig 2>/dev/null || true

echo "=== 5/6: Espanso (X11 build) ==="
if ! command -v espanso &> /dev/null; then
    # X11 build from the AUR (verify the name with: $AUR_HELPER -Ss espanso)
    "$AUR_HELPER" -S --needed --noconfirm espanso-x11
fi
# No setcap needed on X11 (that is only for the Wayland build).

espanso service register || true
espanso start || true

mkdir -p ~/.config/espanso/match

if [ ! -e ~/.config/espanso/match/emails.yml ]; then
cat > ~/.config/espanso/match/emails.yml << 'EOF'
matches:
  - trigger: ":lorda"
    replace: "lordavella25@gmail.com"

  - trigger: ":cala"
    replace: "calabresa25@hotmail.com"

  - trigger: ":uemail"
    replace: "guilherme.maldonado@ue-germany.de"
EOF
fi

# Types out Klipper history slots (:v1 = most recent copy).
if [ ! -e ~/.config/espanso/match/clip-slots.yml ]; then
cat > ~/.config/espanso/match/clip-slots.yml << CLIPEOF
matches:
$(for i in 0 1 2 3 4 5 6 7 8; do
    trigger_num=$((i + 1))
    cat << ENTRY
  - trigger: ":v${trigger_num}"
    replace: "{{output}}"
    vars:
      - name: output
        type: shell
        params:
          cmd: "$QDBUS_BIN org.kde.klipper /klipper org.kde.klipper.klipper.getClipboardHistoryItem $i"

ENTRY
done)
CLIPEOF
fi

espanso restart || true

echo "=== 6/6: Helper scripts (~/.local/bin) + Obsidian template ==="
mkdir -p ~/.local/bin
if ! grep -q '.local/bin' ~/.bashrc; then
    echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc
fi
export PATH="$HOME/.local/bin:$PATH"

if [ ! -e ~/.local/bin/translate-clipboard.py ]; then
cat > ~/.local/bin/translate-clipboard.py << 'PYEOF'
#!/usr/bin/env python3
import subprocess, urllib.parse, urllib.request, json, sys

CHUNK_SIZE = 500

def notify(msg):
    try:
        subprocess.run(["notify-send", "Translate", msg], check=False)
    except FileNotFoundError:
        print(msg, file=sys.stderr)

def get_clipboard():
    return subprocess.run(["xclip", "-selection", "clipboard", "-o"],
                          capture_output=True, text=True).stdout

def set_clipboard(text):
    subprocess.run(["xclip", "-selection", "clipboard"], input=text, text=True)

def translate_chunk(chunk):
    encoded = urllib.parse.quote(chunk, safe="")
    url = f"https://api.mymemory.translated.net/get?q={encoded}&langpair=autodetect|en"
    with urllib.request.urlopen(url, timeout=15) as resp:
        data = json.loads(resp.read().decode("utf-8"))
    t = data.get("responseData", {}).get("translatedText", "")
    return t.replace("\\/", "/").replace("\\n", "\n").replace("\\t", "\t")

def main():
    text = get_clipboard()
    if not text.strip():
        notify("Clipboard is empty!")
        return
    chunks = [text[i:i+CHUNK_SIZE] for i in range(0, len(text), CHUNK_SIZE)]
    parts = []
    for i, chunk in enumerate(chunks, 1):
        try:
            parts.append(translate_chunk(chunk))
        except Exception as e:
            notify(f"Translation failed on chunk {i}: {e}")
            return
    result = "".join(parts)
    set_clipboard(result)
    notify(result[:300] + ("…" if len(result) > 300 else ""))

if __name__ == "__main__":
    main()
PYEOF
fi
chmod +x ~/.local/bin/translate-clipboard.py

if [ ! -e ~/.local/bin/teams-toggle.sh ]; then
cat > ~/.local/bin/teams-toggle.sh << 'SHEOF'
#!/bin/bash
# EDIT THESE TWO LINES after checking:  xdotool getactivewindow getwindowclassname
TEAMS_CLASS="teams-for-linux"
TEAMS_LAUNCH_CMD="teams-for-linux"

# Electron apps expose several helper windows; keep only ones with a title.
WIN_ID=""
for id in $(xdotool search --class "$TEAMS_CLASS"); do
    if [ -n "$(xdotool getwindowname "$id" 2>/dev/null)" ]; then
        WIN_ID="$id"
        break
    fi
done

if [ -n "$WIN_ID" ]; then
    ACTIVE_ID=$(xdotool getactivewindow 2>/dev/null)
    if [ "$WIN_ID" = "$ACTIVE_ID" ]; then
        xdotool windowminimize "$WIN_ID"
    else
        xdotool windowactivate "$WIN_ID"
    fi
else
    nohup $TEAMS_LAUNCH_CMD >/dev/null 2>&1 &
fi
SHEOF
fi
chmod +x ~/.local/bin/teams-toggle.sh

mkdir -p ~/linux-automation/obsidian
if [ ! -e ~/linux-automation/obsidian/Class\ Entry\ Template.md ]; then
cat > ~/linux-automation/obsidian/Class\ Entry\ Template.md << 'MDEOF'
<%*
const dash = tp.date.now("DD-MM-YYYY");
const slash = tp.date.now("DD/MM/YYYY");
let folder = tp.file.folder(true);
if (folder === "/" || folder === ".") folder = "";
const path = (folder ? folder + "/" : "") + dash + ".md";
if (!(await tp.file.exists(path))) {
  await tp.file.create_new("# Dia " + slash + "\n", dash, false, folder || undefined);
}
tR += "# Dia " + slash + "\n[[" + dash + "]]\n";
%>
MDEOF
fi

cat << INSTRUCTIONS

============================================================
 Done. Manual steps left:

 0. At the SDDM login screen, pick the "Plasma (X11)" session
    (bottom-left dropdown) before logging in.

 KDE shortcuts — System Settings > Shortcuts > Custom Shortcuts,
 right-click > New > Global Shortcut > Command/URL:

   Translate Clipboard | python3 $HOME/.local/bin/translate-clipboard.py | Meta+T
   Teams Toggle        | $HOME/.local/bin/teams-toggle.sh                | F9
   NormCap             | flatpak run com.github.dynobo.normcap           | Meta+Shift+T
                         (NormCap itself is installed by the base scripts)

 Klipper's history popup works on Meta+V out of the box.

 1. Teams: install it ('$AUR_HELPER -S teams-for-linux'), then run
    'xdotool getactivewindow getwindowclassname' while it is focused
    and edit TEAMS_CLASS / TEAMS_LAUNCH_CMD in ~/.local/bin/teams-toggle.sh

 2. Obsidian: copy ~/linux-automation/obsidian/Class Entry Template.md
    into your vault, install the Templater plugin, set its template
    folder, enable a Template Hotkey for it, bind it to Ctrl+Shift+D
    (Settings > Hotkeys). Also remap PgUp/PgDn there.

 3. Clipboard slots: :v1 to :v9 type out Klipper history slots.

 4. chezmoi backup:
    chezmoi add ~/.bashrc ~/.config/espanso ~/.local/bin/translate-clipboard.py ~/.local/bin/teams-toggle.sh
============================================================
INSTRUCTIONS
