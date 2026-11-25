import Foundation
import PinCore
import IBrain
import IBrainSemantics

/// Pin-owned orchestration of sealed pure interpreters. The caller keeps the
/// native source permit/ticket and revalidates across every provider await.
/// No model allocates identity, writes memory or grants an action.
public struct PinSealedSourceCompletion:Sendable {
    public let groupContext:PinVisualGroupContext?
    public let temporalPolicy:ObservationTemporalPolicy
    public let initial:AppointmentCandidate
    public let projection:MemoryProjection
    public let unresolvedFields:Set<EvidenceTextField>
    public let receipts:[DecisionReceipt]
    public var sourceValueProof:PinSelectedSourceValueProof? = nil
}

public enum PinSealedSourcePipeline {
    public static let version="pin-sealed-source-completion-v2"
    public static func request(_ memory:PhotoMemory,temporalPolicy:ObservationTemporalPolicy = .anchoredSpansV7)throws->ObservationRequest {
        guard [.anchoredSpansV7,.anchoredSpansV8,.anchoredSpansV9].contains(temporalPolicy) else{throw PinDevelopmentError.sourceNotAllowed}
        let original=try PinDevelopmentSourceReader.request(memory)
        return ObservationRequest(taskID:original.taskID,source:original.source,lines:original.lines,
            declaredVisualClues:original.declaredVisualClues,documentPolicy:.documentContentV4,temporalPolicy:temporalPolicy)
    }
    public static func initial(_ memory:PhotoMemory,temporalPolicy:ObservationTemporalPolicy = .anchoredSpansV7,initialPolicy:PinInitialSourcePolicy = .legacy,provider:any DecisionProvider,trace:PinSourceTraceSink?=nil)async throws->AppointmentCandidate {
        if let reading=memory.visualReading {guard try reading.validatedReceipt().visibleDocumentCount<=1 else{throw PinEvidenceError.invalidSupport}}
        let policy=initialPolicy.selected(for:memory)
        let request=try request(memory,temporalPolicy:temporalPolicy),task=try policy.task(request)
        trace?(.init(stage:"initial.request",memory:memory,task:task))
        do {
            let receipt=try await provider.decide(task)
            let candidate=try policy.compile(request,task:task,receipt:receipt)
            trace?(.init(stage:"initial.compiled",memory:memory,date:(candidate.appointment ?? candidate.partialAppointment)?.date,task:task));return candidate
        }catch{trace?(.init(stage:"initial.compile",outcome:"fail",memory:memory,task:task,error:error));throw error}
    }
    /// Explicit V8 preparation profile. The task and single provider invocation
    /// are unchanged; only a validated non-admitting reading may remain pending.
    public static func assessInitial(_ memory:PhotoMemory,temporalPolicy:ObservationTemporalPolicy = .anchoredSpansV8,initialPolicy:PinInitialSourcePolicy = .legacy,provider:any DecisionProvider,trace:PinSourceTraceSink?=nil)async throws->VisualSourcePreparationAssessment {
        let policy=initialPolicy.selected(for:memory)
        let request=try request(memory,temporalPolicy:temporalPolicy),task=try policy.task(request)
        trace?(.init(stage:"initial.request",memory:memory,task:task))
        do {
            let receipt=try await provider.decide(task)
            let result=try policy.assess(request,task:task,receipt:receipt)
            try result.validate(source:request.source)
            trace?(.init(stage:"initial.assessed."+result.state.rawValue,memory:memory,task:task));return result
        }catch{trace?(.init(stage:"initial.assessment",outcome:"fail",memory:memory,task:task,error:error));throw error}
    }
    public static func assessGroup(_ memory:PhotoMemory,group:PinVisualGroupContext,provider:any DecisionProvider)async throws->VisualSourcePreparationAssessment {
        let request=try group.request(memory:memory,temporalPolicy:.anchoredSpansV9),task=try VisualObservationInterpreter.task(request,detailPolicy:.componentsV4)
        let receipt=try await provider.decide(task)
        let result=try VisualSourcePreparationInterpreter.assess(request,task:task,receipt:receipt)
        try result.validate(source:request.source);_=try group.evidence(memory:memory);return result
    }
    public static func complete(_ candidate:AppointmentCandidate,memory:PhotoMemory,recordID:String,recordRevision:Int,
                                contextZone:String,temporalPolicy:ObservationTemporalPolicy = .anchoredSpansV7,groupContext:PinVisualGroupContext?=nil,printedClockNotation:Bool=false,initialPolicy:PinInitialSourcePolicy = .legacy,fieldPolicy:ObservedTextFieldsPolicy = .bounded64V1,completionCapacity:SourceCompletionCapacity = .bounded64V1,valueRecovery:SourceReadingRecoveryPolicy = .nativeCompletionsV3,combinedSourceFields:Bool=false,selectedSourceValues:Bool=false,provider:any DecisionProvider,trace:PinSourceTraceSink?=nil)async throws->PinSealedSourceCompletion {
        guard (!combinedSourceFields || (fieldPolicy == .denseSourceV2 && completionCapacity == .denseSourceV1)),(completionCapacity == .bounded64V1 || fieldPolicy == completionCapacity.fieldPolicy),!printedClockNotation || temporalPolicy == .anchoredSpansV9 else{throw PinDevelopmentError.configuration}
        var boundary="completion.source"
        func emit(_ stage:String,_ projection:MemoryProjection?=nil,_ task:ChoiceTask?=nil){trace?(.init(stage:stage,memory:memory,recordID:recordID,recordRevision:recordRevision,date:projection?.appointment.date,task:task))}
        do {
        let full=try request(memory,temporalPolicy:temporalPolicy)
        let request=try groupContext?.request(memory:memory,temporalPolicy:temporalPolicy) ?? full
        if groupContext==nil,let reading=memory.visualReading {guard try reading.validatedReceipt().visibleDocumentCount<=1 else{throw PinEvidenceError.invalidSupport}}
        let selected=try groupContext?.evidence(memory:memory)
        let source=selected?.source ?? request.source,lines=selected?.lines ?? request.lines
        let suffix=groupContext.map{"-group"+String($0.ordinal)} ?? ""
        func validate(_ p:MemoryProjection)throws{try selected?.validate(currentFullSource:full.source,projection:p)}
        let initialTask=try (groupContext==nil ? initialPolicy.selected(for:memory):.legacy).task(request)
        try candidate.receipt.validate(for:initialTask)
        guard !recordID.isEmpty,recordRevision>0,candidate.source==request.source.reference,candidate.disposition == .booking,
              let appointment=candidate.appointment ?? candidate.partialAppointment else{throw PinEvidenceError.invalidSupport}
        let native=PinCore.EvidenceSource(memory)
        let snapshot=try PinEvidenceSnapshot(memories:[memory],records:[PinRecordPin(id:recordID,revision:recordRevision,sources:[native])],scope:request.source.scope)
        var projection=MemoryProjection(recordID:recordID,recordRevision:recordRevision,scope:request.source.scope,
            appointment:appointment,support:candidate.support)
        try validate(projection)
        emit("initial.bound",projection);boundary="selected.values"
        projection=try LabelledAppointmentFieldValues.project(projection,sources:[source],policy:.explicitColonLabelsV1).projection
        try validate(projection)
        emit("selected.values",projection);boundary="selected.recovery"
        projection=try SourceReadingRecovery.assess(projection,sources:[source],policy:valueRecovery).projection

        try validate(projection)
        emit("selected.recovery",projection)
        // Completeness is a different operation from whole-source role selection.
        // Venue applies to bookings; performer applies to admission tickets.
        // Both field tasks share one base and compile atomically.
        var fields:Set<EvidenceTextField>=[.venue]
        if projection.appointment.kind == .eventTicket{fields.insert(.performer)}
        let fieldContext=ObservedTextFieldsContext(source:source,current:projection)
        let prefix="pin-source-fields-"+memory.id+"-"+String(memory.revision)+suffix
        var fieldReceipts:[String:DecisionReceipt]=[:],receipts=[candidate.receipt]
        boundary="fields.prepare"
        let fieldTasks=try combinedSourceFields ? [CombinedObservedTextFieldsInterpreter.task(id:prefix,context:fieldContext,fields:fields,policy:fieldPolicy)]:ObservedTextFieldsInterpreter.tasks(idPrefix:prefix,context:fieldContext,fields:fields,policy:fieldPolicy)
        for task in fieldTasks {
            boundary="fields.request";emit(boundary,projection,task)
            let receipt=try await provider.decide(task);try receipt.validate(for:task);emit("fields.receipt",projection,task);fieldReceipts[task.id]=receipt;receipts.append(receipt)
        }
        boundary="fields.compile"
        let completed:ObservedTextFieldsCompletion
        if combinedSourceFields {
            guard let task=fieldTasks.first,fieldTasks.count==1,let raw=fieldReceipts[task.id],fieldReceipts.count==1 else{throw PinDevelopmentError.invalidReceipt}
            completed=try CombinedObservedTextFieldsInterpreter.compile(raw,task:task,id:prefix,context:fieldContext,fields:fields,policy:fieldPolicy)
        }else{completed=try ObservedTextFieldsInterpreter.compile(fieldReceipts,idPrefix:prefix,context:fieldContext,fields:fields,policy:fieldPolicy)}
        projection=try PinSourceValueHostProjection.project(completed.projection,sources:[source]);try validate(projection);emit("fields.compiled",projection)
        // Recover ONLY missing start components, never replace known/corrected facts.
        let oldDate=projection.appointment.date
        let missingDate=oldDate.year==nil || oldDate.month==nil || oldDate.day==nil
        let missingClock=oldDate.hour==nil || oldDate.minute==nil
        if (missingDate || missingClock) && oldDate.certainty == .explicit {
            let id="pin-source-start-"+memory.id+"-"+String(memory.revision)+suffix
            boundary="printedStart.prepare"
            let task=try PrintedStartFieldInterpreter.task(id:id,source:source,lines:lines,temporalPolicy:temporalPolicy)
            boundary="printedStart.request";emit(boundary,projection,task)
            let receipt=try await provider.decide(task);try receipt.validate(for:task);receipts.append(receipt)
            boundary="printedStart.compile"
            let candidate:PrintedStartReadCandidate?
            if [.anchoredSpansV8,.anchoredSpansV9].contains(temporalPolicy) {
                candidate=try PrintedStartFieldInterpreter.assess(receipt,id:id,source:source,lines:lines,temporalPolicy:temporalPolicy).candidate
            }else{
                candidate=try PrintedStartFieldInterpreter.compile(receipt,id:id,source:source,lines:lines,temporalPolicy:temporalPolicy)
            }
            if let read=candidate {
            var supported=Set<PrintedFactRequirement>()
            if missingDate,read.date.year != nil,read.date.month != nil,read.date.day != nil{supported.insert(.localDate)}
            if missingClock,read.date.hour != nil,read.date.minute != nil{supported.insert(.startClock)}
            if !supported.isEmpty,read.date.certainty == .explicit {
                boundary="printedStart.complete"
                projection=try PrintedStartFieldInterpreter.complete(read,in:projection,source:source,requested:supported)
            }
            }
            if printedClockNotation {
                let context=TemporalRoleExplanationContext(source:source,current:projection,lines:lines,temporalTaskID:id,temporalReceipt:receipt,temporalPolicy:temporalPolicy)
                let notationID="pin-source-clock-notation-"+memory.id+"-"+String(memory.revision)+suffix
                boundary="printedClockNotation.prepare"
                if let notationTask=try PrintedClockNotationInterpreter.task(id:notationID,context:context,capacity:completionCapacity) {
                    try validate(projection);boundary="printedClockNotation.request";emit(boundary,projection,notationTask)
                    let supplemental=try await provider.decide(notationTask);try supplemental.validate(for:notationTask);receipts.append(supplemental)
                    boundary="printedClockNotation.compile"
                    projection=try PrintedClockNotationInterpreter.compile(supplemental,id:notationID,context:context,capacity:completionCapacity)
                    try validate(projection);emit("printedClockNotation.completedOrHeld",projection,notationTask)
                }
            }
        }
        try validate(projection)
        emit("printedStart.completedOrHeld",projection)
        if temporalPolicy == .anchoredSpansV9,projection.appointment.date.certainty == .explicit,
           projection.appointment.date.captureYearDerivation==nil,projection.appointment.date.temporalDerivation==nil,
           projection.support.first(where:{$0.field == .date}).map({$0.origin == .observed}) ?? true {
            let id="pin-source-date-components-"+memory.id+"-"+String(memory.revision)+suffix
            boundary="printedDate.prepare"
            if let task=try PrintedDateComponentsInterpreter.task(id:id,current:projection,source:source,lines:lines,capacity:completionCapacity) {
                boundary="printedDate.request";emit(boundary,projection,task)
                let receipt=try await provider.decide(task);try receipt.validate(for:task);receipts.append(receipt)
                boundary="printedDate.compile"
                projection=try PrintedDateComponentsInterpreter.compile(receipt,id:id,current:projection,source:source,lines:lines,capacity:completionCapacity)
                try validate(projection);emit("printedDate.completedOrHeld",projection)
            }
        }
        if temporalPolicy == .anchoredSpansV9,projection.appointment.date.year==nil,
           projection.appointment.date.month != nil,projection.appointment.date.day != nil,
           projection.appointment.date.printedDateText != nil,projection.support.first(where:{$0.field == .date})?.origin == .observed {
            let id="pin-source-year-supplement-"+memory.id+"-"+String(memory.revision)+suffix
            boundary="printedYear.prepare"
            let task=try PrintedDateSupplementInterpreter.task(id:id,current:projection,source:source,capacity:completionCapacity)
            if (task.questions["year"]?.criteria.count ?? 0)>1 {
                boundary="printedYear.request";emit(boundary,projection,task)
                let receipt=try await provider.decide(task);try receipt.validate(for:task);receipts.append(receipt)
                boundary="printedYear.compile"
                projection=try PrintedDateSupplementInterpreter.compile(receipt,id:id,current:projection,source:source,capacity:completionCapacity)
                try validate(projection);emit("printedYear.completedOrHeld",projection)
            }
        }
        // A missing year needs a semantic year-presence decision. Original
        // capture context supplies a labelled estimate, never a printed fact,
        // event timezone, import date, GPS venue or personal calendar claim.
        let temporalClaim=try JSONDecoder().decode(AppointmentDateComponents.self,from:JSONEncoder().encode(projection.appointment.date))
        if projection.appointment.date.year==nil && (![.anchoredSpansV8,.anchoredSpansV9].contains(temporalPolicy) || temporalClaim.hasTemporalClaim) {
            let id="pin-source-temporal-"+memory.id+"-"+String(memory.revision)+suffix
            boundary="temporalMeaning.prepare"
            let task=try TemporalMeaningInterpreter.task(id:id,source:source,capacity:completionCapacity)
            boundary="temporalMeaning.request";emit(boundary,projection,task)
            let receipt=try await provider.decide(task);try receipt.validate(for:task);receipts.append(receipt)
            boundary="temporalMeaning.compile"
            let meaning=try TemporalMeaningInterpreter.compile(receipt,id:id,source:source,capacity:completionCapacity)
            let context=memory.photographedAt.map{OriginalCaptureContext(source:source.reference,capturedAt:$0,
                origin:memory.isScreenshot==true ? .originalScreenshot:.originalPhoto,timeZoneID:contextZone,relativeDayContemporaneous:false)}
            boundary="temporalResolution"
            projection=try TemporalResolution.resolve(projection,sources:[source],meaning:meaning.meaning,context:context,
                printedWeekday:meaning.printedWeekday,printedYearEvidence:meaning.printedYearEvidence,policy:.captureContextV1).projection
        }
        try validate(projection)
        emit("temporal.resolvedOrHeld",projection);boundary="DTO.decode"
        // This is still the complete native date DTO. Unsupported raw text is
        // retained; a truly undated document does not become an empty schedule.
        let e=JSONEncoder(),date=try JSONDecoder().decode(AppointmentDateComponents.self,from:e.encode(projection.appointment.date))
        projection=MemoryProjection(recordID:recordID,recordRevision:recordRevision,scope:projection.scope,
            appointment:projection.appointment,support:projection.support,documentOnlyWithoutDate:!date.hasTemporalClaim)
        emit("DTO.decoded",projection);boundary="evidence.bind"
        try validate(projection)
        _=try snapshot.bindEvidence(for:projection);emit("evidence.bound",projection)
        var valueProof:PinSelectedSourceValueProof?
        if selectedSourceValues {
            let context=SelectedSourceFieldValuesContext(source:source,projection:projection,bookingReference:candidate.bookingReferenceEvidence)
            let id="pin-selected-source-values-"+memory.id+"-"+String(memory.revision)+suffix
            boundary="selectedSourceValues.prepare"
            let task=try SelectedSourceFieldValuesInterpreter.task(id:id,context:context)
            var receipt:DecisionReceipt?
            if let task {
                boundary="selectedSourceValues.request";emit(boundary,projection,task)
                receipt=try await provider.decide(task);try receipt!.validate(for:task);receipts.append(receipt!)
            }
            boundary="selectedSourceValues.compile"
            let result=try SelectedSourceFieldValuesInterpreter.compile(receipt,id:id,context:context)
            guard result.unresolvedFields.isEmpty else{throw PinEvidenceError.invalidSupport}
            valueProof=try PinSelectedSourceValueProof(taskID:id,context:context,receipt:receipt,result:result)
            projection=result.projection;try validate(projection);_=try snapshot.bindEvidence(for:projection)
            emit("selectedSourceValues.bound",projection,task)
        }
        var result=PinSealedSourceCompletion(groupContext:groupContext,temporalPolicy:temporalPolicy,initial:candidate,projection:projection,unresolvedFields:completed.unresolvedFields,receipts:receipts)
        result.sourceValueProof=valueProof;return result
        }catch{trace?(.init(stage:boundary,outcome:"fail",memory:memory,recordID:recordID,recordRevision:recordRevision,error:error));throw error}
    }
    public static func draft(_ completed:PinSealedSourceCompletion,ticket:CanonicalWriteTicket,memory:PhotoMemory)throws->CanonicalAppointmentDraft {
        let p=completed.projection,request=try request(memory,temporalPolicy:completed.temporalPolicy)
        guard p.recordID==ticket.id,p.recordRevision==ticket.nextRevision,p.sources==[request.source.reference]else{throw PinEvidenceError.staleRecord}
        try completed.groupContext?.validate(memory:memory,projection:p)
        if completed.groupContext==nil,let reading=memory.visualReading {guard try reading.validatedReceipt().visibleDocumentCount<=1 else{throw PinEvidenceError.invalidSupport}}
        let snapshot=try PinEvidenceSnapshot(memories:[memory],records:[PinRecordPin(id:ticket.id,revision:ticket.nextRevision,sources:[PinCore.EvidenceSource(memory)])],scope:p.scope)
        let draft=try PinCanonicalMapping.draft(snapshot.bindEvidence(for:p),primarySourceID:memory.id)
        return try preservingSourceValues(in:preservingBookingReference(in:draft,completed:completed,memory:memory),completed:completed)
    }
    static func preservingSourceValues(in draft:CanonicalAppointmentDraft,completed:PinSealedSourceCompletion)throws->CanonicalAppointmentDraft {
        guard let proof=completed.sourceValueProof else{return draft}
        try proof.validate();guard proof.result.projection==completed.projection else{throw PinEvidenceError.invalidSupport}
        var observation=draft.observation;observation.sourceValueProof=try proof.encoded()
        return CanonicalAppointmentDraft(recordID:draft.recordID,recordRevision:draft.recordRevision,observation:observation,sources:draft.sources,support:draft.support,documentOnlyWithoutDate:draft.documentOnlyWithoutDate,bookingLinkEvidence:draft.bookingLinkEvidence)
    }
    /// The SDK keeps the selected booking reference on its initial candidate,
    /// outside AppointmentProjection. Preserve that exact observed quote in
    /// Pin's existing optional field; never parse a reference from source text.
    static func preservingBookingReference(in draft:CanonicalAppointmentDraft,completed:PinSealedSourceCompletion,memory:PhotoMemory)throws->CanonicalAppointmentDraft {
        guard let reference=completed.initial.bookingReferenceEvidence else{return draft}
        let request=try completed.groupContext?.request(memory:memory,temporalPolicy:completed.temporalPolicy) ?? request(memory,temporalPolicy:completed.temporalPolicy)
        guard completed.initial.source==request.source.reference,reference.source==request.source.reference,
              draft.sources==[AppointmentSource(memory)] else{throw PinEvidenceError.invalidSupport}
        let policies:[PinInitialSourcePolicy]=completed.groupContext==nil ? [.compactKeysV1.selected(for:memory),.compactCurrentVisualV1.selected(for:memory),.legacy]:[.legacy]
        guard let policy=try policies.first(where:{try $0.task(request).digest()==completed.initial.receipt.requestSHA256})else{throw PinEvidenceError.invalidSupport}
        let task=try policy.task(request)
        let verified=try policy.compile(request,task:task,receipt:completed.initial.receipt)
        guard verified.bookingReferenceEvidence==reference,
              let pair=try (memory.textEvidence ?? []).enumerated().first(where:{try PinOCRObservationID.make($0.element,offset:$0.offset)==reference.observationID}),
              pair.element.text==reference.quote else{throw PinEvidenceError.invalidSupport}
        var observation=draft.observation
        var value=reference.quote
        var version="pin-source-booking-reference/1/"+task.version+"/"+completed.initial.receipt.requestSHA256
        if let proof=completed.sourceValueProof {
            try proof.validate()
            guard proof.context.bookingReference==reference,proof.context.source==request.source,proof.result.projection==completed.projection,
                  proof.result.unresolvedFields.isEmpty,let selection=proof.result.bookingReference,selection.originalAnchor==reference else{throw PinEvidenceError.invalidSupport}
            value=selection.valueQuote;version="pin-source-booking-reference/2/"+task.version+"/"+completed.initial.receipt.requestSHA256
            observation.sourceValueProof=try proof.encoded()
        }
        guard observation.bookingReference==nil || observation.bookingReference==value else{throw PinEvidenceError.invalidSupport}
        observation.bookingReference=value
        observation.fieldFacts=(observation.fieldFacts ?? [])+[FieldFact(field:"bookingReference",value:value,origin:.observed,source:EvidenceSource(memory),support:[pair.element],extractorVersion:version)]
        observation.evidence=(observation.fieldFacts ?? []).flatMap(\.support)
        struct ReferenceSupport:Encodable {
            let field="bookingReference",origin="observed"
            let anchors:[EvidenceAnchor],confidence:Double,extractorVersion:String
        }
        let support=try JSONDecoder().decode(AppointmentSemanticField.self,from:JSONEncoder().encode(ReferenceSupport(anchors:[reference],confidence:Double(pair.element.confidence),extractorVersion:version)))
        return CanonicalAppointmentDraft(recordID:draft.recordID,recordRevision:draft.recordRevision,observation:observation,sources:draft.sources,support:draft.support+[support],documentOnlyWithoutDate:draft.documentOnlyWithoutDate,bookingLinkEvidence:draft.bookingLinkEvidence)
    }
    /// Independent source replay callers compare this to the proof they just
    /// reconstructed; a retained context is never substituted for replay.
    public static func validateRetainedSourceValues(_ record:AppointmentItem,completed:PinSealedSourceCompletion)throws {
        guard record.observation.sourceValueProof==(try completed.sourceValueProof?.encoded()) else{throw PinEvidenceError.invalidSupport}
        _=try PinSelectedSourceValueProof.retained(record)
    }
    /// Verify the optional native-only retrieval field against the same
    /// completed source receipts before a host admits its derived projection.
    /// Older canonical records without the field remain readable unchanged.
    public static func validateRetainedBookingReference(_ record:AppointmentItem,completed:PinSealedSourceCompletion,memory:PhotoMemory)throws {
        let support=record.semanticSupport?.filter{$0.field=="bookingReference"} ?? []
        let facts=record.observation.fieldFacts?.filter{$0.field=="bookingReference"} ?? []
        if record.observation.bookingReference==nil {
            guard support.isEmpty,facts.isEmpty,completed.sourceValueProof?.result.bookingReference==nil else{throw PinEvidenceError.invalidSupport};return
        }
        let p=completed.projection
        guard record.canonicalRecordID==p.recordID,record.canonicalRevision==p.recordRevision,record.allSources==[AppointmentSource(memory)] else{throw PinEvidenceError.invalidSupport}
        let snapshot=try PinEvidenceSnapshot(memories:[memory],records:[PinRecordPin(id:p.recordID,revision:p.recordRevision,sources:[PinCore.EvidenceSource(memory)])],scope:p.scope)
        let expected=try preservingBookingReference(in:PinCanonicalMapping.draft(snapshot.bindEvidence(for:p),primarySourceID:memory.id),completed:completed,memory:memory)
        guard record.observation.bookingReference==expected.observation.bookingReference,
              support==expected.support.filter({$0.field=="bookingReference"}),
              facts==expected.observation.fieldFacts?.filter({$0.field=="bookingReference"}),
              record.observation.sourceValueProof==(try completed.sourceValueProof?.encoded()) else{throw PinEvidenceError.invalidSupport}
    }
    /// Identity is established by the separate exact bundle receipt. Current
    /// facts retain the complete single-source field proofs. If the bundle's
    /// current values disagree, hold; do not prefer whichever yields an answer.
    public static func replacementEvidence(_ completed:PinSealedSourceCompletion,linked:AppointmentBundleCandidate,
        memories:[PhotoMemory],recordID:String,recordRevision:Int,rolePolicy:BundleComponentRolePolicy = .separatedRolesV6)throws->AppointmentBookingLinkEvidence {
        let request=try PinDevelopmentSourceReader.bundleRequest(memories)
        let task=try ComponentEvidenceBundleInterpreter.task(for:request,rolePolicy:rolePolicy)
        try linked.receipt.validate(for:task)
        guard completed.projection.recordID==recordID,completed.projection.recordRevision==recordRevision,
              linked.relation == .sameBooking,linked.unresolved.isEmpty,let current=linked.appointment,
              Set(linked.contributors)==Set(request.documents.map{$0.source.reference})else{throw PinEvidenceError.invalidSupport}
        let scope=completed.projection.scope,sources=Set(linked.factSources.map{PinCore.EvidenceSource(id:$0.id,fingerprint:$0.fingerprint,revision:$0.revision)})
        let snapshot=try PinEvidenceSnapshot(memories:memories,records:[PinRecordPin(id:recordID,revision:recordRevision,sources:sources)],scope:scope)
        let projection=MemoryProjection(recordID:recordID,recordRevision:recordRevision,scope:scope,appointment:current,support:linked.support)
        let values=try PinSourceValueHostProjection.project(projection,sources:snapshot.authority.sources)
        guard values.appointment==completed.projection.appointment else{throw PinEvidenceError.invalidSupport}
        let identities=try JSONDecoder().decode([AppointmentBookingIdentityEvidence].self,from:JSONEncoder().encode(linked.identityEvidence))
        return AppointmentBookingLinkEvidence(identities:identities,taskSHA256:try task.digest())
    }
    public static func replacementDraft(_ completed:PinSealedSourceCompletion,linked:AppointmentBundleCandidate,
        ticket:CanonicalWriteTicket,memories:[PhotoMemory],primarySourceID:String,rolePolicy:BundleComponentRolePolicy = .separatedRolesV6)throws->CanonicalAppointmentDraft {
        guard let incoming=memories.first(where:{$0.id==primarySourceID})else{throw PinEvidenceError.invalidSupport}
        let link=try replacementEvidence(completed,linked:linked,memories:memories,recordID:ticket.id,recordRevision:ticket.nextRevision,rolePolicy:rolePolicy)
        let single=try draft(completed,ticket:ticket,memory:incoming)
        return CanonicalAppointmentDraft(recordID:single.recordID,recordRevision:single.recordRevision,observation:single.observation,
            sources:single.sources,support:single.support,documentOnlyWithoutDate:single.documentOnlyWithoutDate,bookingLinkEvidence:link)
    }
    public static func rejection(_ candidate:AppointmentCandidate,memory:PhotoMemory,temporalPolicy:ObservationTemporalPolicy = .anchoredSpansV7,initialPolicy:PinInitialSourcePolicy = .legacy)throws->AppointmentSourceRejection {
        let policy=initialPolicy.selected(for:memory)
        let request=try request(memory,temporalPolicy:temporalPolicy),task=try policy.task(request)
        try candidate.receipt.validate(for:task)
        guard candidate.source==request.source.reference,candidate.disposition == .notBooking,
              try policy.compile(request,task:task,receipt:candidate.receipt).disposition == .notBooking else{throw PinEvidenceError.invalidSupport}
        return AppointmentSourceRejection(source:AppointmentSource(memory),observationIDs:request.lines.map(\.id),taskSHA256:try task.digest())
    }
}
