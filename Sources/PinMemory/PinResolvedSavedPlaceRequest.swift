import Foundation
import IBrainRetrieval
import PinCore

#if canImport(FoundationModels)
import FoundationModels

@available(iOS 26.0, macOS 26.0, *)
@Generable
enum QueryOperation {
    case cityShortlist, priorNeighborhood, unsupported
}

@available(iOS 26.0, macOS 26.0, *)
@Generable
enum QueryCategory {
    case cafe, restaurant, any
}

@available(iOS 26.0, macOS 26.0, *)
@Generable
enum QuerySources {
    case screenshots, all, unrepresented
}

@available(iOS 26.0, macOS 26.0, *)
@Generable
struct ModelPlaceRequest {
    let operation: QueryOperation
    @Guide(description: "Exact city phrase from the question or an empty string. In a follow-up, only include an explicit reference to the previous city.")
    let city: String
    @Guide(description: "Exact neighborhood phrase, or empty. No neighborhood for a city-wide shortlist.")
    let neighborhood: String
    let category: QueryCategory
    let sources: QuerySources
    @Guide(description: "Exact excluded establishment name or an empty string.")
    let exclude: String
    @Guide(description: "True only if every substantive condition can be expressed using the typed fields.")
    let fullyRepresented: Bool
}

#endif

public enum PinSavedPlaceEvidenceScope: Sendable {
    case permittedPhotos
    case screenshots

    public func select(_ memories: [PhotoMemory]) -> [PhotoMemory] {
        switch self {
        case .permittedPhotos: memories
        case .screenshots: memories.filter { $0.isScreenshot == true }
        }
    }
}

public enum PinResolvedSavedPlaceRequest: Sendable {
    case existing(PinSavedPlaceIntent)
    case city(String, category: String?, screenshotsOnly: Bool, omit: String?)
    case priorArea(String, category: String?, omit: String?)

    public func evidenceScope(previous: PinSavedPlaceEvidenceScope?) -> PinSavedPlaceEvidenceScope {
        switch self {
        case .city(_, _, let screenshotsOnly, _): screenshotsOnly ? .screenshots : .permittedPhotos
        case .priorArea, .existing(.neighborhood), .existing(.neighborhoodExcluding),
             .existing(.filterDisplayed), .existing(.priorVisits): previous ?? .permittedPhotos
        default: .permittedPhotos
        }
    }

    public func city(previous: String?) -> String? {
        switch self {
        case .city(let city, _, _, _), .existing(.saved(let city, _)),
             .existing(.savedExcluding(let city, _, _)), .existing(.visited(let city, _)): city
        default: previous
        }
    }

    public func answer(in catalog: SavedPlaceCatalog, previous: SavedPlaceDisplayedContext?, requestID: UUID) throws -> SavedPlaceAnswer {
        switch self {
        case .existing(let value):
            return try value.answer(in: catalog, displayed: previous, requestID: requestID)
        case .city(let city, let category, _, let omit):
            return try catalog.savedPlaces(in: city, category: category, excluding: omit, requestID: requestID)
        case .priorArea(let area, let category, let omit):
            guard let previous else { throw SavedPlaceError.staleDisplayedContext }
            return try catalog.refine(previous, parentRequestID: previous.answerRequestID,
                                      neighborhood: area, category: category, excluding: omit, requestID: requestID)
        }
    }

    #if canImport(FoundationModels)
    @available(iOS 26.0, macOS 26.0, *)
    public static func read(_ question: String, previousCity: String?, hasPrevious: Bool) async throws -> Self? {
        let model = SystemLanguageModel.default
        guard model.isAvailable, question.utf8.count <= 1024 else { return nil }
        let request = try await LanguageModelSession(model: model, instructions: """
            Interpret the user's complete saved places query. The previous city is context only.
            cityShortlist is an explicit saved recommendations request with a named city.
            priorNeighborhood limits the previous displayed result to one named neighborhood.
            A filter may also exclude one named place. Copy literal spans, never add a location.
            Honor an explicit screenshot-only constraint. Visiting, ordering by rank or time,
            a new question about other locations, multiple exclusions, distances, and unrepresentable
            constraints must be unsupported. A prior question cannot become a fresh search.
            """).respond(to: """
                Prior displayed result exists: \(hasPrevious)
                Prior city if known: \(previousCity ?? "none")
                User question: \(question)
                """, generating: ModelPlaceRequest.self, options: .init(sampling: .greedy)).content
        let omit = request.exclude.isEmpty ? nil : request.exclude
        guard request.fullyRepresented, request.sources != .unrepresented,
              [request.city, request.neighborhood, request.exclude].allSatisfy({ $0.isEmpty || literal($0, in: question) })
        else { return nil }

        let priorCue = PinSavedPlaceIntent.targetsDisplayedPlaces(question) ||
            pattern(#"\b(?:from|of|among) (?:those|that|these|the previous)\b|\b(?:those|these) results\b"#, in: question)
        let omitCue = pattern(#"\b(?:except|exclude|omit|skip|leave out|leave .* out)\b"#, in: question)
        let photoCue = PinSavedPlaceQuestionRouting.usesScreenshotScope(question)
        // "Saved to visit" describes a future recommendation. It is distinct
        // from a question asking which places were actually visited.
        let predicates = question.replacingOccurrences(of: #"\bsav(?:e|ed) to visit\b"#, with: "saved",
            options: [.regularExpression, .caseInsensitive])
        guard omitCue == (omit != nil), photoCue == (request.sources == .screenshots),
              !pattern(#"\b(?:before|after|closest|farthest|nearest|latest|oldest|within|distance|sort|rank|how many|visited|visit)\b"#,
                       in: predicates) else { return nil }
        let mentionsCafe = pattern(#"\bcaf[eé]s\b"#, in: question)
        let mentionsRestaurant = pattern(#"\brestaurants\b"#, in: question)
        if mentionsCafe && mentionsRestaurant { return nil }
        let category: String? = mentionsCafe ? "cafe" : mentionsRestaurant ? "restaurant" : nil
        // Explicit displayed-result reference belongs to the host's
        // navigation policy. The model supplies only the literal predicates.
        if priorCue {
            guard hasPrevious, request.operation != .unsupported, !request.neighborhood.isEmpty, !photoCue,
                  request.city.isEmpty || request.city.caseInsensitiveCompare(previousCity ?? "") == .orderedSame
            else { return nil }
            return .priorArea(request.neighborhood, category: category, omit: omit)
        }
        guard request.operation == .cityShortlist, !request.city.isEmpty, request.neighborhood.isEmpty,
              pattern(#"\b(?:saved|save|shortlist|meant to try|wanted to try|picks)\b"#, in: question)
        else { return nil }
        return .city(request.city, category: category, screenshotsOnly: photoCue, omit: omit)
    }

    private static func literal(_ phrase: String, in text: String) -> Bool {
        let p = NSRegularExpression.escapedPattern(for: phrase)
        return phrase.utf8.count <= 160 && pattern(#"(?<![\p{L}\p{M}\p{N}])"# + p +
            #"(?![\p{L}\p{M}\p{N}])"#, in: text)
    }

    private static func pattern(_ expression: String, in text: String) -> Bool {
        text.range(of: expression, options: [.regularExpression, .caseInsensitive]) != nil
    }
    #endif
}
