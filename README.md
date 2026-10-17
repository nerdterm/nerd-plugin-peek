# peek

A plugin for [nerd](https://github.com/nerdterm/nerd): previews for files nerd would otherwise show as binary or raw.
Select one in the tree and the preview shows:

| File | Preview |
|---|---|
| SQLite (`.db`, `.sqlite`, `.sqlite3`) | the tables and views (the first 50), each with its row count, its schema and its first 20 rows |
| Archives (`.zip`, `.whl`, `.jar`, `.tar`, `.tgz`, `.tar.gz`) | the files inside and their sizes; nothing is extracted |
| A `.gz` that is not a tar | that it is a gzip file, and its size |
| Jupyter notebooks (`.ipynb`) | the cells in order, with their text outputs; images and HTML as a note |
| Property lists (`.plist`, XML or binary) | keys and values |
| Certificates (`.pem`, `.crt`, `.cer`, PEM or DER) | each certificate's subject, issuer, validity and SHA-256 fingerprint; a private key in the file is never shown |
| Excel workbooks (`.xlsx`) | each sheet by name, its first 50 rows of 20 columns; formulas are not evaluated, their saved values are shown |

Risk level 0: it only shows things. It has no network and writes nothing outside its own data folder. A database is
opened read only and immutable, so nothing is written beside it, and with sqlite3's `-safe`, so nothing in it can read
or write another file. Immutable also means a database another program is writing in WAL mode shows what its main file
holds, without the newest changes. Each program it runs is stopped after 3 seconds, a whole preview after 8 seconds
(it says so). Selecting another file stops the one before; the program it was running stops within 3 seconds. A
notebook over 32 MB is not read.

`demo.cast` is a recording of it (asciinema), made with sample files.

## Install

In nerd: **Plugins…** in the main menu, then **peek**. Or in a terminal:

```sh
nerd --plugin-add https://github.com/nerdterm/nerd-plugin-peek
```

## Requirements

nerd 0.7.0 or later, and macOS 15 or later (for `/usr/bin/jq`). It uses only programs that come with macOS: `sqlite3`, `unzip`, `tar`, `gzip`,
`plutil`, `openssl`, `awk`, `perl`.

## Development

`sh test/test.sh` builds sample files of every kind, previews each through a stand-in for nerd's socket and checks
the result. `nerd --plugin-check --catalog .` and `nerd --plugin-trial .` check the plugin as the catalog will.

## Licence

MIT, see [LICENSE](LICENSE).
