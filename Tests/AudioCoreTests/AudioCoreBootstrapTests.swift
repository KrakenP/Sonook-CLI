import AudioCore
import Testing

@Test func audioCoreBootstrapMetadata() {
    #expect(AudioCoreInfo.version == "1.0.0")
    #expect(AudioCoreInfo.projectName == "Sonook")
    #expect(AudioCoreInfo.chineseName == "听澜")
    #expect(AudioCoreInfo.currentSchemaVersion == 1)
}
