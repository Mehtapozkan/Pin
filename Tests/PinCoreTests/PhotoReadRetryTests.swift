import XCTest
@testable import PinCore

final class PhotoReadRetryTests: XCTestCase {
    func testColdIntakeDoesNotRescheduleUnchangedFailedOrCloudOnlyReads() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let file=root.appendingPathComponent("index.json")
        let store=try MemoryStore(file:file)
        let versions=["read":"v1","cloud":"v1","failed":"v1","unavailable":"v1","unread":"v1"]
        let permit=try await store.synchronizeSources(versions)
        try await store.upsert(PhotoMemory(id:"read",fingerprint:"v1",text:["CREAM"]),permit:permit)
        try await store.recordReadIssue(id:"cloud",fingerprint:"v1",issue:.needsDownload,permit:permit)
        try await store.recordReadIssue(id:"failed",fingerprint:"v1",issue:.analysisFailed,permit:permit)
        try await store.recordReadIssue(id:"unavailable",fingerprint:"v1",issue:.photoUnavailable,permit:permit)
        let before=try Data(contentsOf:file)
        let cold=try MemoryStore(file:file)
        _=try await cold.synchronizeSources(versions,restartingImport:true)
        let pending=await cold.pendingSourceIDs(versions)
        XCTAssertEqual(pending,["unread"],"Durable failures need an explicit retry; restarting indexing must not erase the checkpoint")
        let summary=await cold.readSummary(versions)
        XCTAssertEqual(summary.read,1);XCTAssertEqual(summary.failed,1);XCTAssertEqual(summary.unavailable,1);XCTAssertEqual(summary.needsDownload,1);XCTAssertEqual(summary.unread,1)
        XCTAssertEqual(try Data(contentsOf:file),before)
        let hits=await cold.find("cream");XCTAssertEqual(hits.map(\.id),["read"])
    }

    func testExplicitLocalRetryNeverDownloadsCloudOrRereadsSuccessAndRecoveryClearsOnlyItsIssue() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let file=root.appendingPathComponent("index.json"), store=try MemoryStore(file:file)
        let versions=["good":"v1","empty":"v1","cloud":"v1","failed":"v1","unavailable":"v1","interrupted":"v1"]
        let permit=try await store.synchronizeSources(versions)
        try await store.upsert(PhotoMemory(id:"good",fingerprint:"v1",text:["Appointment"]),permit:permit)
        try await store.upsert(PhotoMemory(id:"empty",fingerprint:"v1",imageRecognitionAvailable:false),permit:permit)
        for (id,issue) in [("cloud",PhotoReadIssue.needsDownload),("failed",.analysisFailed),("unavailable",.photoUnavailable)] {
            try await store.recordReadIssue(id:id,fingerprint:"v1",issue:issue,permit:permit)
        }
        let before=try Data(contentsOf:file)
        let local=await store.pendingSourceIDs(versions,retrying:[.photoUnavailable,.analysisFailed])
        XCTAssertEqual(local,["failed","unavailable","interrupted"])
        let download=await store.pendingSourceIDs(versions,retrying:[.needsDownload])
        XCTAssertEqual(download,["cloud","interrupted"])
        let network=await store.sourcesNeedingDownload(versions);XCTAssertEqual(network,["cloud"])
        XCTAssertEqual(try Data(contentsOf:file),before,"Planning a retry must not erase an issue or manufacture a read")
        let oldGood=await store.all().first{$0.id=="good"}
        try await store.upsert(PhotoMemory(id:"failed",fingerprint:"v1",text:["CREAM repaired"]),permit:permit)
        let after=await store.readSummary(versions)
        XCTAssertEqual(after.read,3);XCTAssertEqual(after.failed,0);XCTAssertEqual(after.unavailable,1);XCTAssertEqual(after.needsDownload,1);XCTAssertEqual(after.unread,1);XCTAssertEqual(after.withoutUsableDetails,1)
        let cold=try MemoryStore(file:file);_=try await cold.synchronizeSources(versions)
        let coldPending=await cold.pendingSourceIDs(versions);XCTAssertEqual(coldPending,["interrupted"])
        let goodAfter=await cold.all().first{$0.id=="good"};XCTAssertEqual(goodAfter,oldGood)
        let hits=await cold.find("cream");XCTAssertEqual(hits.map(\.id),["failed"])
    }

    func testChangedSourceGetsOneNewReadButForgetWithdrawalAndStalePermitFenceRetry() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let store=try MemoryStore(file:root.appendingPathComponent("index.json"))
        let old=["changed":"v1","forgotten":"v1","withdrawn":"v1"]
        let permit=try await store.synchronizeSources(old)
        for id in old.keys { try await store.recordReadIssue(id:id,fingerprint:"v1",issue:.analysisFailed,permit:permit) }
        try await store.forget("forgotten")
        let current=["changed":"v2","forgotten":"v1"]
        _=try await store.synchronizeSources(current,restartingImport:true)
        let automatic=await store.pendingSourceIDs(current);XCTAssertEqual(automatic,["changed"])
        let retried=await store.pendingSourceIDs(old,retrying:[.analysisFailed,.photoUnavailable,.needsDownload]);XCTAssertTrue(retried.isEmpty)
        do { try await store.upsert(PhotoMemory(id:"changed",fingerprint:"v1",text:["late"]),permit:permit);XCTFail("stale retry returned") } catch PinStoreError.staleImport {}
        let summary=await store.readSummary(current);XCTAssertEqual(summary.total,1);XCTAssertEqual(summary.unread,1);XCTAssertEqual(summary.failed,0)
    }
}
