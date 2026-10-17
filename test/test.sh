#!/bin/sh
# Builds sample files, asks plugin.sh to preview each through a stand-in for nerd's socket, and checks the answers.
# macOS: it needs sqlite3, plutil, zip, tar, perl and jq in /usr/bin.
set -u
cd "$(dirname "$0")/.."
root=$(mktemp -d)
trap 'rm -rf "$root"' EXIT
export NERD_PLUGIN=peek NERD_PLUGIN_DATA="$root/data" NERD_SOCKET="$root/s.sock" PEEK_TEST_ROOT="$root"
mkdir -p "$NERD_PLUGIN_DATA" "$root/f"
f=$root/f
fails=0
check() {
    if eval "$2"; then printf 'ok   %s\n' "$1"; else printf 'FAIL %s\n' "$1"; fails=$((fails + 1)); fi
}

sqlite3 "$f/app.db" "CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT); INSERT INTO users (name) VALUES ('ada'), ('linus');
    CREATE TABLE \"odd \"\"name\" (x); CREATE VIEW names AS SELECT name FROM users;"
cp "$f/app.db" "$f/what is this? #1.sqlite"
printf 'TOPSECRET\n' > "$root/secret.txt"
sqlite3 "$f/evil.db" "CREATE VIEW leak AS SELECT readfile('$root/secret.txt') AS secret;"
printf 'not a database' > "$f/fake.db"
printf 'hello\n' > "$f/a.txt"
(cd "$f" && zip -q bundle.zip a.txt app.db && tar -czf bundle.tgz a.txt && cp bundle.tgz bundle.tar.gz && gzip -c a.txt > note.gz)
printf '<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>Name</key><string>nerd</string><key>Count</key><integer>3</integer></dict></plist>\n' > "$f/x.plist"
plutil -convert binary1 -o "$f/bin.plist" "$f/x.plist"
cat > "$f/nb.ipynb" <<'EOF'
{"cells":[{"cell_type":"markdown","source":["# Title\n","text"]},{"cell_type":"code","execution_count":1,"source":["print(1)"],"outputs":[{"output_type":"stream","name":"stdout","text":["1\n"]},{"output_type":"display_data","data":{"image/png":"AAAA","text/plain":["<Figure>"]}}]},{"cell_type":"code","execution_count":2,"source":"1/0","outputs":[{"output_type":"error","ename":"ZeroDivisionError","evalue":"division by zero","traceback":[]}]}],"metadata":{},"nbformat":4,"nbformat_minor":5}
EOF

# Slow, big and odd files for the limits.
views=$(awk 'BEGIN { for (i = 0; i < 60; i++) printf "CREATE VIEW v%02d AS WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c) SELECT x FROM c;", i }')
sqlite3 "$f/slow.db" "$views"
sqlite3 "$f/many.db" "$(awk 'BEGIN { for (i = 0; i < 60; i++) printf "CREATE TABLE t%02d (x);", i }')"
img=$(head -c 2400000 /dev/zero | base64 | tr -d '\n')
printf '{"cells":[{"cell_type":"code","execution_count":1,"source":"plot()","outputs":[{"output_type":"display_data","data":{"image/png":"%s","text/plain":"<Figure>"}}]}],"metadata":{},"nbformat":4,"nbformat_minor":5}\n' "$img" > "$f/big.ipynb"
mkfifo "$f/pipe.db"
printf '<?xml version="1.0"?><plist version="1.0"><dict><key>a</key>' > "$f/bad.plist"

# Every preview request in turn, each given time to be answered before the next; with BURST set, all at once 50 ms
# apart, then the one answer that is current.
ask() {
    rm -f "$NERD_SOCKET"
    perl -MIO::Socket::UNIX -e '
        my ($path, @files) = @ARGV;
        my $l = IO::Socket::UNIX->new(Type => SOCK_STREAM(), Local => $path, Listen => 1) or die "listen: $!";
        my $c = $l->accept or die "accept";
        $c->autoflush(1);
        <$c>;
        $| = 1;
        my $req = 0;
        for my $file (@files) {
            $req++;
            (my $p = $file) =~ s/(["\\])/\\$1/g;
            print $c "{\"event\":\"preview_request\",\"req\":$req,\"path\":\"$p\",\"cols\":80,\"rows\":20}\n";
            # The successor goes out once the slow count(*) of the first request runs, not after a fixed delay: under load the job may not have started it yet.
            if ($ENV{BURST_FILE}) { if ($req == 1) { for (1 .. 100) { last if -s $ENV{BURST_FILE}; select(undef, undef, undef, 0.1) } } else { select(undef, undef, undef, 0.05) } next }
            if ($ENV{BURST}) { if ($req == 1) { for (1 .. 100) { last if grep { /^sqlite3 / && /count\(\*\)/ && index($_, "$ENV{PEEK_TEST_ROOT}/f/slow.db") >= 0 } `ps -axo command=`; select(undef, undef, undef, 0.1) } } else { select(undef, undef, undef, 0.05) } next }
            my $m = <$c>;
            print $m;
        }
        # The plugin is still running here. Only the sqlite3 of this run on its own slow.db is counted, never one of an installed
        # peek or of another run. At the answer to the successor the replaced one must still run (its job was stopped, not
        # waited for); in the last second of 6, just past the 3 s alarm, none may be left.
        if ($ENV{BURST_FILE}) {
            my $m = <$c>; print $m;
            opendir(my $d, "$ENV{NERD_PLUGIN_DATA}/out"); print "{\"scratch\":" . (scalar grep { /^[cjxz]\./ } readdir $d) . "}\n";
        } elsif ($ENV{BURST}) {
            my $left = sub { scalar grep { /^sqlite3 / && index($_, "$ENV{PEEK_TEST_ROOT}/f/slow.db") >= 0 } `ps -axo command=` };
            my $m = <$c>; print $m;
            print "{\"alive\":" . $left->() . "}\n";
            my $n = 0; for (1 .. 60) { select(undef, undef, undef, 0.1); $n += $left->() if $_ > 50 }
            print "{\"sqlite3\":$n}\n";
        }
    ' "$NERD_SOCKET" "$@" &
    server=$!
    sleep 0.3
    sh "${PLUGIN:-plugin.sh}" 2> "$root/stderr" &
    plugin=$!
    wait "$server"
    kill "$plugin" 2>/dev/null
    wait "$plugin" 2>/dev/null
}

out=$(ask "$f/app.db" "$f/what is this? #1.sqlite" "$f/evil.db" "$f/fake.db" "$f/bundle.zip" "$f/bundle.tgz" "$f/bundle.tar.gz" "$f/note.gz" "$f/nb.ipynb" "$f/x.plist" "$f/bin.plist" "$f/missing.db")
text() { printf '%s\n' "$out" | jq -r --argjson r "$1" 'select(.Preview.req == $r) | .Preview.lines[] | map(.text) | join("")'; }

check "sqlite: tables and views, counts, schema, rows" 'text 1 | grep -qx "3 tables and views" && text 1 | grep -qx "users · 2 rows" && text 1 | grep -q "CREATE TABLE users" && text 1 | grep -q "linus"'
check "sqlite: a quote in a table name" 'text 1 | grep -q "odd \"name · 0 rows"'
check "sqlite: a path with spaces, ? and #" 'text 2 | grep -qx "users · 2 rows"'
# sqlite3 refuses readfile() in a view by itself, so this holds without -safe too; the virtual table check below is the one for -safe.
check "sqlite: a view that reads another file shows nothing of it" 'text 3 | grep -q "leak" && ! text 3 | grep -q TOPSECRET'
check "sqlite: not a database says so" 'text 4 | grep -q "Not a SQLite database"'
check "zip: the files inside" 'text 5 | grep -q "a.txt" && text 5 | grep -q "app.db"'
check "tgz and tar.gz: the files inside" 'text 6 | grep -q "a.txt" && text 7 | grep -q "a.txt"'
check "a gzip that is not a tar" 'text 8 | grep -q "A gzip file" || { text 8; false; }'
check "notebook: cells, outputs, images, errors" 'text 9 | grep -qx "# Title" && text 9 | grep -qx "In \[1\]" && text 9 | grep -qx "print(1)" && text 9 | grep -qx "1" && text 9 | grep -qx "\[image\]" && text 9 | grep -qx "ZeroDivisionError: division by zero"'
check "plist, XML and binary" 'text 10 | grep -q "\"Name\" => \"nerd\"" && text 11 | grep -q "\"Count\" => 3"'
check "a missing file is answered" 'text 12 | grep -q "cannot read missing.db"'
check "every request answered once" '[ "$(printf "%s\n" "$out" | grep -c "\"Preview\"")" = 12 ]'
check "no line over 256 characters" '[ "$(printf "%s\n" "$out" | jq -s "[.[].Preview.lines[][] .text | length] | max")" -le 256 ]'
check "nothing written beside the database" '[ "$(ls "$f" | grep -c -e "-journal" -e "-shm" -e "-wal")" = 0 ]'

began=$(date +%s)
out=$(ask "$f/slow.db" "$f/many.db" "$f/big.ipynb" "$f/pipe.db" "$f/bad.plist")
check "a slow database stops at the deadline and says so" 'text 1 | grep -q "Stopped after 8 seconds" && [ $(( $(date +%s) - began )) -lt 40 ]'
check "over 50 tables: the first 50, said so" 'text 2 | grep -qx "60 tables and views" && text 2 | grep -qx "The first 50 are shown."'
check "a notebook over 2 MB with an image" 'text 3 | grep -qx "plot()" && text 3 | grep -qx "\[image\]"'
check "a FIFO is answered, never read" 'text 4 | grep -q "cannot read pipe.db"'
check "a file that is not a property list says so" 'text 5 | grep -qx "Not a property list."'

out=$(BURST=1 ask "$f/slow.db" "$f/app.db")
check "a request replaced by a newer one: its answer dropped, its work stopped" 'printf "%s\n" "$out" | jq -e "select(.Preview) | .Preview.req == 2" > /dev/null && printf "%s\n" "$out" | jq -e "select(.sqlite3) // {sqlite3: 0} | .sqlite3 == 0" > /dev/null && printf "%s\n" "$out" | grep -q "\"sqlite3\":" && printf "%s\n" "$out" | jq -e "select(.alive != null) | .alive >= 1" > /dev/null'

for n in 1 2; do openssl req -x509 -newkey rsa:2048 -nodes -keyout "$root/k$n.pem" -out "$root/c$n.pem" -days 30 -subj "/CN=peek test $n/O=nerdterm" 2>/dev/null; done
cat "$root/c1.pem" "$root/c2.pem" "$root/k1.pem" > "$f/chain.pem"
openssl x509 -in "$root/c1.pem" -outform DER -out "$f/one.cer"
printf 'not a certificate\n' > "$f/junk.crt"
mkdir -p "$root/xl/xl/_rels" "$root/xl/xl/worksheets"
printf '<?xml version="1.0"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"/>' > "$root/xl/[Content_Types].xml"
printf '<?xml version="1.0"?><workbook xmlns="x" xmlns:r="r"><sheets><sheet name="Prices &amp; stock" sheetId="1" r:id="rId7"/><sheet name="Empty" sheetId="2" r:id="rId8"/></sheets></workbook>' > "$root/xl/xl/workbook.xml"
printf '<?xml version="1.0"?><Relationships xmlns="x"><Relationship Id="rId7" Type="t" Target="worksheets/sheet2.xml"/><Relationship Id="rId8" Type="t" Target="worksheets/sheet1.xml"/></Relationships>' > "$root/xl/xl/_rels/workbook.xml.rels"
printf '<?xml version="1.0"?><sst xmlns="x"><si><t>item</t></si><si><t>price</t></si><si><r><t>cof</t></r><r><t>fee</t></r></si><si><t>tea\n&amp; milk</t></si></sst>' > "$root/xl/xl/sharedStrings.xml"
printf '<?xml version="1.0"?><worksheet xmlns="x"><sheetData><row r="1"><c r="A1" t="s"><v>0</v></c><c r="B1" t="s"><v>1</v></c><c r="D1" t="inlineStr"><is><t>note</t></is></c></row><row r="2"><c r="A2" t="s"><v>2</v></c><c r="B2"><v>3.5</v></c><c r="D2" t="b"><v>1</v></c></row><row r="3"><c r="A3" t="s"><v>3</v></c><c r="B3"><v>2</v></c></row></sheetData></worksheet>' > "$root/xl/xl/worksheets/sheet2.xml"
printf '<?xml version="1.0"?><worksheet xmlns="x"><sheetData/></worksheet>' > "$root/xl/xl/worksheets/sheet1.xml"
(cd "$root/xl" && zip -q -r "$f/book.xlsx" .)
(cd "$f" && zip -q notbook.xlsx a.txt)

out=$(ask "$f/chain.pem" "$f/one.cer" "$f/junk.crt" "$f/book.xlsx" "$f/notbook.xlsx")
check "certificates: each one in a PEM chain" 'text 1 | grep -qx "Certificate 1 of 2" && text 1 | grep -qx "Subject: O=nerdterm,CN=peek test 2" && text 1 | grep -q "^SHA-256: [0-9A-F:]*$"'
check "a private key in the file is never printed" 'text 1 | grep -q "holds a private key; it is not shown" && ! text 1 | grep -q "PRIVATE KEY-----" && ! text 1 | grep -q "^MII"'
check "a DER certificate" 'text 2 | grep -qx "Subject: O=nerdterm,CN=peek test 1" && text 2 | grep -q "^Valid until: "'
check "not a certificate says so" 'text 3 | grep -qx "No certificate this can read."'
check "excel: sheets by the workbook's order and names, through its relationships" 'text 4 | grep -qx "Prices & stock" && text 4 | grep -qx "Empty" && [ "$(text 4 | grep -n -x -e "Prices & stock" -e Empty | cut -d: -f2 | tr "\n" " ")" = "Prices & stock Empty " ]'
check "excel: shared, rich, inline, number and boolean cells, a gap kept" 'text 4 | grep -q "^item  *price  *-  *note" && text 4 | grep -q "^coffee  *3.5  *-  *TRUE" && text 4 | grep -q "^tea & milk  *2"'
check "not a workbook says so" 'text 5 | grep -qx "Not an Excel workbook."'

# Hostile and odd files.
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$root/k3.pem" -out "$f/spoof.pem" -days 30 -subj '/CN=evil.com\/O=Apple Inc.' 2>/dev/null
head -c 60000000 /dev/urandom > "$f/huge.cer"
w="$root/w"
cp -R "$root/xl" "$w"
awk 'BEGIN { printf "<?xml version=\"1.0\"?><worksheet><sheetData><row r=\"1\"><c r=\"A1\" t=\"inlineStr\"><is><t>top</t></is></c></row>"; for (i = 0; i < 2000000; i++) printf "\n"; printf "</sheetData></worksheet>" }' > "$w/xl/worksheets/sheet2.xml"
(cd "$w" && zip -q -r "$f/lines.xlsx" .)
o="$root/o"
cp -R "$root/xl" "$o"
sheets=$(awk 'BEGIN { for (i = 1; i <= 12; i++) printf "<sheet name=\"S%d\" sheetId=\"%d\" r:id=\"rId8\"/>", i, i }')
printf '<?xml version="1.0"?><workbook xmlns="x" xmlns:r="r"><sheets>%s</sheets></workbook>' "$sheets" > "$o/xl/workbook.xml"
printf '<?xml version="1.0"?><worksheet><sheetData><row><c t="inlineStr"><is><t>no address</t></is></c><c t="inlineStr"><is><t>a&#64;b</t></is></c></row></sheetData></worksheet>' > "$o/xl/worksheets/sheet1.xml"
(cd "$o" && zip -q -r "$f/odd.xlsx" .)

began=$(date +%s)
out=$(ask "$f/spoof.pem" "$f/huge.cer" "$f/lines.xlsx" "$f/odd.xlsx")
check "a / inside a name stays in that name" 'text 1 | grep -qx "Subject: CN=evil.com/O=Apple Inc." && ! text 1 | grep -q "^Subject: O="'
check "a huge .cer: read up to 2 MB, answered, no copy left" 'text 2 | grep -qx "No certificate this can read." && [ "$(ls "$NERD_PLUGIN_DATA/out" | grep -c "^[cj]\.")" = 0 ]'
check "a sheet of two million lines: shown, quickly" 'text 3 | grep -qx "top" && [ $(( $(date +%s) - began )) -lt 30 ]'
check "past 10 sheets, said so; a cell without an address; &#64;" 'text 4 | grep -qx "The first 10 of 12 sheets are shown." && text 4 | grep -q "^no address  *a@b"'

# A certificate preview stopped by a newer request: a stand-in openssl holds it, and no copy of the file may be left.
mkdir "$root/oshim"
printf '#!/bin/sh\necho $$ > "%s/openssl.pid"\nexec /bin/sleep 15\n' "$root" > "$root/oshim/openssl"
chmod +x "$root/oshim/openssl"
sed "s#^PATH=/usr/bin:/bin#PATH=$root/oshim:/usr/bin:/bin#" plugin.sh > "$root/plugin-oshim.sh"
out=$(PLUGIN="$root/plugin-oshim.sh" BURST_FILE="$root/openssl.pid" ask "$f/chain.pem" "$f/note.gz")
check "a certificate preview stopped by a newer request leaves no copy" 'printf "%s\n" "$out" | jq -e "select(.scratch != null) | .scratch == 0" > /dev/null'

# Guards no earlier test could see.
# -safe is the only lock against a virtual table in the schema reading another file.
printf 'TOPSECRET-READ' > "$root/zsecret.txt"
(cd "$root" && zip -q -0 victim.zip zsecret.txt)
sqlite3 "$f/zvt.db" "CREATE VIRTUAL TABLE z USING zipfile('$root/victim.zip');"
# A WAL database: opened without immutable, sqlite3 writes -shm and -wal beside it.
mkdir "$root/wal"
sqlite3 "$root/wal/w.db" "PRAGMA journal_mode=wal; CREATE TABLE t (x); INSERT INTO t VALUES (1);" > /dev/null
rm -f "$root/wal/w.db-shm" "$root/wal/w.db-wal"
# A table name with a control character (sqlite3 prints it escaped); a plist value with ESC and U+009B (plutil prints them raw).
sqlite3 "$f/ctl.db" "$(printf 'CREATE TABLE "ev\033[2Jil" (x); CREATE TABLE ok (v);')"
printf '{"a":"x\\u001b[2Jy\\u009bz"}' > "$root/ctl.json"
plutil -convert binary1 -o "$f/ctl.plist" "$root/ctl.json"
# unzip would read a[12].zip as a pattern and list a1.zip.
mkdir "$root/wild"
printf 'x' > "$root/wild/other-member.txt"; printf 'x' > "$root/wild/mine.txt"
(cd "$root/wild" && zip -q a1.zip other-member.txt && zip -q 'a[12].zip' mine.txt && rm other-member.txt mine.txt)
# A notebook one byte over 32 MB; an odd one: ESC and 1000 characters in a count, a numeric cell type, data that is not an object.
{ printf '{"cells":[]}'; head -c 33554432 /dev/zero | tr '\0' ' '; } > "$f/over.ipynb"
jq -n -c --arg c "$(printf '\033')$(head -c 1000 /dev/zero | tr '\0' 9)" '{cells: [{cell_type: "code", execution_count: $c, source: "a", outputs: [{output_type: "display_data", data: "x"}, {output_type: "stream", text: "after"}]}, {cell_type: 5, source: "b"}]}' > "$f/odd.ipynb"
ln -s over.ipynb "$f/over-link.ipynb"
sqlite3 "$f/ctl2.db" "$(printf 'CREATE TABLE "ev\033[2Jil" (x);')"
for n in $(seq 21); do cat "$root/c1.pem"; done > "$f/many.pem"

out=$(ask "$f/zvt.db" "$root/wal/w.db" "$f/ctl.db" "$f/ctl.plist" "$root/wild/a[12].zip" "$f/over.ipynb" "$f/odd.ipynb" "$f/many.pem" "$f/note.gz" "$f/over-link.ipynb" "$f/ctl2.db")
check "sqlite: a virtual table in the schema reads nothing of another file" 'text 1 | grep -q "^z ·" && ! text 1 | grep -q TOPSECRET-READ'
check "sqlite: a WAL database leaves nothing beside it" 'text 2 | grep -qx "t · 1 rows" && [ "$(ls "$root/wal" | grep -c -e "-shm" -e "-wal")" = 0 ]'
check "plist: ESC and U+009B in a value never reach the output" 'text 4 | grep -q "x\[2Jyz" && printf "%s\n" "$out" | jq -e "select(.Preview.req == 4) | [.Preview.lines[][].text | test(\"[\\u0000-\\u001f\\u007f-\\u009f]\")] | any | not" > /dev/null'
check "sqlite: a table whose name holds a control character is left out" 'text 3 | grep -qx "1 table or view" && ! text 3 | grep -q "il · "'
check "zip: a path with a wildcard is read literally" 'text 5 | grep -q "mine.txt" && ! text 5 | grep -q "other-member.txt" && text 5 | grep -qx "Archive:  a\[12\].zip"'
check "a notebook over 32 MB is refused, said so" 'text 6 | grep -qx "A notebook over 32 MB is not shown."'
check "notebook: heading cut, stripped and a string; a data that is not an object loses nothing after it" 'text 7 | grep -qx "after" && printf "%s\n" "$out" | jq -e "select(.Preview.req == 7) | [.Preview.lines[][].text | type] | unique == [\"string\"]" > /dev/null && [ "$(text 7 | awk "length > 256" | wc -l)" -eq 0 ] && ! text 7 | grep -q "$(printf "\033")"'
check "certificates: past 20, said so" 'text 8 | grep -qx "The first 20 are shown." && text 8 | grep -qx "Certificate 20 of 21" && ! text 8 | grep -q "Certificate 21 of"'
check "a link to a notebook over 32 MB is refused too" 'text 10 | grep -qx "A notebook over 32 MB is not shown."'
check "a database whose tables all hold control characters says so" 'text 11 | grep -qx "Tables with a control character in their name are not shown."'

# A gzip that never ends and never prints: head never closes the pipe, so only the alarm stops it. A stand-in gzip
# first in PATH sleeps 15 seconds; with the alarm the answer comes in seconds and the stand-in is gone.
mkdir "$root/shim"
printf '#!/bin/sh\necho $$ > "%s/gzip.pid"\nexec /bin/sleep 15\n' "$root" > "$root/shim/gzip"
chmod +x "$root/shim/gzip"
sed "s#^PATH=/usr/bin:/bin#PATH=$root/shim:/usr/bin:/bin#" plugin.sh > "$root/plugin-shim.sh"
began=$(date +%s)
out=$(PLUGIN="$root/plugin-shim.sh" ask "$f/note.gz")
took=$(( $(date +%s) - began ))
check "a gzip that never ends stops at the alarm, and none is left" '[ -s "$root/gzip.pid" ] && text 1 | grep -q "A gzip file" && [ "$took" -lt 10 ] && ! kill -0 "$(cat "$root/gzip.pid")" 2>/dev/null'

[ "$fails" = 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
