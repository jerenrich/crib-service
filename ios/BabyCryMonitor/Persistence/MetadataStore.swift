import Foundation

@MainActor final class MetadataStore {
    private let url: URL
    init(filename: String = "listener-metadata.json", directory: URL? = nil) throws {
        let folder = try directory ?? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("BabyCryMonitor", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        url = folder.appendingPathComponent(filename)
    }
    func load() throws -> SessionSnapshot {
        guard FileManager.default.fileExists(atPath: url.path) else { return SessionSnapshot() }
        return try JSONDecoder().decode(SessionSnapshot.self, from: Data(contentsOf: url))
    }
    func save(_ snapshot: SessionSnapshot) throws {
        let data = try JSONEncoder().encode(snapshot)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        var resource = URLResourceValues(); resource.isExcludedFromBackup = true
        var file = url; try file.setResourceValues(resource)
    }
}
