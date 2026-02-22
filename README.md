# versions (Swift)

A command-line interface to the macOS file versioning system, written in Swift.
This is a Swift rewrite and improvement of [jcfieldsdev/versions](https://github.com/jcfieldsdev/versions) (Objective-C), with the addition of `--save` to create new versions programmatically and a `--hook` mode for Claude Code integration.

Requires macOS 10.12 (Sierra) or higher.

## Installation

```bash
chmod +x install.sh
./install.sh
```

Or compile manually:

```bash
swiftc versions.swift -O -o versions
sudo mv versions /usr/local/bin/
```

Or run without compiling (slower startup):

```bash
chmod +x versions.swift
./versions.swift myfile.swift
```

## Usage

```
versions [option] <file> [destination]
```

If called with no option, lists all versions of the file.

| Option | Short | Description |
|--------|-------|-------------|
| _(none)_ | | List all versions |
| `--save` | `-s` | **Save a new version of the current file now** |
| `--view <id>` | `-v <id>` | Print a version's contents to stdout |
| `--restore <id> <dest>` | `-r <id> <dest>` | Restore a version to a new file (history unchanged) |
| `--replace <id>` | `-p <id>` | Replace current file with an older version |
| `--delete <id>` | `-d <id>` | Delete a specific version |
| `--deleteAll` | `-x` | Delete all older versions |
| `--help` | `-h` | Show help |

Version `0` is always the current file. Older versions have higher identifiers (1 = most recent old, 2 = next older, etc.).

## Examples

### List versions

```bash
$ versions myfile.swift
[ id]  Date                            Name
------------------------------------------------------------
[  2]  Apr 7, 2020 at 10:29:48 PM     myfile.swift
[  1]  Apr 7, 2020 at 10:35:22 PM     myfile.swift
[  0]  Apr 7, 2020 at 10:49:09 PM     myfile.swift (current)
```

### Save a new version

```bash
$ versions --save myfile.swift
Saved new version of myfile.swift [Feb 21, 2026 at 9:00:00 AM].
```

Use this in a Claude Code pre-tool-use hook to snapshot files before Claude edits them:

```python
# ~/.claude/hooks/pre_tool_use.py
import json, sys, subprocess, os

data = json.load(sys.stdin)
if data.get("tool_name") in ("Write", "Edit", "MultiEdit"):
    path = data.get("tool_input", {}).get("file_path", "")
    if path and os.path.exists(path):
        subprocess.run(["versions", "--save", path])
sys.exit(0)
```

### View a version

```bash
versions --view 1 myfile.swift           # print to stdout
versions --view 1 myfile.swift | less    # scrollable
versions --view 1 myfile.swift | open -ft  # open in editor
versions --view 1 myfile.swift | diff myfile.swift -  # diff with current
```

### Restore a version

```bash
# Save to a new file (non-destructive):
versions --restore 1 myfile.swift myfile-old.swift

# Replace the current file with an older version:
versions --replace 1 myfile.swift
```

### Delete versions

```bash
versions --delete 1 myfile.swift    # delete one version
versions --deleteAll myfile.swift   # delete all old versions
```

## Notes

- `NSFileVersion` stores version data in `/.DocumentRevisions-V100` (a hidden system directory). Versions are stored automatically by macOS for files in NSDocument-based apps and iCloud Drive. For arbitrary files, `--save` explicitly triggers a version snapshot using `NSFileVersion.addOfItem(at:withContentsOf:)`.
- The Finder "Browse All Versions" UI works best for iCloud/NSDocument files. For arbitrary paths (like code files), the versions are stored and accessible via this tool, but may not appear in Finder's UI.
- Deleting a version renumbers remaining versions, so be careful when chaining delete commands.

## Author

Rob

## License

GPL-3.0
