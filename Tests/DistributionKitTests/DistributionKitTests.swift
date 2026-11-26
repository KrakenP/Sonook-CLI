import DistributionKit
import Testing

@Suite("DistributionKit Bootstrap")
struct DistributionKitBootstrapTests {
    @Test func infoReportsP5Version() {
        #expect(DistributionKitInfo.version == "1.0.0")
    }
}
