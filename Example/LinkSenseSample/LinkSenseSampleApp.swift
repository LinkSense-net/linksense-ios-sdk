import SwiftUI
import LinkSense

@main
struct LinkSenseSampleApp: App {
    @StateObject private var viewModel = SampleViewModel()

    init() {
        let cfg = SampleConfig.load()
        LinkSense.shared.configure(
            LinkSenseConfiguration(
                sdkKey: cfg.sdkKey,
                baseURL: cfg.baseURL,
                enableClipboard: false,
                logLevel: .debug
            )
        )
        LinkSense.shared.start()
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
