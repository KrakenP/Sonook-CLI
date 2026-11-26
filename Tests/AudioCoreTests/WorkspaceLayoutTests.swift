import AudioCore
import Foundation
import Testing

@Suite("WorkspaceLayout")
struct WorkspaceLayoutTests {
    @Test("Default workspace resolves to ~/Sonook unless SONOOK_WORKSPACE overrides it")
    func defaultWorkspaceResolution() {
        let fakeHome = URL(fileURLWithPath: "/tmp/sonook-fake-home", isDirectory: true)
        let defaultRoot = SonookWorkspaceLayout.defaultWorkspaceRoot(environment: [:], homeDirectory: fakeHome)
        #expect(defaultRoot.path == "/tmp/sonook-fake-home/Sonook")

        let overrideRoot = SonookWorkspaceLayout.defaultWorkspaceRoot(
            environment: ["SONOOK_WORKSPACE": "/tmp/custom-sonook-ws"],
            homeDirectory: fakeHome
        )
        #expect(overrideRoot.path == "/tmp/custom-sonook-ws")
    }

    @Test("Filename sanitizer preserves Chinese titles and strips unsafe path characters")
    func filenameSanitization() {
        #expect(SonookWorkspaceLayout.sanitizeFileNameComponent("山海听澜：第一卷 / 试听版") == "山海听澜：第一卷-试听版")
        #expect(SonookWorkspaceLayout.sanitizeFileNameComponent("..//??**  ") == "untitled")
        #expect(SonookWorkspaceLayout.sanitizeFileNameComponent("  My Book: Vol 1  ") == "My-Book-Vol-1")
    }

    @Test("Chapter range tags cover single, contiguous, full-book, and sparse selections")
    func chapterRangeTagFormatting() {
        #expect(SonookWorkspaceLayout.chapterRangeTag(chapterNumbers: [1], totalChapterCount: 100) == "ch001")
        #expect(SonookWorkspaceLayout.chapterRangeTag(chapterNumbers: [1, 2], totalChapterCount: 100) == "ch001-002")
        #expect(SonookWorkspaceLayout.chapterRangeTag(chapterNumbers: [1, 2, 3], totalChapterCount: 3) == "full")
        #expect(SonookWorkspaceLayout.chapterRangeTag(chapterNumbers: [1, 3, 5], totalChapterCount: 20) == "ch001+003+005")
        #expect(SonookWorkspaceLayout.chapterRangeTag(chapterNumbers: [], totalChapterCount: 10) == "empty")
    }

    @Test("Default output URLs place audiobooks, character cards, and verify reports under outputs/<name>__<id>")
    func defaultOutputDirectoriesAndNaming() {
        let ws = URL(fileURLWithPath: "/tmp/sonook-ws", isDirectory: true)
        let proj = ProjectRecord(
            projectID: "proj_abc12345",
            name: "山海听澜",
            projectType: .audiobook,
            createdAtISO8601: "2026-11-26T00:00:00Z"
        )

        let dryM4B = SonookWorkspaceLayout.defaultAudiobookOutputURL(
            workspaceRoot: ws,
            project: proj,
            chapterNumbers: [1, 2],
            totalChapterCount: 50,
            audioMode: .dry,
            format: .m4b
        )
        #expect(dryM4B.path == "/tmp/sonook-ws/outputs/山海听澜__proj_abc12345/audiobooks/山海听澜_ch001-002_dry.m4b")

        let soundscapeM4B = SonookWorkspaceLayout.defaultAudiobookOutputURL(
            workspaceRoot: ws,
            project: proj,
            chapterNumbers: [1, 2, 3],
            totalChapterCount: 3,
            audioMode: .soundscape,
            format: .m4b
        )
        #expect(soundscapeM4B.path == "/tmp/sonook-ws/outputs/山海听澜__proj_abc12345/audiobooks/山海听澜_full_soundscape.m4b")

        let charMD = SonookWorkspaceLayout.defaultCharactersMarkdownURL(workspaceRoot: ws, project: proj)
        #expect(charMD.path == "/tmp/sonook-ws/outputs/山海听澜__proj_abc12345/characters/characters.voice-cards.md")

        let reportURL = SonookWorkspaceLayout.defaultVerifyReportURL(
            workspaceRoot: ws,
            project: proj,
            chapterNumbers: [1, 2],
            totalChapterCount: 50
        )
        #expect(reportURL.path == "/tmp/sonook-ws/outputs/山海听澜__proj_abc12345/reports/verify_ch001-002.json")
    }
}
