import Foundation

public struct MuseumPlace: Equatable, Sendable, Identifiable {
    public var id:String
    public var name:String
    public var aliases:[String]
    public var address:String
    public var reference:String
}
/// Bounded, offline directory snapshot. It resolves a printed name; it cannot
/// recognize an arbitrary artwork, locate a person, or establish attendance.
public enum MuseumDirectory {
    public static let version="pin-japan-museums-20261025-v1"
    public static let lookedUpAt="2026-10-25"
    public static let places:[MuseumPlace]=[
        MuseumPlace(id:"tnm",name:"Tokyo National Museum",aliases:["東京国立博物館","Tokyo National Museum"],address:"13-9 Ueno Park, Taito-ku, Tokyo 110-8712, Japan",reference:"https://www.tnm.jp/modules/r_free_page/index.php?id=113-0"),
        MuseumPlace(id:"nact",name:"The National Art Center, Tokyo",aliases:["国立新美術館","The National Art Center, Tokyo","National Art Center Tokyo"],address:"7-22-2 Roppongi, Minato-ku, Tokyo 106-8558, Japan",reference:"https://www.nact.jp/english/information/"),
        MuseumPlace(id:"tobikan",name:"Tokyo Metropolitan Art Museum",aliases:["東京都美術館","Tokyo Metropolitan Art Museum"],address:"8-36 Ueno Park, Taito-ku, Tokyo 110-0007, Japan",reference:"https://www.tobikan.jp/guide/")
    ]
}
public struct MuseumObservation: Equatable, Sendable, Identifiable {
    public var id:String { source.id }
    public var source:EvidenceSource
    public var place:MuseumPlace?
    public var candidates:[MuseumPlace]
    public var facts:[FieldFact]
    public var uncertainty:String
}
public enum MuseumPhotoReader {
    public static let version="museum-native-v3"
    private static func normalized(_ value:String)->String {
        value.folding(options:[.caseInsensitive,.widthInsensitive,.diacriticInsensitive],locale:Locale(identifier:"en_US_POSIX")).filter { $0.isLetter || $0.isNumber }
    }
    /// A wrapped sign can name one place across adjacent OCR rows. Require
    /// an exact alias, geometry, comparable type size and overlapping columns;
    /// never concatenate the whole page or use a filename/location as support.
    private static func nameSupports(_ place:MuseumPlace,lines:[CardLine])->[[CardLine]] {
        let aliases=place.aliases.map(normalized)
        var matches=lines.filter { $0.confidence >= 0.5 && aliases.contains(where:normalized($0.text).contains) }.map { [$0] }
        let ordered=lines.sorted { ($0.region?.y ?? -1) > ($1.region?.y ?? -1) }
        for start in ordered.indices {
            var run:[CardLine]=[]
            for line in ordered[start..<min(start+5,ordered.count)] {
                guard line.confidence >= 0.5,let region=line.region else { break }
                if let previous=run.last?.region {
                    let overlap=min(previous.x+previous.width,region.x+region.width)-max(previous.x,region.x)
                    let gap=previous.y-(region.y+region.height)
                    let small=min(previous.height,region.height),large=max(previous.height,region.height)
                    guard region.y < previous.y,large <= small*2,
                          overlap >= min(previous.width,region.width)*0.6,
                          gap >= -small*0.15,gap <= large*1.5 else { break }
                }
                run.append(line)
                if run.count > 1 && aliases.contains(normalized(run.map(\.text).joined(separator:" "))) { matches.append(run) }
            }
        }
        return matches
    }
    public static func isCandidate(_ memory:PhotoMemory)->Bool {
        let text=memory.text.joined(separator:" ").lowercased()
        return text.contains("museum") || text.contains("博物館") || text.contains("美術館") || text.contains("art center") || text.contains("admission ticket") || text.contains("artist") || memory.labels.contains { $0.confidence >= 0.5 && ["artwork","painting","sculpture","statue"].contains($0.name.lowercased()) }
    }
    public static func read(_ memory:PhotoMemory)->MuseumObservation? {
        guard !AppointmentCardReader.isPinInterface(memory.text),isCandidate(memory) else { return nil }
        let source=EvidenceSource(memory)
        // Older OCR stored only lines admitted at >= .5. Preserve that lower
        // bound rather than inventing precise confidence or an image region.
        let lines=memory.textEvidence ?? memory.text.map { CardLine($0,confidence:0.5) }
        let candidates=MuseumDirectory.places.filter { !nameSupports($0,lines:lines).isEmpty }
        let corpus=memory.text.joined(separator:" ").lowercased()
        let map=corpus.range(of:"\\bmap\\b|nearby|directions|area guide|walk to|towards|周辺|案内図|アクセスマップ|→|←|[0-9]+\\s*(?:m\\b|km\\b|メートル|キロ)",options:.regularExpression) != nil
        let credit=corpus.range(of:"courtesy of|collection of|on loan|loan from|copyright|reproduction|複製|所蔵|博物館蔵|美術館蔵|貸出|提供",options:.regularExpression) != nil
        let place=candidates.count == 1 && !map && !credit ? candidates[0] : nil
        var facts:[FieldFact]=[]
        if let place {
            let supports=nameSupports(place,lines:lines)
            let support=supports.flatMap { $0 }.reduce(into:[CardLine]()) { if !$0.contains($1) { $0.append($1) } }
            for group in supports { facts.append(FieldFact(field:"printedMuseumName",value:group.map(\.text).joined(separator:"\n"),origin:.observed,source:source,support:group,extractorVersion:version)) }
            facts.append(FieldFact(field:"museumName",value:place.name,origin:.external,source:source,support:support,extractorVersion:version,reference:place.reference,referenceVersion:MuseumDirectory.version,lookedUpAt:MuseumDirectory.lookedUpAt))
            facts.append(FieldFact(field:"museumAddress",value:place.address,origin:.external,source:source,support:support,extractorVersion:version,reference:place.reference,referenceVersion:MuseumDirectory.version,lookedUpAt:MuseumDirectory.lookedUpAt))
        }
        let uncertainty=place != nil ? "A museum name in a photo does not confirm a visit." : candidates.count > 1 ? "This photo names multiple museums; I can’t choose one." : map ? "A map or directions can mention a place without showing a visit." : credit ? "An artwork credit can name a lender or collection without establishing the venue." : "I couldn’t identify the museum from the available details."
        return MuseumObservation(source:source,place:place,candidates:candidates,facts:facts,uncertainty:uncertainty)
    }
}
public enum MuseumQuestion {
    public static func matches(_ text:String)->Bool {
        let value=text.lowercased().trimmingCharacters(in:.whitespacesAndNewlines)
        if value.contains("博物館") || value.contains("美術館") { return true }
        let words=value.components(separatedBy:CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        let question=words.joined(separator:" ")
        let museum=words.contains("museum") || words.contains("museums") || question.contains("art center")
        guard museum else { return false }
        if words.contains("japan") || words.contains("tokyo") { return true }
        return ["museum","museums","my museums","which museums did i visit","what museums did i visit","show my museums"].contains(question)
    }
}


public struct MuseumVisitGroup: Equatable, Sendable, Identifiable {
    public var id:String
    public var place:MuseumPlace
    public var sources:[EvidenceSource]
    /// A photo-day inference, never a confirmed attendance or ticket validity date.
    public var photoDay:Date?
    public var uncertainty:String
}
public enum MuseumVisitGrouper {
    private static func uncertainty(for sources:[EvidenceSource],day:Date?,current:[String:PhotoMemory])->String {
        guard day != nil else { return "Visit date unknown. A saved image or its creation date does not establish attendance." }
        if sources.contains(where: { current[$0.id]?.coordinate == nil }) {
            return "Location is missing for at least one photo. This may be a saved image; a museum visit is not confirmed."
        }
        return "The photos share a date and museum name. Their recorded locations do not prove a visit; attendance is not confirmed."
    }
    private static func distance(_ a:PhotoCoordinate,_ b:PhotoCoordinate)->Double {
        let rad=Double.pi/180
        let dLat=(b.latitude-a.latitude)*rad,dLon=(b.longitude-a.longitude)*rad
        let q=pow(sin(dLat/2),2)+cos(a.latitude*rad)*cos(b.latitude*rad)*pow(sin(dLon/2),2)
        return 6_371_000*2*atan2(sqrt(max(0,min(1,q))),sqrt(max(0,1-min(1,q))))
    }
    private static func inJapan(_ coordinate:PhotoCoordinate)->Bool {
        coordinate.latitude.isFinite && coordinate.longitude.isFinite && (24...46).contains(coordinate.latitude) && (122...154).contains(coordinate.longitude)
    }
    public static func groups(_ memories:[PhotoMemory])->[MuseumVisitGroup] {
        let current=Dictionary(uniqueKeysWithValues:memories.map { ($0.id,$0) })
        let resolved=memories.compactMap { memory -> (PhotoMemory,MuseumPlace)? in
            guard let observation=MuseumPhotoReader.read(memory),let place=observation.place,observation.source.matches(memory) else { return nil }
            return (memory,place)
        }.sorted { a,b in
            let ad=a.0.photographedAt ?? .distantFuture,bd=b.0.photographedAt ?? .distantFuture
            return ad == bd ? a.0.id < b.0.id : ad < bd
        }
        var calendar=Calendar(identifier:.gregorian);calendar.timeZone=TimeZone(identifier:"Asia/Tokyo")!
        var groups:[MuseumVisitGroup]=[]
        for (memory,place) in resolved {
            // Existing records without media-kind metadata are deliberately
            // unknown. A screenshot of a ticket is not a visit timestamp.
            let canDate=memory.isScreenshot == false && memory.photographedAt != nil && (memory.coordinate.map(inJapan) ?? true)
            let date=canDate ? memory.photographedAt : nil
            let day=date.map { calendar.startOfDay(for:$0) }
            let matching=groups.indices.last { index in
                let group=groups[index]
                guard let day,group.photoDay == day,group.place.id == place.id,
                      let first=group.sources.first.flatMap({ current[$0.id] }),let start=first.photographedAt,let date,
                      date.timeIntervalSince(start) <= 4*3600 else { return false }
                // No chaining across a distant observation. Coordinates only
                // veto a group; they never assign an unnamed photo to a venue.
                return group.sources.allSatisfy { source in
                    guard let a=current[source.id]?.coordinate,let b=memory.coordinate else { return true }
                    return distance(a,b) <= 500
                }
            }
            if let index=matching {
                groups[index].sources.append(EvidenceSource(memory))
                groups[index].uncertainty=uncertainty(for:groups[index].sources,day:day,current:current)
            }
            else {
                let sources=[EvidenceSource(memory)]
                groups.append(MuseumVisitGroup(id:place.id+"|"+memory.id+"|"+memory.fingerprint+"|"+String(memory.revision),place:place,sources:sources,photoDay:day,uncertainty:uncertainty(for:sources,day:day,current:current)))
            }
        }
        return groups.sorted { a,b in
            let ad=a.photoDay ?? .distantPast,bd=b.photoDay ?? .distantPast
            return ad == bd ? a.id < b.id : ad > bd
        }
    }
    /// Recompute from the current authoritative projection. Stale memberships
    /// and dependent facts never survive a revision/forget/access change.
    public static func validated(_ group:MuseumVisitGroup,in current:[PhotoMemory])->MuseumVisitGroup? {
        groups(current).first { $0.id == group.id && $0 == group }
    }
}
