import SwiftUI
import PinCore

struct SavedScreenshotCorrectionTarget:Identifiable {
    var id:String {source.id}
    let source:EvidenceSource
    let title:String
    let expected:SavedPhotoInterpretation?
}

/// Presentation values are supplied only after the native owner admits an answer.
/// The view neither interprets queries nor manufactures evidence permissions.
struct SavedScreenshotCard: Identifiable {
    struct Fact: Identifiable {
        let id: String
        let text: String
        let origin: String
    }
    let id: String
    let title: String
    let facts: [Fact]
    let uncertain: Bool

    // A literal excerpt gives unnamed cards a readable heading. It only joins
    // already-admitted adjacent facts; it does not infer a title or add claims.
    var displayTitle: String {
        guard title == "Saved photo", let first = facts.first,
              first.origin == "From this photo" else { return title }
        // An admitted section label can start a different proposal within the photo.
        // Keep that label with its sentence, and keep the full excerpt in the body.
        let sectionLabels = facts.indices.dropLast().filter { index in
            let fact = facts[index]
            let line = fact.text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return fact.origin == first.origin && line.hasSuffix(":") &&
                (line.hasPrefix("for ") || line.hasPrefix("about "))
        }
        let start = sectionLabels.count == 1 ? sectionLabels[0] : facts.startIndex
        var excerpt = ""
        for fact in facts[start...] {
            guard fact.origin == first.origin else { return title }
            let next = excerpt.isEmpty ? fact.text : excerpt + " " + fact.text
            guard next.count <= 220 else { return title }
            excerpt = next
            if let last = excerpt.last, ".!?".contains(last) { return excerpt }
        }
        return title
    }

    var heading: String {
        let fullHeading = displayTitle
        guard let first = facts.first, first.origin == "From this photo",
              let lastCharacter = first.text.last, !".!?:;".contains(lastCharacter),
              first.text.count <= 54, !first.text.contains("\n"),
              fullHeading.hasPrefix(first.text + " ") else { return fullHeading }
        return first.text
    }

    struct Paragraph:Identifiable {
        let id:String
        var text:String
        let origin:String
    }
    var paragraphs:[Paragraph] {
        var paragraphs: [Paragraph] = facts.reduce(into: []) { result, fact in
            if let last=result.last, last.origin == fact.origin {
                result[result.count-1].text += " " + fact.text
            } else { result.append(Paragraph(id:fact.id,text:fact.text,origin:fact.origin)) }
        }
        let heading = self.heading
        if let lead = paragraphs.first, lead.origin == "From this photo",
           lead.text == heading || lead.text.hasPrefix(heading + " ") {
            paragraphs[0].text = String(lead.text.dropFirst(heading.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return paragraphs
    }
}

struct SavedScreenshotResult<Thumbnail: View>: View {
    let cards: [SavedScreenshotCard]
    let coverage: String
    let thumbnail: (String) -> Thumbnail
    let open: (String) -> Void
    let correct: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 9) {
                Text("From your saved photos")
                    .font(.largeTitle.weight(.semibold)).tracking(-0.8)
                    .accessibilityAddTraits(.isHeader).accessibilityIdentifier("savedContentHeading")
                Text(coverage).font(.footnote).foregroundStyle(Color.pinMuted)
                    .accessibilityIdentifier("savedContentCoverage")
            }
            if cards.isEmpty {
                Text("No matching saved content was established in the photos checked.")
                    .font(.title3).accessibilityIdentifier("savedContentEmpty")
            }
            ForEach(cards) { card in
                VStack(alignment: .leading, spacing: 14) {
                    if card.uncertain {
                        Text("Possible match").font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.pinMuted)
                    }
                    Text(card.heading).font(.title2.weight(.semibold)).tracking(-0.25)
                        .accessibilityAddTraits(.isHeader)
                    ForEach(card.paragraphs) { fact in
                        VStack(alignment: .leading, spacing: 6) {
                            if !fact.text.isEmpty { Text(fact.text).font(.body).lineSpacing(3) }
                            Text(fact.origin).font(.caption).foregroundStyle(Color.pinMuted)
                        }
                    }
                    Button { open(card.id) } label: {
                        HStack(spacing: 12) {
                            thumbnail(card.id).frame(width: 60, height: 68).clipped()
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .accessibilityHidden(true)
                            Text("Original photo").font(.headline)
                            Spacer()
                            Image(systemName: "arrow.up.right").font(.subheadline.weight(.semibold))
                                .foregroundStyle(Color.pinRose)
                        }.frame(minHeight: 48).padding(9)
                            .background(Color.pinBackground.opacity(0.76), in: RoundedRectangle(cornerRadius: 14))
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityLabel("Open original for \(card.displayTitle)")
                    Button("Correct interpretation") { correct(card.id) }
                        .font(.subheadline.weight(.semibold)).frame(minHeight: 44)
                        .buttonStyle(.plain).foregroundStyle(Color.pinRose)
                        .accessibilityLabel("Correct interpretation of \(card.displayTitle)")
                }
                .padding(20).frame(maxWidth: .infinity, alignment: .leading)
                .pinAnswerSurface()
                .accessibilityIdentifier("savedContentCard-" + card.id)
            }
        }.foregroundStyle(Color.pinInk)
    }
}

struct SavedScreenshotCorrectionSheet: View {
    let title: String
    let initialText: String
    let save: (String?) async throws -> SavedInterpretationSaveResult
    let didSave: (SavedInterpretationSaveResult) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var saving = false
    @State private var failed = false

    var body: some View {
        NavigationStack {
            Form {
                Text(title).font(.headline)
                Text("Your interpretation stays attached to this photo. The original text is kept separately.")
                    .font(.subheadline).foregroundStyle(.secondary)
                TextEditor(text: $text).frame(minHeight: 160)
                    .accessibilityLabel("Your interpretation")
                if failed { Text("The photo changed or the correction could not be saved. Close this sheet and check the current photo.").foregroundStyle(.red) }
            }
            .navigationTitle("Correct interpretation")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(saving) }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "Saving…" : "Save") {
                        saving = true; failed = false
                        Task { @MainActor in
                            do {
                                let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
                                let result=try await save(value.isEmpty ? nil : value)
                                didSave(result); dismiss()
                            } catch { failed = true; saving = false }
                        }
                    }.disabled(saving || text.count > 12_000)
                }
            }
        }.onAppear { text = initialText }
    }
}

#if DEBUG && targetEnvironment(simulator)
/// Presentation-only authored control. It never opens a store or provider and
/// cannot admit evidence, restore a forgotten record, or qualify an answer.
struct PinSavedAnnotationRenderControl: View {
    static var enabled:Bool {
        Bundle.main.bundleIdentifier == "app.pin.savedcandidate" &&
        ProcessInfo.processInfo.arguments.contains("--test-saved-annotation-render")
    }
    var body:some View {
        ScrollView {
            SavedScreenshotResult(cards:[SavedScreenshotCard(id:"layout-control",title:"Saved photo",facts:[
                .init(id:"printed-1",text:"Offer eight weekday lunches",origin:"From this photo"),
                .init(id:"printed-2",text:"each month for £64.",origin:"From this photo"),
                .init(id:"printed-3",text:"Membership renews monthly until cancelled.",origin:"From this photo"),
                .init(id:"owner",text:"Lunch club — planning note",origin:"Your interpretation")
            ],uncertain:false)],coverage:"Authored presentation control",thumbnail:{_ in Color.pinRose},open:{_ in},correct:{_ in})
                .padding(20)
        }.background(Color.pinBackground)
    }
}
#endif
