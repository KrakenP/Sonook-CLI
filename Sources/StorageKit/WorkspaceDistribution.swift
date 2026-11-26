import AudioCore

extension SQLiteWorkspaceStore: DistributionStoreProtocol {
    public func savePublishedRelease(_ release: PublishedReleaseRecord) async throws {
        try db.execute("""
            INSERT INTO published_releases(release_id, project_id, release_version, created_at, document) VALUES (?,?,?,?,?)
            ON CONFLICT(release_id) DO UPDATE SET project_id=excluded.project_id, release_version=excluded.release_version,
                created_at=excluded.created_at, document=excluded.document
            """, [release.releaseID, release.projectID, String(release.releaseVersion), release.createdAtISO8601, try encodedDocument(release)])
    }

    public func publishedRelease(id: String) async throws -> PublishedReleaseRecord? {
        try db.query("SELECT document FROM published_releases WHERE release_id=?", [id]) { try $0.document(PublishedReleaseRecord.self) }.first
    }

    public func listPublishedReleases(projectID: String?) async throws -> [PublishedReleaseRecord] {
        try db.query("""
            SELECT document FROM published_releases WHERE (?1 IS NULL OR project_id=?1)
            ORDER BY project_id, release_version DESC, release_id
            """, [projectID]) { try $0.document(PublishedReleaseRecord.self) }
    }
}

extension SQLiteWorkspaceStore: AuthStoreProtocol {
    public func savePairingChallenge(_ challenge: PairingChallengeRecord) async throws {
        try db.execute("""
            INSERT INTO pairing_challenges(challenge_id, expires_at, consumed_at, document) VALUES (?,?,?,?)
            ON CONFLICT(challenge_id) DO UPDATE SET expires_at=excluded.expires_at, consumed_at=excluded.consumed_at,
                document=excluded.document WHERE pairing_challenges.consumed_at IS NULL
            """, [challenge.challengeID, challenge.expiresAtISO8601, challenge.consumedAtISO8601, try encodedDocument(challenge)])
    }

    public func pairingChallenge(id: String) async throws -> PairingChallengeRecord? {
        try db.query("SELECT document FROM pairing_challenges WHERE challenge_id=?", [id]) { try $0.document(PairingChallengeRecord.self) }.first
    }

    public func consumePairingChallenge(id: String, consumedAtISO8601: String) async throws -> Bool {
        try db.execute("""
            UPDATE pairing_challenges SET consumed_at=?2, document=json_set(document, '$.consumed_at', ?2)
            WHERE challenge_id=?1 AND consumed_at IS NULL AND julianday(expires_at)>julianday(?2)
            """, [id, consumedAtISO8601]) == 1
    }

    public func savePairedDevice(_ device: PairedDeviceRecord) async throws {
        try db.execute("""
            INSERT INTO paired_devices(device_id, token_hash_sha256, revoked_at, document) VALUES (?,?,?,?)
            ON CONFLICT(device_id) DO UPDATE SET token_hash_sha256=excluded.token_hash_sha256,
                revoked_at=excluded.revoked_at, document=excluded.document WHERE paired_devices.revoked_at IS NULL
            """, [device.deviceID, device.tokenHashSHA256, device.revokedAtISO8601, try encodedDocument(device)])
    }

    public func pairedDevice(id: String) async throws -> PairedDeviceRecord? {
        try db.query("SELECT document FROM paired_devices WHERE device_id=?", [id]) { try $0.document(PairedDeviceRecord.self) }.first
    }

    public func pairedDevice(tokenHashSHA256: String) async throws -> PairedDeviceRecord? {
        try db.query("SELECT document FROM paired_devices WHERE token_hash_sha256=?", [tokenHashSHA256]) {
            try $0.document(PairedDeviceRecord.self)
        }.first
    }

    public func listPairedDevices() async throws -> [PairedDeviceRecord] {
        try db.query("SELECT document FROM paired_devices ORDER BY device_id") { try $0.document(PairedDeviceRecord.self) }
    }

    public func revokePairedDevice(id: String, revokedAtISO8601: String) async throws -> Bool {
        try db.execute("""
            UPDATE paired_devices SET revoked_at=?2, document=json_set(document, '$.revoked_at', ?2)
            WHERE device_id=?1 AND revoked_at IS NULL
            """, [id, revokedAtISO8601]) == 1
    }
}
