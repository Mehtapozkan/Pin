import XCTest
@testable import PinCore

final class PhotoTextRereadTests:XCTestCase {
    private func fixture()async throws->(MemoryStore,URL,PhotoMemory,PhotoMemory,ImportPermit) {
        let file=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("memories.json")
        let store=try MemoryStore(file:file)
        let a=PhotoMemory(id:"reread-A",fingerprint:"vision-v4|reread-A|1|2|640x480|none",photographedAt:Date(timeIntervalSince1970:2),coordinate:.init(latitude:1,longitude:2),text:["OLD"],labels:[VisualLabel("ticket",confidence:0.8)],revision:7,imageRecognitionAvailable:false,textEvidence:[CardLine("OLD",confidence:0.7)],isScreenshot:true)
        let b=PhotoMemory(id:"untouched",fingerprint:"other",text:["KEEP"])
        let permit=try await store.synchronizeSources([a.id:a.fingerprint,b.id:b.fingerprint])
        try await store.upsert(a,permit:permit);try await store.upsert(b,permit:permit)
        return (store,file,a,b,permit)
    }
    func testSameSourceTextCASAdvancesOnlyObservationRevisionAndPreservesOtherFields()async throws {
        let (store,file,a,b,permit)=try await fixture(),ticket=try await store.prepareTextReread(EvidenceSource(a),permit:permit)
        let lines=[CardLine("NEW complete venue line",confidence:0.9,region:.init(x:0.1,y:0.2,width:0.6,height:0.1))]
        let updated=try await store.commitTextReread(lines,ticket:ticket)
        var expected=a;expected.revision=8;expected.text=lines.map(\.text);expected.textEvidence=lines
        XCTAssertEqual(updated,expected)
        let current=await store.all();XCTAssertEqual(current.first{$0.id==b.id},b)
        do{_=try await store.current(RecallHit(memory:a,score:1));XCTFail("old source revision displayed")}catch{}
        let cold=try MemoryStore(file:file);_=try await cold.synchronizeSources([a.id:a.fingerprint,b.id:b.fingerprint])
        let retained=await cold.all();XCTAssertEqual(retained.first{$0.id==a.id},expected);XCTAssertEqual(retained.first{$0.id==b.id},b)
    }
    func testOrdinarySameFingerprintImportStillNoOpsAndExplicitIdenticalRereadKeepsBytes()async throws {
        let (store,file,a,_,permit)=try await fixture(),before=try Data(contentsOf:file)
        var unexpected=a;unexpected.text=["IGNORED"];try await store.upsert(unexpected,permit:permit)
        XCTAssertEqual(try Data(contentsOf:file),before)
        let ticket=try await store.prepareTextReread(EvidenceSource(a),permit:permit)
        let value=try await store.commitTextReread(a.textEvidence!,ticket:ticket)
        XCTAssertEqual(value,a);XCTAssertEqual(try Data(contentsOf:file),before)
    }
    func testCompetingTextCASCannotOverwriteFirstAcceptedRevision()async throws {
        let (store,file,a,_,permit)=try await fixture()
        let one=try await store.prepareTextReread(EvidenceSource(a),permit:permit),two=try await store.prepareTextReread(EvidenceSource(a),permit:permit)
        _=try await store.commitTextReread([CardLine("FIRST")],ticket:one);let bytes=try Data(contentsOf:file)
        do{_=try await store.commitTextReread([CardLine("LATE")],ticket:two);XCTFail("late CAS overwrite")}catch{}
        XCTAssertEqual(try Data(contentsOf:file),bytes)
    }
    func testForgetRejectsPendingRereadAndSurvivesCold()async throws {
        let (store,file,a,b,permit)=try await fixture(),ticket=try await store.prepareTextReread(EvidenceSource(a),permit:permit)
        try await store.forget(a.id);let bytes=try Data(contentsOf:file)
        do{_=try await store.commitTextReread([CardLine("LATE")],ticket:ticket);XCTFail("Forgotten source resurrected")}catch{}
        XCTAssertEqual(try Data(contentsOf:file),bytes)
        let cold=try MemoryStore(file:file),fresh=try await cold.synchronizeSources([a.id:a.fingerprint,b.id:b.fingerprint])
        do{_=try await cold.prepareTextReread(EvidenceSource(a),permit:fresh);XCTFail("forgotten cold ticket")}catch{}
        let retained=await cold.all();XCTAssertEqual(retained,[b])
    }
    func testPartialAccessABAInvalidatesTicketWithoutDeletingRetainedBytes()async throws {
        let (store,file,a,b,permit)=try await fixture(),ticket=try await store.prepareTextReread(EvidenceSource(a),permit:permit),bytes=try Data(contentsOf:file)
        _=try await store.synchronizeSources([b.id:b.fingerprint],confirmingAccess:false)
        _=try await store.synchronizeSources([a.id:a.fingerprint,b.id:b.fingerprint])
        do{_=try await store.commitTextReread([CardLine("LATE")],ticket:ticket);XCTFail("access ABA survived")}catch{}
        XCTAssertEqual(try Data(contentsOf:file),bytes)
    }
    func testUnconfirmedCatalogueAndAccessOnlyCannotMintTextReread()async throws {
        let (store,_,a,b,_)=try await fixture()
        let partial=try await store.synchronizeSources([a.id:a.fingerprint,b.id:b.fingerprint],confirmingAccess:false)
        do{_=try await store.prepareTextReread(EvidenceSource(a),permit:partial);XCTFail("unconfirmed catalogue granted write")}catch{}
        let file=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+"/new.json"),other=try MemoryStore(file:file)
        let access=try await other.synchronizeAccess([a.id]);try await other.upsert(a,permit:access)
        do{_=try await other.prepareTextReread(EvidenceSource(a),permit:access);XCTFail("no source catalogue granted write")}catch{}
    }
    func testMetadataChangeAndForeignStoreRejectTickets()async throws {
        let (store,file,a,b,permit)=try await fixture(),ticket=try await store.prepareTextReread(EvidenceSource(a),permit:permit)
        let other=try MemoryStore(file:file);_=try await other.synchronizeSources([a.id:a.fingerprint,b.id:b.fingerprint])
        do{_=try await other.commitTextReread([CardLine("FOREIGN")],ticket:ticket);XCTFail("old store authority reused")}catch{}
        _=try await store.synchronizeSources([a.id:"different",b.id:b.fingerprint]);let bytes=try Data(contentsOf:file)
        do{_=try await store.commitTextReread([CardLine("WRONG IMAGE")],ticket:ticket);XCTFail("metadata change ignored")}catch{}
        XCTAssertEqual(try Data(contentsOf:file),bytes)
    }
    func testMalformedObservationsDoNotChangeSavedState()async throws {
        let (store,file,a,_,permit)=try await fixture(),ticket=try await store.prepareTextReread(EvidenceSource(a),permit:permit),bytes=try Data(contentsOf:file)
        var region=CardLine("bad region");region.region=EvidenceRegion(x:0,y:0,width:2,height:1)
        for lines in [[CardLine("bad confidence",confidence:.nan)],[region],Array(repeating:CardLine("x"),count:4097)] {
            do{_=try await store.commitTextReread(lines,ticket:ticket);XCTFail("invalid observations saved")}catch{}
            XCTAssertEqual(try Data(contentsOf:file),bytes)
        }
    }
    func testCancelledTextCommitCannotWrite()async throws {
        let (store,file,a,_,permit)=try await fixture(),ticket=try await store.prepareTextReread(EvidenceSource(a),permit:permit),bytes=try Data(contentsOf:file)
        let task=Task{withUnsafeCurrentTask{$0?.cancel()};return try await store.commitTextReread([CardLine("CANCELLED")],ticket:ticket)}
        do{_=try await task.value;XCTFail("cancelled observations saved")}catch{}
        XCTAssertEqual(try Data(contentsOf:file),bytes)
    }
    func testForeignImportPermitCannotMintRereadEvenWithMatchingEpochAndSource()async throws {
        let (store,_,a,_,_)=try await fixture(),(_,_,_,_,foreignPermit)=try await fixture()
        do{_=try await store.prepareTextReread(EvidenceSource(a),permit:foreignPermit);XCTFail("foreign import permit minted native write authority")}catch{}
    }

}
