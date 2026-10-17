# One worksheet's XML, given on one line, as tab-separated rows; its shared strings read first (one string a line).
# Usage: LC_ALL=C awk -v rows=50 -v cols=20 -f xlsx.awk strings.txt sheet-on-one-line.xml
function col(ref,   n, i, c) {
    n = 0
    for (i = 1; i <= length(ref); i++) {
        c = substr(ref, i, 1)
        if (c !~ /[A-Z]/) break
        n = n * 26 + index("ABCDEFGHIJKLMNOPQRSTUVWXYZ", c)
    }
    return n
}
function attr(s, name,   m) {
    if (match(s, " " name "=\"[^\"]*\"")) { m = substr(s, RSTART + length(name) + 3, RLENGTH - length(name) - 4); return m }
    return ""
}
function decode(s,   m, c) {
    # Numeric entities in the ASCII range become their character; any other stays as written.
    while (match(s, /&#[0-9]+;/)) {
        c = substr(s, RSTART + 2, RLENGTH - 3) + 0
        s = substr(s, 1, RSTART - 1) (c >= 32 && c < 127 ? sprintf("%c", c) : " ") substr(s, RSTART + RLENGTH)
    }
    gsub(/&lt;/, "<", s); gsub(/&gt;/, ">", s); gsub(/&quot;/, "\"", s); gsub(/&apos;/, "'", s); gsub(/&amp;/, "\\&", s)
    gsub(/[\t\r\n]/, " ", s)
    return s
}
FNR == NR { str[NR - 1] = $0; next }
{ xml = xml $0 " " }
END {
    n = split(xml, parts, "<row")
    shown = 0
    for (r = 2; r <= n && shown < rows; r++) {
        row = parts[r]
        sub(/<\/row>.*/, "", row)
        k = split(row, cells, "<c ")
        delete line
        last = 0
        for (i = 2; i <= k; i++) {
            c = " " cells[i]
            head = c; sub(/>.*/, "", head)
            # The address is optional: a cell without one follows the cell before it.
            ref = attr(head, "r")
            ci = ref == "" ? last + 1 : col(ref)
            if (ci < 1 || ci > cols) continue
            t = attr(head, "t")
            v = ""
            if (t == "inlineStr") {
                if (match(c, /<t[^>]*>[^<]*<\/t>/)) { v = substr(c, RSTART, RLENGTH); sub(/<t[^>]*>/, "", v); sub(/<\/t>/, "", v) }
            } else if (match(c, /<v>[^<]*<\/v>/)) {
                v = substr(c, RSTART + 3, RLENGTH - 7)
                if (t == "s") v = str[v + 0]
                else if (t == "b") v = (v == "1" ? "TRUE" : "FALSE")
            }
            v = decode(v)
            # Bytes, not characters (LC_ALL=C): a character cut in two loses its first bytes too.
            if (length(v) > 40) { v = substr(v, 1, 39); sub(/[\300-\377][\200-\277]*$/, "", v); v = v "…" }
            line[ci] = v
            if (ci > last) last = ci
        }
        out = ""
        for (i = 1; i <= last; i++) out = out (i > 1 ? "\t" : "") ((i in line) && line[i] != "" ? line[i] : "-")
        print out
        shown++
    }
    if (n - 1 > rows) print "…"
}
