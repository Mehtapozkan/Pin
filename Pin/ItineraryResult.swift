import SwiftUI
import PinCore

struct ItineraryResult: View {
    let answer: RailItinerary
    let open: (PhotoMemory) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Rail booking " + answer.booking).font(.largeTitle.bold()).accessibilityIdentifier("itineraryHeading")
            if let summary = answer.summary { Text(summary) }
            ForEach(answer.rows) { row in
                VStack(alignment: .leading, spacing: 8) {
                    if let photo = row.photo {
                        Button { open(photo) } label: {
                            HStack { Label(row.kind.label, systemImage: "photo.on.rectangle"); Spacer(); Image(systemName: "arrow.up.right").font(.footnote) }.font(.headline).foregroundStyle(Color.pinRose)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }.accessibilityIdentifier("itinerary-" + row.kind.rawValue)
                    } else { Text(row.kind.label).font(.headline) }
                    Text(row.detail)
                }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                    .pinAnswerSurface()
            }
        }
    }
}
