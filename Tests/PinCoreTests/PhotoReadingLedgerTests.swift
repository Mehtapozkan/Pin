import XCTest
@testable import PinCore
final class PhotoReadingLedgerTests:XCTestCase {
    func makeStore() throws -> (MemoryStore,URL) {
        let file=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("index.json")
        return (try MemoryStore(file:file),file)
    }
    func testDurableCoveragePartitionsSourcesWithoutCallingReadUnderstanding() async throws {
        let (store,file)=try makeStore()
        let ids=Set(["read","empty","cloud","unavailable","failed","unread"])
        let fingerprints=Dictionary(uniqueKeysWithValues:ids.map { ($0,"v1") })
        let permit=try await store.synchronizeAccess(ids)
        try await store.upsert(PhotoMemory(id:"read",fingerprint:"v1",text:["Appointment"],labels:[]),permit:permit)
        try await store.upsert(PhotoMemory(id:"empty",fingerprint:"v1",imageRecognitionAvailable:false),permit:permit)
        try await store.recordReadIssue(id:"cloud",fingerprint:"v1",issue:.needsDownload,permit:permit)
        try await store.recordReadIssue(id:"unavailable",fingerprint:"v1",issue:.photoUnavailable,permit:permit)
        try await store.recordReadIssue(id:"failed",fingerprint:"v1",issue:.analysisFailed,permit:permit)
        let summary=await store.readSummary(fingerprints)
        XCTAssertEqual(summary.total,6);XCTAssertEqual(summary.read,2);XCTAssertEqual(summary.unread,1)
        XCTAssertEqual(summary.needsDownload,1);XCTAssertEqual(summary.unavailable,1);XCTAssertEqual(summary.failed,1)
        XCTAssertEqual(summary.withoutUsableDetails,1);XCTAssertEqual(summary.partialRecognition,1)
        XCTAssertEqual(summary.total,summary.read + summary.incomplete)
        let reopened=try MemoryStore(file:file)
        let invisible=await reopened.readSummary(fingerprints);XCTAssertEqual(invisible.total,0)
        _=try await reopened.synchronizeAccess(ids)
        let retained=await reopened.readSummary(fingerprints);XCTAssertEqual(retained,summary)
    }
    func testSuccessfulRetryClearsFailureAndRetainsSearch() async throws {
        let (store,file)=try makeStore();let permit=try await store.synchronizeAccess(["shoe"])
        try await store.recordReadIssue(id:"shoe",fingerprint:"v1",issue:.analysisFailed,permit:permit)
        try await store.upsert(PhotoMemory(id:"shoe",fingerprint:"v1",text:["CREAM"],labels:[VisualLabel("sneakers",confidence:0.9)]),permit:permit)
        let reopened=try MemoryStore(file:file);_=try await reopened.synchronizeAccess(["shoe"])
        let summary=await reopened.readSummary(["shoe":"v1"]);XCTAssertEqual(summary.read,1);XCTAssertEqual(summary.failed,0)
        let hits=await reopened.find("cream");XCTAssertEqual(hits.map(\.id),["shoe"])
    }
    func testChangedOrWithdrawnSourcesDoNotInheritOldFailures() async throws {
        let (store,_)=try makeStore();let permit=try await store.synchronizeAccess(["source"])
        try await store.recordReadIssue(id:"source",fingerprint:"v1",issue:.needsDownload,permit:permit)
        let revised=await store.readSummary(["source":"v2"]);XCTAssertEqual(revised.unread,1);XCTAssertEqual(revised.needsDownload,0)
        _=try await store.synchronizeAccess([])
        do { try await store.recordReadIssue(id:"source",fingerprint:"v1",issue:.analysisFailed,permit:permit);XCTFail("Stale issue admitted") } catch PinStoreError.staleImport {}
        _=try await store.synchronizeAccess(["source"])
        let restored=await store.readSummary(["source":"v1"]);XCTAssertEqual(restored.unread,1)
    }
    func testForgettingRemovesFailureAndRejectsLateWork() async throws {
        let (store,file)=try makeStore();let permit=try await store.synchronizeAccess(["source"])
        try await store.recordReadIssue(id:"source",fingerprint:"v1",issue:.analysisFailed,permit:permit)
        try await store.forget("source")
        do { try await store.recordReadIssue(id:"source",fingerprint:"v1",issue:.needsDownload,permit:permit);XCTFail("Forgotten source returned") } catch PinStoreError.staleImport {}
        let reopened=try MemoryStore(file:file);_=try await reopened.synchronizeAccess(["source"])
        let summary=await reopened.readSummary(["source":"v1"]);XCTAssertEqual(summary.total,0)
    }
    func testCloudDownloadSelectionFollowsCurrentSourceAuthority() async throws {
        let (store,_) = try makeStore()
        let fingerprints = ["cloud":"v1", "failed":"v1", "read":"v1"]
        let permit = try await store.synchronizeSources(fingerprints)
        try await store.recordReadIssue(id:"cloud",fingerprint:"v1",issue:.needsDownload,permit:permit)
        try await store.recordReadIssue(id:"failed",fingerprint:"v1",issue:.analysisFailed,permit:permit)
        try await store.upsert(PhotoMemory(id:"read",fingerprint:"v1",text:["Photo read"]),permit:permit)
        let initial = await store.sourcesNeedingDownload(fingerprints)
        XCTAssertEqual(initial, Set(["cloud"]))

        let changed = ["cloud":"v2", "failed":"v1", "read":"v1"]
        _ = try await store.synchronizeSources(changed)
        let afterChange = await store.sourcesNeedingDownload(changed)
        XCTAssertTrue(afterChange.isEmpty)
        let revisedPermit = try await store.synchronizeSources(changed,restartingImport:true)
        try await store.recordReadIssue(id:"cloud",fingerprint:"v2",issue:.needsDownload,permit:revisedPermit)
        let revised = await store.sourcesNeedingDownload(changed)
        XCTAssertEqual(revised, Set(["cloud"]))
        _ = try await store.synchronizeAccess(["failed", "read"])
        let afterWithdrawal = await store.sourcesNeedingDownload(changed)
        XCTAssertTrue(afterWithdrawal.isEmpty)
    }

    func testUnchangedLedgerSynchronizationDoesNotRewriteIndex() async throws {
        let (store,file)=try makeStore();let permit=try await store.synchronizeAccess(["source"])
        try await store.recordReadIssue(id:"source",fingerprint:"v1",issue:.photoUnavailable,permit:permit)
        let before=try Data(contentsOf:file)
        _=try await store.synchronizeAccess(["source"])
        XCTAssertEqual(try Data(contentsOf:file),before)
    }
}
