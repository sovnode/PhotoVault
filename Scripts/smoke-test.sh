#!/bin/sh
# End-to-end check of the real app against a real sparse bundle.
#
# Usage: Scripts/smoke-test.sh
#
# Builds the app, creates a throwaway vault under .smoke/, fills it with
# generated photos and videos, launches the app from the vault, and checks what
# unit tests can't see: indexing through the real UI process, idle CPU (catches
# SwiftUI render loops), quitting promptly (catches a hung main thread), the
# WAL checkpoint on quit, warm restarts, picking up new files, the photo viewer,
# that nothing lands in ~/Library (preferences, saved state, caches), and
# ejecting afterward.
#
# A PhotoVault window appears for about a minute. Your own vaults and any
# PhotoVault you have open are left alone: the script launches its own copy
# and only ever signals that one process.

set -u
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
WORK="$ROOT/.smoke"
PASSED=0
FAILED=0
PID=""
MOUNT=""

pass() { PASSED=$((PASSED + 1)); printf '  \342\234\224 %s\n' "$1"; }
fail() { FAILED=$((FAILED + 1)); printf '  \342\234\230 %s\n' "$1"; }
expect() {  # expect "description" actual expected
    if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (got '$2', expected '$3')"; fi
}

# Detaches any disk image whose backing file lives under $1.
detach_images_under() {
    hdiutil info 2>/dev/null | awk -F'\t' -v dir="$1" '
        /^image-path[ \t]*:/ { cur = $0; sub(/^image-path[ \t]*:[ \t]*/, "", cur); next }
        index(cur, dir) == 1 && NF >= 3 && $3 ~ /^\// { print $3 }
    ' | while IFS= read -r m; do
        hdiutil detach "$m" -quiet 2>/dev/null || hdiutil detach "$m" -force -quiet 2>/dev/null
    done
}

cleanup() {
    if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then
        kill -TERM "$PID" 2>/dev/null; sleep 3; kill -KILL "$PID" 2>/dev/null
    fi
    detach_images_under "$WORK"
    rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

sql() { sqlite3 "$MOUNT/.catalog/catalog.sqlite" "$1" 2>/dev/null; }
size_of() { stat -f %z "$1" 2>/dev/null || echo 0; }

# Seconds of CPU the process has used so far, in hundredths.
cpu_cs() {
    ps -o time= -p "$PID" 2>/dev/null | awk -F'[:.]' '
        NF == 3 { print ($1 * 60 + $2) * 100 + $3 }
        NF == 4 { print (($1 * 60 + $2) * 60 + $3) * 100 + $4 }'
}

# CPU used over five idle seconds, as a percentage. Measured from cumulative
# CPU time rather than `ps %cpu`, which is a decaying average and would still
# be high just after indexing finishes.
idle_cpu_percent() {
    sleep 3
    a=$(cpu_cs); sleep 5; b=$(cpu_cs)
    [ -n "$a" ] && [ -n "$b" ] || { echo 999; return; }
    echo $(( (b - a) / 5 ))
}

# PHOTOVAULT_SMOKE_SCREEN=2 Scripts/smoke-test.sh opens every window on the
# second display, out of the way of someone working on the main one.
SCREEN="${PHOTOVAULT_SMOKE_SCREEN:+PHOTOVAULT_SMOKE_SCREEN=$PHOTOVAULT_SMOKE_SCREEN}"

launch() {  # launch [ENV=VALUE ...]
    # shellcheck disable=SC2086  # $SCREEN is empty or one VAR=value
    env $SCREEN "$@" "$MOUNT/PhotoVault.app/Contents/MacOS/PhotoVault" >>"$WORK/app.log" 2>&1 &
    PID=$!
}

# Opens PhotoVault the way Finder does, through LaunchServices, which makes it
# the active app. `launch` starts it in the background instead, where its window
# never becomes active — and SwiftUI saves the window frame to
# ~/Library/Preferences exactly then, so 1.0 and 1.1 passed while leaking.
# -n: always this vault's copy, even if a PhotoVault is open on another vault.
launch_like_finder() {  # launch_like_finder [ENV=VALUE ...]
    envs=""
    for kv in $SCREEN "$@"; do envs="$envs --env $kv"; done
    # shellcheck disable=SC2086  # $envs is meant to split into separate arguments
    open -n $envs --stdout "$WORK/app.log" --stderr "$WORK/app-stderr.log" -a "$MOUNT/PhotoVault.app" || return 1
    t=0; PID=""
    while [ -z "$PID" ] && [ "$t" -lt 40 ]; do
        PID=$(pgrep -f "$MOUNT/PhotoVault.app/Contents/MacOS/PhotoVault" | head -1)
        [ -n "$PID" ] || { sleep 0.5; t=$((t + 1)); }
    done
    [ -n "$PID" ]
}

# Waits until a query returns the expected value.
wait_for() {  # wait_for seconds "sql" expected
    t=0
    while [ "$t" -lt "$1" ]; do
        [ "$(sql "$2")" = "$3" ] && return 0
        kill -0 "$PID" 2>/dev/null || return 1
        sleep 1; t=$((t + 1))
    done
    return 1
}

# Sends SIGTERM and waits for a clean exit. A wedged main thread never handles
# the signal, so a timeout here means the app hung.
stop_app() {
    kill -TERM "$PID" 2>/dev/null
    t=0
    while kill -0 "$PID" 2>/dev/null; do
        [ "$t" -ge 15 ] && return 1
        sleep 1; t=$((t + 1))
    done
    PID=""
    return 0
}

# ------------------------------------------------------------------ setup

detach_images_under "$WORK"
rm -rf "$WORK"
mkdir -p "$WORK"

echo "Setup"
# The name has a space on purpose: vault names do ("Family Photos"), and a
# script that splits paths on whitespace should fail here first.
# Without JoyTag to start with: the first launches run as before 1.3.0, and
# JoyTag goes in later, where its own checks are.
OUT="$(Scripts/new-vault.sh "$WORK/Smoke Vault" 2g --without-joytag 2>&1)" || { echo "$OUT"; fail "create vault and install app"; exit 1; }
MOUNT="$(printf '%s\n' "$OUT" | awk -F'Mounted: *' '/Mounted:/ { print $2 }' | tail -1)"
[ -d "$MOUNT/PhotoVault.app" ] && [ -d "$MOUNT/Photos" ] && [ -f "$MOUNT/.metadata_never_index" ] \
    && pass "vault created and app installed at $MOUNT" \
    || { fail "vault created and app installed"; exit 1; }
[ -f "$MOUNT/.VolumeIcon.icns" ] && xcrun GetFileInfo -a "$MOUNT" | grep -q C \
    && pass "vault volume shows the app icon" || fail "vault volume shows the app icon"

SUMMARY="$(swift -suppress-warnings Scripts/make-test-media.swift "$MOUNT/Photos" 40 2>&1 | tail -1)"
PHOTOS=$(printf '%s' "$SUMMARY" | sed -n 's/.*photos=\([0-9]*\).*/\1/p')
VIDEOS=$(printf '%s' "$SUMMARY" | sed -n 's/.*videos=\([0-9]*\).*/\1/p')
UNSUPPORTED=$(printf '%s' "$SUMMARY" | sed -n 's/.*unsupported=\([0-9]*\).*/\1/p')
TAGGED=$(printf '%s' "$SUMMARY" | sed -n 's/.*tagged=\([0-9]*\).*/\1/p')
SKY=$(printf '%s' "$SUMMARY" | sed -n 's/.*sky=\([0-9]*\).*/\1/p')
[ -n "$PHOTOS" ] && pass "generated $PHOTOS photos, $VIDEOS videos, $UNSUPPORTED unsupported file" \
    || { fail "generate test media: $SUMMARY"; exit 1; }
TOTAL=$((PHOTOS + VIDEOS + UNSUPPORTED))
THUMBS=$((PHOTOS + VIDEOS))

# ------------------------------------------------------------------ cold start

# Nothing may be written outside the vault. AppKit and SwiftUI save
# window geometry and state to the Mac on their own, so snapshot every place an
# app writes under its own name now, and compare after the last launch. (A
# PhotoVault you are using at the same time could also write there; don't use it
# mid-test.)
outside_state() {
    for f in "$HOME/Library/Preferences/"local.photovault.app* \
             "$HOME/Library/Saved Application State/local.photovault.app.savedState" \
             "$HOME/Library/Caches/local.photovault.app" \
             "$HOME/Library/HTTPStorages/local.photovault.app"* \
             "$HOME/Library/Application Support/local.photovault.app"; do
        [ -e "$f" ] || continue
        printf '%s %s\n' "$f" "$(find "$f" -type f -exec shasum {} + 2>/dev/null | shasum | cut -c1-40)"
    done
    true
}
OUTSIDE_BEFORE="$(outside_state)"

echo "First launch, opened as Finder opens it"
launch_like_finder PHOTOVAULT_SMOKE_RESIZE=1 || { fail "launch through LaunchServices"; exit 1; }
if wait_for 120 "SELECT COUNT(*) FROM photo WHERE thumb_off IS NOT NULL;" "$THUMBS"; then
    pass "indexed and built $THUMBS thumbnails"
else
    fail "indexed and built $THUMBS thumbnails (got $(sql "SELECT COUNT(*) FROM photo WHERE thumb_off IS NOT NULL;"))"
fi
expect "every file has a row" "$(sql "SELECT COUNT(*) FROM photo;")" "$TOTAL"
# Tags are read after thumbnails, so wait for that pass to finish.
if wait_for 30 "SELECT COUNT(DISTINCT photo_id) FROM tag;" "$TAGGED"; then
    pass "keywords already in $TAGGED photos read into the catalog"
else
    fail "keywords already in photos read into the catalog (got $(sql "SELECT COUNT(DISTINCT photo_id) FROM tag;") of $TAGGED)"
fi
expect "tags merge regardless of case (Sky = sky)" "$(sql "SELECT COUNT(*) FROM tag WHERE key = 'sky' AND name = 'Sky';")" "$SKY"
[ -f "$MOUNT/.Tag Groups.txt" ] && [ ! -e "$MOUNT/Tag Groups.txt" ] && pass ".Tag Groups.txt installed in the vault, hidden, to be edited" || fail ".Tag Groups.txt installed in the vault, hidden"
expect "unplayable container badged, not dropped" "$(sql "SELECT COUNT(*) FROM photo WHERE playable = 0;")" "$UNSUPPORTED"
expect "thumbnail pack ends exactly where the catalog says" \
    "$(sql "SELECT MAX(thumb_off + thumb_len) FROM photo;")" "$(size_of "$MOUNT/.catalog/thumbs.pack")"

t=0; while [ $t -lt 20 ] && ! grep -q "smoke: defaults write" "$WORK/app.log"; do sleep 1; t=$((t + 1)); done
grep -q "smoke: resized window" "$WORK/app.log" && pass "window and sidebar resized" || fail "window and sidebar resized"
# Each route AppKit and SwiftUI use to save window geometry was taken, and
# refused before reaching ~/Library/Preferences. "save frame" is SwiftUI saving
# the frame as the window becomes active — the one 1.0 and 1.1 missed.
REFUSED="$(sed -n 's/^smoke: refused: //p' "$WORK/app.log" | tail -1)"
for route in "autosave name" "save frame" "split view"; do
    printf '%s\n' "$REFUSED" | grep -Eq "$route [1-9]" \
        && pass "window geometry save refused: $route" \
        || fail "window geometry save refused: $route (got '$REFUSED')"
done
grep -q "smoke: defaults write held in memory: yes" "$WORK/app.log" \
    && pass "anything else written to the app's preferences stays in memory" \
    || fail "anything else written to the app's preferences stays in memory"

CPU=$(idle_cpu_percent)
[ "$CPU" -lt 10 ] && pass "idle in the grid (${CPU}% CPU)" || fail "idle in the grid (${CPU}% CPU — a render loop?)"

if stop_app; then pass "quit promptly"; else fail "quit promptly (still running after 15s — hung main thread?)"; fi
expect "WAL checkpointed on quit" "$(size_of "$MOUNT/.catalog/catalog.sqlite-wal")" "0"
expect "catalog integrity" "$(sql "PRAGMA integrity_check;")" "ok"
expect "clean shutdown recorded" "$(sql "SELECT value FROM meta WHERE key = 'clean_shutdown';")" "1"
expect "window size saved in the vault's catalog instead" "$(sql "SELECT COUNT(*) FROM meta WHERE key = 'setting.window.frame';")" "1"
if strings "$MOUNT/.catalog/catalog.sqlite" | grep -qE "/Volumes/|$(id -un)"; then
    fail "catalog stores no mount path or username"
else
    pass "catalog stores no mount path or username"
fi

# ------------------------------------------------------------------ warm start

echo "Second launch: a new photo, and the viewer open"
PACK_BEFORE=$(size_of "$MOUNT/.catalog/thumbs.pack")
sips -Z 300 "$MOUNT/Photos/IMG_1000.jpg" --out "$MOUNT/Photos/2019/added_later.jpg" >/dev/null 2>&1
launch PHOTOVAULT_SMOKE_OPEN_VIEWER=1
if wait_for 60 "SELECT COUNT(*) FROM photo WHERE thumb_off IS NOT NULL;" "$((THUMBS + 1))"; then
    pass "new photo picked up on launch"
else
    fail "new photo picked up on launch"
fi
expect "re-reading a folder kept every photo's date and dimensions" \
    "$(sql "SELECT COUNT(*) FROM photo WHERE width = 0 OR height = 0 OR captured_at IS NULL;")" "0"
GROWTH=$(( $(size_of "$MOUNT/.catalog/thumbs.pack") - PACK_BEFORE ))
[ "$GROWTH" -gt 0 ] && [ "$GROWTH" -lt 200000 ] \
    && pass "existing thumbnails reused (pack grew ${GROWTH} bytes)" \
    || fail "existing thumbnails reused (pack grew ${GROWTH} bytes)"

t=0; while [ $t -lt 20 ] && ! grep -q "smoke: viewer opened" "$WORK/app.log"; do sleep 1; t=$((t + 1)); done
grep -q "smoke: viewer opened" "$WORK/app.log" && pass "photo viewer opened" || fail "photo viewer opened"
grep -q "smoke: properties panel open" "$WORK/app.log" && pass "properties panel open" || fail "properties panel open"

CPU=$(idle_cpu_percent)
[ "$CPU" -lt 10 ] && pass "idle with the viewer and properties panel open (${CPU}% CPU)" || fail "idle with the viewer and properties panel open (${CPU}% CPU)"

if stop_app; then pass "quit promptly from the viewer"; else fail "quit promptly from the viewer"; fi
expect "WAL checkpointed again" "$(size_of "$MOUNT/.catalog/catalog.sqlite-wal")" "0"

# ------------------------------------------------------------------ stop mid-scan

echo "Third launch: stop a scan part-way, then let the next launch finish it"
mkdir -p "$MOUNT/Photos/batch2"
n=0
find "$MOUNT/Photos" -name 'IMG_*.jpg' | head -30 | while IFS= read -r src; do
    sips -Z $((200 + n * 7)) "$src" --out "$MOUNT/Photos/batch2/B_$n.jpg" >/dev/null 2>&1
    n=$((n + 1))
done
BEFORE=$(sql "SELECT COUNT(*) FROM photo WHERE thumb_off IS NOT NULL;")
TOTAL3=$((BEFORE + 30))
# Thumbnails slowed to one second each, two at a time, so there's a scan to stop.
launch PHOTOVAULT_SMOKE_SLOW_THUMBS=1
t=0
while [ $t -lt 60 ] && [ "$(sql "SELECT COUNT(*) FROM photo WHERE thumb_off IS NOT NULL;")" -le "$BEFORE" ]; do
    sleep 0.5; t=$((t + 1))
done
if stop_app; then pass "quit promptly in the middle of a scan"; else fail "quit promptly in the middle of a scan"; fi
DONE=$(sql "SELECT COUNT(*) FROM photo WHERE thumb_off IS NOT NULL;")
[ "$DONE" -gt "$BEFORE" ] && [ "$DONE" -lt "$TOTAL3" ] \
    && pass "scan stopped part-way ($((DONE - BEFORE)) of 30 new thumbnails kept)" \
    || fail "scan stopped part-way (got $((DONE - BEFORE)) of 30)"
expect "WAL checkpointed after stopping mid-scan" "$(size_of "$MOUNT/.catalog/catalog.sqlite-wal")" "0"
expect "stopping badged nothing as broken" "$(sql "SELECT COUNT(*) FROM photo WHERE playable = 0;")" "$UNSUPPORTED"
launch PHOTOVAULT_SMOKE_FILTER=1
if wait_for 90 "SELECT COUNT(*) FROM photo WHERE thumb_off IS NOT NULL;" "$TOTAL3"; then
    pass "the next launch finished the scan"
else
    fail "the next launch finished the scan (got $(sql "SELECT COUNT(*) FROM photo WHERE thumb_off IS NOT NULL;") of $TOTAL3)"
fi

# A smart album built from a tag rule, with its filter panel left open.
t=0; while [ $t -lt 30 ] && ! grep -q "smoke: filter panel open" "$WORK/app.log"; do sleep 1; t=$((t + 1)); done
MATCHED=$(sed -n 's/^smoke: filter panel open, \([0-9]*\) photos match/\1/p' "$WORK/app.log" | tail -1)
# Copies made with sips carry their keywords along, so count from the tags themselves.
expect "a smart album including the tag sky shows exactly the photos with it" "$MATCHED" \
    "$(sql "SELECT COUNT(DISTINCT t.photo_id) FROM tag t JOIN photo p ON p.id = t.photo_id WHERE t.key = 'sky' AND p.missing = 0 AND p.trashed = 0;")"
expect "its rules are saved in the vault's catalog" \
    "$(sql "SELECT json_extract(rules, '$.items[0].name') FROM smart_album WHERE name = 'Smoke filter';")" "sky"
CPU=$(idle_cpu_percent)
[ "$CPU" -lt 10 ] && pass "idle with the filter panel open (${CPU}% CPU)" || fail "idle with the filter panel open (${CPU}% CPU — a layout loop?)"
if stop_app; then pass "quit promptly after finishing"; else fail "quit promptly after finishing"; fi

sleep 2   # preference writes land asynchronously, via cfprefsd
OUTSIDE_AFTER="$(outside_state)"
if [ "$OUTSIDE_AFTER" = "$OUTSIDE_BEFORE" ]; then
    pass "nothing written outside the vault (preferences, saved state, caches)"
else
    fail "nothing written outside the vault — changed: $(printf '%s\n' "$OUTSIDE_AFTER" | grep -vxF "$OUTSIDE_BEFORE" | cut -d' ' -f1 | tr '\n' ' ')"
fi

# Folder browsing: every folder's count in the catalog must match the media
# files directly inside it on disk (the vault has nested folders: 2019/summer,
# 2021/trip, batch2 …).
MISMATCH=""
FOLDERS=0
while IFS='|' read -r folder count; do
    [ -n "$folder" ] || continue
    FOLDERS=$((FOLDERS + 1))
    ondisk=$(find "$MOUNT/$folder" -maxdepth 1 -type f \( -name '*.jpg' -o -name '*.mp4' -o -name '*.mov' -o -name '*.mkv' \) | wc -l | tr -d ' ')
    [ "$ondisk" = "$count" ] || MISMATCH="$MISMATCH $folder($count vs $ondisk)"
done <<EOF
$(sql "SELECT folder, COUNT(*) FROM photo WHERE missing = 0 AND trashed = 0 GROUP BY folder;")
EOF
[ -z "$MISMATCH" ] && [ "$FOLDERS" -ge 5 ] \
    && pass "folder counts match the disk ($FOLDERS folders)" \
    || fail "folder counts match the disk:$MISMATCH ($FOLDERS folders)"

# ------------------------------------------------------------------ JoyTag

# JoyTag's tags go into the catalog; no photo changes at all (by design:
# rewriting every photo grows a vault's disk image). The vault has
# had no model so far; it goes in now.
checksums() { (cd "$MOUNT/Photos" && find . -type f ! -name '.*' -exec shasum {} + | sort -k2); }
jt_count() { sql "SELECT COUNT(*) FROM classification WHERE classifier = 'jt';"; }
# Every photo's classification time, so a later launch can show it re-tagged none.
jt_times() { sql "SELECT group_concat(id, ',') FROM (SELECT c.photo_id || ':' || c.classified_at AS id FROM classification c JOIN photo p ON p.id = c.photo_id WHERE c.classifier = 'jt' AND p.rel_path NOT LIKE '%_later.jpg' AND p.rel_path NOT LIKE '%after_rename.jpg' ORDER BY c.photo_id);"; }
if [ -f tools/joytag/package/JoyTag/manifest.json ]; then
    echo "Fifth launch: JoyTag installed — tagging stopped part-way, then finished"
    BEFORE_SUMS="$(checksums)"
    cp "$MOUNT/Photos/IMG_1000.jpg" "$WORK/fresh.jpg"   # keywords of its own: beach, Sky
    Scripts/joytag/install.sh "$MOUNT" >/dev/null && [ -f "$MOUNT/.catalog/models/JoyTag/manifest.json" ] \
        && pass "JoyTag installed in the vault's .catalog/models" || fail "JoyTag installed in the vault's .catalog/models"
    TAGGABLE=$(sql "SELECT COUNT(*) FROM photo WHERE missing = 0 AND trashed = 0 AND thumb_off IS NOT NULL;")
    PACK_BEFORE=$(size_of "$MOUNT/.catalog/thumbs.pack")

    # Slowed to under two photos a second, so there's a run to stop.
    launch PHOTOVAULT_SMOKE_SLOW_TAGGING=1
    t=0
    while [ $t -lt 120 ] && [ "$(jt_count)" -lt 3 ]; do sleep 0.5; t=$((t + 1)); done
    if stop_app; then pass "quit promptly in the middle of tagging"; else fail "quit promptly in the middle of tagging"; fi
    DONE=$(jt_count)
    [ "$DONE" -gt 0 ] && [ "$DONE" -lt "$TAGGABLE" ] \
        && pass "tagging stopped part-way ($DONE of $TAGGABLE kept)" \
        || fail "tagging stopped part-way (got $DONE of $TAGGABLE)"
    expect "WAL checkpointed after stopping mid-tagging" "$(size_of "$MOUNT/.catalog/catalog.sqlite-wal")" "0"

    launch
    if wait_for 180 "SELECT COUNT(*) FROM classification WHERE classifier = 'jt';" "$TAGGABLE"; then
        pass "the next launch finished tagging ($TAGGABLE photos and videos)"
    else
        fail "the next launch finished tagging (got $(jt_count) of $TAGGABLE)"
    fi
    expect "every photo's and video's tags kept in the catalog" \
        "$(sql "SELECT COUNT(*) FROM classification WHERE classifier = 'jt' AND in_file = 0;")" "$TAGGABLE"
    [ "$(sql "SELECT COUNT(*) FROM tag WHERE source = 'jt';")" -gt 0 ] && pass "JoyTag found tags" || fail "JoyTag found tags"
    expect "each with its score in the catalog" "$(sql "SELECT COUNT(*) FROM tag WHERE source = 'jt' AND confidence IS NULL;")" "0"
    expect "no thumbnail rebuilt" "$(size_of "$MOUNT/.catalog/thumbs.pack")" "$PACK_BEFORE"
    expect "no file left to re-read" \
        "$(sql "SELECT COUNT(*) FROM photo WHERE media_type = 0 AND missing = 0 AND tags_read != mtime;")" "0"
    CPU=$(idle_cpu_percent)
    [ "$CPU" -lt 10 ] && pass "idle once tagging is done (${CPU}% CPU)" || fail "idle once tagging is done (${CPU}% CPU)"
    if stop_app; then pass "quit promptly after tagging"; else fail "quit promptly after tagging"; fi

    expect "every photo and video byte for byte as it was" "$(checksums)" "$BEFORE_SUMS"

    echo "Sixth launch: nothing left to tag, and a new photo"
    TIMES=$(jt_times)
    cp "$WORK/fresh.jpg" "$MOUNT/Photos/batch2/fresh_later.jpg"
    launch
    if wait_for 60 "SELECT COUNT(*) FROM classification c JOIN photo p ON p.id = c.photo_id WHERE p.rel_path = 'Photos/batch2/fresh_later.jpg' AND c.classifier = 'jt';" "1"; then
        pass "a photo added later is tagged on the next launch"
    else
        fail "a photo added later is tagged on the next launch"
    fi
    expect "no other photo tagged again" "$(jt_times)" "$TIMES"
    expect "the new photo keeps its own keywords" \
        "$(sql "SELECT group_concat(t.name, ';') FROM (SELECT t.name FROM tag t JOIN photo p ON p.id = t.photo_id WHERE p.rel_path = 'Photos/batch2/fresh_later.jpg' AND t.source = 'manual' ORDER BY t.name) t;")" "Sky;beach"
    if stop_app; then pass "quit promptly"; else fail "quit promptly"; fi

    # ---------------------------------------------------------- pv-prefix-keywords

    echo "pv-prefix-keywords: the vault's own keywords marked as OtherTagger's, in the catalog, app closed"
    swift build -c release --product pv-prefix-keywords >/dev/null 2>&1
    TOOL="$(swift build -c release --product pv-prefix-keywords --show-bin-path)/pv-prefix-keywords"
    OWNED=$(sql "SELECT COUNT(DISTINCT t.photo_id) FROM tag t JOIN photo p ON p.id = t.photo_id WHERE t.source = 'manual' AND p.missing = 0;")
    OUT1="$("$TOOL" --vault "$MOUNT" --prefix ext --label "OtherTagger" --yes 2>&1)"
    printf '%s\n' "$OUT1" | grep -q "^$OWNED photos have keywords with no declared prefix" \
        && pass "it shows how many photos it will change ($OWNED)" \
        || fail "it shows how many photos it will change ($OWNED): $(printf '%s' "$OUT1" | sed -n 3p)"
    expect "every keyword of their own marked as OtherTagger's" "$(sql "SELECT COUNT(*) FROM tag WHERE source = 'manual';")" "0"
    expect "recorded in the catalog, under OtherTagger" \
        "$(sql "SELECT COUNT(*) FROM classification WHERE classifier = 'ext' AND label = 'OtherTagger' AND in_file = 0;")" "$OWNED"
    expect "the photos aren't touched" "$(checksums | grep -v fresh_later)" "$BEFORE_SUMS"
    OUT2="$("$TOOL" --vault "$MOUNT" --prefix ext --label "OtherTagger" --yes 2>&1)"
    printf '%s\n' "$OUT2" | grep -q "^Nothing to do" && pass "a second run changes nothing" \
        || fail "a second run changes nothing: $(printf '%s' "$OUT2" | tail -1)"
    expect "the app's clean-shutdown flag left as it was" "$(sql "SELECT value FROM meta WHERE key = 'clean_shutdown';")" "1"

    echo "Seventh launch: nothing to redo after marking; a photo added afterwards; a marked file read again"
    PACK_BEFORE=$(size_of "$MOUNT/.catalog/thumbs.pack")
    TIMES=$(jt_times)
    cp "$WORK/fresh.jpg" "$MOUNT/Photos/batch2/after_rename.jpg"
    touch "$MOUNT/Photos/IMG_1000.jpg"   # read again on the next launch
    launch
    if wait_for 60 "SELECT COUNT(*) FROM classification c JOIN photo p ON p.id = c.photo_id WHERE p.rel_path = 'Photos/batch2/after_rename.jpg' AND c.classifier = 'jt';" "1"; then
        pass "a photo added after the rename is tagged"
    else
        fail "a photo added after the rename is tagged"
    fi
    GROWTH=$(( $(size_of "$MOUNT/.catalog/thumbs.pack") - PACK_BEFORE ))
    [ "$GROWTH" -gt 0 ] && [ "$GROWTH" -lt 300000 ] \
        && pass "no thumbnail rebuilt after marking, only the new and the touched photo's" \
        || fail "no thumbnail rebuilt after marking (pack grew $GROWTH bytes)"
    expect "nothing re-tagged after marking" "$(jt_times)" "$TIMES"
    expect "the new photo's keywords are a person's own" \
        "$(sql "SELECT group_concat(t.source || ':' || t.name, ';') FROM (SELECT t.source, t.name FROM tag t JOIN photo p ON p.id = t.photo_id WHERE p.rel_path = 'Photos/batch2/after_rename.jpg' AND t.source != 'jt' ORDER BY t.name) t;")" "manual:Sky;manual:beach"
    expect "a marked photo read again keeps its keywords as OtherTagger's" \
        "$(sql "SELECT group_concat(t.source || ':' || t.name, ';') FROM (SELECT t.source, t.name FROM tag t JOIN photo p ON p.id = t.photo_id WHERE p.rel_path = 'Photos/IMG_1000.jpg' AND t.source != 'jt' ORDER BY t.name) t;")" "ext:Sky;ext:beach"
    expect "...having been read again" "$(sql "SELECT tags_read = mtime FROM photo WHERE rel_path = 'Photos/IMG_1000.jpg';")" "1"
    if stop_app; then pass "quit promptly"; else fail "quit promptly"; fi

    sleep 2
    OUTSIDE_AFTER="$(outside_state)"
    if [ "$OUTSIDE_AFTER" = "$OUTSIDE_BEFORE" ]; then
        pass "nothing written outside the vault while tagging (no model cache in ~/Library/Caches)"
    else
        fail "nothing written outside the vault while tagging — changed: $(printf '%s\n' "$OUTSIDE_AFTER" | grep -vxF "$OUTSIDE_BEFORE" | cut -d' ' -f1 | tr '\n' ' ')"
    fi
else
    echo "JoyTag: skipped — not packaged in this checkout (Scripts/joytag/package.sh)"
fi

# ------------------------------------------------------------------ places and playback

echo "Last launch: each view keeps its place; Repeat, Play Next, one speed, a slideshow"
MARK=$(wc -l < "$WORK/app.log" | tr -d ' ')
launch PHOTOVAULT_SMOKE_PLACES=1 PHOTOVAULT_SMOKE_PLAYBACK=1
t=0
while ! tail -n +$((MARK + 1)) "$WORK/app.log" | grep -q "closing the viewer ended"; do
    [ "$t" -ge 90 ] && break
    sleep 1; t=$((t + 1))
done
LOG="$(tail -n +$((MARK + 1)) "$WORK/app.log")"
said() { printf '%s\n' "$LOG" | sed -n "s/^smoke: $1/\\1/p" | head -1; }
expect "a view comes back where it was left" "$(said 'place kept: \([a-z]*\).*')" "yes"
expect "a folder opens at its own top, not where another view was" "$(said 'a folder opens at its top: \([a-z]*\)')" "yes"
expect "showing only videos and back keeps a view's place" "$(said 'place kept through a filter: \([a-z]*\).*')" "yes"
expect "a view keeps its place when come back to with a filter on" "$(said 'place kept with a filter on: \([a-z]*\).*')" "yes"
MOVES="$(said 'slideshow moved on \([0-9]*\) times.*')"
case "$MOVES" in 2|3) pass "a slideshow moves on after each photo's time ($MOVES moves in 5 s at 2 s)" ;;
                 *) fail "a slideshow moves on after each photo's time (got '$MOVES' moves in 5 s at 2 s)" ;; esac
expect "the display stays awake during a slideshow" "$(said 'slideshow moved on [0-9]* times; display kept awake: \([a-z]*\)')" "yes"
LOOPS="$(printf '%s\n' "$LOG" | grep -c "video ended and looped")"
[ "$LOOPS" -ge 1 ] && pass "Repeat loops a video ($LOOPS times)" || fail "Repeat loops a video"
expect "a speed chosen in the player becomes every video's" "$(said 'video speed taken from the player: \(.*\)')" "1.5"
expect "Play Next moves on when a video ends" "$(said 'moved on after the video ended: \([a-z]*\)')" "yes"
expect "a zoomed video keeps its zoom while it loops" \
    "$(printf '%s\n' "$LOG" | grep -A1 'smoke: after looping,' | sed -n 's/^smoke: video zoom //p')" "2.5"
expect "a video opened again starts unzoomed" \
    "$(printf '%s\n' "$LOG" | grep -A1 'smoke: opened again,' | sed -n 's/^smoke: video zoom //p')" "1.0"
expect "closing the viewer ends the slideshow" "$(said 'closing the viewer ended the slideshow: \([a-z]*\)')" "yes"
expect "the video speed is kept in the vault's catalog" "$(sql "SELECT value FROM meta WHERE key = 'setting.video.speed';")" "1.5"
expect "the slideshow time is kept in the vault's catalog" "$(sql "SELECT value FROM meta WHERE key = 'setting.viewer.interval';")" "2.0"
if stop_app; then pass "quit promptly"; else fail "quit promptly"; fi
expect "All Media's place is kept in the vault's catalog" "$(sql "SELECT COUNT(*) FROM meta WHERE key = 'setting.place.all';")" "1"

# ------------------------------------------------------------------ eject

echo "Eject"
if hdiutil detach "$MOUNT" -quiet 2>/dev/null; then
    pass "volume ejects once the app has quit"
    MOUNT=""
else
    fail "volume ejects once the app has quit"
fi

echo
if [ "$FAILED" -eq 0 ]; then
    echo "Smoke test passed: $PASSED checks"
    exit 0
else
    echo "Smoke test FAILED: $FAILED of $((PASSED + FAILED)) checks"
    [ -s "$WORK/app.log" ] && { echo "--- app output ---"; tail -20 "$WORK/app.log"; }
    [ -s "$WORK/app-stderr.log" ] && { echo "--- app errors (first launch) ---"; tail -20 "$WORK/app-stderr.log"; }
    exit 1
fi
