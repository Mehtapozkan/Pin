import XCTest
@testable import PinCore
final class ProtectedSourceMetadataTests:XCTestCase {
    func fp(modified:String="100",captured:String="50",pixels:String="1200x900",location:String="35.0,139.0")->String { "vision-v4|fixture|\(modified)|\(captured)|\(pixels)|\(location)" }
    func setup() async throws -> (MemoryStore,URL,PhotoMemory,RecallHit) {
        let file=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("memory.json")
        let store=try MemoryStore(file:file)
        let memory=PhotoMemory(id:"fixture",fingerprint:fp(),coordinate:PhotoCoordinate(latitude:35,longitude:139),text:["Already read"])
        let permit=try await store.synchronizeSources([memory.id:memory.fingerprint]);try await store.upsert(memory,permit:permit)
        return (store,file,memory,RecallHit(memory:memory,score:1))
    }
    func testLockedMetadataOnlyChangeHidesFactsWithoutRepeatingAnalysisOrRewritingBytes() async throws {
        let (store,file,memory,hit)=try await setup();let before=try Data(contentsOf:file)
        let current=fp(location:"none");let permit=try await store.synchronizeSources([memory.id:current],confirmingAccess:false)
        let pending=await store.pendingSourceIDs([memory.id:current]);XCTAssertTrue(pending.isEmpty)
        let visible=await store.all();XCTAssertTrue(visible.isEmpty)
        let summary=await store.readSummary([memory.id:current]);XCTAssertEqual(summary.total,1);XCTAssertEqual(summary.unread,1);XCTAssertEqual(summary.sourceMetadataPending,1)
        XCTAssertEqual(summary.total,summary.read+summary.incomplete)
        XCTAssertEqual(try Data(contentsOf:file),before)
        do { _=try await store.current(hit);XCTFail("unconfirmed facts exposed") } catch {}
        var wrong=memory;wrong.fingerprint=current;wrong.coordinate=nil
        do { try await store.upsert(wrong,permit:permit);XCTFail("unconfirmed metadata overwrote cached observations") } catch {}
        let audit=await store.sourceReconciliationAudit();XCTAssertEqual(audit.retained,1);XCTAssertEqual(audit.changed,1);XCTAssertEqual(audit.metadataDeferred,1);XCTAssertEqual(audit.changedFields,["location":1])
    }
    func testRestoredSourceMetadataReusesExactOldBytesAndRejectsOldPermit() async throws {
        let (store,file,memory,_)=try await setup();let before=try Data(contentsOf:file)
        let old=try await store.synchronizeSources([memory.id:fp(location:"none")],confirmingAccess:false)
        _=try await store.synchronizeSources([memory.id:memory.fingerprint],confirmingAccess:true)
        let visible=await store.all();XCTAssertEqual(visible,[memory]);XCTAssertEqual(try Data(contentsOf:file),before)
        let summary=await store.readSummary([memory.id:memory.fingerprint]);XCTAssertEqual(summary.read,1);XCTAssertEqual(summary.sourceMetadataPending,0)
        do { try await store.upsert(PhotoMemory(id:memory.id,fingerprint:fp(location:"none")),permit:old);XCTFail("old permit survived metadata confirmation") } catch {}
    }
    func testConfirmedGPSRemovalRemainsARealSourceChange() async throws {
        let (store,_,memory,hit)=try await setup();let current=fp(location:"none")
        let permit=try await store.synchronizeSources([memory.id:current],confirmingAccess:true)
        let pending=await store.pendingSourceIDs([memory.id:current]);XCTAssertEqual(pending,[memory.id])
        let audit=await store.sourceReconciliationAudit();XCTAssertEqual(audit.metadataDeferred,0)
        try await store.upsert(PhotoMemory(id:memory.id,fingerprint:current,text:["Re-read after confirmation"]),permit:permit)
        let visible=await store.all();XCTAssertEqual(visible[0].revision,2);XCTAssertNil(visible[0].coordinate)
        do { _=try await store.current(hit);XCTFail("old source facts survived confirmed change") } catch {}
    }
    func testChangedImageVersionOrPositiveSizeNeverUsesMetadataDeferral() async throws {
        for current in [fp(modified:"101",location:"none"),fp(pixels:"900x900",location:"none"),fp(modified:"101",pixels:"0x0"),fp(modified:"0",pixels:"900x900")] {
            let (store,_,memory,_)=try await setup()
            _=try await store.synchronizeSources([memory.id:current],confirmingAccess:false)
            let pending=await store.pendingSourceIDs([memory.id:current]);XCTAssertEqual(pending,[memory.id])
            let audit=await store.sourceReconciliationAudit();XCTAssertEqual(audit.metadataDeferred,0)
        }
    }
    func testUnknownProtectedVersionAndCaptureMetadataWaitButNewPhotosCanBeRead() async throws {
        for current in [fp(modified:"0"),fp(captured:"0"),fp(pixels:"0x0"),fp(captured:"51",location:"35.0001,139.0")] {
            let (store,_,memory,_)=try await setup()
            let fingerprints=[memory.id:current,"new":"vision-v4|new|0.0|0.0|1200x900|none"]
            _=try await store.synchronizeSources(fingerprints,confirmingAccess:false)
            let pending=await store.pendingSourceIDs(fingerprints);XCTAssertEqual(pending,["new"])
            let summary=await store.readSummary(fingerprints);XCTAssertEqual(summary.unread,2);XCTAssertEqual(summary.sourceMetadataPending,1)
        }
    }
    func testColdReturnAndForgettingPreserveHeldBytesAndNeverResurrect() async throws {
        let (store,file,memory,_)=try await setup();let before=try Data(contentsOf:file)
        _=try await store.synchronizeSources([memory.id:fp(location:"none")],confirmingAccess:false)
        let cold=try MemoryStore(file:file);_=try await cold.synchronizeSources([memory.id:fp(location:"none")],confirmingAccess:false)
        XCTAssertEqual(try Data(contentsOf:file),before)
        let pending=await cold.pendingSourceIDs([memory.id:fp(location:"none")]);XCTAssertTrue(pending.isEmpty)
        try await cold.forget(memory.id);_=try await cold.synchronizeSources([memory.id:memory.fingerprint])
        let restored=await cold.all();XCTAssertTrue(restored.isEmpty);let forgotten=await cold.isForgotten(memory.id);XCTAssertTrue(forgotten)
    }
    func testExplicitWithdrawalClearsHoldAndAllowsARestoredNewRead() async throws {
        let (store,_,memory,_)=try await setup();let current=fp(location:"none")
        _=try await store.synchronizeSources([memory.id:current],confirmingAccess:false)
        _=try await store.synchronizeAccess([])
        let fresh=try await store.synchronizeAccess([memory.id])
        let pending=await store.pendingSourceIDs([memory.id:current]);XCTAssertEqual(pending,[memory.id])
        try await store.upsert(PhotoMemory(id:memory.id,fingerprint:current,text:["Read after access restored"]),permit:fresh)
        let visible=await store.all();XCTAssertEqual(visible.count,1)
    }

}
