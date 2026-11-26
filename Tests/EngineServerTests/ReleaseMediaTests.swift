import Foundation
import Testing

@Suite("Published pack downloads")
struct ReleaseMediaTests {
    @Test func resumedBytesMatchFullFileAndETag() async throws {
        try await HTTPFixture.run { fixture in
            let release = await fixture.register()
            let chapters = fixture.root.appendingPathComponent(release.packRelativePath).appendingPathComponent("chapters")
            try FileManager.default.createDirectory(at: chapters, withIntermediateDirectories: true)
            let bytes = Data((0..<150_000).map { UInt8(truncatingIfNeeded: $0) })
            try bytes.write(to: chapters.appendingPathComponent("001.m4a"))
            let token = try await fixture.pair([.downloadMedia]).bearer_token
            let file = "/v1/releases/release/files/chapters/001.m4a"
            let first = try await fixture.send(file, token: token, range: "bytes=0-15")
            #expect(first.status == 206)
            #expect(first.header("Content-Range") == "bytes 0-15/150000")
            #expect(first.header("Accept-Ranges") == "bytes")
            #expect(first.header("Content-Length") == "16")
            #expect(first.data == bytes.prefix(16))
            let second = try await fixture.send(file, token: token, range: "bytes=16-")
            #expect(second.status == 206)
            #expect(second.header("Content-Range") == "bytes 16-149999/150000")
            #expect(digest(first.data + second.data) == digest(bytes))
            let full = try await fixture.send(file, token: token)
            #expect(full.status == 200 && full.data == bytes)
            #expect(full.header("ETag") == "\"\(digest(bytes))\"")
            #expect(first.header("ETag") == full.header("ETag") && second.header("ETag") == full.header("ETag"))
            var resume = fixture.request(file, token: token, range: "bytes=16-")
            resume.setValue(first.header("ETag"), forHTTPHeaderField: "If-Range")
            let (tail, matched) = try await fixture.session.data(for: resume)
            #expect((matched as? HTTPURLResponse)?.statusCode == 206 && tail == second.data)
            resume.setValue("\"outdated\"", forHTTPHeaderField: "If-Range")
            let (replacement, changed) = try await fixture.session.data(for: resume)
            #expect((changed as? HTTPURLResponse)?.statusCode == 200 && replacement == bytes)
            let last = try await fixture.send(file, token: token, range: "bytes=-2")
            #expect(last.data == bytes.suffix(2))
            for range in ["bytes=150000-", "bytes=5-4", "bytes=0-3,9-12"] {
                let invalid = try await fixture.send(file, token: token, range: range)
                #expect(invalid.status == 416)
                #expect(invalid.header("Content-Range") == "bytes */150000")
            }
            try Data().write(to: chapters.appendingPathComponent("empty"))
            let empty = "/v1/releases/release/files/chapters/empty"
            #expect(try await fixture.send(empty, token: token).status == 200)
            #expect(try await fixture.send(empty, token: token, range: "bytes=0-").status == 416)
        }
    }

    @Test func packBoundaryForFilesAndManifest() async throws {
        try await HTTPFixture.run { fixture in
            let manager = FileManager.default
            let release = await fixture.register()
            let pack = fixture.root.appendingPathComponent(release.packRelativePath)
            try manager.createDirectory(at: pack, withIntermediateDirectories: true)
            let privateFile = fixture.root.appendingPathComponent("secret")
            let content = Data("unpublished".utf8)
            try content.write(to: privateFile)
            try manager.createSymbolicLink(at: pack.appendingPathComponent("link"), withDestinationURL: fixture.root)
            try manager.createSymbolicLink(at: pack.appendingPathComponent("manifest.json"), withDestinationURL: privateFile)
            try manager.createSymbolicLink(at: fixture.root.appendingPathComponent("alias"), withDestinationURL: fixture.root)
            await fixture.register(pack: "alias", id: "linked")
            await fixture.register(pack: "../", id: "invalid")
            let token = try await fixture.pair([.downloadMedia, .readCatalog]).bearer_token
            for path in ["release/files/%2e%2e/secret", "release/files/%2Fsecret", "release/files/%00",
                         "release/files//secret", "release/files/link/secret", "release/manifest",
                         "linked/files/secret", "invalid/files/secret"] {
                let response = try await fixture.send("/v1/releases/" + path, token: token)
                #expect([400, 403].contains(response.status), "Expected rejection of \(path)")
                #expect(response.data != content)
            }
            #expect(try await fixture.send("/v1/releases/unregistered/files/secret", token: token).status == 404)
        }
    }
}
