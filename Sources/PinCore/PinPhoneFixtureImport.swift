#if DEBUG
import Foundation
import CryptoKit

/// Developer fixture planning only. This type never opens Photos, an index or
/// a session; the existing app importer remains the sole mutation owner.
public enum PinPhoneFixtureImport {
    public enum Issue: String, Error { case manifestMismatch, invalidManifest, invalidPhase, importInFlight, incompatibleState, incompleteImport }
    public struct Asset: Decodable, Sendable {
        public let file: String
        public let sha256: String
        public let photographedAt: Date
        public let phase: Int
    }
    public struct Manifest: Decodable { let schema: Int; let assets: [Asset] }
    public struct State: Codable, Equatable, Sendable {
        public let importing: Bool
        public let phase: Int
        public let ids: [String:String]
        public init(importing: Bool, phase: Int, ids: [String:String]) { self.importing=importing;self.phase=phase;self.ids=ids }
    }
    public struct Plan: Sendable {
        public let phase: Int
        public let active: [Asset]
        public let pending: [Asset]
        public let existing: State
        public var reservation: State { State(importing:true,phase:phase,ids:existing.ids) }
        public func completed(adding added: [String:String]) throws -> State {
            guard Set(added.keys)==Set(pending.map(\.sha256)),
                  added.values.allSatisfy({!$0.isEmpty && $0.utf8.count<=512}),
                  Set(added.values).count==added.count,
                  Set(added.values).isDisjoint(with:Set(existing.ids.values)) else { throw Issue.incompleteImport }
            return State(importing:false,phase:phase,ids:existing.ids.merging(added){old,_ in old})
        }
    }
    public static func plan(manifestData: Data, expectedSHA256: String, phase: Int, stateData: Data?, maximumAssets: Int) throws -> Plan {
        guard manifestData.count<=32_768,
              SHA256.hash(data:manifestData).map({String(format:"%02x",$0)}).joined()==expectedSHA256 else { throw Issue.manifestMismatch }
        let decoder=JSONDecoder();decoder.dateDecodingStrategy = .iso8601
        let manifest: Manifest
        do { manifest=try decoder.decode(Manifest.self,from:manifestData) } catch { throw Issue.invalidManifest }
        guard (1...4).contains(maximumAssets),manifest.schema==1,(1...maximumAssets).contains(manifest.assets.count),
              Set(manifest.assets.map(\.file)).count==manifest.assets.count,
              Set(manifest.assets.map(\.sha256)).count==manifest.assets.count,
              manifest.assets.allSatisfy({asset in
                  asset.file==URL(fileURLWithPath:asset.file).lastPathComponent && asset.file.hasSuffix(".jpg") && asset.file.utf8.count<=128 &&
                  asset.sha256.utf8.count==64 && asset.sha256.utf8.allSatisfy({(48...57).contains($0)||(97...102).contains($0)}) &&
                  asset.photographedAt.timeIntervalSince1970.isFinite && (1...2).contains(asset.phase)
              }) else { throw Issue.invalidManifest }
        guard (1...2).contains(phase) else { throw Issue.invalidPhase }
        let active=manifest.assets.filter{$0.phase<=phase}
        guard !active.isEmpty else { throw Issue.invalidPhase }
        let state: State
        do { state=try stateData.map{try JSONDecoder().decode(State.self,from:$0)} ?? State(importing:false,phase:phase,ids:[:]) } catch { throw Issue.incompatibleState }
        guard !state.importing else { throw Issue.importInFlight }
        guard (1...phase).contains(state.phase),
              Set(state.ids.keys).isSubset(of:Set(manifest.assets.filter{$0.phase<=state.phase}.map(\.sha256))),
              state.ids.values.allSatisfy({!$0.isEmpty && $0.utf8.count<=512}),Set(state.ids.values).count==state.ids.count else { throw Issue.incompatibleState }
        return Plan(phase:phase,active:active,pending:active.filter{state.ids[$0.sha256]==nil},existing:state)
    }
}
#endif
