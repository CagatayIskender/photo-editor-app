import Foundation
import AurumCore
import AurumServices

/// The template gallery: every template in the content library, and building
/// a project from one plus the media the user picked.
@MainActor
public final class TemplatesViewModel: ObservableObject {
    @Published public private(set) var templates: [TemplateDefinition]
    @Published public var failure: String?

    let deps: AppDependencies

    public init(deps: AppDependencies) {
        self.deps = deps
        self.templates = deps.content.templates
    }

    /// The template's default track, if it ships with the app.
    public func music(for template: TemplateDefinition) -> MusicSelection? {
        guard let id = template.musicTrackID, let track = deps.content.music.first(where: { $0.id == id }) else { return nil }
        return MusicSelection(source: .library(trackID: track.id), title: track.title, beats: track.beats)
    }

    /// Swatch colours for a template's card: its look's swatch, if any.
    public func swatch(for template: TemplateDefinition) -> [String] {
        template.lookID.flatMap { deps.catalog.look(id: $0)?.swatch } ?? []
    }

    /// Builds the edit. Fewer items than slots is fine: the builder reuses them in order.
    public func build(_ template: TemplateDefinition, media: [PickedMedia]) -> VideoProject? {
        do {
            let project = try TemplateBuilder.build(template, media: media.map(\.templateMedia), music: music(for: template))
            deps.analytics.track(.toolOpened(tool: "template.\(template.id)"))
            return project
        } catch {
            failure = String(localized: "Pick at least one photo or clip.")
            return nil
        }
    }

    /// "5 photos or clips", for a card.
    nonisolated static func mediaCountText(_ count: Int) -> String {
        count == 1 ? String(localized: "1 photo or clip") : String(localized: "\(count) photos or clips")
    }

    /// Total length at the template's own tempo, for a card.
    nonisolated static func length(of template: TemplateDefinition) -> Seconds {
        let beat = BeatGrid(bpm: template.bpm).beatLength
        let slots = template.slots.reduce(0.0) { $0 + Double($1.beats) * beat }
        return slots + (template.intro?.duration ?? 0) + (template.outro?.duration ?? 0)
    }
}
