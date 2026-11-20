import Foundation
import MihonDomain

/// Small, account-scoped snapshots of the two landing pages and the filter directory.
actor BikaLandingArchive {
    private struct Entry<Value: Codable>: Codable {
        let saved: Date
        let value: Value
    }

    private let directory: URL
    private let lifetime: TimeInterval = 7 * 24 * 60 * 60

    init(directory: URL) { self.directory = directory }

    private func file(_ key: String, _ session: UUID) -> URL {
        directory.appendingPathComponent("\(session.uuidString)-\(key).json")
    }

    func read(_ listing: SourceListing, session: UUID, now: Date = Date()) -> MangasPage? {
        guard listing != .search else { return nil }
        return readFile(file(listing.rawValue, session), now: now)
    }

    func save(_ page: MangasPage, listing: SourceListing, session: UUID, now: Date = Date()) {
        guard listing != .search, !Task.isCancelled else { return }
        let url = file(listing.rawValue, session)
        if page.mangas.isEmpty {
            try? FileManager.default.removeItem(at: url)
        } else {
            writeFile(page, to: url, now: now)
        }
    }

    func readOptions(session: UUID, now: Date = Date()) -> BikaFilterOptions? {
        readFile(file("directory", session), now: now)
    }

    func saveOptions(_ options: BikaFilterOptions, session: UUID, now: Date = Date()) {
        guard !Task.isCancelled else { return }
        let url = file("directory", session)
        if options.categories.isEmpty && options.tags.isEmpty {
            try? FileManager.default.removeItem(at: url)
        } else {
            writeFile(options, to: url, now: now)
        }
    }

    private func readFile<Value: Codable>(_ url: URL, now: Date) -> Value? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let entry = try? JSONDecoder().decode(Entry<Value>.self, from: data),
              (0..<lifetime).contains(now.timeIntervalSince(entry.saved)) else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return entry.value
    }

    private func writeFile<Value: Codable>(_ value: Value, to url: URL, now: Date) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(Entry(saved: now, value: value))
            #if os(iOS)
            try data.write(to: url, options: [.atomic, .completeFileProtection])
            #else
            try data.write(to: url, options: .atomic)
            #endif
        } catch {
            // A full or locked cache must not prevent delivery of the live page.
        }
    }

    func remove(session: UUID) {
        for key in [SourceListing.popular.rawValue, SourceListing.latest.rawValue, "directory"] {
            try? FileManager.default.removeItem(at: file(key, session))
        }
    }
}
