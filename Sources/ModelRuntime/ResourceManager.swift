import AudioCore
import Foundation
import MLX

public enum ModelRuntimeError: Error, LocalizedError, Sendable {
    case modelNotRegistered(String)
    case modelKindMismatch(modelID: String, expected: ModelKind, actual: ModelKind)
    case unsupportedProvider(String)
    case modelDirectoryMissing(String)
    case insufficientMemoryBudget(requiredBytes: UInt64, budgetBytes: UInt64)
    case missingTimbreAnchor(characterID: String, reason: String)
    case corruptedTimbreAnchor(characterID: String, assetID: String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .modelNotRegistered(let id):
            return "Model not registered in workspace: \(id)"
        case .modelKindMismatch(let id, let expected, let actual):
            return "Model '\(id)' has kind \(actual.rawValue), expected \(expected.rawValue)"
        case .unsupportedProvider(let providerID):
            return "Unsupported ModelRuntime provider: \(providerID)"
        case .modelDirectoryMissing(let path):
            return "Local model weights directory does not exist: \(path)"
        case .insufficientMemoryBudget(let req, let budget):
            return "Requested model budget (\(MemoryProbe.formatMiB(req))) exceeds hardware budget (\(MemoryProbe.formatMiB(budget)))"
        case .missingTimbreAnchor(let cid, let reason):
            return "Locked-voice synthesis for '\(cid)' requires a verified timbre anchor: \(reason)"
        case .corruptedTimbreAnchor(let cid, let assetID):
            return "Timbre anchor asset '\(assetID)' for character '\(cid)' failed SHA-256 integrity verification"
        case .cancelled:
            return "Model lease acquisition cancelled"
        }
    }
}

public struct RuntimeResourceSnapshot: Codable, Equatable, Sendable {
    public let hardwareMemoryBytes: UInt64
    public let budgetBytes: UInt64
    public let loadedModelIDs: [String]
    public let activeLeaseCount: Int
    public let waitingInteractiveCount: Int
    public let waitingBackgroundCount: Int
    public let memorySample: MemorySample
    public let evictionCount: Int

    enum CodingKeys: String, CodingKey {
        case hardwareMemoryBytes = "hardware_memory_bytes"
        case budgetBytes = "budget_bytes"
        case loadedModelIDs = "loaded_model_ids"
        case activeLeaseCount = "active_lease_count"
        case waitingInteractiveCount = "waiting_interactive_count"
        case waitingBackgroundCount = "waiting_background_count"
        case memorySample = "memory_sample"
        case evictionCount = "eviction_count"
    }
}

/// Manages single-worker Apple Silicon GPU model leases, hardware-adaptive memory budgets,
/// interactive-over-background priority ordering at safe segment boundaries, and mandatory
/// MLX cache reclamation on every segment exit, error, and model switch.
public actor ModelResourceManager {
    private enum LoadedInstance {
        case llm(any LLMProvider)
        case tts(any TTSProvider)
        case asr(any ASRProvider)

        var lifecycle: any ModelLifecycle {
            switch self {
            case .llm(let p): return p
            case .tts(let p): return p
            case .asr(let p): return p
            }
        }
    }

    private struct LoadedRecord {
        let entry: ModelRegistryEntry
        let instance: LoadedInstance
        var lastUsedAt: Date
        var activeLeases: Int
    }

    private struct Waiter {
        let id: UUID
        let priority: TaskPriority
        let enqueuedAt: Date
        let continuation: CheckedContinuation<Void, Error>
    }

    public let hardwareMemoryBytes: UInt64
    public let budgetBytes: UInt64

    private var loaded: [String: LoadedRecord] = [:]
    private var gpuBusy: Bool = false
    private var waiters: [Waiter] = []
    private var evictionCount: Int = 0
    private var measuredPeakByModel: [String: UInt64] = [:]

    /// Uses 65% of physical unified memory by default (adaptive across 16GB / 24GB / 32GB / 64GB+ Macs),
    /// never hardcoding 64GB assumptions.
    public init(budgetFraction: Double = 0.65, overrideBudgetBytes: UInt64? = nil) {
        let phys = ProcessInfo.processInfo.physicalMemory
        self.hardwareMemoryBytes = phys
        if let overrideBudgetBytes {
            self.budgetBytes = overrideBudgetBytes
        } else {
            self.budgetBytes = UInt64(Double(phys) * min(max(budgetFraction, 0.25), 0.85))
        }
    }

    public func snapshot() -> RuntimeResourceSnapshot {
        let waitingInteractive = waiters.filter { $0.priority == .interactive }.count
        let waitingBackground = waiters.filter { $0.priority == .background }.count
        let activeLeases = loaded.values.reduce(0) { $0 + $1.activeLeases }
        return RuntimeResourceSnapshot(
            hardwareMemoryBytes: hardwareMemoryBytes,
            budgetBytes: budgetBytes,
            loadedModelIDs: loaded.keys.sorted(),
            activeLeaseCount: activeLeases,
            waitingInteractiveCount: waitingInteractive,
            waitingBackgroundCount: waitingBackground,
            memorySample: MemoryProbe.sample(label: "runtime_snapshot"),
            evictionCount: evictionCount
        )
    }

    public func measuredPeakBytes(for modelID: String) -> UInt64? {
        measuredPeakByModel[modelID]
    }

    /// Acquires exclusive GPU execution turn with priority ordering (`.interactive` preempts queued `.background`
    /// at the next safe segment boundary), ensures the target LLM is loaded within budget, runs `body`,
    /// and always reclaims transient MLX cache on completion or error.
    public func withLLMLease<T: Sendable>(
        entry: ModelRegistryEntry,
        priority: TaskPriority = .background,
        body: @Sendable (any LLMProvider) async throws -> T
    ) async throws -> T {
        guard entry.kind == .llm else {
            throw ModelRuntimeError.modelKindMismatch(modelID: entry.modelID, expected: .llm, actual: entry.kind)
        }
        try await acquireTurn(priority: priority)
        defer { releaseTurn() }

        let instance = try await ensureLoaded(entry: entry)
        guard case .llm(let provider) = instance else {
            throw ModelRuntimeError.modelKindMismatch(modelID: entry.modelID, expected: .llm, actual: entry.kind)
        }
        markLeaseDelta(modelID: entry.modelID, delta: 1)
        defer {
            markLeaseDelta(modelID: entry.modelID, delta: -1)
            MemoryProbe.clearMLXCache()
            recordPeak(for: entry.modelID)
        }
        return try await body(provider)
    }

    public func withTTSLease<T: Sendable>(
        entry: ModelRegistryEntry,
        priority: TaskPriority = .background,
        body: @Sendable (any TTSProvider) async throws -> T
    ) async throws -> T {
        guard entry.kind == .tts else {
            throw ModelRuntimeError.modelKindMismatch(modelID: entry.modelID, expected: .tts, actual: entry.kind)
        }
        try await acquireTurn(priority: priority)
        defer { releaseTurn() }

        let instance = try await ensureLoaded(entry: entry)
        guard case .tts(let provider) = instance else {
            throw ModelRuntimeError.modelKindMismatch(modelID: entry.modelID, expected: .tts, actual: entry.kind)
        }
        markLeaseDelta(modelID: entry.modelID, delta: 1)
        defer {
            markLeaseDelta(modelID: entry.modelID, delta: -1)
            // Crucial P0 finding: VoxCPM2 / FishSpeech / IndexTTS do not clear MLX pool internally.
            MemoryProbe.clearMLXCache()
            recordPeak(for: entry.modelID)
        }
        return try await body(provider)
    }

    public func withASRLease<T: Sendable>(
        entry: ModelRegistryEntry,
        priority: TaskPriority = .background,
        body: @Sendable (any ASRProvider) async throws -> T
    ) async throws -> T {
        guard entry.kind == .asr else {
            throw ModelRuntimeError.modelKindMismatch(modelID: entry.modelID, expected: .asr, actual: entry.kind)
        }
        try await acquireTurn(priority: priority)
        defer { releaseTurn() }

        let instance = try await ensureLoaded(entry: entry)
        guard case .asr(let provider) = instance else {
            throw ModelRuntimeError.modelKindMismatch(modelID: entry.modelID, expected: .asr, actual: entry.kind)
        }
        markLeaseDelta(modelID: entry.modelID, delta: 1)
        defer {
            markLeaseDelta(modelID: entry.modelID, delta: -1)
            MemoryProbe.clearMLXCache()
            recordPeak(for: entry.modelID)
        }
        return try await body(provider)
    }

    /// Explicitly unloads all idle resident models and reclaims MLX GPU buffers.
    public func unloadAllIdle() async {
        let idleIDs = loaded.values.filter { $0.activeLeases == 0 }.map(\.entry.modelID)
        for id in idleIDs {
            if let rec = loaded.removeValue(forKey: id) {
                await rec.instance.lifecycle.unload()
                evictionCount += 1
            }
        }
        MemoryProbe.clearMLXCache()
    }

    /// Validates that a locked-voice character has a committed timbre anchor whose on-disk SHA-256 matches.
    public static func resolveVerifiedTimbreAnchorURL(
        for card: CharacterVoiceCard,
        artifactStore: any ArtifactStoreProtocol
    ) async throws -> (anchor: VoiceTimbreAnchor, fileURL: URL) {
        guard let anchor = card.timbreAnchor else {
            throw ModelRuntimeError.missingTimbreAnchor(
                characterID: card.characterID,
                reason: "CharacterVoiceCard has no timbreAnchor; run voice design audition first"
            )
        }
        guard let asset = try await artifactStore.asset(id: anchor.assetID) else {
            throw ModelRuntimeError.missingTimbreAnchor(
                characterID: card.characterID,
                reason: "Anchor asset '\(anchor.assetID)' not found in ArtifactStore"
            )
        }
        guard asset.fileSHA256 == anchor.fileSHA256 else {
            throw ModelRuntimeError.corruptedTimbreAnchor(characterID: card.characterID, assetID: anchor.assetID)
        }
        let verified = try await artifactStore.verifyAssetIntegrity(assetID: anchor.assetID)
        guard verified else {
            throw ModelRuntimeError.corruptedTimbreAnchor(characterID: card.characterID, assetID: anchor.assetID)
        }
        let url = try await artifactStore.resolveFileURL(for: anchor.assetID)
        return (anchor, url)
    }

    // MARK: - Internal Scheduling & Eviction

    private func acquireTurn(priority: TaskPriority) async throws {
        if Task.isCancelled { throw ModelRuntimeError.cancelled }
        if !gpuBusy {
            gpuBusy = true
            return
        }
        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                waiters.append(Waiter(id: waiterID, priority: priority, enqueuedAt: Date(), continuation: cont))
            }
        } onCancel: {
            Task { await self.cancelWaiter(id: waiterID) }
        }
    }

    private func cancelWaiter(id: UUID) {
        if let idx = waiters.firstIndex(where: { $0.id == id }) {
            let w = waiters.remove(at: idx)
            w.continuation.resume(throwing: ModelRuntimeError.cancelled)
        }
    }

    private func releaseTurn() {
        guard !waiters.isEmpty else {
            gpuBusy = false
            return
        }
        // Highest priority first (.interactive > .background), FIFO within same priority.
        waiters.sort { lhs, rhs in
            if lhs.priority != rhs.priority {
                return lhs.priority > rhs.priority
            }
            return lhs.enqueuedAt < rhs.enqueuedAt
        }
        let next = waiters.removeFirst()
        next.continuation.resume()
    }

    private func ensureLoaded(entry: ModelRegistryEntry) async throws -> LoadedInstance {
        if var existing = loaded[entry.modelID] {
            existing.lastUsedAt = Date()
            loaded[entry.modelID] = existing
            return existing.instance
        }

        let needed = entry.effectiveBudgetBytes
        if needed > budgetBytes {
            throw ModelRuntimeError.insufficientMemoryBudget(requiredBytes: needed, budgetBytes: budgetBytes)
        }

        // Evict LRU idle models until estimated budget + live physical footprint leave headroom.
        // For single-worker MLX stage switching (LLM -> VoiceDesign -> VoxCPM2 -> ASR), evicting other idle models
        // guarantees zero cross-stage memory stacking.
        let otherIdle = loaded.values
            .filter { $0.activeLeases == 0 && $0.entry.modelID != entry.modelID }
            .sorted { $0.lastUsedAt < $1.lastUsedAt }

        for candidate in otherIdle {
            let currentAllocated = loaded.values.reduce(UInt64(0)) { $0 + $1.entry.effectiveBudgetBytes }
            let liveFootprint = MemoryProbe.currentProcessMemory().physFootprint
            let shouldEvict = (currentAllocated + needed > budgetBytes)
                || (liveFootprint + needed > budgetBytes)
                || (candidate.entry.kind != entry.kind)
            if shouldEvict {
                if let rec = loaded.removeValue(forKey: candidate.entry.modelID) {
                    await rec.instance.lifecycle.unload()
                    evictionCount += 1
                }
            }
        }
        MemoryProbe.clearMLXCache()

        let url = URL(fileURLWithPath: entry.localPath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ModelRuntimeError.modelDirectoryMissing(entry.localPath)
        }

        let instance = try buildProvider(for: entry, directory: url)
        MemoryProbe.resetMLXPeak()
        try await instance.lifecycle.load()
        loaded[entry.modelID] = LoadedRecord(entry: entry, instance: instance, lastUsedAt: Date(), activeLeases: 0)
        recordPeak(for: entry.modelID)
        return instance
    }

    private func buildProvider(for entry: ModelRegistryEntry, directory: URL) throws -> LoadedInstance {
        switch (entry.kind, entry.providerID) {
        case (.llm, "mlx-swift-lm"), (.llm, "qwen-mlx"):
            return .llm(MLXLocalLLMProvider(modelDirectory: directory, modelID: entry.modelID, modelRevision: entry.revision))
        case (.tts, MLXQwen3TTSProvider.providerIdentifier):
            return .tts(MLXQwen3TTSProvider(modelDirectory: directory, mode: .customVoice, modelID: entry.modelID, modelRevision: entry.revision))
        case (.tts, MLXQwen3TTSProvider.voiceDesignProviderIdentifier):
            return .tts(MLXQwen3TTSProvider(modelDirectory: directory, mode: .voiceDesign, modelID: entry.modelID, modelRevision: entry.revision))
        case (.tts, MLXVoxCPM2Provider.providerIdentifier):
            return .tts(MLXVoxCPM2Provider(modelDirectory: directory, modelID: entry.modelID, modelRevision: entry.revision))
        case (.tts, MLXFishSpeechProvider.providerIdentifier):
            return .tts(MLXFishSpeechProvider(modelDirectory: directory, modelID: entry.modelID, modelRevision: entry.revision))
        case (.tts, MLXIndexTTSProvider.providerIdentifier):
            return .tts(MLXIndexTTSProvider(modelDirectory: directory, modelID: entry.modelID, modelRevision: entry.revision))
        case (.asr, "qwen3-asr-mlx"), (.asr, "mlx-audio-asr"):
            return .asr(MLXQwen3ASRProvider(modelDirectory: directory, modelID: entry.modelID, modelRevision: entry.revision))
        default:
            throw ModelRuntimeError.unsupportedProvider("\(entry.kind.rawValue):\(entry.providerID)")
        }
    }

    private func markLeaseDelta(modelID: String, delta: Int) {
        guard var rec = loaded[modelID] else { return }
        rec.activeLeases = max(0, rec.activeLeases + delta)
        rec.lastUsedAt = Date()
        loaded[modelID] = rec
    }

    private func recordPeak(for modelID: String) {
        let mem = MemoryProbe.currentProcessMemory()
        let current = max(mem.physFootprint, mem.resident)
        if let prev = measuredPeakByModel[modelID] {
            measuredPeakByModel[modelID] = max(prev, current)
        } else {
            measuredPeakByModel[modelID] = current
        }
    }
}
