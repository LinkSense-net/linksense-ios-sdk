#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import UniformTypeIdentifiers

/// A drop-in paste control that claims deferred attribution without a system
/// paste alert.
///
/// On iOS 16+ any *programmatic* pasteboard read raises an approval alert.
/// `PasteButton` is exempt because the user's tap is the consent — which makes
/// this the only clipboard attribution path that costs the user nothing. Show
/// it somewhere a new user would plausibly land after installing from a shared
/// link ("Have an invite link? Paste it").
///
/// ```swift
/// LinkSensePasteButton { url in
///     guard let url else { return }   // nothing recognisable on the pasteboard
///     router.handle(url)
/// }
/// ```
///
/// The closure runs on the main queue, once per tap, with the resolved deep
/// link — or `nil` if the pasted value carried no `click_id`.
///
/// Not available to the Flutter or React Native wrappers, which cannot host a
/// SwiftUI view directly; those call
/// `LinkSense.shared.submitPastedLink(_:completion:)` instead.
@available(iOS 16.0, *)
public struct LinkSensePasteButton: View {
    private let onResolve: (URL?) -> Void

    public init(onResolve: @escaping (URL?) -> Void) {
        self.onResolve = onResolve
    }

    public var body: some View {
        // Ask for plain text rather than .url: a pasted link is very often a
        // bare string, and UTType.url only matches when the source app wrote a
        // typed URL item.
        PasteButton(payloadType: String.self) { strings in
            guard let pasted = strings.first else {
                onResolve(nil)
                return
            }
            LinkSense.shared.submitPastedLink(pasted, completion: onResolve)
        }
    }
}
#endif
