#!/usr/bin/env swift

// versions - A command-line interface to the macOS file versioning system
// Written in Swift. Requires macOS 10.12 (Sierra) or higher.

import Foundation

// MARK: - Helpers

func printUsage() {
    print("""
    Usage: versions [option] <file> [destination]

    If called with no option, lists all versions of the file.

    Options:
      (none)                       List all versions
      --save,      -s              Save a new version of the current file now
      --hook,      -k              Read Claude Code PreToolUse JSON from stdin and save a version
      --view,      -v <id>         Print an old version's contents to stdout
      --restore,   -r <id> <dest>  Restore a version to a new file (leave history intact)
      --replace,   -p <id>         Replace current file with an older version
      --delete,    -d <id>         Delete a specific version
      --deleteAll, -x              Delete all older versions
      --help,      -h              Show this help

    The current version always has identifier 0. Older versions have higher numbers.

    Examples:
      versions myfile.swift                        # list versions
      versions --save myfile.swift                 # snapshot current file
      versions --hook                              # Claude Code PreToolUse hook (reads JSON from stdin)
      versions --view 1 myfile.swift               # print version 1 to stdout
      versions --view 1 myfile.swift | diff myfile.swift -
      versions --restore 1 myfile.swift old.swift  # save version 1 to old.swift
      versions --replace 1 myfile.swift            # revert file to version 1
      versions --delete 1 myfile.swift             # delete version 1
      versions --deleteAll myfile.swift            # delete all old versions

    Claude Code hook setup (~/.claude/settings.json):
      {
        "hooks": {
          "PreToolUse": [{
            "matcher": "Write|Edit|MultiEdit",
            "hooks": [{ "type": "command", "command": "/usr/local/bin/versions --hook" }]
          }]
        }
      }
    """)
}

func exitWithError(_ message: String) -> Never {
    fputs("Error: \(message)\n", stderr)
    exit(1)
}

func resolvedURL(_ path: String) -> URL {
    let expanded = NSString(string: path).expandingTildeInPath
    return URL(fileURLWithPath: expanded).standardizedFileURL
}

func otherVersions(for url: URL) -> [NSFileVersion] {
    guard let versions = NSFileVersion.otherVersionsOfItem(at: url) else { return [] }
    return versions.sorted { ($0.modificationDate ?? .distantPast) < ($1.modificationDate ?? .distantPast) }
}

func versionForID(_ id: Int, others: [NSFileVersion]) -> NSFileVersion? {
    guard id > 0 else { return nil }
    let index = others.count - id
    guard index >= 0 && index < others.count else { return nil }
    return others[index]
}

func formatDate(_ date: Date?) -> String {
    guard let date = date else { return "unknown date" }
    let fmt = DateFormatter()
    fmt.dateStyle = .medium
    fmt.timeStyle = .medium
    return fmt.string(from: date)
}

// MARK: - Commands

func cmdList(fileURL: URL) {
    guard FileManager.default.fileExists(atPath: fileURL.path) else {
        exitWithError("File not found: \(fileURL.path)")
    }

    let others = otherVersions(for: fileURL)
    let total = others.count

    if total == 0 {
        print("No saved versions found for \(fileURL.lastPathComponent).")
        print("(Tip: use --save to snapshot the current file.)")
        return
    }

    func col(_ s: String, _ width: Int) -> String { s.padding(toLength: width, withPad: " ", startingAt: 0) }

    print("\(col("[ id]", 6))  \(col("Date", 30))  Name")
    print(String(repeating: "-", count: 60))

    for (i, v) in others.enumerated() {
        let id = total - i
        let name = v.localizedName ?? fileURL.lastPathComponent
        let date = formatDate(v.modificationDate)
        print(String(format: "[%3d]  ", id) + "\(col(date, 30))  \(name)")
    }

    let currentAttr = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
    let currentDate = (currentAttr?[.modificationDate] as? Date).map { formatDate($0) } ?? "now"
    print(String(format: "[%3d]  ", 0) + "\(col(currentDate, 30))  \(fileURL.lastPathComponent) (current)")
}

func cmdSave(fileURL: URL) {
    guard FileManager.default.fileExists(atPath: fileURL.path) else {
        exitWithError("File not found: \(fileURL.path)")
    }

    do {
        let version = try NSFileVersion.addOfItem(at: fileURL, withContentsOf: fileURL, options: [])
        let date = formatDate(version.modificationDate)
        print("Saved new version of \(fileURL.lastPathComponent) [\(date)].")
    } catch {
        exitWithError("Could not save version: \(error.localizedDescription)")
    }
}

/// --hook mode: reads Claude Code PreToolUse JSON from stdin, extracts file_path, saves a version.
func cmdHook() {
    let inputData = FileHandle.standardInput.readDataToEndOfFile()
    guard let json = try? JSONSerialization.jsonObject(with: inputData) as? [String: Any]
    else {
        // Not valid JSON — exit cleanly so we don't block Claude
        exit(0)
    }

    guard let toolInput = json["tool_input"] as? [String: Any],
          let rawPath = toolInput["file_path"] as? String,
          !rawPath.isEmpty
    else {
        // No file_path in this tool call (e.g. MultiEdit uses a different key) — skip silently
        exit(0)
    }

    let fileURL = resolvedURL(rawPath)

    guard FileManager.default.fileExists(atPath: fileURL.path) else {
        // New file being created — nothing to version yet
        exit(0)
    }

    do {
        let version = try NSFileVersion.addOfItem(at: fileURL, withContentsOf: fileURL, options: [])
        let date = formatDate(version.modificationDate)
        fputs("📸 Saved version of \(fileURL.lastPathComponent) [\(date)].\n", stderr)
    } catch {
        // Non-fatal — print warning but don't block Claude
        fputs("Warning: could not save version of \(fileURL.lastPathComponent): \(error.localizedDescription)\n", stderr)
    }

    exit(0)
}

func cmdView(id: Int, fileURL: URL) {
    guard FileManager.default.fileExists(atPath: fileURL.path) else {
        exitWithError("File not found: \(fileURL.path)")
    }

    if id == 0 {
        guard let data = try? Data(contentsOf: fileURL),
              let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
        else { exitWithError("Could not read current file.") }
        print(text, terminator: "")
        return
    }

    let others = otherVersions(for: fileURL)
    guard let version = versionForID(id, others: others) else {
        exitWithError("No version with identifier \(id). Run without options to list available versions.")
    }
    let versionURL = version.url
    guard let data = try? Data(contentsOf: versionURL),
          let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
    else { exitWithError("Could not read version \(id).") }
    print(text, terminator: "")
}

func cmdRestore(id: Int, fileURL: URL, destURL: URL) {
    guard FileManager.default.fileExists(atPath: fileURL.path) else {
        exitWithError("File not found: \(fileURL.path)")
    }

    let others = otherVersions(for: fileURL)
    guard let version = versionForID(id, others: others) else {
        exitWithError("No version with identifier \(id).")
    }
    let versionURL = version.url

    do {
        if FileManager.default.fileExists(atPath: destURL.path) {
            try FileManager.default.removeItem(at: destURL)
        }
        try FileManager.default.copyItem(at: versionURL, to: destURL)
        print("Successfully restored version \(id) of \(fileURL.lastPathComponent) to \(destURL.lastPathComponent).")
    } catch {
        exitWithError("Could not restore: \(error.localizedDescription)")
    }
}

func cmdReplace(id: Int, fileURL: URL) {
    guard FileManager.default.fileExists(atPath: fileURL.path) else {
        exitWithError("File not found: \(fileURL.path)")
    }

    let others = otherVersions(for: fileURL)
    guard let version = versionForID(id, others: others) else {
        exitWithError("No version with identifier \(id).")
    }

    do {
        _ = try version.replaceItem(at: fileURL, options: [])
        print("Successfully replaced \(fileURL.lastPathComponent) with version \(id).")
    } catch {
        exitWithError("Could not replace file: \(error.localizedDescription)")
    }
}

func cmdDelete(id: Int, fileURL: URL) {
    guard FileManager.default.fileExists(atPath: fileURL.path) else {
        exitWithError("File not found: \(fileURL.path)")
    }

    let others = otherVersions(for: fileURL)
    guard let version = versionForID(id, others: others) else {
        exitWithError("No version with identifier \(id).")
    }

    do {
        try version.remove()
        print("Successfully deleted version \(id) of \(fileURL.lastPathComponent).")
    } catch {
        exitWithError("Could not delete version: \(error.localizedDescription)")
    }
}

func cmdDeleteAll(fileURL: URL) {
    guard FileManager.default.fileExists(atPath: fileURL.path) else {
        exitWithError("File not found: \(fileURL.path)")
    }

    do {
        try NSFileVersion.removeOtherVersionsOfItem(at: fileURL)
        print("Successfully deleted all previous versions of \(fileURL.lastPathComponent).")
    } catch {
        exitWithError("Could not delete versions: \(error.localizedDescription)")
    }
}

// MARK: - Argument Parsing

var args = CommandLine.arguments.dropFirst()

guard !args.isEmpty else {
    printUsage()
    exit(0)
}

let flag = args.first!

if flag == "--help" || flag == "-h" {
    printUsage()
    exit(0)
}

// Hook mode — reads stdin, no file argument needed
if flag == "--hook" || flag == "-k" {
    cmdHook()
}

if flag == "--save" || flag == "-s" {
    guard let filePath = args.dropFirst().first else {
        exitWithError("--save requires a file argument.")
    }
    cmdSave(fileURL: resolvedURL(filePath))
    exit(0)
}

if flag == "--deleteAll" || flag == "-x" {
    guard let filePath = args.dropFirst().first else {
        exitWithError("--deleteAll requires a file argument.")
    }
    cmdDeleteAll(fileURL: resolvedURL(filePath))
    exit(0)
}

let idRequiringFlags: Set<String> = ["--view", "-v", "--restore", "-r", "--replace", "-p", "--delete", "-d"]

if idRequiringFlags.contains(flag) {
    let remaining = Array(args.dropFirst())
    guard let idStr = remaining.first, let id = Int(idStr), id >= 0 else {
        exitWithError("\(flag) requires a non-negative integer identifier. Use no options to list versions.")
    }
    guard remaining.count >= 2 else {
        exitWithError("\(flag) requires a file argument after the identifier.")
    }
    let filePath = remaining[1]
    let fileURL = resolvedURL(filePath)

    switch flag {
    case "--view", "-v":
        cmdView(id: id, fileURL: fileURL)
    case "--restore", "-r":
        guard remaining.count >= 3 else {
            exitWithError("--restore requires a destination file as the third argument.")
        }
        cmdRestore(id: id, fileURL: fileURL, destURL: resolvedURL(remaining[2]))
    case "--replace", "-p":
        cmdReplace(id: id, fileURL: fileURL)
    case "--delete", "-d":
        cmdDelete(id: id, fileURL: fileURL)
    default:
        break
    }
    exit(0)
}

// No flag — list versions (also handles --list / -l explicitly)
let filePath: String
if flag == "--list" || flag == "-l" {
    guard let p = args.dropFirst().first else {
        exitWithError("--list requires a file argument.")
    }
    filePath = p
} else {
    filePath = flag
}

cmdList(fileURL: resolvedURL(filePath))