import CoreImage
import SwiftUI
import AurumCore

/// Keeps the Studio preview in step with the document without queueing work.
///
/// At most one render runs at a time. Requests that arrive meanwhile replace
/// each other, so when the running render finishes only the newest document
/// is rendered next. A fast slider drag therefore never builds a backlog.
@MainActor
public final class PreviewScheduler: ObservableObject {
    @Published public private(set) var image: CGImage?

    private let engine: RenderEngine
    private var proxy: CIImage?
    private var isRendering = false
    private var pending: (EditDocument, Bool)?

    public init(engine: RenderEngine) {
        self.engine = engine
    }

    /// Sets the screen-size proxy of the photo being edited.
    public func setProxy(_ proxy: CIImage) {
        self.proxy = proxy
    }

    public func request(_ document: EditDocument, compareOriginal: Bool = false) {
        pending = (document, compareOriginal)
        guard !isRendering else { return }
        drain()
    }

    private func drain() {
        guard let next = pending, let proxy else { return }
        pending = nil
        isRendering = true
        Task { [engine] in
            // This task inherits the main actor, so state updates below are safe.
            let result = await engine.renderPreview(next.0, proxy: proxy, compareOriginal: next.1)
            if let result { self.image = result }
            self.isRendering = false
            self.drain()
        }
    }
}
