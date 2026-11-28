import AudioCore
import Foundation
import Testing

@Suite struct BuildProgressTests {
    @Test func bars() {
        #expect(BuildProgressFormatter.formatBar(completed: 12, total: 30) == "[████████░░░░░░░░░░░░] 40% (12/30)")
        for completed in [-1, 0] {
            #expect(BuildProgressFormatter.formatBar(completed: completed, total: 2, width: 4) == "[░░░░] 0% (0/2)")
        }
        for completed in [2, Int.max] {
            #expect(BuildProgressFormatter.formatBar(completed: completed, total: 2, width: 4) == "[████] 100% (2/2)")
        }
        #expect(BuildProgressFormatter.formatBar(completed: 29, total: 100, width: 0) == "[] 29% (29/100)")
        #expect(BuildProgressFormatter.formatBar(completed: Int.max - 1, total: Int.max, width: 1).contains("99%"))
        for total in [-1, 0] {
            #expect(BuildProgressFormatter.formatBar(completed: 4, total: total, width: 4) == "[░░░░] 0% (0/0)")
        }
    }

    @Test(arguments: [(-1.0, "00:00"), (0, "00:00"), (9.9, "00:09"), (3599, "59:59"),
                      (3600, "1:00:00"), (36001, "10:00:01")])
    func elapsed(seconds: TimeInterval, expected: String) {
        #expect(BuildProgressFormatter.formatElapsed(seconds) == expected)
    }

    @Test func events() throws {
        let event = BuildProgressEvent(stage: .synthesizing, subphase: "tts", completed: 1, total: 2, message: "开始\n片段\r\u{1B}")
        let encoded = try JSONEncoder().encode(event)
        #expect(try JSONDecoder().decode(BuildProgressEvent.self, from: encoded) == event)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(object["schema_version"] as? Int == 1)
        let tty = BuildProgressFormatter.formatEvent(event, elapsedSeconds: 62, interactiveTTY: true)
        #expect(tty == "开始 片段  [██████████░░░░░░░░░░] 50% (1/2)  01:02")
        #expect(BuildProgressFormatter.formatEvent(event, elapsedSeconds: 62, interactiveTTY: false) == "[4/5] 语音合成与质检  " + tty)
        for total in [nil, 0] as [Int?] {
            let event = BuildProgressEvent(stage: .exporting, completed: 0, total: total, message: "完成")
            #expect(BuildProgressFormatter.formatEvent(event, elapsedSeconds: 0, interactiveTTY: false) == "[5/5] 导出音频  完成  00:00")
        }
        #expect(BuildProgressStage.allCases.count == BuildProgressStage.totalStages)
    }
}
