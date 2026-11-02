import SwiftUI
import AurumCore
import AurumDesign
import AurumRender
import AurumServices
import AurumFeatures

/// Builds the live dependencies and hands them to the root view.
@main
struct AurumApp: App {
    @StateObject private var app: AppModel

    init() {
        let brand = Brand.load(from: .main)
        Brand.current = brand
        let catalog = Self.loadCatalog()
        let isUITest = ProcessInfo.processInfo.arguments.contains("-uiTesting")
        let deps: AppDependencies
        if isUITest {
            // Sample photos and a mock store, so UI tests never touch the real library or App Store.
            deps = AppDependencies.sample(catalog: catalog)
        } else {
            deps = AppDependencies(
                catalog: catalog,
                brand: brand,
                engine: RenderEngine(catalog: catalog),
                photos: LivePhotoLibrary(),
                drafts: FileDraftStore(directory: FileDraftStore.defaultDirectory(), catalog: catalog),
                presets: PresetStore(fileURL: PresetStore.defaultURL()),
                purchases: StoreKitPurchaseService(weeklyID: brand.products.weekly, yearlyID: brand.products.yearly),
                analytics: ConsoleAnalytics(),
                remoteConfig: BundledRemoteConfig(),
                preferences: Preferences()
            )
        }
        _app = StateObject(wrappedValue: AppModel(deps: deps))
    }

    var body: some Scene {
        WindowGroup {
            RootView(app: app)
        }
    }

    /// The catalogue ships in the bundle. A missing or broken file is a build error, so crash loudly.
    static func loadCatalog() -> LookCatalog {
        guard let url = Bundle.main.url(forResource: "catalog", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let catalog = try? LookCatalog.decode(from: data) else {
            fatalError("Looks/catalog.json is missing or invalid. Run tools/generate_catalog.py.")
        }
        return catalog
    }
}
