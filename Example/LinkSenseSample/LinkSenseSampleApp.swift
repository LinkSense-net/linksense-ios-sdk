import SwiftUI
import LinkSense

@main
struct LinkSenseSampleApp: App {
    @StateObject private var viewModel = SampleViewModel()

    init() {
        let cfg = SampleConfig.load()
        do {
            try LinkSense.shared.configure(
                LinkSenseConfiguration(
                    sdkKey: cfg.sdkKey,
                    enableClipboard: false,
                    logLevel: .debug
                )
            )
            LinkSense.shared.start()
        } catch {
            // Malformed key (e.g. the Secrets.xcconfig placeholder). Calls
            // made later fail with `.notConfigured`, which the UI shows.
            print("LinkSense.configure failed: \(error.localizedDescription)")
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView(viewModel: viewModel)
                .onAppear {
                    LinkSense.shared.onDeferredDeepLink { [viewModel] url in
                        viewModel.deferredDeepLink = url
                    }
                }
                .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
                    LinkSense.shared.continueUserActivity(activity) { [viewModel] url in
                        viewModel.lastUniversalLink = url
                    }
                }
        }
    }
}
