import Foundation
import PinCore
import IBrain

/// A genuine SDK prior-revision capture and the native row current at capture.
/// Session-bound/non-Codable, with no public initializer and no writer authority.
public struct PinCapturedAppointmentRevision:Sendable {
    public var recordID:String{native.canonicalRecordID!}
    let session:UUID
    let native:AppointmentItem
    let sdk:CapturedRecordRevision
    func matchesPrevious(of current:AppointmentItem)->Bool {
        guard current.canonicalRecordID==native.canonicalRecordID,let revision=current.canonicalRevision,let old=native.canonicalRevision,revision==old+1,let previous=current.previousEvidence else{return false}
        return previous.revision==old && previous.source==native.source && previous.additionalSources==native.additionalSources && previous.observation==native.observation && previous.semanticSupport==native.semanticSupport
    }
    public static func previousRow(of current:AppointmentItem)->AppointmentItem? {
        guard let history=current.previousEvidence,let id=current.canonicalRecordID,let revision=current.canonicalRevision,history.revision<revision else{return nil}
        var row=AppointmentItem(source:history.source,observation:history.observation)
        row.canonicalRecordID=id;row.canonicalRevision=history.revision;row.additionalSources=history.additionalSources;row.semanticSupport=history.semanticSupport
        return row
    }
}
