import XCTest
@testable import PinCore

final class SavedPhotoInterpretationTests:XCTestCase {
    private func fixture()async throws->(MemoryStore,URL,PhotoMemory,PhotoMemory) {
        let file=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+"/memory.json")
        let store=try MemoryStore(file:file)
        let a=PhotoMemory(id:"saved-A",fingerprint:"original-A",text:["Printed restaurant idea"],textEvidence:[CardLine("Printed restaurant idea")])
        let b=PhotoMemory(id:"saved-B",fingerprint:"original-B",text:["Unchanged photograph"])
        let permit=try await store.synchronizeSources([a.id:a.fingerprint,b.id:b.fingerprint])
        try await store.upsert(a,permit:permit);try await store.upsert(b,permit:permit)
        return(store,file,a,b)
    }
    func testPlanCorrectionCoexistsWithOtherEditorsAndRetiresWithDependentPhoto() async throws {
        let (store, file, a, b) = try await fixture()
        let source = EvidenceSource(a)
        let related = EvidenceSource(b)
        let note = try await store.savePhotoInterpretation(source: source, correction: "My note", expected: nil)
        let edit = try await store.savePlanDetail(source: source, person: "  Maya CHEN ", field: .status,
            value: "tentative", additionalSources: [related], expected: note)
        XCTAssertEqual(edit?.planCorrections?.first?.person, "maya chen")
        XCTAssertEqual(edit?.correction, "My note")
        do {
            _ = try await store.savePlanDetail(source: source, person: "Maya Chen", field: .status,
                value: "confirmed", additionalSources: [related], expected: note)
            XCTFail("A stale editor replaced an existing correction")
        } catch PinStoreError.staleResult {}
        let updated = try await store.savePlaceDetail(source: source, mentionID: "place", field: .address,
            value: "2 Example Street", expected: edit)
        XCTAssertEqual(updated?.planCorrections, edit?.planCorrections)
        let cold = try MemoryStore(file: file)
        _ = try await cold.synchronizeSources([a.id: a.fingerprint, b.id: b.fingerprint])
        let retained = await cold.savedPhotoInterpretations()
        XCTAssertEqual(retained.first, updated)
        try await cold.forget(b.id)
        let remaining = await cold.savedPhotoInterpretations()
        XCTAssertNil(remaining.first?.planCorrections)
        XCTAssertEqual(remaining.first?.correction, "My note")
        XCTAssertEqual(remaining.first?.placeCorrections?.first?.value, "2 Example Street")
        let memories = await cold.all()
        XCTAssertEqual(memories, [a])
    }

    func testPlaceFieldCorrectionKeepsExistingAnnotationIndexAndColdBytes() async throws {
        let (store, file, a, b) = try await fixture()
        let source = EvidenceSource(a)
        let annotation = try await store.savePhotoInterpretation(source: source, correction: "My note", expected: nil)
        let saved = try await store.savePlaceDetail(
            source: source, mentionID: "first-mention", field: .address,
            value: " 2 Example Street ", expected: annotation
        )
        XCTAssertEqual(saved?.correction, "My note")
        XCTAssertEqual(saved?.placeCorrections?.first?.value, "2 Example Street")
        let updatedAnnotation = try await store.savePhotoInterpretation(
            source: source, correction: "Updated note", expected: saved
        )
        XCTAssertEqual(updatedAnnotation?.placeCorrections, saved?.placeCorrections)
        let bytes = try Data(contentsOf: file)
        let cold = try MemoryStore(file: file)
        _ = try await cold.synchronizeSources([a.id: a.fingerprint, b.id: b.fingerprint])
        let interpretations = await cold.savedPhotoInterpretations()
        let memories = await cold.all()
        let search = await cold.find("restaurant")
        XCTAssertEqual(interpretations.first, updatedAnnotation)
        XCTAssertEqual(Set(memories.map(EvidenceSource.init)), [source, EvidenceSource(b)])
        XCTAssertEqual(search.map(\.id), [a.id])
        XCTAssertEqual(try Data(contentsOf: file), bytes)
    }

    func testPlaceCorrectionStaleEditorAndForgetFence() async throws {
        let (store, file, a, b) = try await fixture()
        let source = EvidenceSource(a)
        let first = try await store.savePlaceDetail(
            source: source, mentionID: "first-mention", field: .neighborhood, value: "Shibuya", expected: nil
        )
        do {
            _ = try await store.savePlaceDetail(
                source: source, mentionID: "first-mention", field: .neighborhood, value: "Ueno", expected: nil
            )
            XCTFail("A stale editor replaced a saved place field")
        } catch PinStoreError.staleResult {}
        let second = try await store.savePlaceDetail(
            source: source, mentionID: "another-mention", field: .neighborhood, value: "Ueno", expected: first
        )
        XCTAssertEqual(second?.placeCorrections?.count, 2)
        try await store.forget(RecallHit(memory: a, score: 0))
        let cold = try MemoryStore(file: file)
        _ = try await cold.synchronizeSources([a.id: a.fingerprint, b.id: b.fingerprint])
        let interpretations = await cold.savedPhotoInterpretations()
        let memories = await cold.all()
        let forgotten = await cold.isForgotten(a.id)
        XCTAssertTrue(interpretations.isEmpty)
        XCTAssertEqual(memories, [b])
        XCTAssertTrue(forgotten)
    }

    func testCorrectionSurvivesColdWithoutChangingObservationsSearchOrPendingIndex()async throws {
        let(store,file,a,b)=try await fixture()
        let before=await store.find("restaurant"),pending=await store.pendingSourceIDs([a.id:a.fingerprint,b.id:b.fingerprint])
        let saved=try await store.savePhotoInterpretation(source:EvidenceSource(a),correction:"My idea is a recurring lunch subscription",expected:nil)
        let all=await store.all();XCTAssertEqual(Set(all.map(EvidenceSource.init)),Set([a,b].map(EvidenceSource.init)))
        XCTAssertEqual(all.first{$0.id==a.id},a);XCTAssertEqual(all.first{$0.id==b.id},b)
        let after=await store.find("restaurant"),afterPending=await store.pendingSourceIDs([a.id:a.fingerprint,b.id:b.fingerprint])
        XCTAssertEqual(before.map(\.id),after.map(\.id));XCTAssertEqual(pending,afterPending)
        let bytes=try Data(contentsOf:file),cold=try MemoryStore(file:file)
        _=try await cold.synchronizeSources([a.id:a.fingerprint,b.id:b.fingerprint])
        let retained=await cold.savedPhotoInterpretations();XCTAssertEqual(retained,[saved!]);XCTAssertEqual(try Data(contentsOf:file),bytes)
        _=try await cold.savePhotoInterpretation(source:EvidenceSource(a),correction:saved!.correction,expected:saved)
        XCTAssertEqual(try Data(contentsOf:file),bytes)
    }
    func testStaleEditorAndSourceChangeCannotOverwriteOrResurrectCorrection()async throws {
        let(store,file,a,b)=try await fixture()
        let first=try await store.savePhotoInterpretation(source:EvidenceSource(a),correction:"FIRST",expected:nil)!
        let bytes=try Data(contentsOf:file)
        do{_=try await store.savePhotoInterpretation(source:EvidenceSource(a),correction:"LATE",expected:nil);XCTFail("stale editor overwrote correction")}catch{}
        XCTAssertEqual(try Data(contentsOf:file),bytes)
        let permit=try await store.synchronizeSources([a.id:"new-A",b.id:b.fingerprint])
        var updated=a;updated.fingerprint="new-A";try await store.upsert(updated,permit:permit)
        updated.revision=a.revision+1
        let retired=await store.savedPhotoInterpretations();XCTAssertEqual(retired.first?.correction,nil);XCTAssertGreaterThan(retired.first!.recordRevision,first.recordRevision)
        do{_=try await store.savePhotoInterpretation(source:EvidenceSource(a),correction:"OLD",expected:first);XCTFail("old source correction accepted")}catch{}
        let second=try await store.savePhotoInterpretation(source:EvidenceSource(updated),correction:"NEW",expected:retired.first)!
        XCTAssertGreaterThan(second.recordRevision,retired.first!.recordRevision)
    }
    func testPartialCatalogueRetainsBytesButConfirmedWithdrawalAndForgetPurgeCorrection()async throws {
        let(store,file,a,b)=try await fixture()
        _=try await store.savePhotoInterpretation(source:EvidenceSource(a),correction:"PRIVATE",expected:nil)
        let bytes=try Data(contentsOf:file)
        _=try await store.synchronizeSources([b.id:b.fingerprint],confirmingAccess:false)
        let hidden=await store.savedPhotoInterpretations();XCTAssertTrue(hidden.isEmpty);XCTAssertEqual(try Data(contentsOf:file),bytes)
        _=try await store.synchronizeSources([a.id:a.fingerprint,b.id:b.fingerprint])
        let restored=await store.savedPhotoInterpretations();XCTAssertEqual(restored.count,1)
        try await store.forget(a.id)
        let forgotten=await store.savedPhotoInterpretations();XCTAssertTrue(forgotten.isEmpty)
        let cold=try MemoryStore(file:file);_=try await cold.synchronizeSources([a.id:a.fingerprint,b.id:b.fingerprint])
        let stillForgotten=await cold.savedPhotoInterpretations();XCTAssertTrue(stillForgotten.isEmpty)
        XCTAssertFalse(String(data:try Data(contentsOf:file),encoding:.utf8)!.contains("PRIVATE"))
        _=try await cold.savePhotoInterpretation(source:EvidenceSource(b),correction:"OTHER",expected:nil)
        _=try await cold.synchronizeSources([:])
        XCTAssertFalse(String(data:try Data(contentsOf:file),encoding:.utf8)!.contains("OTHER"))
    }
    func testRereadRetiresCorrectionAndUnconfirmedCatalogueCannotEdit()async throws {
        let(store,_,a,b)=try await fixture()
        let first=try await store.savePhotoInterpretation(source:EvidenceSource(a),correction:"FIRST",expected:nil)!
        let permit=try await store.synchronizeSources([a.id:a.fingerprint,b.id:b.fingerprint])
        let ticket=try await store.prepareTextReread(EvidenceSource(a),permit:permit)
        let updated=try await store.commitTextReread([CardLine("New printed observation")],ticket:ticket)
        let retired=await store.savedPhotoInterpretations();XCTAssertEqual(retired.first?.source,EvidenceSource(updated));XCTAssertNil(retired.first?.correction)
        XCTAssertGreaterThan(retired.first!.recordRevision,first.recordRevision)
        _=try await store.synchronizeSources([a.id:a.fingerprint,b.id:b.fingerprint],confirmingAccess:false)
        do{_=try await store.savePhotoInterpretation(source:EvidenceSource(updated),correction:"unconfirmed",expected:retired.first);XCTFail("unconfirmed edit")}catch{}
    }
    func testRereadStartedBeforeCorrectionCannotEraseItAndColdReopenRetainsIt()async throws {
        let(store,file,a,b)=try await fixture()
        let permit=try await store.synchronizeSources([a.id:a.fingerprint,b.id:b.fingerprint])
        let ticket=try await store.prepareTextReread(EvidenceSource(a),permit:permit)
        let saved=try await store.savePhotoInterpretation(source:EvidenceSource(a),correction:"Fictional test idea; not a purchase",expected:nil)
        let bytes=try Data(contentsOf:file)
        do{_=try await store.commitTextReread([CardLine("Late printed observation")],ticket:ticket);XCTFail("late reread erased a newly saved correction")}catch PinStoreError.staleImport{}
        XCTAssertEqual(try Data(contentsOf:file),bytes)
        let cold=try MemoryStore(file:file)
        _=try await cold.synchronizeSources([a.id:a.fingerprint,b.id:b.fingerprint])
        let retained=await cold.savedPhotoInterpretations(),all=await cold.all()
        XCTAssertEqual(retained,[saved!]);XCTAssertEqual(all.first{$0.id==a.id},a);XCTAssertEqual(all.first{$0.id==b.id},b)
    }
    func testPreparedRereadCannotEraseCorrectionEditedAfterStaging()async throws {
        let(store,file,a,b)=try await fixture()
        let first=try await store.savePhotoInterpretation(source:EvidenceSource(a),correction:"First correction",expected:nil)
        let permit=try await store.synchronizeSources([a.id:a.fingerprint,b.id:b.fingerprint])
        let ticket=try await store.prepareTextReread(EvidenceSource(a),permit:permit)
        let prepared=try await store.stageTextReread([CardLine("Late printed observation")],ticket:ticket)
        let edited=try await store.savePhotoInterpretation(source:EvidenceSource(a),correction:"Edited correction",expected:first)
        let bytes=try Data(contentsOf:file)
        do{_=try await store.commitPreparedReread(prepared);XCTFail("staged reread erased an edited correction")}catch PinStoreError.staleImport{}
        XCTAssertEqual(try Data(contentsOf:file),bytes)
        let retained=await store.savedPhotoInterpretations();XCTAssertEqual(retained,[edited!])
    }
    func testCorrectionSaveThenRevokeStillInvalidatesEarlierReread()async throws {
        let(store,file,a,b)=try await fixture()
        let permit=try await store.synchronizeSources([a.id:a.fingerprint,b.id:b.fingerprint])
        let ticket=try await store.prepareTextReread(EvidenceSource(a),permit:permit)
        let first=try await store.savePhotoInterpretation(source:EvidenceSource(a),correction:"Temporary correction",expected:nil)
        let revoked=try await store.savePhotoInterpretation(source:EvidenceSource(a),correction:nil,expected:first)
        let bytes=try Data(contentsOf:file)
        do{_=try await store.commitTextReread([CardLine("Late printed observation")],ticket:ticket);XCTFail("reread crossed correction save/revoke")}catch PinStoreError.staleImport{}
        XCTAssertEqual(try Data(contentsOf:file),bytes)
        let retained=await store.savedPhotoInterpretations();XCTAssertEqual(retained,[revoked!])
    }
    func testCorrectionOnAnotherPhotoDoesNotBlockRereadOrIndexProgress()async throws {
        let(store,_,a,b)=try await fixture()
        let permit=try await store.synchronizeSources([a.id:a.fingerprint,b.id:b.fingerprint])
        let ticket=try await store.prepareTextReread(EvidenceSource(a),permit:permit)
        let saved=try await store.savePhotoInterpretation(source:EvidenceSource(b),correction:"Other photo correction",expected:nil)
        let updated=try await store.commitTextReread([CardLine("Current printed observation")],ticket:ticket)
        XCTAssertEqual(updated.revision,a.revision+1)
        let retained=await store.savedPhotoInterpretations(),all=await store.all()
        let pending=await store.pendingSourceIDs([a.id:a.fingerprint,b.id:b.fingerprint])
        XCTAssertEqual(retained,[saved!]);XCTAssertEqual(all.first{$0.id==b.id},b);XCTAssertTrue(pending.isEmpty)
    }
}
