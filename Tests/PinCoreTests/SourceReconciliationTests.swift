import XCTest
@testable import PinCore

final class SourceReconciliationTests: XCTestCase {
    private func file() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("memories-v1.json") }
    func testColdPartialCatalogueHidesMissingSourcesWithoutRewritingOrLosingThem() async throws {
        let url=file();let old=try MemoryStore(file:url)
        let permit=try await old.synchronizeSources(["shoe":"v1","other":"v1","cloud":"v1"])
        try await old.upsert(PhotoMemory(id:"shoe",fingerprint:"v1",text:["cream"]),permit:permit)
        try await old.upsert(PhotoMemory(id:"other",fingerprint:"v1",text:["museum"]),permit:permit)
        try await old.recordReadIssue(id:"cloud",fingerprint:"v1",issue:.needsDownload,permit:permit)
        let bytes=try Data(contentsOf:url)
        let cold=try MemoryStore(file:url)
        _=try await cold.synchronizeSources(["shoe":"v1","new":"v1"],confirmingAccess:false,restartingImport:true)
        let visible=await cold.all();XCTAssertEqual(visible.map(\.id),["shoe"])
        let summary=await cold.readSummary(["shoe":"v1","new":"v1"])
        XCTAssertEqual(summary.read,1);XCTAssertEqual(summary.unread,1)
        XCTAssertEqual(try Data(contentsOf:url),bytes)
        _=try await cold.synchronizeSources(["shoe":"v1","other":"v1","cloud":"v1"],restartingImport:true)
        let restored=await cold.all();XCTAssertEqual(Set(restored.map(\.id)),["shoe","other"])
        let retained=await cold.readSummary(["shoe":"v1","other":"v1","cloud":"v1"])
        XCTAssertEqual(retained.needsDownload,1)
        XCTAssertEqual(try Data(contentsOf:url),bytes)
    }
    func testChangedSourceIsHiddenAndOldResultRejectedBeforeRereading() async throws {
        let store=try MemoryStore(file:file())
        let permit=try await store.synchronizeSources(["source":"v1"])
        try await store.upsert(PhotoMemory(id:"source",fingerprint:"v1",text:["cream"]),permit:permit)
        let original=await store.find("cream")[0]
        let revised=try await store.synchronizeSources(["source":"v2"],confirmingAccess:false)
        let hits=await store.find("cream");XCTAssertTrue(hits.isEmpty)
        let projection=await store.validatedHits([original]);XCTAssertTrue(projection.isEmpty)
        let fingerprint=await store.fingerprint(for:"source");XCTAssertNil(fingerprint)
        do { _=try await store.current(original);XCTFail("Old source version remained visible") } catch PinStoreError.staleResult {}
        do { try await store.upsert(original.memory,permit:revised);XCTFail("Wrong fingerprint admitted") } catch PinStoreError.staleImport {}
        do { try await store.recordReadIssue(id:"source",fingerprint:"v1",issue:.analysisFailed,permit:revised);XCTFail("Wrong-version failure admitted") } catch PinStoreError.staleImport {}
        try await store.upsert(PhotoMemory(id:"source",fingerprint:"v2",text:["new text"]),permit:revised)
        let updated=await store.all();XCTAssertEqual(updated.first?.revision,2)
    }
    func testConfirmedWithdrawalPurgesRetainedSourceAndRejectsLateWork() async throws {
        let url=file();let store=try MemoryStore(file:url)
        let first=try await store.synchronizeSources(["keep":"v1","withdraw":"v1"])
        try await store.upsert(PhotoMemory(id:"withdraw",fingerprint:"v1",text:["private fixture"]),permit:first)
        let partial=try await store.synchronizeSources(["keep":"v1"],confirmingAccess:false)
        let before=try Data(contentsOf:url)
        let confirmed=try await store.synchronizeSources(["keep":"v1"],restartingImport:true)
        XCTAssertNotEqual(try Data(contentsOf:url),before)
        do { try await store.recordReadIssue(id:"keep",fingerprint:"v1",issue:.analysisFailed,permit:partial);XCTFail("Old partial permit survived reconciliation") } catch PinStoreError.staleImport {}
        try await store.recordReadIssue(id:"keep",fingerprint:"v1",issue:.analysisFailed,permit:confirmed)
        let reopened=try MemoryStore(file:url)
        _=try await reopened.synchronizeSources(["keep":"v1","withdraw":"v1"])
        let summary=await reopened.readSummary(["keep":"v1","withdraw":"v1"])
        XCTAssertEqual(summary.failed,1);XCTAssertEqual(summary.unread,1);XCTAssertEqual(summary.read,0)
    }
    func testEmptyPartialCataloguePreservesBytesAndForgettingThroughColdReturn() async throws {
        let url=file();let store=try MemoryStore(file:url)
        let permit=try await store.synchronizeSources(["read":"v1","forgotten":"v1"])
        try await store.upsert(PhotoMemory(id:"read",fingerprint:"v1",text:["cream"]),permit:permit)
        try await store.forget("forgotten")
        let before=try Data(contentsOf:url)
        let cold=try MemoryStore(file:url)
        _=try await cold.synchronizeSources([:],confirmingAccess:false)
        let hidden=await cold.all();XCTAssertTrue(hidden.isEmpty)
        XCTAssertEqual(try Data(contentsOf:url),before)
        let restored=try await cold.synchronizeSources(["read":"v1","forgotten":"v1"],confirmingAccess:false)
        let pending=await cold.pendingSourceIDs(["read":"v1","forgotten":"v1"]);XCTAssertTrue(pending.isEmpty)
        do { try await cold.upsert(PhotoMemory(id:"forgotten",fingerprint:"v1"),permit:restored);XCTFail("Forgotten source restored through partial catalogue") } catch PinStoreError.staleImport {}
        XCTAssertEqual(try Data(contentsOf:url),before)
    }
}
