#!/bin/sh
# peek: previews of SQLite databases, archives, Jupyter notebooks and property lists.
# Each request runs in the background; a newer one stops it and makes its answer stale. Every message to nerd goes
# through one writer, which drops a stale answer.
PATH=/usr/bin:/bin
here=$(pwd)
cd "$NERD_PLUGIN_DATA" || exit 1
rm -rf to-nerd msgs out
rm -f cur.*
mkfifo to-nerd msgs
mkdir out
# What one program may print before it is cut, how long it may take, and how long a whole preview may take.
BYTES=2097152
SECONDS_MAX=3
DEADLINE=8

nojq() {
    printf '[[{"text":"peek needs macOS 15 or later: it builds previews with /usr/bin/jq","role":"warn"}]]'
}

emit() {
    f=$(mktemp out/m.XXXXXX)
    cat > "$f"
    printf '%s %s %s\n' "$f" "$jkind" "$jturn" >&4
}

# Runs $@ for at most SECONDS_MAX seconds, its output cut at BYTES; the sandbox has no timeout, perl's alarm is one.
# Its errors are dropped: they would mix into the content.
limited() {
    perl -e 'alarm shift; exec @ARGV' "$SECONDS_MAX" "$@" 2>/dev/null | head -c "$BYTES"
}

# Still this job's turn and within the preview's deadline: a request a newer one replaced stops between steps.
current() {
    [ "$(cat "cur.$jkind" 2>/dev/null)" = "$jturn" ] && [ $(( $(date +%s) - started )) -lt "$DEADLINE" ]
}

# Text on stdin as preview lines in one role; each line cut so it fits 512 cells.
as() {
    jq -R -c --arg r "$1" '[{text: (gsub("\t"; "    ") | gsub("[\u0000-\u001f\u007f-\u009f]"; "") | .[0:256]), role: $r}]'
}
say() { printf '%s\n' "$2" | as "$1"; }

# SQLite: every table and view with its row count, its schema, and its first rows. Read only and immutable, so
# nothing is written beside the file; -safe is the only lock against a virtual table in the schema reading another file.
sqlite() {
    f=$1
    uri="file:$(printf '%s' "$f" | jq -sRr @uri | sed 's#%2F#/#g')?immutable=1"
    q() { limited sqlite3 -init /dev/null -readonly -safe -bail "$uri" "$@"; }
    [ "$(head -c 15 "$f")" = "SQLite format 3" ] || { say warn "Not a SQLite database."; return; }
    # Names with a control character in them would split or be asked for escaped; they are left out rather than misread.
    names=$(q "SELECT name FROM sqlite_schema WHERE type IN ('table','view') AND name NOT LIKE 'sqlite_%' AND name NOT GLOB '*[' || char(1) || '-' || char(31) || char(127) || '-' || char(159) || ']*' ORDER BY name;")
    if [ -z "$names" ]; then
        if [ "$(q "SELECT count(*) FROM sqlite_schema WHERE type IN ('table','view') AND name NOT LIKE 'sqlite_%';")" -gt 0 ]; then
            say faint "Tables with a control character in their name are not shown."
        else
            say faint "An empty database: no tables."
        fi
        return
    fi
    n=$(printf '%s\n' "$names" | grep -c .)
    if [ "$n" = 1 ]; then say faint "1 table or view"; else say faint "$n tables and views"; fi
    [ "$n" -gt 50 ] && say faint "The first 50 are shown."
    printf '%s\n' "$names" | head -n 50 | while IFS= read -r t; do
        current || { say faint "Stopped after $DEADLINE seconds; the rest is not shown."; break; }
        id=$(printf '%s' "$t" | sed 's/"/""/g')
        say text ""
        say accent "$t · $(q "SELECT count(*) FROM \"$id\";" | head -n 1) rows"
        q "SELECT sql FROM sqlite_schema WHERE name = '$(printf '%s' "$t" | sed "s/'/''/g")';" | as faint
        q -header -column "SELECT * FROM \"$id\" LIMIT 20;" | as text
    done
}

# Archives: the files inside and their sizes, never extracted.
archive() {
    f=$1
    case $f in
        *.zip | *.whl | *.jar)
            # unzip reads its archive argument as a wildcard; a link with a fixed name is read literally.
            tmp=$(mktemp -d out/z.XXXXXX)
            ln -s -- "$f" "$tmp/a.zip"
            out=$(limited unzip -l "$tmp/a.zip")
            rm -rf "$tmp"
            printf '%s' "$out" | head -n 1 | grep -q '^Archive:' || { say warn "Not a zip archive."; return; }
            out=$(printf 'Archive:  %s\n' "${f##*/}"; printf '%s\n' "$out" | tail -n +2)
            ;;
        *)
            # A tar says so at byte 257; bsdtar alone would read any text as an mtree listing.
            case $f in
                *.gz | *.tgz) magic=$(limited gzip -dc "$f" | head -c 262 | tail -c 5) ;;
                *) magic=$(head -c 262 "$f" | tail -c 5) ;;
            esac
            if [ "$magic" != ustar ]; then
                case $f in
                    *.gz | *.tgz) say text "A gzip file of $(stat -L -f %z "$f") bytes, not a tar archive." ;;
                    *) say warn "Not a tar archive." ;;
                esac
                return
            fi
            out=$(limited tar -tvf "$f")
            ;;
    esac
    printf '%s\n' "$out" | as text
}

# Jupyter: cells in order with their text outputs; images and HTML as a note. jq reads the whole file, images and
# all, under the time limit and a size cap; its lines are capped too.
notebook() {
    [ "$(stat -L -f %z "$1")" -le 33554432 ] || { say faint "A notebook over 32 MB is not shown."; return; }
    out=$(perl -e 'alarm shift; exec @ARGV' "$SECONDS_MAX" jq -c -f "$here/notebook.jq" "$1" 2>/dev/null | head -n 2001)
    [ -n "$out" ] || { say warn "Not a notebook this can read."; return; }
    printf '%s\n' "$out"
}

# Certificates: subject, issuer, validity and fingerprint of each one in the file, PEM or DER. Only openssl's
# answers are shown, never the file's own lines, so a private key in it is never printed.
certs() {
    f=$1
    tmp=$(mktemp -d out/c.XXXXXX)
    # Only the file's first BYTES are read, once; everything below works on that copy.
    head -c "$BYTES" "$f" > "$tmp/in"
    mkdir "$tmp/certs"
    if grep -q -e '-----BEGIN CERTIFICATE-----' "$tmp/in"; then
        # Closed after each one, so thousands of certificates never run out of open files.
        awk -v d="$tmp/certs" '/-----BEGIN CERTIFICATE-----/ { n++; on = 1; if (n > 20) exit } on { print > (d "/" n ".pem") } /-----END CERTIFICATE-----/ { on = 0; close(d "/" n ".pem") }' "$tmp/in"
        n=$(grep -c -e '-----BEGIN CERTIFICATE-----' "$tmp/in")
        [ "$n" -gt 20 ] && say faint "The first 20 are shown."
        form=PEM
    else
        cp "$tmp/in" "$tmp/certs/1.pem"
        n=1
        form=DER
    fi
    grep -q -e '-----BEGIN [A-Z ]*PRIVATE KEY-----' "$tmp/in" && say warn "This file also holds a private key; it is not shown."
    shown=0
    for c in $(ls "$tmp/certs" | sort -n); do
        current || { say faint "Stopped after $DEADLINE seconds; the rest is not shown."; break; }
        # RFC 2253 names: a "/" inside a value stays part of it and cannot pose as another field.
        out=$(limited openssl x509 -inform "$form" -in "$tmp/certs/$c" -noout -nameopt RFC2253,-esc_msb -subject -issuer -dates -fingerprint -sha256)
        [ -n "$out" ] || continue
        shown=$((shown + 1))
        say text ""
        say accent "Certificate $shown of $n"
        printf '%s\n' "$out" | sed -E 's#^subject= ?#Subject: #; s#^issuer= ?#Issuer: #; s#^notBefore=#Valid from: #; s#^notAfter=#Valid until: #; s#^(SHA256|sha256) Fingerprint=#SHA-256: #' | as text
    done
    rm -rf "$tmp"
    [ "$shown" -gt 0 ] || say warn "No certificate this can read."
}

# Excel: each sheet's name and its first 50 rows of 20 columns, read from the workbook's XML; nothing is evaluated.
excel() {
    f=$1
    tmp=$(mktemp -d out/x.XXXXXX)
    # unzip reads its archive argument as a wildcard; a link with a fixed name is read literally.
    z=$tmp/a.zip
    ln -s -- "$f" "$z"
    limited unzip -Z1 "$z" | grep -qx 'xl/workbook.xml' || { rm -rf "$tmp"; say warn "Not an Excel workbook."; return; }
    limited unzip -p "$z" xl/sharedStrings.xml | tr '\n' ' ' | sed 's#</si>#\
#g' | sed 's/<rPh[^>]*>.*<\/rPh>//g; s/<[^>]*>//g' > "$tmp/strings"
    # Sheet order and names from the workbook; their files from its relationships.
    limited unzip -p "$z" xl/_rels/workbook.xml.rels | tr '<' '\n' | sed -n 's/.*Id="\([^"]*\)".*Target="\([^"]*\)".*/\1 \2/p' > "$tmp/rels"
    limited unzip -p "$z" xl/workbook.xml | tr '<' '\n' | grep '^sheet ' | sed -n 's/.* name="\([^"]*\)".* r:id="\([^"]*\)".*/\2\t\1/p' > "$tmp/all"
    head -n 10 "$tmp/all" > "$tmp/sheets"
    [ "$(grep -c . "$tmp/all")" -gt 10 ] && say faint "The first 10 of $(grep -c . "$tmp/all") sheets are shown."
    tab=$(printf '\t')
    while IFS="$tab" read -r rid name; do
        current || { say faint "Stopped after $DEADLINE seconds; the rest is not shown."; break; }
        target=$(awk -v r="$rid" '$1 == r { print $2 }' "$tmp/rels" | sed 's#^/xl/##; s#^#xl/#')
        say text ""
        say accent "$(printf '%s' "$name" | sed 's/&amp;/\&/g; s/&lt;/</g; s/&gt;/>/g; s/&quot;/"/g')"
        limited unzip -p "$z" "$target" > "$tmp/sheet"
        # One line in, so awk never grows a string line by line; under the alarm like every other program.
        tr '\n' ' ' < "$tmp/sheet" > "$tmp/flat"
        LC_ALL=C limited awk -v rows=50 -v cols=20 -f "$here/xlsx.awk" "$tmp/strings" "$tmp/flat" | column -t -s "$tab" | as text
    done < "$tmp/sheets"
    rm -rf "$tmp"
}

# plutil's own verdict first: through a pipe its exit status would be lost.
plist() {
    perl -e 'alarm shift; exec @ARGV' "$SECONDS_MAX" plutil -lint -s "$1" > /dev/null 2>&1 || { say warn "Not a property list."; return; }
    limited plutil -p "$1" | as text
}

# A case inside $(…) does not parse in macOS's sh (bash 3.2): the choice is a function of its own.
render() {
    f=$1
    # A FIFO or a device would block a read forever: only regular files (a link to one is followed).
    [ -f "$f" ] && [ -r "$f" ] || { say warn "cannot read ${f##*/}"; return; }
    case $(printf '%s' "${f##*.}" | tr 'A-Z' 'a-z') in
        db | sqlite | sqlite3) sqlite "$f" ;;
        zip | whl | jar | tar | tgz | gz) archive "$f" ;;
        ipynb) notebook "$f" ;;
        plist) plist "$f" ;;
        pem | crt | cer) certs "$f" ;;
        xlsx) excel "$f" ;;
        *) say warn "peek does not read this type." ;;
    esac
}

preview() {
    req=$1
    f=$2
    started=$(date +%s)
    lines=$(render "$f" | head -n 2001)
    [ -n "$lines" ] || lines=$(say warn "Nothing to show.")
    printf '%s\n' "$lines" | jq -s -c --argjson req "$req" '{Preview: {req: $req, lines: .[0:2000], cut: (length > 2000)}}' | emit
}

job() {
    jkind=$1
    shift
    jturn=$(( $(cat "cur.$jkind" 2>/dev/null || echo 0) + 1 ))
    printf '%s' "$jturn" > "cur.$jkind"
    eval "old=\${job_$jkind:-}"
    if [ -n "$old" ]; then
        kill "$old" 2>/dev/null
        wait "$old" 2>/dev/null
    fi
    "$@" &
    eval "job_$jkind=$!"
}

nc -U "$NERD_SOCKET" < to-nerd | {
    printf '{"Connect":{"protocol":2,"role":"plugin","plugin":"%s","events":["preview_request"]}}\n' "$NERD_PLUGIN" >&3
    while read -r f k t; do
        [ "$(cat "cur.$k" 2>/dev/null)" = "$t" ] && cat "$f" >&3
        rm -f "$f"
    done < msgs &
    exec 4> msgs
    while IFS= read -r line; do
        if [ ! -x /usr/bin/jq ]; then
            req=$(printf '%s' "$line" | sed -n 's/.*"req":\([0-9]*\).*/\1/p')
            [ -n "$req" ] && printf '{"Preview":{"req":%s,"lines":%s,"cut":false}}\n' "$req" "$(nojq)" >&3
            continue
        fi
        vars=$(printf '%s' "$line" | jq -r 'def s: (. // "" | tostring); @sh "ev=\(.event | s) req=\(.req | s) path=\(.path | s)"' 2>/dev/null)
        [ -n "$vars" ] || continue
        eval "$vars"
        [ "$ev" = preview_request ] && job preview preview "$req" "$path"
    done
    exec 4>&-
} 3> to-nerd
