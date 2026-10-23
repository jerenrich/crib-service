import Foundation

struct MetadataStoreError: LocalizedError {
    enum Operation: String { case directory, read, decode, encode, write, backup_exclusion }
    let operation: Operation
    let underlyingError: any Error
    var errorDescription: String? { underlyingError.localizedDescription }
}

@MainActor final class MetadataStore {
    private let url: URL
    init(filename: String = "listener-metadata.json", directory: URL? = nil) throws {
        do {
            let folder = try directory ?? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                .appendingPathComponent("BabyCryMonitor", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            url = folder.appendingPathComponent(filename)
        } catch { throw MetadataStoreError(operation: .directory, underlyingError: error) }
    }
    func load() throws -> SessionSnapshot {
        guard FileManager.default.fileExists(atPath: url.path) else { return SessionSnapshot() }
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch { throw MetadataStoreError(operation: .read, underlyingError: error) }
        do { return try JSONDecoder().decode(SessionSnapshot.self, from: data) }
        catch { throw MetadataStoreError(operation: .decode, underlyingError: error) }
    }
    func save(_ snapshot: SessionSnapshot) throws {
        let data: Data
        do { data = try JSONEncoder().encode(snapshot) }
        catch { throw MetadataStoreError(operation: .encode, underlyingError: error) }
        do { try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]) }
        catch { throw MetadataStoreError(operation: .write, underlyingError: error) }
        do {
            var resource = URLResourceValues(); resource.isExcludedFromBackup = true
            var file = url; try file.setResourceValues(resource)
        } catch { throw MetadataStoreError(operation: .backup_exclusion, underlyingError: error) }
    }
}
