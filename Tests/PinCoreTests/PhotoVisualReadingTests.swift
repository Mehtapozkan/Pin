import XCTest
@testable import PinCore

final class PhotoVisualReadingTests:XCTestCase {
    private func reading(_ memory:PhotoMemory)throws->PhotoVisualReading {
        let id=UUID().uuidString,source:[String:Any]=["id":memory.id,"fingerprint":memory.fingerprint,"revision":memory.revision]
        let original=String(repeating:"a",count:64),frame=String(repeating:"b",count:64)
        let request=try JSONSerialization.data(withJSONObject:["contract":"visual-source-evidence-v2-host-image-binding-v1","taskID":id,"source":source,"modelFrameSHA256":frame,"readingPolicy":"verbatimFieldsV2","sourceImageBinding":["source":source,"imageSHA256":original,"acquisitionID":id]],options:[.sortedKeys])
        let receipt=try JSONSerialization.data(withJSONObject:["provider":"authored-native-visual","model":"no-model","requestSHA256":PhotoVisualReading.hash(request),"coverage":"partial","visibleDocumentCount":2,"elapsedSeconds":0,"observations":[["kind":"text","value":"Authored front event","box":[10,10,500,100]],["kind":"visualLabel","value":"printed-ticket-body","box":[0,0,600,800]],["kind":"visualLabel","value":"overlapping-documents","box":[0,0,1000,1000]]]],options:[.sortedKeys])
        return try PhotoVisualReading(sourceBeforeRead:EvidenceSource(memory),originalSHA256:original,frameSHA256:frame,requestData:request,receiptData:receipt)
    }
    private func fixture()async throws->(MemoryStore,URL,PhotoMemory,PhotoMemory,ImportPermit) {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),file=root.appendingPathComponent("memories.json")
        addTeardownBlock{try? FileManager.default.removeItem(at:root)}
        let store=try MemoryStore(file:file),a=PhotoMemory(id:"visual-A",fingerprint:"same-photo",text:["old"],labels:[VisualLabel("ticket",confidence:0.9)],textEvidence:[CardLine("old")]),b=PhotoMemory(id:"other",fingerprint:"other",text:["untouched"])
        let permit=try await store.synchronizeSources([a.id:a.fingerprint,b.id:b.fingerprint]);try await store.upsert(a,permit:permit);try await store.upsert(b,permit:permit)
        return (store,file,a,b,permit)
    }
    func testPartialVisualCASAndColdPreserveCountProofMetadataAndOtherWholeSource()async throws {
        let (store,file,a,b,permit)=try await fixture(),visual=try reading(a)
        let old=try JSONSerialization.jsonObject(with:Data(contentsOf:file)) as! [String:Any];XCTAssertEqual(old["schema"] as? Int,1)
        let ticket=try await store.prepareTextReread(EvidenceSource(a),permit:permit)
        let revised=try await store.commitVisualReread(visual,ticket:ticket)
        XCTAssertEqual(revised.revision,a.revision+1);XCTAssertEqual(revised.fingerprint,a.fingerprint);XCTAssertEqual(revised.labels,a.labels)
        XCTAssertEqual(revised.visualReading,visual);XCTAssertEqual(try visual.validatedReceipt().coverage,"partial");XCTAssertEqual(try visual.validatedReceipt().visibleDocumentCount,2)
        XCTAssertTrue(revised.textEvidence!.allSatisfy{$0.confidence==0});try visual.validate(for:revised)
        let before=try Data(contentsOf:file),cold=try MemoryStore(file:file);_=try await cold.synchronizeSources([a.id:a.fingerprint,b.id:b.fingerprint])
        let rows=await cold.all();XCTAssertEqual(rows.first{$0.id==a.id},revised);XCTAssertEqual(rows.first{$0.id==b.id},b);XCTAssertEqual(try Data(contentsOf:file),before)
        let wire=try JSONSerialization.jsonObject(with:before) as! [String:Any];XCTAssertEqual(wire["schema"] as? Int,2)
    }
    func testVisualCASCannotSurviveForgetOrBeReplayed()async throws {
        let (store,file,a,_,permit)=try await fixture(),visual=try reading(a),ticket=try await store.prepareTextReread(EvidenceSource(a),permit:permit)
        _=try await store.commitVisualReread(visual,ticket:ticket);let before=try Data(contentsOf:file)
        do{_=try await store.commitVisualReread(visual,ticket:ticket);XCTFail("visual CAS replay")}catch{}
        XCTAssertEqual(try Data(contentsOf:file),before)
        try await store.forget(a.id);let forgotten=try Data(contentsOf:file)
        do{_=try await store.commitVisualReread(visual,ticket:ticket);XCTFail("forgotten visual source restored")}catch{}
        XCTAssertEqual(try Data(contentsOf:file),forgotten)
    }
    func testTextReplacementClearsOldVisualProofInsteadOfRebindingIt()async throws {
        let (store,_,a,_,permit)=try await fixture(),visual=try reading(a)
        let first=try await store.prepareTextReread(EvidenceSource(a),permit:permit),revised=try await store.commitVisualReread(visual,ticket:first)
        let ticket=try await store.prepareTextReread(EvidenceSource(revised),permit:permit)
        let current=try await store.commitTextReread([CardLine("New local OCR")],ticket:ticket)
        XCTAssertNil(current.visualReading);XCTAssertEqual(current.revision,revised.revision+1)
        XCTAssertThrowsError(try visual.validate(for:current))
    }
    func testTamperedBindingAndLegacySchemaCannotSilentlyDiscardEvidence()async throws {
        let (store,file,a,_,permit)=try await fixture(),visual=try reading(a),ticket=try await store.prepareTextReread(EvidenceSource(a),permit:permit)
        XCTAssertThrowsError(try PhotoVisualReading(sourceBeforeRead:EvidenceSource(a),originalSHA256:String(repeating:"c",count:64),frameSHA256:visual.frameSHA256,requestData:visual.requestData,receiptData:visual.receiptData))
        _=try await store.commitVisualReread(visual,ticket:ticket)
        var wire=try JSONSerialization.jsonObject(with:Data(contentsOf:file)) as! [String:Any];wire["schema"]=1
        let forged=try JSONSerialization.data(withJSONObject:wire);try forged.write(to:file)
        XCTAssertThrowsError(try MemoryStore(file:file));XCTAssertEqual(try Data(contentsOf:file),forged)
    }
    func testOrdinaryImportCannotIntroduceOrRebindVisualProof()async throws {
        let (store,file,a,b,permit)=try await fixture(),visual=try reading(a)
        var forged=a;forged.revision += 1;forged.visualReading=visual;forged.textEvidence=try visual.textLines();forged.text=forged.textEvidence!.map(\.text)
        let before=try Data(contentsOf:file)
        do{try await store.upsert(forged,permit:permit);XCTFail("ordinary import installed visual proof")}catch{}
        XCTAssertEqual(try Data(contentsOf:file),before)
        let ticket=try await store.prepareTextReread(EvidenceSource(a),permit:permit),revised=try await store.commitVisualReread(visual,ticket:ticket)
        let next=try await store.synchronizeSources([a.id:"new-fingerprint",b.id:b.fingerprint])
        let imported=PhotoMemory(id:a.id,fingerprint:"new-fingerprint",text:["new native read"],textEvidence:[CardLine("new native read")])
        try await store.upsert(imported,permit:next)
        let rows=await store.all(),current=try XCTUnwrap(rows.first{$0.id==a.id})
        XCTAssertNil(current.visualReading);XCTAssertGreaterThan(current.revision,revised.revision)
        XCTAssertEqual(rows.first{$0.id==b.id},b)
        XCTAssertThrowsError(try visual.validate(for:current))
    }

}
