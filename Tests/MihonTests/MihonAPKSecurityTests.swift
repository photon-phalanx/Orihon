import XCTest
import CryptoKit
import Compression
@testable import MihonDomain
@testable import MihonAPKEngine
@testable import MihonData

/// APK hardening: bounded decompression and APK Signature Scheme v2 verification. Signed packages are built here
/// with a throwaway test key; the live test checks a real Keiyoushi APK against the repo's published fingerprint.
final class MihonAPKSecurityTests: XCTestCase {

    // MARK: - Signing fixtures

    /// Test-only EC P-256 key and its self-signed certificate (generated for these tests, used nowhere else).
    private static let testKeyPEM = """
    -----BEGIN PRIVATE KEY-----
    MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQg45Pla3jsfpyBb8qb
    3Vz5NToe4vBXI2fCKh2phPRAhoahRANCAAQne6j6+JXRrc2lTkSQVYPRQUP09qQa
    Nnsv7yR7XLdtjm2josZ+aWTewWH6lLdDNfcRiP6VJcTkmFNVmfNEq9Ql
    -----END PRIVATE KEY-----
    """
    private static let testCertificate = Data(base64Encoded: """
    MIIBZjCCAQwCCQDUNVPiBqFFMDAKBggqhkjOPQQDAjA6MR4wHAYDVQQDDBVNaWhvbi1pT1MgdGVzdCBzaWduZXIxGDAWBgNVBAoM\
    D01paG9uLWlPUyB0ZXN0czAgFw0yNjEwMjcxNDM0MjNaGA8yMTI2MTAwMzE0MzQyM1owOjEeMBwGA1UEAwwVTWlob24taU9TIHRl\
    c3Qgc2lnbmVyMRgwFgYDVQQKDA9NaWhvbi1pT1MgdGVzdHMwWTATBgcqhkjOPQIBBggqhkjOPQMBBwNCAAQne6j6+JXRrc2lTkSQ\
    VYPRQUP09qQaNnsv7yR7XLdtjm2josZ+aWTewWH6lLdDNfcRiP6VJcTkmFNVmfNEq9QlMAoGCCqGSM49BAMCA0gAMEUCIQCcYyF9\
    HF+vf49xuREiJx+Xwp3y06LXqKBAkrv9AdoI4gIgDokyIg6ag6fBfTiRgqjEGgOvZB3Dvk9GZu4aQ2BuA3g=
    """)!
    private static let testFingerprint = "cf22c98f272ef8396071fcc232c5cae238f167a70b91aedd9a8d15706a2a6029"
    private static let keiyoushiFingerprint = "9add655a78e96c4ec7a53ef89dccb557cb5d767489fac5e785d671a5a75d4da2"

    private static func u32(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8(truncatingIfNeeded: v >> (8 * $0)) } }
    private static func u64(_ v: UInt64) -> [UInt8] { (0..<8).map { UInt8(truncatingIfNeeded: v >> (8 * $0)) } }
    private static func lp(_ d: [UInt8]) -> [UInt8] { u32(UInt32(d.count)) + d }
    private static func le32(_ b: [UInt8], _ i: Int) -> Int {
        Int(b[i]) | Int(b[i + 1]) << 8 | Int(b[i + 2]) << 16 | Int(b[i + 3]) << 24
    }

    /// The chunked SHA-256 content digest of an unsigned ZIP (its end record already points at the offset the
    /// signing block will take).
    private static func contentDigest(_ b: [UInt8], centralDirectory: Int, end: Int) -> [UInt8] {
        var chunks: [UInt8] = []
        var count: UInt32 = 0
        for section in [b[0..<centralDirectory], b[centralDirectory..<end], b[end...]] {
            var start = section.startIndex
            while start < section.endIndex {
                let stop = min(start + (1 << 20), section.endIndex)
                chunks += SHA256.hash(data: [0xA5] + u32(UInt32(stop - start)) + Array(section[start..<stop]))
                count += 1
                start = stop
            }
        }
        return Array(SHA256.hash(data: [0x5A] + u32(count) + chunks))
    }

    /// Inserts an APK Signature Scheme v2 block (one ECDSA-SHA256 signer) before the central directory, as
    /// `apksigner` does. Returns the signed APK and the signed content digest.
    private static func signV2(_ zip: Data) throws -> (apk: Data, digest: [UInt8]) {
        let key = try P256.Signing.PrivateKey(pemRepresentation: testKeyPEM)
        let b = [UInt8](zip)
        let end = try XCTUnwrap((0...(b.count - 22)).reversed().first { le32(b, $0) == 0x0605_4B50 })
        let centralDirectory = le32(b, end + 16)
        let digest = contentDigest(b, centralDirectory: centralDirectory, end: end)
        let signedData = lp(lp(u32(0x0201) + lp(digest))) + lp(lp([UInt8](testCertificate))) + lp([])
        let signature = [UInt8](try key.signature(for: signedData).derRepresentation)
        let signer = lp(signedData) + lp(lp(u32(0x0201) + lp(signature))) + lp([UInt8](key.publicKey.derRepresentation))
        let value = lp(lp(signer))
        let pair = u64(UInt64(4 + value.count)) + u32(0x7109_871A) + value
        let size = UInt64(pair.count + 8 + 16)
        let block = u64(size) + pair + u64(size) + Array("APK Sig Block 42".utf8)
        var record = Array(b[end...])
        record.replaceSubrange(16..<20, with: u32(UInt32(centralDirectory + block.count)))
        return (Data(Array(b[0..<centralDirectory]) + block + Array(b[centralDirectory..<end]) + record), digest)
    }

    /// The app's synthetic extension package rewritten with a central directory: the synthetic archive has only
    /// local headers, and an APK signing block sits in front of the central directory.
    private static func extensionApk() throws -> Data {
        let ext = try XCTUnwrap(MihonSeedData.extensions.first { $0.pkgName.hasSuffix("zaimanhua") })
        let inspector = APKBinaryDexInspector()
        let entries = try inspector.extractZipEntries(from: inspector.buildSyntheticMihonExtensionApk(for: ext))
        return zip(entries.values.sorted { $0.fileName < $1.fileName }.map { ($0.fileName, [UInt8]($0.data), nil) })
    }

    // MARK: - Signature verification

    func testSignedApkVerifiesAndNamesItsSigner() throws {
        let (apk, _) = try Self.signV2(try Self.extensionApk())
        let verification = try APKSignatureVerifier().verify(apkData: apk)
        XCTAssertEqual(verification.schemes, [2])
        XCTAssertEqual(verification.certificateFingerprints, [Self.testFingerprint])
        XCTAssertTrue(verification.isSigned(by: Self.testFingerprint.uppercased()))
        XCTAssertTrue(verification.isSigned(by: stride(from: 0, to: 64, by: 2).map { i -> String in
            let start = Self.testFingerprint.index(Self.testFingerprint.startIndex, offsetBy: i)
            return String(Self.testFingerprint[start..<Self.testFingerprint.index(start, offsetBy: 2)])
        }.joined(separator: ":")), "colon-separated fingerprints match too")
        XCTAssertFalse(verification.isSigned(by: Self.keiyoushiFingerprint))
        XCTAssertFalse(verification.isSigned(by: "—"))
        // Signing leaves the package readable.
        XCTAssertNoThrow(try APKBinaryDexInspector().inspectAndroidPackage(apkData: apk, artifactPath: "signed.apk"))
    }

    func testTamperedApksAreRejected() throws {
        let (apk, digest) = try Self.signV2(try Self.extensionApk())
        let verifier = APKSignatureVerifier()

        var content = [UInt8](apk)
        content[40] ^= 0xFF
        XCTAssertThrowsError(try verifier.verify(apkData: Data(content))) {
            XCTAssertEqual($0 as? APKSignatureError, .digestMismatch)
        }

        var signedData = [UInt8](apk)
        let digestAt = try XCTUnwrap((0...(signedData.count - digest.count)).first { Array(signedData[$0..<$0 + digest.count]) == digest })
        signedData[digestAt] ^= 0xFF
        XCTAssertThrowsError(try verifier.verify(apkData: Data(signedData))) {
            XCTAssertEqual($0 as? APKSignatureError, .invalidSignature)
        }

        XCTAssertThrowsError(try verifier.verify(apkData: try Self.extensionApk())) {
            XCTAssertEqual($0 as? APKSignatureError, .notSigned)
        }
    }

    // MARK: - Bounded decompression

    /// A ZIP of stored or deflated entries with a chosen declared size (no data descriptors).
    private static func zip(_ entries: [(name: String, data: [UInt8], declaredSize: UInt32?)]) -> Data {
        var local: [UInt8] = []
        var central: [UInt8] = []
        for entry in entries {
            var compressed = [UInt8](repeating: 0, count: max(1024, entry.data.count + 1024))
            let written = entry.data.withUnsafeBufferPointer { src in
                compressed.withUnsafeMutableBufferPointer { dst in
                    compression_encode_buffer(dst.baseAddress!, dst.count, src.baseAddress!, src.count, nil, COMPRESSION_ZLIB)
                }
            }
            let payload = Array(compressed.prefix(written))
            let name = Array(entry.name.utf8)
            let size = entry.declaredSize ?? UInt32(entry.data.count)
            let sizes = u32(0) + u32(UInt32(payload.count)) + u32(size)
            var header = u32(0x0403_4B50) + [20, 0, 0, 0, 8, 0, 0, 0, 0, 0]
            header += sizes
            header += [UInt8(name.count), 0, 0, 0] + name
            central += u32(0x0201_4B50) + [20, 0, 20, 0, 0, 0, 8, 0, 0, 0, 0, 0]
            central += sizes
            central += [UInt8(name.count), 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
            central += u32(UInt32(local.count)) + name
            local += header + payload
        }
        let end = u32(0x0605_4B50) + [0, 0, 0, 0, UInt8(entries.count), 0, UInt8(entries.count), 0]
            + u32(UInt32(central.count)) + u32(UInt32(local.count)) + [0, 0]
        return Data(local + central + end)
    }

    func testDecompressionBombsAreRejected() {
        let inspector = APKBinaryDexInspector()
        let tenMegabytes = [UInt8](repeating: 0, count: 10 << 20)
        let fortyMegabytes = [UInt8](repeating: 0, count: 40 << 20)
        let cases: [(String, Data)] = [
            ("a header that lies about a 40 MB entry", Self.zip([("classes.dex", fortyMegabytes, 1000)])),
            ("a declared 4 GB entry", Self.zip([("classes.dex", Array(tenMegabytes.prefix(100)), 0xFFFF_FFF0)])),
            ("seven 10 MB entries", Self.zip((1...7).map { ("classes\($0).dex", tenMegabytes, nil) }))
        ]
        for (label, archive) in cases {
            XCTAssertThrowsError(try inspector.inspectAndroidPackage(apkData: archive, artifactPath: "bomb.apk"), label) { error in
                guard case .archiveTooLarge? = error as? APKInspectionError else {
                    return XCTFail("\(label): \(error)")
                }
            }
        }
        // Entries the inspector never reads are not inflated at all.
        let resources = Self.zip([("res/raw/big.bin", fortyMegabytes, nil), ("classes.dex", [0x64, 0x65, 0x78], nil)])
        XCTAssertThrowsError(try inspector.inspectAndroidPackage(apkData: resources, artifactPath: "res.apk")) { error in
            if case .archiveTooLarge? = error as? APKInspectionError { XCTFail("a skipped entry counted against the limit") }
        }
    }

    func testBoundedInflate() throws {
        let text = Data(String(repeating: "Mihon", count: 1000).utf8)
        var compressed = [UInt8](repeating: 0, count: text.count)
        let written = text.withUnsafeBytes { src in
            compressed.withUnsafeMutableBufferPointer { dst in
                compression_encode_buffer(dst.baseAddress!, dst.count, src.bindMemory(to: UInt8.self).baseAddress!, text.count, nil, COMPRESSION_ZLIB)
            }
        }
        let deflated = Data(compressed.prefix(written))
        XCTAssertEqual(try MihonInflate.inflate(deflated, sizeHint: 0, limit: 1 << 20), text, "a wrong size hint is retried")
        XCTAssertThrowsError(try MihonInflate.inflate(deflated, sizeHint: text.count, limit: 4000)) {
            XCTAssertEqual($0 as? MihonInflate.Failure, .tooLarge)
        }
        XCTAssertThrowsError(try MihonInflate.inflate(Data([1, 2, 3]), sizeHint: 10, limit: 100)) {
            XCTAssertEqual($0 as? MihonInflate.Failure, .invalidStream)
        }
    }

    // MARK: - Install flow

    /// Installs only what the repo's key signed: the same package installs from a repo that publishes the test
    /// key's fingerprint and is refused (cached copy discarded, state restored) under Keiyoushi's.
    @MainActor
    func testInstallRequiresTheRepoSigningKey() async throws {
        let (apk, _) = try Self.signV2(try Self.extensionApk())
        let store = MihonRepositoryStore(bootstrapNetwork: false)
        let repoUrl = "https://example.invalid/mihon-ios-test-repo"
        var ext = try XCTUnwrap(store.extensions.first { $0.pkgName.hasSuffix("zaimanhua") })
        ext.pkgName = "eu.kanade.tachiyomi.extension.zh.mihontest\(UUID().uuidString.prefix(8).lowercased())"
        ext.apkName = "\(ext.pkgName).apk"
        ext.apkUrl = nil
        ext.repoUrl = repoUrl
        ext.installState = .available
        store.extensions.append(ext)
        let cached = try XCTUnwrap(MihonNetworkClient.cachedExtensionApkURL(apkName: ext.apkName))
        defer { try? FileManager.default.removeItem(at: cached) }

        store.extensionRepos.append(ExtensionRepo(baseUrl: repoUrl, name: "Test", website: repoUrl, signingKeyFingerprint: Self.keiyoushiFingerprint))
        try apk.write(to: cached)
        await store.inspectAndInstallExtensionApk(ext)
        XCTAssertEqual(store.extensions.first { $0.pkgName == ext.pkgName }?.installState, .available)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cached.path), "a rejected download is not kept")

        store.extensionRepos[store.extensionRepos.count - 1].signingKeyFingerprint = Self.testFingerprint
        try apk.write(to: cached)
        await store.inspectAndInstallExtensionApk(ext)
        XCTAssertEqual(store.extensions.first { $0.pkgName == ext.pkgName }?.installState, .installed)
        XCTAssertEqual(store.apkInspectionsByPkg[ext.pkgName]?.signature?.certificateFingerprints, [Self.testFingerprint])
    }

    /// A second install while one runs is ignored (it would record "downloading" as the state to restore), and an
    /// update signed by another key than the installed version is refused even when the repo key matches.
    @MainActor
    func testInstallGuardsAgainstReentryAndSignerChanges() async throws {
        let (apk, _) = try Self.signV2(try Self.extensionApk())
        let store = MihonRepositoryStore(bootstrapNetwork: false)
        let repoUrl = "https://example.invalid/mihon-ios-test-repo-2"
        var ext = try XCTUnwrap(store.extensions.first { $0.pkgName.hasSuffix("zaimanhua") })
        ext.pkgName = "eu.kanade.tachiyomi.extension.zh.mihontest\(UUID().uuidString.prefix(8).lowercased())"
        ext.apkName = "\(ext.pkgName).apk"
        ext.apkUrl = nil
        ext.repoUrl = repoUrl
        ext.installState = .downloadingApk
        store.extensions.append(ext)
        store.extensionRepos.append(ExtensionRepo(baseUrl: repoUrl, name: "Test", website: repoUrl, signingKeyFingerprint: Self.testFingerprint))
        let cached = try XCTUnwrap(MihonNetworkClient.cachedExtensionApkURL(apkName: ext.apkName))
        defer { try? FileManager.default.removeItem(at: cached) }
        try apk.write(to: cached)

        await store.inspectAndInstallExtensionApk(ext)
        XCTAssertEqual(store.extensions.last?.installState, .downloadingApk, "a running install is left alone")

        // The installed version was signed by another key: the update is refused and the install stays.
        store.extensions[store.extensions.count - 1].installState = .hasUpdate
        var installed = try XCTUnwrap(try APKBinaryDexInspector().inspectAndroidPackage(apkData: apk, artifactPath: "installed.apk"))
        installed.signature = APKSignatureVerification(schemes: [2], certificateFingerprints: [Self.keiyoushiFingerprint])
        store.apkInspectionsByPkg[ext.pkgName] = installed
        await store.inspectAndInstallExtensionApk(ext)
        XCTAssertEqual(store.extensions.last?.installState, .hasUpdate)

        // The same signer updates.
        installed.signature = APKSignatureVerification(schemes: [2], certificateFingerprints: [Self.testFingerprint])
        store.apkInspectionsByPkg[ext.pkgName] = installed
        try apk.write(to: cached)
        await store.inspectAndInstallExtensionApk(ext)
        XCTAssertEqual(store.extensions.last?.installState, .installed)
    }

    func testCachedApkNamesCannotEscapeTheCache() {
        XCTAssertNil(MihonNetworkClient.cachedExtensionApkURL(apkName: "../../Preferences/x.apk"))
        XCTAssertNil(MihonNetworkClient.cachedExtensionApkURL(apkName: "a/b.apk"))
        XCTAssertNil(MihonNetworkClient.cachedExtensionApkURL(apkName: ".."))
        XCTAssertNotNil(MihonNetworkClient.cachedExtensionApkURL(apkName: "tachiyomi-zh.zaimanhua-v1.6.1.apk"))
    }

    // MARK: - Live (skipped offline)

    func testLiveKeiyoushiApkIsSignedByTheRepoKey() async throws {
        let apkUrl = "https://github.com/keiyoushi/extensions/releases/download/8ef06cd-0/tachiyomi-all.mangadex-v1.6.0.apk"
        let data: Data
        do {
            data = try await MihonNetworkClient.shared.fetchAsset(url: URL(string: apkUrl)!)
        } catch {
            throw XCTSkip("Network unavailable: \(error.localizedDescription)")
        }
        let verification = try APKSignatureVerifier().verify(apkData: data)
        XCTAssertTrue(verification.isSigned(by: Self.keiyoushiFingerprint), "\(verification.certificateFingerprints)")
    }
}
