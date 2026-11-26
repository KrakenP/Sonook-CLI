import AudioCore
import KnowledgeKit
import Testing

@Suite("KnowledgeKit Bootstrap")
struct KnowledgeKitBootstrapTests {
    @Test func infoReportsP4Version() {
        #expect(KnowledgeKitInfo.version == "1.0.0")
    }
}
