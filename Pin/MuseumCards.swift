import PinCore
import SwiftUI

struct MuseumCards:View {
    let memories:[PhotoMemory]
    let open:(PhotoMemory)->Void
    let forget:(PhotoMemory)->Void
    private var observations:[MuseumObservation] { memories.compactMap(MuseumPhotoReader.read) }
    private var groups:[MuseumVisitGroup] { MuseumVisitGrouper.groups(memories) }
    private var unresolved:[MuseumObservation] { observations.filter { $0.place == nil } }
    private func photoDay(_ date:Date)->String {
        let format=DateFormatter();format.dateFormat="MMM d, yyyy";format.timeZone=TimeZone(identifier:"Asia/Tokyo");return format.string(from:date)
    }
    var body:some View {
        // Expanding a source row changes the height of a card above the visible
        // anchor. An eager stack avoids the lazy placement feedback loop seen
        // when opening lower museum cards inside the shared ScrollView.
        // Source thumbnails still mount only when their disclosure is expanded.
        VStack(alignment:.leading,spacing:18) {
            Text("Museums in your photos").font(.title2.weight(.semibold))
            if groups.isEmpty {
                Text("I couldn’t identify a museum from the available details.").font(.headline)
            }
            ForEach(groups) { group in
                VStack(alignment:.leading,spacing:12) {
                    Text(group.place.name).font(.title3.weight(.semibold))
                    Text(group.place.address).font(.subheadline)
                    Text("Address from the museum’s website").font(.caption).foregroundStyle(Color.pinMuted)
                    if let date=group.photoDay { Text("Date recorded by Photos · \(photoDay(date)) (Japan time)").font(.headline) }
                    else { Text("Visit date unknown").font(.headline) }
                    Text(group.uncertainty).font(.subheadline).foregroundStyle(Color.pinMuted)
                    DisclosureGroup("\(group.sources.count) source photo\(group.sources.count == 1 ? "" : "s")") {
                        VStack(alignment:.leading,spacing:14) {
                            ForEach(group.sources,id:\.id) { source in
                                if let memory=memories.first(where:source.matches) { sourceRow(memory) }
                            }
                        }.padding(.top,10)
                    }.tint(Color.pinRose)
                    DisclosureGroup("Why this place?") {
                        VStack(alignment:.leading,spacing:7) {
                            ForEach(group.sources,id:\.id) { source in
                                if let evidence=observations.first(where: { $0.source == source }) {
                                    ForEach(Array(evidence.facts.filter { $0.origin == .observed }.enumerated()),id:\.offset) { _,fact in
                                        Text("“\(fact.value)”").font(.subheadline)
                                    }
                                }
                            }
                            if let url=URL(string:group.place.reference) { Link("Museum website",destination:url).font(.subheadline) }
                            Text("Name and address checked \(MuseumDirectory.lookedUpAt). A printed name can also appear on a ticket, advertisement or saved image.").font(.caption).foregroundStyle(Color.pinMuted)
                        }.frame(maxWidth:.infinity,alignment:.leading).padding(.top,8)
                    }.tint(Color.pinRose)
                }.padding(18).frame(maxWidth:.infinity,alignment:.leading)
                    .background(.white.opacity(0.85),in:RoundedRectangle(cornerRadius:24))
            }
            if !unresolved.isEmpty {
                DisclosureGroup("\(unresolved.count) photo\(unresolved.count == 1 ? " needs" : "s need") more evidence") {
                    VStack(alignment:.leading,spacing:18) {
                        ForEach(unresolved) { observation in
                            if let memory=memories.first(where:observation.source.matches) {
                                VStack(alignment:.leading,spacing:8) {
                                    Text(observation.uncertainty).font(.subheadline)
                                    if !observation.candidates.isEmpty { Text("Names seen: " + observation.candidates.map(\.name).joined(separator:", ")).font(.caption).foregroundStyle(Color.pinMuted) }
                                    sourceRow(memory)
                                }
                            }
                        }
                    }.padding(.top,10)
                }.tint(Color.pinRose)
            }
            Text("Pin currently resolves names for three Tokyo museums. Other places and artwork may remain unidentified. A nearby location or a photo date alone doesn’t prove a visit.")
                .font(.caption).foregroundStyle(Color.pinMuted)
        }
    }
    private func sourceRow(_ memory:PhotoMemory)->some View {
        VStack(alignment:.leading,spacing:8) {
            Button { open(memory) } label: {
                HStack(spacing:12) {
                    LibraryPhoto(id:memory.id,pixelSize:240).frame(width:78,height:64).clipped().clipShape(RoundedRectangle(cornerRadius:10))
                    Text("Original photo").font(.subheadline.weight(.medium));Spacer();Image(systemName:"arrow.up.right")
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityIdentifier("museumOriginal")
            Button("Forget this photo in Pin") { forget(memory) }.font(.caption).foregroundStyle(Color.pinMuted).accessibilityIdentifier("museumForget")
        }.frame(maxWidth:.infinity,alignment:.leading)
    }
}
