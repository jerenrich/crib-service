import Foundation
import XCTest
#if canImport(MonitorCore)
@testable import MonitorCore
#else
@testable import BabyCryMonitor
#endif

final class CalibrationAudioArchiveTests: XCTestCase {
    func testArchiveInteroperatesWithSystemExtractorAndPreservesLargeBinaryAndUnicodeNames() throws {
        #if os(macOS)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let audio = folder.appendingPathComponent("night-é.m4a")
        let metadata = folder.appendingPathComponent("index.json")
        let empty = folder.appendingPathComponent("empty.txt")
        let payload = Data((0..<200_000).map { UInt8($0 % 251) })
        try payload.write(to: audio); try Data("{\"schema\":1}".utf8).write(to: metadata); try Data().write(to: empty)
        let zip = folder.appendingPathComponent("night.zip")
        try CalibrationAudioArchive.write(files: [audio, metadata, empty], to: zip)
        let output = folder.appendingPathComponent("extracted")
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", zip.path, output.path]
        try process.run(); process.waitUntilExit(); XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(try Data(contentsOf: output.appendingPathComponent(audio.lastPathComponent)), payload)
        XCTAssertEqual(try Data(contentsOf: output.appendingPathComponent(metadata.lastPathComponent)), try Data(contentsOf: metadata))
        XCTAssertEqual(try Data(contentsOf: output.appendingPathComponent(empty.lastPathComponent)), Data())
        #endif
    }
    func testFailedExportRemovesPartialArchive() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let destination = folder.appendingPathComponent("failed.zip")
        XCTAssertThrowsError(try CalibrationAudioArchive.write(files: [folder.appendingPathComponent("missing.m4a")], to: destination))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }
}
