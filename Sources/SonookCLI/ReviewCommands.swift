import AudioCore
import EngineSDK
import Foundation

extension SonookCLI {
    static func runReview(args: [String], jsonMode: Bool) async throws {
        guard let action = args.first else {
            stderrWrite("""
            Usage:
              sonook review list --project <id> [--chapters <spec>] [--all] [--workspace <dir>] [--json]
              sonook review retry --project <id> [--chapters <spec>] [--main-tts <id>] [--asr <id>] [--seed <n>] [--max-rounds <n>] [--workspace <dir>] [--json]
              sonook review approve-all --project <id> [--chapters <spec>] --note <text> [--max-cer <0.10>] [--dry-run] [--workspace <dir>] [--json]
              sonook review reassign <segment-id> --project <id> --speaker <char-id-or-name> [--workspace <dir>] [--json]
            """)
            exit(2)
        }
        let rest = Array(args.dropFirst())
        let engine = try SonookEngine(workspaceRoot: resolveWorkspaceURL(from: rest))

        switch action {
        case "list":
            guard let projectID = option("--project", in: rest) else {
                stderrWrite("Missing --project for review list.\n"); exit(2)
            }
            let items = try await engine.listReviewQueue(
                projectID: projectID,
                chapterSpec: option("--chapters", in: rest),
                includeApproved: rest.contains("--all")
            )
            if jsonMode {
                try printJSON(items)
            } else if items.isEmpty {
                print("Review queue is empty for \(projectID).")
            } else {
                print("Review Queue (\(projectID), items=\(items.count)):")
                for item in items {
                    let cerStr = item.adjustedCER.map { String(format: "adjCER=%.2f%%", $0 * 100) } ?? "adjCER=n/a"
                    let flags = (item.attributionFlags + item.asrFailureReasons).joined(separator: ",")
                    let preview = item.spokenText.count > 40 ? String(item.spokenText.prefix(40)) + "…" : item.spokenText
                    print("  \(item.segmentID)\t#\(item.chapterNumber)\t\(item.speakerName)(\(item.speakerID))\t\(item.status.rawValue)\t\(cerStr)\t[\(flags)]")
                    print("    Text:  \(preview)")
                    if let t = item.rawTranscript, !t.isEmpty {
                        let tPreview = t.count > 44 ? String(t.prefix(44)) + "…" : t
                        print("    ASR:   \(tPreview)")
                    }
                    if let path = item.audioFilePath {
                        print("    Audio: \(path)")
                    }
                }
            }

        case "retry":
            guard let projectID = option("--project", in: rest) else {
                stderrWrite("Missing --project for review retry.\n"); exit(2)
            }
            let report = try await engine.batchRetryNeedsReview(
                projectID: projectID,
                chapterSpec: option("--chapters", in: rest),
                mainTTSModelID: option("--main-tts", in: rest),
                asrModelID: option("--asr", in: rest),
                baseSeed: option("--seed", in: rest).flatMap(UInt64.init) ?? 42,
                maxRounds: option("--max-rounds", in: rest).flatMap(Int.init) ?? 2
            ) { msg in
                stderrWrite("\(msg)\n")
            }
            if jsonMode {
                try printJSON(report)
            } else {
                print("Batch review retry finished (\(report.projectID)): rounds=\(report.roundsExecuted), attempted=\(report.attemptedSegments), verified=\(report.verifiedCount), improved=\(report.improvedCount), remaining=\(report.remainingNeedsReviewCount)")
                for d in report.details {
                    print(String(format: "  r%d %@ (seed=%llu): swap=%@ %@->%@ adjCER=%.2f%% (%@)",
                                 d.round, d.segmentID, d.seedUsed, String(d.swapped),
                                 d.previousStatus.rawValue, d.newStatus.rawValue, d.newAdjustedCER * 100, d.decisionReason))
                }
            }

        case "approve-all":
            guard let projectID = option("--project", in: rest) else {
                stderrWrite("Missing --project for review approve-all.\n"); exit(2)
            }
            let note = option("--note", in: rest) ?? "batch approved by reviewer"
            let maxCER = option("--max-cer", in: rest).flatMap(Double.init)
            let dryRun = rest.contains("--dry-run")
            let report = try await engine.batchApproveSegments(
                projectID: projectID,
                chapterSpec: option("--chapters", in: rest),
                note: note,
                maxCER: maxCER,
                dryRun: dryRun
            )
            if jsonMode {
                try printJSON(report)
            } else {
                let prefix = report.dryRun ? "[DRY-RUN] Would approve" : "Approved"
                print("\(prefix) \(report.approvedSegmentIDs.count) segment(s) in \(report.projectID) (skipped=\(report.skippedSegmentIDs.count))")
                if !report.approvedSegmentIDs.isEmpty {
                    print("  Approved: \(report.approvedSegmentIDs.joined(separator: ", "))")
                }
                if !report.skippedSegmentIDs.isEmpty {
                    print("  Skipped:  \(report.skippedSegmentIDs.joined(separator: ", "))")
                }
            }

        case "reassign":
            guard let segmentID = rest.first, !segmentID.hasPrefix("-"),
                  let projectID = option("--project", in: rest),
                  let speaker = option("--speaker", in: rest) else {
                stderrWrite("Usage: sonook review reassign <segment-id> --project <id> --speaker <char-id-or-name>\n"); exit(2)
            }
            let report = try await engine.reassignSegmentSpeaker(
                projectID: projectID,
                segmentID: segmentID,
                speakerQuery: speaker
            )
            if jsonMode {
                try printJSON(report)
            } else {
                print("Reassigned \(report.segmentID): \(report.previousSpeakerID) -> \(report.newSpeakerName) (\(report.newSpeakerID)), status=\(report.previousStatus.rawValue)->\(report.newStatus.rawValue), script_rev=\(report.scriptRevision)")
            }

        default:
            stderrWrite("Unknown review subcommand: \(action)\n"); exit(2)
        }
    }

    static func runCache(args: [String], jsonMode: Bool) async throws {
        guard let action = args.first else {
            stderrWrite("Usage: sonook cache plan --project <id> [--chapters <spec>] [--main-tts <id>] [--workspace <dir>] [--json]\n")
            exit(2)
        }
        let rest = Array(args.dropFirst())
        let engine = try SonookEngine(workspaceRoot: resolveWorkspaceURL(from: rest))

        switch action {
        case "plan":
            guard let projectID = option("--project", in: rest) else {
                stderrWrite("Missing --project for cache plan.\n"); exit(2)
            }
            let plan = try await engine.planCacheInvalidation(
                projectID: projectID,
                chapterSpec: option("--chapters", in: rest),
                mainTTSModelID: option("--main-tts", in: rest)
            )
            if jsonMode {
                try printJSON(plan)
            } else {
                print("Cache Plan (\(plan.projectID), model=\(plan.modelID)): reusable=\(plan.reusableSegments)/\(plan.totalSegments), invalidated=\(plan.invalidatedSegments)")
                for e in plan.entries where e.needsResynthesis {
                    print("  [INVALIDATED] \(e.segmentID) (#\(e.chapterNumber) \(e.speakerID)): \(e.reason.rawValue)")
                }
            }
        default:
            stderrWrite("Unknown cache subcommand: \(action)\n"); exit(2)
        }
    }

    static func runMemory(args: [String], jsonMode: Bool) async throws {
        guard let action = args.first else {
            stderrWrite("Usage: sonook memory list --project <id> [--up-to <chapter-num>] [--workspace <dir>] [--json]\n")
            exit(2)
        }
        let rest = Array(args.dropFirst())
        let engine = try SonookEngine(workspaceRoot: resolveWorkspaceURL(from: rest))

        switch action {
        case "list":
            guard let projectID = option("--project", in: rest) else {
                stderrWrite("Missing --project for memory list.\n"); exit(2)
            }
            let memories = try await engine.listChapterMemories(
                projectID: projectID,
                maxChapterNumber: option("--up-to", in: rest).flatMap(Int.init)
            )
            if jsonMode {
                try printJSON(memories)
            } else if memories.isEmpty {
                print("No chapter memories recorded for \(projectID).")
            } else {
                print("Chapter Memories (\(projectID), count=\(memories.count)):")
                for m in memories {
                    print("  #\(m.chapterNumber) (\(m.chapterID)) active=[\(m.activeCharacterIDs.joined(separator: ","))]: \(m.summary)")
                }
            }
        default:
            stderrWrite("Unknown memory subcommand: \(action)\n"); exit(2)
        }
    }
}
