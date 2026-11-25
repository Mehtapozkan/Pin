import Foundation
import CryptoKit
#if os(iOS) && canImport(Photos)
import Photos
#endif

/// Withdrawal of development payload exports, not canonical memory or a new
/// permission owner. PhotoKit remains authoritative. Dispatch reservations and
/// image budgets survive; withdrawn receipts cannot be used as recovery input.
public enum PinPrivatePayloadWithdrawal {
    private static let lock = NSRecursiveLock()

    private static func accessRevoked() -> Bool {
        #if os(iOS) && canImport(Photos)
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        return status == .denied || status == .restricted
        #else
        return false
        #endif
    }

    /// A late response/diagnostic cannot recreate payloads after withdrawal.
    /// Serializing writes with cleanup closes the check/delete/write race.
    public static func withWriteAccess<T>(_ operation: () throws -> T) throws -> T {
        try withWriteAccess(permissionRevoked: accessRevoked, operation)
    }

    static func withWriteAccess<T>(permissionRevoked: () -> Bool, _ operation: () throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        guard !permissionRevoked() else { throw PinEvidenceError.staleRecord }
        return try operation()
    }

    public static func write(_ data: Data, to file: URL, options: Data.WritingOptions = .atomic) throws {
        try withWriteAccess { try data.write(to: file, options: options) }
    }

    @discardableResult
    public static func withdrawIfRevoked(documents: URL) throws -> Bool {
        try withdrawIfRevoked(documents: documents, permissionRevoked: accessRevoked)
    }

    @discardableResult
    static func withdrawIfRevoked(documents: URL, permissionRevoked: () -> Bool) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard permissionRevoked() else { return false }
        let fm = FileManager.default
        // These contain derived payloads only. Photos originals, imported sample
        // inputs, native stores, pairing and configuration are outside this list.
        let payloadDirectories = ["fresh-results", "fresh-source-assessments", "fresh-source-groups",
            "fresh-unit-replacements-v1", "fresh-completed-source-checkpoints", "fresh-native-frames-v2",
            "fresh-native-frames-v2.pending", "fresh-native-frames-first-cohort-retained", "fresh-source-proof"]
        for name in payloadDirectories {
            let root = documents.appendingPathComponent(name)
            for file in try files(root) { try fm.removeItem(at: file) }
        }
        let trace = documents.appendingPathComponent("fresh-source-trace.jsonl")
        if fm.fileExists(atPath: trace.path) {
            try requireRegular(trace); try fm.removeItem(at: trace)
        }
        for file in try files(documents.appendingPathComponent("fresh-source-attempts")) {
            let name = file.lastPathComponent
            if name.hasSuffix(".initial-envelope.json") || name.hasSuffix("receipt.json") {
                try fm.removeItem(at: file)
            } else {
                try retainReservation(file)
            }
        }
        for name in ["fresh-unit-relations", "fresh-clock-repairs-v1", "fresh-unit-recovery-authorizations-v1", "fresh-explanations"] {
            for file in try files(documents.appendingPathComponent(name)) {
                if file.lastPathComponent.hasSuffix(".attempt.json") || file.pathExtension == "started" || name == "fresh-explanations" { try retainReservation(file) }
                else { try fm.removeItem(at: file) }
            }
        }
        // Preserve exact durable count/status/source bindings and occupied task
        // directories. Receipt/frame removal never restores an available slot.
        for file in try files(documents.appendingPathComponent("fresh-reread")) {
            if file.lastPathComponent.hasSuffix(".continuation-started.json") {try retainReservation(file)}
            else if file.lastPathComponent != "attempts.json" { try fm.removeItem(at: file) }
        }
        // Explicit recovery uses the same payload layout in an isolated child
        // journal. Revocation must withdraw those receipts as well, while its
        // claim/reservations stay occupied and cannot authorize another try.
        if fm.fileExists(atPath:documents.path) {
            for child in try fm.contentsOfDirectory(at:documents,includingPropertiesForKeys:[.isDirectoryKey,.isSymbolicLinkKey]) {
                let prefix="source-regression-",name=child.lastPathComponent
                guard name.hasPrefix(prefix),UUID(uuidString:String(name.dropFirst(prefix.count))) != nil else{continue}
                let values=try child.resourceValues(forKeys:[.isDirectoryKey,.isSymbolicLinkKey])
                guard values.isDirectory==true,values.isSymbolicLink != true else{throw PinEvidenceError.staleRecord}
                try withdrawIfRevoked(documents:child,permissionRevoked:{true})
                for file in try files(child) where file.lastPathComponent.hasSuffix(".authorization.json") {
                    try retainReservation(file)
                }
            }
        }
        return true
    }

    private struct Reservation: Codable {
        let schema: Int
        let payloadWithdrawn: Bool
        let originalSHA256: String
    }
    private static func retainReservation(_ file: URL) throws {
        let bytes = try Data(contentsOf: file)
        if let old = try? JSONDecoder().decode(Reservation.self, from: bytes),
           old.schema == 1, old.payloadWithdrawn, old.originalSHA256.count == 64 { return }
        let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(Reservation(schema: 1, payloadWithdrawn: true, originalSHA256: hash)).write(to: file, options: .atomic)
    }

    private static func requireRegular(_ file: URL) throws {
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw PinEvidenceError.staleRecord }
    }
    private static func files(_ root: URL) throws -> [URL] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.path) else { return [] }
        let values = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw PinEvidenceError.staleRecord }
        var result: [URL] = []
        for child in try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) {
            let childValues = try child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard childValues.isSymbolicLink != true else { throw PinEvidenceError.staleRecord }
            if childValues.isDirectory == true { result += try files(child) }
            else { try requireRegular(child); result.append(child) }
        }
        return result
    }
}
