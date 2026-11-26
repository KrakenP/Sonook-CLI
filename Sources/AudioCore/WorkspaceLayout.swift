import Foundation

/// Audio render track mode reflected in exported audiobook filenames.
public enum ExportAudioMode: String, Codable, Equatable, Sendable {
    case dry
    case ambient
    case soundscape
}

/// Canonical local directory layout and human-readable output file naming contract for Sonook workspaces.
///
/// Layout under `<workspaceRoot>` (default `~/Sonook`, override via `--workspace` or `SONOOK_WORKSPACE`):
/// - `sonook.sqlite` — engine database (projects, sources, chapters, scripts, jobs, asset index)
/// - `outputs/<sanitizedName>__<projectID>/`
///   - `audiobooks/<sanitizedTitle>_<chapterTag>_<dry|ambient|soundscape>.<ext>` (+ `.timeline.json`)
///   - `characters/characters.voice-cards.md`
///   - `reports/verify_<chapterTag>.json`
/// - `assets/<kind>/<sha256>.<ext>` — immutable content-addressed internal engine blobs
/// - `.tmp/` — transient atomic staging directory (cleaned by `doctor`)
public enum SonookWorkspaceLayout: Sendable {
    public static let defaultRootFolderName = "Sonook"
    public static let outputsFolderName = "outputs"
    public static let assetsFolderName = "assets"
    public static let tempFolderName = ".tmp"
    public static let audiobooksFolderName = "audiobooks"
    public static let charactersFolderName = "characters"
    public static let reportsFolderName = "reports"
    public static let charactersMarkdownFileName = "characters.voice-cards.md"

    /// Resolves the default workspace root when `--workspace` is not passed.
    /// Priority: `SONOOK_WORKSPACE` environment variable > `<homeDirectory>/Sonook`.
    public static func defaultWorkspaceRoot(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        if let envPath = environment["SONOOK_WORKSPACE"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !envPath.isEmpty {
            let expanded = (envPath as NSString).expandingTildeInPath
            return URL(fileURLWithPath: expanded, isDirectory: true)
        }
        return homeDirectory.appendingPathComponent(defaultRootFolderName, isDirectory: true)
    }

    /// Sanitizes a book title or project name for safe cross-platform filesystem paths while
    /// preserving readable Chinese / Unicode characters.
    public static func sanitizeFileNameComponent(
        _ raw: String,
        fallback: String = "untitled",
        maxLength: Int = 60
    ) -> String {
        let forbidden: Set<Character> = ["/", "\\", ":", "*", "?", "\"", "<", ">", "|"]
        var mapped = ""
        mapped.reserveCapacity(raw.count)
        for ch in raw {
            if forbidden.contains(ch) || ch.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
                mapped.append("-")
            } else if ch.isWhitespace {
                mapped.append("-")
            } else {
                mapped.append(ch)
            }
        }
        // Collapse consecutive dashes and strip leading/trailing dashes or dots (avoid hidden/relative names).
        var collapsed = ""
        var prevDash = false
        for ch in mapped {
            if ch == "-" {
                if !prevDash {
                    collapsed.append(ch)
                    prevDash = true
                }
            } else {
                collapsed.append(ch)
                prevDash = false
            }
        }
        let trimmed = collapsed.trimmingCharacters(in: CharacterSet(charactersIn: "-."))
        guard !trimmed.isEmpty, trimmed != ".", trimmed != ".." else {
            return fallback
        }
        if trimmed.count > maxLength {
            return String(trimmed.prefix(maxLength)).trimmingCharacters(in: CharacterSet(charactersIn: "-."))
        }
        return trimmed
    }

    public static func outputsRoot(workspaceRoot: URL) -> URL {
        workspaceRoot.appendingPathComponent(outputsFolderName, isDirectory: true)
    }

    public static func projectOutputDirectory(workspaceRoot: URL, project: ProjectRecord) -> URL {
        projectOutputDirectory(workspaceRoot: workspaceRoot, projectID: project.projectID, projectName: project.name)
    }

    public static func projectOutputDirectory(workspaceRoot: URL, projectID: String, projectName: String) -> URL {
        let safeName = sanitizeFileNameComponent(projectName, fallback: "project")
        let safeID = sanitizeFileNameComponent(projectID, fallback: "proj")
        return outputsRoot(workspaceRoot: workspaceRoot)
            .appendingPathComponent("\(safeName)__\(safeID)", isDirectory: true)
    }

    public static func audiobooksDirectory(workspaceRoot: URL, project: ProjectRecord) -> URL {
        projectOutputDirectory(workspaceRoot: workspaceRoot, project: project)
            .appendingPathComponent(audiobooksFolderName, isDirectory: true)
    }

    public static func charactersDirectory(workspaceRoot: URL, project: ProjectRecord) -> URL {
        projectOutputDirectory(workspaceRoot: workspaceRoot, project: project)
            .appendingPathComponent(charactersFolderName, isDirectory: true)
    }

    public static func reportsDirectory(workspaceRoot: URL, project: ProjectRecord) -> URL {
        projectOutputDirectory(workspaceRoot: workspaceRoot, project: project)
            .appendingPathComponent(reportsFolderName, isDirectory: true)
    }

    /// Formats a deterministic chapter-range tag for filenames (`ch001`, `ch001-002`, `full`, or `ch001+003`).
    public static func chapterRangeTag(chapterNumbers: [Int], totalChapterCount: Int) -> String {
        let sorted = Array(Set(chapterNumbers)).sorted()
        guard let first = sorted.first, let last = sorted.last else {
            return "empty"
        }
        if totalChapterCount > 0 && sorted.count == totalChapterCount {
            return "full"
        }
        if sorted.count == 1 {
            return String(format: "ch%03d", first)
        }
        let isContiguous = (last - first + 1) == sorted.count
        if isContiguous {
            return String(format: "ch%03d-%03d", first, last)
        }
        let prefix = sorted.prefix(4).map { String(format: "%03d", $0) }.joined(separator: "+")
        return sorted.count > 4 ? "ch\(prefix)+etc" : "ch\(prefix)"
    }

    public static func defaultAudiobookOutputURL(
        workspaceRoot: URL,
        project: ProjectRecord,
        title: String? = nil,
        chapterNumbers: [Int],
        totalChapterCount: Int,
        audioMode: ExportAudioMode,
        format: ExportFormat
    ) -> URL {
        let baseTitle = sanitizeFileNameComponent(title ?? project.name, fallback: project.projectID)
        let chapterTag = chapterRangeTag(chapterNumbers: chapterNumbers, totalChapterCount: totalChapterCount)
        let fileName = "\(baseTitle)_\(chapterTag)_\(audioMode.rawValue).\(format.rawValue)"
        return audiobooksDirectory(workspaceRoot: workspaceRoot, project: project)
            .appendingPathComponent(fileName, isDirectory: false)
    }

    public static func defaultCharactersMarkdownURL(workspaceRoot: URL, project: ProjectRecord) -> URL {
        charactersDirectory(workspaceRoot: workspaceRoot, project: project)
            .appendingPathComponent(charactersMarkdownFileName, isDirectory: false)
    }

    public static func defaultVerifyReportURL(
        workspaceRoot: URL,
        project: ProjectRecord,
        chapterNumbers: [Int],
        totalChapterCount: Int
    ) -> URL {
        let chapterTag = chapterRangeTag(chapterNumbers: chapterNumbers, totalChapterCount: totalChapterCount)
        return reportsDirectory(workspaceRoot: workspaceRoot, project: project)
            .appendingPathComponent("verify_\(chapterTag).json", isDirectory: false)
    }
}
