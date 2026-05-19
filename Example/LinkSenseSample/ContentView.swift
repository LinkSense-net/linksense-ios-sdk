import SwiftUI
import LinkSense

struct ContentView: View {
    @ObservedObject var viewModel: SampleViewModel
    private let config = SampleConfig.load()

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ConfigCard(config: config)
                    DeferredDeepLinkCard(url: viewModel.deferredDeepLink)
                    UniversalLinkCard(url: viewModel.lastUniversalLink)
                    CrudCard(viewModel: viewModel)
                    ResultCard(result: viewModel.lastResult)
                    Spacer(minLength: 8)
                }
                .padding(16)
            }
            .navigationTitle("LinkSense Sample")
        }
        .navigationViewStyle(.stack)
    }
}

private struct SectionCard<Content: View>: View {
    let title: String
    var tint: Color? = nil
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(tint ?? Color(.secondarySystemBackground))
        )
    }
}

private struct KeyValueRow: View {
    let key: String
    let value: String
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text("\(key): ")
                .font(.footnote)
            Text(value)
                .font(.system(.footnote, design: .monospaced))
                .lineLimit(2)
                .truncationMode(.tail)
        }
    }
}

private struct ConfigCard: View {
    let config: SampleConfig
    var body: some View {
        SectionCard(
            title: "Configuration",
            tint: config.isUnconfigured ? Color.red.opacity(0.15) : nil
        ) {
            if config.isUnconfigured {
                Text("Set LINKSENSE_SDK_KEY in Example/LinkSenseSample/Secrets.xcconfig to configure the SDK.")
                    .font(.footnote)
            }
            KeyValueRow(key: "SDK key", value: config.maskedSdkKey)
            KeyValueRow(key: "Base URL", value: config.baseURL?.absoluteString ?? "default (https://linksense.net)")
            KeyValueRow(key: "App-link host", value: config.appLinkHost)
        }
    }
}

private struct DeferredDeepLinkCard: View {
    let url: URL?
    var body: some View {
        SectionCard(title: "Deferred deep link") {
            Text(url?.absoluteString ?? "Not delivered yet.")
                .font(.footnote)
        }
    }
}

private struct UniversalLinkCard: View {
    let url: URL?
    var body: some View {
        SectionCard(title: "Last universal link") {
            Text(url?.absoluteString ?? "No NSUserActivity received.")
                .font(.footnote)
        }
    }
}

private struct CrudCard: View {
    @ObservedObject var viewModel: SampleViewModel
    var body: some View {
        SectionCard(title: "Link CRUD") {
            VStack(alignment: .leading, spacing: 8) {
                TextField("Name", text: $viewModel.form.name)
                    .textFieldStyle(.roundedBorder)
                TextField("Desktop URL", text: $viewModel.form.desktopUrl)
                    .textFieldStyle(.roundedBorder)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                TextField("Slug (optional)", text: $viewModel.form.slug)
                    .textFieldStyle(.roundedBorder)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                TextField(
                    "ID override (defaults to last created: \(viewModel.lastCreatedId ?? "—"))",
                    text: $viewModel.form.idOverride
                )
                .textFieldStyle(.roundedBorder)
                .autocapitalization(.none)
                .disableAutocorrection(true)
                TextField("Update name", text: $viewModel.form.updateName)
                    .textFieldStyle(.roundedBorder)

                HStack(spacing: 8) {
                    Button("Create") { viewModel.createLink() }
                    Button("Get") { viewModel.getLink() }
                    Button("Update") { viewModel.updateLink() }
                    Button("Delete") { viewModel.deleteLink() }
                }
                .disabled(viewModel.inFlight)
            }
        }
    }
}

private struct ResultCard: View {
    let result: ResultRow
    var body: some View {
        SectionCard(title: "Last result") {
            switch result {
            case .pending:
                Text("No operation yet.")
                    .font(.footnote)
            case .ok(let label, let link):
                VStack(alignment: .leading, spacing: 6) {
                    Text(label).font(.callout)
                    if let link {
                        Text(linkDescription(link))
                            .font(.system(.footnote, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            case .err(let message):
                Text(message)
                    .font(.callout)
                    .foregroundColor(.red)
            }
        }
    }

    private func linkDescription(_ link: SDKLink) -> String {
        """
        id: \(link.id)
        name: \(link.name)
        slug: \(link.slug)
        fullUrl: \(link.fullUrl.absoluteString)
        desktopUrl: \(link.desktopUrl?.absoluteString ?? "—")
        createdAt: \(link.createdAt)
        """
    }
}
