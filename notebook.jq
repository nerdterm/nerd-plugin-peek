# A Jupyter notebook as preview lines, one JSON array per line: cells in order, their text outputs under them.
def cut: gsub("\t"; "    ") | gsub("[\u0000-\u001f\u007f-\u009f]"; "") | .[0:256];
def text: if type == "array" then join("") elif type == "string" then . else "" end;
def lines($role): split("\n")[] | [{text: cut, role: $role}];
def blank: [{text: "", role: "text"}];

(.cells // []) | to_entries[] | .value as $c | .key as $i
| blank,
  [{text: ((if $c.cell_type == "code" then "In [\($c.execution_count // " ")]" else ($c.cell_type // "cell" | tostring) end) | cut), role: "accent"}],
  ($c.source | text | lines(if $c.cell_type == "code" then "teal" else "text" end)),
  ($c.outputs // [] | .[] | (.data | objects // {}) as $d
    | if .output_type == "stream" then (.text | text | lines("muted"))
      elif .output_type == "error" then [{text: ("\(.ename): \(.evalue)" | cut), role: "bad"}]
      elif $d["text/plain"] then
        (if $d["image/png"] or $d["image/jpeg"] or $d["image/svg+xml"] then [{text: "[image]", role: "faint"}] else empty end),
        ($d["text/plain"] | text | lines("muted"))
      elif $d["image/png"] or $d["image/jpeg"] then [{text: "[image]", role: "faint"}]
      elif $d["text/html"] then [{text: "[html]", role: "faint"}]
      else empty end)
