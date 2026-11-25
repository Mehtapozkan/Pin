import IBrain
import IBrainRetrieval
import PinCore
import PinMemory
import SwiftUI

/// Draws the already admitted place answer. Pin's existing source-opening
/// owner receives the card and optional field so it can recheck access.
struct SavedPlacesResult: View {
    let answer: SavedPlaceAnswer
    let openSources: (String, SavedPlaceField?) -> Void
    let correct: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Saved places")
                .font(.largeTitle.bold()).accessibilityIdentifier("savedPlacesHeading")
            if answer.cards.isEmpty && answer.unresolved.isEmpty {
                Text("No matching places in the photos checked.").font(.title3)
                    .accessibilityIdentifier("savedPlacesEmpty")
            }
            ForEach(answer.cards, id: \.id) { card in
                placeCard(card)
            }
            if !answer.unresolved.isEmpty {
                Text(unresolvedHeading).font(.headline)
                    .accessibilityIdentifier("savedPlacesUnresolved")
                ForEach(answer.unresolved, id: \.id) { card in
                    Text(card.establishedValue(for: .name) ?? "Unnamed place")
                        .font(.body)
                }
            }
            if answer.coverage.hasGaps {
                Text("Some photos still need checking.")
                    .font(.subheadline).foregroundStyle(Color.pinMuted)
                    .accessibilityIdentifier("savedPlacesCoverage")
            }
        }
        .foregroundStyle(Color.pinInk)
    }

    private var unresolvedHeading: String {
        switch answer.operation {
        case .cityRestaurants: "City or restaurant type unclear"
        case .citySavedPlaces: "City or place type unclear"
        case .neighborhood: "Neighborhood unclear"
        case .visits, .cityVisits: "Visit unconfirmed"
        }
    }

    private func placeCard(_ card: SavedPlaceCard) -> some View {
        let name = card.establishedValue(for: .name) ?? "Unnamed place"
        return VStack(alignment: .leading, spacing: 12) {
            Text(name).font(.title2.bold())
                .accessibilityIdentifier("savedPlaceName")
            detail(.branch, label: "Branch", card: card)
            detail(.neighborhood, label: "Neighborhood", card: card)
            detail(.city, label: "City", card: card)
            detail(.address, label: "Address", card: card)
            detail(.reason, label: "Saved detail", card: card)
            if card.evidence(for: .neighborhood).isEmpty && card.evidence(for: .address).isEmpty {
                Text("No neighborhood or address in the checked photos.")
                    .font(.subheadline).foregroundStyle(Color.pinMuted)
            }
            Button {
                openSources(card.id, nil)
            } label: {
                Label(card.sources.count == 1 ? "Original photo" : "Original photos",
                      systemImage: "photo.on.rectangle")
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Open originals for \(name)")
            Button { correct(card.id) } label: {
                Text("Correct a detail").font(.subheadline)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Correct a detail for \(name)")
        }
        .buttonStyle(.plain)
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.pinSurface, in: RoundedRectangle(cornerRadius: 24))
    }

    @ViewBuilder
    private func detail(_ field: SavedPlaceField, label: String, card: SavedPlaceCard) -> some View {
        let supports = card.evidence(for: field)
        if let value = card.establishedValue(for: field) {
            Button {
                openSources(card.id, field)
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(label).font(.caption).foregroundStyle(Color.pinMuted)
                    Text(value).font(.body)
                    if supports.contains(where: { $0.origin == .domainCorrection }) {
                        Text("Your correction").font(.caption).foregroundStyle(Color.pinMuted)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .accessibilityHint("Opens the supporting photo")
            .accessibilityIdentifier("savedPlaceField-" + field.rawValue)
        } else if !supports.isEmpty {
            Button("\(label) differs across sources") { openSources(card.id, field) }
                .font(.subheadline).frame(minHeight: 44)
        }
    }
}

struct SavedPlaceDisplay {
    let answer: SavedPlaceAnswer
    let context: SavedPlaceDisplayedContext
    let evidenceScope: PinSavedPlaceEvidenceScope
    let city: String?
}

enum SavedPlacesQualification {
    static var localReaderEnabled: Bool {
        #if PIN_LOCAL_SAVED_PLACES_QUALIFICATION && canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            return ["app.pin.savedplacescandidate", "app.pin.journeyscandidate"].contains(Bundle.main.bundleIdentifier ?? "")
        }
        #endif
        return false
    }
}

enum PeoplePlansQualification {
    static var enabled: Bool {
        #if DEBUG && PIN_PEOPLE_PLANS_QUALIFICATION
        #if PIN_SAVED_PLACES_COMBINED_REVIEW
        if Bundle.main.bundleIdentifier == "app.pin.savedplacescandidate" { return true }
        #endif
        return ["app.pin.peopleplanscandidate", "app.pin.journeyscandidate"].contains(Bundle.main.bundleIdentifier ?? "")
        #else
        false
        #endif
    }
}

struct PersonPlansResult: View {
    let answer: PinPersonPlans.Answer
    let openOriginal: (SourceReference) -> Void
    let correct: (SourceReference) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Plans with \(answer.person)").font(.largeTitle.bold())
                .accessibilityIdentifier("personPlansHeading")
            if answer.cards.isEmpty {
                Text(answer.onlyConfirmed
                     ? "No plans in that answer were explicitly confirmed."
                     : "No plan photo checked explicitly names this person as a participant.")
                    .foregroundStyle(Color.pinMuted)
            }
            ForEach(answer.cards) { card in
                VStack(alignment: .leading, spacing: 10) {
                    let title = card.value(for: .title) ?? card.title.value
                    Text(title).font(.title2.bold())
                    Text(personPlanStatusLabel(card.status)).foregroundStyle(Color.pinMuted)
                    if let quote = participationCondition(in: card) {
                        Text("“\(quote)”").font(.subheadline).foregroundStyle(Color.pinMuted)
                            .accessibilityIdentifier("personPlanParticipationCondition")
                    }
                    ForEach([SavedPlanDetailCorrection.Field.date, .time, .location], id: \.self) { field in
                        if let value = card.value(for: field) { Text(value) }
                    }
                    if !card.ownerCorrections.isEmpty {
                        Text("Your correction").font(.caption).foregroundStyle(Color.pinMuted)
                    }
                    ForEach(card.originalSources, id: \.self) { source in
                        let isOriginal = source == card.source
                        Button {
                            openOriginal(source)
                        } label: {
                            Label(isOriginal ? "Original photo" : "Participation update", systemImage: "photo.on.rectangle")
                                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        }
                        .accessibilityLabel(isOriginal ? "Open original for \(title)" : "Open participation update for \(title)")
                    }
                    Button {
                        correct(card.source)
                    } label: {
                        Text("Correct a detail")
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    }
                    .accessibilityLabel("Correct a detail for \(title)")
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.pinSurface, in: RoundedRectangle(cornerRadius: 22))
            }
        }
        .foregroundStyle(Color.pinInk)
    }

    private func participationCondition(in card: PinPersonPlans.Card) -> String? {
        guard card.status == .tentative, card.ownerCorrections[.status] == nil,
              let evidence = card.statusEvidence else { return nil }
        return ([evidence.evidence] + evidence.supportingEvidence).map(\.quote).first { quote in
            quote.range(of: #"\b(?:if|unless|provided that|as long as)\b"#,
                        options: [.regularExpression, .caseInsensitive]) != nil
        }
    }

}

private func personPlanStatusLabel(_ status: PinPersonPlans.Card.Status) -> String {
    switch status {
    case .unclear: "Status unclear"
    case .withdrawn: "Participation withdrawn"
    default: status.rawValue.capitalized
    }
}

struct PersonPlanCorrectionTarget: Identifiable {
    var id: SourceReference { card.source }
    let card: PinPersonPlans.Card
    let epoch: Int
    let expected: SavedPhotoInterpretation?
}

struct PersonPlanCorrectionSheet: View {
    let target: PersonPlanCorrectionTarget
    let save: (SavedPlanDetailCorrection.Field, String?) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var field = SavedPlanDetailCorrection.Field.title
    @State private var text = ""
    @State private var status = PinPersonPlans.Card.Status.unclear
    @State private var saving = false
    @State private var failed = false

    private var value: String {
        field == .status ? status.rawValue : text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            Form {
                Text(target.card.value(for: .title) ?? target.card.title.value).font(.headline)
                Picker("Detail", selection: $field) {
                    ForEach(SavedPlanDetailCorrection.Field.allCases, id: \.self) { option in
                        Text(option.rawValue.capitalized).tag(option)
                    }
                }
                .pickerStyle(.navigationLink)
                .accessibilityIdentifier("personPlanCorrectionField")
                if field == .status {
                    Picker("Status", selection: $status) {
                        ForEach(PinPersonPlans.Card.Status.allCases, id: \.self) { option in
                            Text(personPlanStatusLabel(option)).tag(option)
                        }
                    }
                    .pickerStyle(.navigationLink)
                    .accessibilityIdentifier("personPlanCorrectionStatus")
                } else {
                    TextField("Corrected value", text: $text)
                        .accessibilityIdentifier("personPlanCorrectedValue")
                }
                if target.card.ownerCorrections[field] != nil {
                    Button("Remove correction", role: .destructive) { saveValue(nil) }
                }
                if failed {
                    Text("The correction couldn’t be saved. Reopen the current plan and try again.")
                        .foregroundStyle(Color.pinMuted)
                }
            }
            .disabled(saving)
            .navigationTitle("Correct a plan")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(saving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { saveValue(value) }
                        .disabled(saving || value.isEmpty || value.utf8.count > 512 || value == target.card.value(for: field))
                }
            }
        }
        .interactiveDismissDisabled(saving)
        .onChange(of: field, initial: true) { _, selected in
            text = target.card.value(for: selected) ?? ""
            status = target.card.status
            failed = false
        }
    }

    private func saveValue(_ value: String?) {
        saving = true
        failed = false
        let selected = field
        Task {
            do { try await save(selected, value); dismiss() }
            catch { saving = false; failed = true }
        }
    }
}

struct SavedPlaceCorrectionTarget: Identifiable {
    struct Detail: Identifiable {
        var id: String { mentionID + "|" + field.rawValue }
        let mentionID: String
        let source: SourceReference
        let field: SavedPlaceDetailCorrection.Field
        let value: String
        let quote: String
        let expected: SavedPhotoInterpretation?
    }
    let id: String
    let name: String
    let details: [Detail]
}

struct SavedPlaceCorrectionSheet: View {
    let target: SavedPlaceCorrectionTarget
    let save: (SavedPlaceCorrectionTarget.Detail, String) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selection = 0
    @State private var value = ""
    @State private var saving = false
    @State private var failed = false

    var body: some View {
        NavigationStack {
            Form {
                Text(target.name).font(.headline)
                Picker("Detail and source", selection: $selection) {
                    ForEach(target.details.indices, id: \.self) { index in
                        let detail = target.details[index]
                        Text("\(detail.field.rawValue.capitalized) · \(detail.quote)").tag(index)
                    }
                }
                TextField("Corrected value", text: $value)
                    .accessibilityIdentifier("savedPlaceCorrectedValue")
                if failed {
                    Text("The correction couldn’t be saved. Open the current answer and try again.")
                        .foregroundStyle(Color.pinMuted)
                }
            }
            .disabled(saving)
            .navigationTitle("Correct a detail")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(saving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saving = true
                        failed = false
                        let detail = target.details[selection]
                        Task {
                            do { try await save(detail, value); dismiss() }
                            catch { saving = false; failed = true }
                        }
                    }
                    .disabled(saving || value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .onChange(of: selection, initial: true) { _, index in value = target.details[index].value }
    }
}

/// Fixed authored decisions let the Simulator exercise the native writer,
/// actual OCR catalogue and UI while a local semantic reader is evaluated.
enum SavedPlacesDevelopmentControl {
    static var enabled: Bool {
        #if DEBUG && targetEnvironment(simulator)
        ["app.pin.savedplacescandidate", "app.pin.journeyscandidate"].contains(Bundle.main.bundleIdentifier ?? "") &&
        ProcessInfo.processInfo.arguments.contains("--test-saved-places-authored")
        #else
        false
        #endif
    }

    private struct Fixture {
        let key: String
        let role: SavedPlaceRole
        let name: String
        let fields: [(SavedPlaceField, String, String)]
    }

    private static let fixtures: [Fixture] = [
        .init(key: "Good for counter seating.", role: .recommendation, name: "Ume Table",
              fields: [(.city, "Tokyo", "Tokyo, Shibuya"), (.neighborhood, "Shibuya", "Tokyo, Shibuya"),
                       (.reason, "Good for counter seating.", "Good for counter seating.")]),
        .init(key: "2-8 Example-dori, Shibuya, Tokyo", role: .listing, name: "Ume Table",
              fields: [(.city, "Tokyo", "2-8 Example-dori, Shibuya, Tokyo"),
                       (.neighborhood, "Shibuya", "2-8 Example-dori, Shibuya, Tokyo"),
                       (.branch, "Shibuya", "Shibuya branch"),
                       (.address, "2-8 Example-dori, Shibuya, Tokyo", "2-8 Example-dori, Shibuya, Tokyo")]),
        .init(key: "Ueno branch", role: .recommendation, name: "Ume Table",
              fields: [(.city, "Tokyo", "Taito, Tokyo"), (.branch, "Ueno", "Ueno branch")]),
        .init(key: "Excellent soba.", role: .recommendation, name: "Sora Noodles",
              fields: [(.city, "Tokyo", "Tokyo"), (.reason, "Excellent soba.", "Excellent soba.")]),
        .init(key: "Shibuya train transfer", role: .incidental, name: "Ume Table", fields: []),
        .init(key: "Yokohama", role: .recommendation, name: "Sora Noodles",
              fields: [(.city, "Yokohama", "Yokohama")])
    ]

    static func catalog(memories: [PhotoMemory], interpretations: [SavedPhotoInterpretation]) throws -> SavedPlaceCatalog {
        let scope = MemoryScope(ownerID: "local-photo-owner", namespace: "saved-places")
        let sources = try PinEvidenceSnapshot(memories: memories, records: [], scope: scope).authority.sources
        var mentions = [SavedPlaceMention]()
        for fixture in fixtures {
            let matches = sources.filter { source in source.observations.contains { $0.value == fixture.key } }
            guard matches.count <= 1 else { throw PinEvidenceError.invalidSource }
            guard let source = matches.first else { continue }
            guard let subject = source.observations.first(where: { $0.value.contains(fixture.name) }) else {
                throw PinEvidenceError.invalidSupport
            }
            let sourceFacts = fixture.fields + [(.name, fixture.name, subject.value),
                                                 (.category, "restaurant", subject.value),
                                                 (.subjectRole, fixture.role.rawValue, subject.value)]
            let facts = try sourceFacts.map { field, value, quote in
                guard let observed = source.observations.first(where: { $0.value == quote }) else {
                    throw PinEvidenceError.invalidSupport
                }
                return SavedPlaceFact(field, value: value,
                    anchors: [EvidenceAnchor(source: source.reference, observationID: observed.id, quote: quote)],
                    extractorVersion: "authored-development-v1")
            }
            mentions.append(SavedPlaceMention(recordID: "pin.saved-place|" + source.reference.id,
                                              recordRevision: source.reference.revision,
                                              source: source.reference, facts: facts))
        }
        let pins = mentions.map { mention in
            let source = mention.source
            return PinRecordPin(id: mention.recordID, revision: mention.recordRevision,
                sources: [EvidenceSource(id: source.id, fingerprint: source.fingerprint, revision: source.revision)])
        }
        return try PinSavedPlaceSourceBinding.catalog(
            scope: scope, memories: memories, records: pins, mentions: mentions, interpretations: interpretations,
            coverage: SavedPlaceCoverage(pendingSourceCount: 0, unresolvedSourceCount: 0))
    }
}

enum VisitsQualification {
    static var enabled: Bool {
        #if DEBUG && PIN_VISIT_RECONSTRUCTION
        #if PIN_SAVED_PLACES_COMBINED_REVIEW
        if Bundle.main.bundleIdentifier == "app.pin.savedplacescandidate" { return true }
        #endif
        return Bundle.main.bundleIdentifier == "app.pin.journeyscandidate"
        #else
        false
        #endif
    }
}

struct VisitReconstructionResult: View {
    let answer: PinVisitReconstruction.Answer
    let openOriginal: (SourceReference) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(answer.city.map { "Visits in \($0)" } ?? "Your visits").font(.largeTitle.bold())
                .accessibilityIdentifier("visitsHeading")
            if answer.cards.isEmpty {
                Text(answer.receiptsOnly ? "No receipts could be linked to the visits in that answer."
                     : "No visits were confirmed by the photos checked.")
                    .foregroundStyle(Color.pinMuted)
            }
            ForEach(answer.cards) { card in
                VStack(alignment: .leading, spacing: 10) {
                    Text(card.visit.value).font(.title2.bold())
                        .accessibilityIdentifier("visitName")
                    if answer.city == nil {
                        Text([card.branch?.value, card.city.value].compactMap { $0 }.joined(separator: " · "))
                            .foregroundStyle(Color.pinMuted)
                    } else if let branch = card.branch {
                        Text(branch.value).foregroundStyle(Color.pinMuted)
                    }
                    if let date = card.date {
                        sourceButton(date.value, id: "visitDate", detail: date)
                    } else {
                        Text("Visit date unclear").foregroundStyle(Color.pinMuted)
                    }
                    if let receipt = card.receipt {
                        let label = card.receiptAssociation?.basis == .sameDateAndVenue ? "Likely matching receipt" : "Receipt"
                        sourceButton("\(label) · \(receipt.value)", id: "visitReceipt", detail: receipt)
                        if card.receiptAssociation?.basis == .sameDateAndVenue {
                            Text("Same venue, city, and printed date").font(.subheadline).foregroundStyle(Color.pinMuted)
                        }
                    } else if card.receiptAmbiguous {
                        Text("Receipt match unclear").foregroundStyle(Color.pinMuted)
                            .accessibilityIdentifier("visitReceiptUnclear")
                    }
                    sourceButton("Original visit photo", id: "visitOriginal", detail: card.visit)
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.pinSurface, in: RoundedRectangle(cornerRadius: 22))
            }
        }
        .foregroundStyle(Color.pinInk)
    }

    private func sourceButton(_ title: String, id: String, detail: PinVisitReconstruction.Detail) -> some View {
        Button {
            openOriginal(detail.anchor.source)
        } label: {
            Label(title, systemImage: "photo.on.rectangle")
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        }
        .accessibilityIdentifier(id)
    }
}
