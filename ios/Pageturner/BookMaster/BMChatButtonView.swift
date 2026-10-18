import SwiftUI

/// A round chat button over every screen but the reader: tap to talk, drag to the other edge or to a
/// different height. A dot says a message is waiting. (Turned off, or hidden over the chat itself and
/// the in-app browser — see `BMChatButton`.)
struct BMChatButtonLayer: View {
    @Environment(AppRouter.self) private var router
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("bm-chat-button") private var enabled = true
    @AppStorage("bm-chat-spot") private var storedSpot = ""
    @State private var drag: CGSize = .zero
    /// Room kept clear below: the tab bar, and the mini player above it when one is up.
    let bottomReserve: CGFloat

    private let bookMaster = BookMaster.shared
    private let notifier = Notifier.shared
    private let size: CGFloat = 52
    private let margin: CGFloat = 12
    /// Below the navigation bar's title row.
    private let topReserve: CGFloat = 56

    private var shown: Bool {
        BMChatButton.isShown(
            linked: bookMaster.isLinked, enabled: enabled,
            readerOpen: router.readerOpen, hiders: router.chatButtonHiders.count)
    }

    private var spot: BMChatButton.Spot { BMChatButton.Spot(stored: storedSpot) ?? .standard }

    var body: some View {
        GeometryReader { geo in
            if shown {
                button(in: geo)
                    .transition(.opacity)
            }
        }
        // the whole screen, so the free band is measured against the real safe areas — and the keyboard
        // does not carry the button up with it
        .ignoresSafeArea()
        .ptAnimation(.easeOut(duration: 0.2), value: shown)
        .task(id: shown && scenePhase == .active) { await poll() }
    }

    // MARK: Drawing

    private func button(in geo: GeometryProxy) -> some View {
        let band = self.band(geo)
        let centre = spot.center(
            width: Double(geo.size.width), top: band.top, bottom: band.bottom,
            size: Double(size), margin: Double(margin))
        // the gestures and the accessibility element belong to the small face, before it is positioned:
        // positioned first, they would stand over the whole screen
        return face
            .gesture(moving(centre: centre, geo: geo, band: band))
            .onTapGesture { open() }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(notifier.chatUnread == nil ? "Chat" : "Chat, a message is waiting")
            .accessibilityHint("Opens the chat")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { open() }
            .accessibilityAction(named: "Move to the other side") { storedSpot = spot.flipped.stored }
            .position(x: CGFloat(centre.x) + drag.width, y: CGFloat(centre.y) + drag.height)
    }

    private var face: some View {
        let unread = notifier.chatUnread != nil
        return Image(systemName: unread ? "bubble.left.and.bubble.right.fill" : "bubble.left.and.bubble.right")
            .font(.system(size: 20, weight: .semibold))
            .foregroundStyle(Color.ptAccent)
            .frame(width: size, height: size)
            .ptGlass(in: Circle(), interactive: true)
            .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
            .overlay(alignment: .topTrailing) {
                if unread {
                    // the chat is the suite's, not Quest Log's: a regular dot (round, in the accent)
                    BMDot(tone: .regular, size: 13, ring: Color(uiColor: .systemBackground))
                        .offset(x: -2, y: 2)
                }
            }
            .contentShape(Circle())
    }

    /// The free height: below the title row and above the tab bar.
    private func band(_ geo: GeometryProxy) -> (top: Double, bottom: Double) {
        (
            Double(geo.safeAreaInsets.top + topReserve),
            Double(geo.size.height - geo.safeAreaInsets.bottom - bottomReserve)
        )
    }

    private func moving(
        centre: (x: Double, y: Double), geo: GeometryProxy, band: (top: Double, bottom: Double)
    ) -> some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .global)
            .onChanged { drag = $0.translation }
            .onEnded { value in
                let landed = BMChatButton.Spot.dropped(
                    x: centre.x + Double(value.translation.width),
                    y: centre.y + Double(value.translation.height),
                    width: Double(geo.size.width), top: band.top, bottom: band.bottom, size: Double(size))
                // one animated change: from where the finger left it to where it rests, with no jump between
                withAnimation(.snappy(duration: 0.25)) {
                    storedSpot = landed.stored
                    drag = .zero
                }
            }
    }

    // MARK: Acting

    private func open() {
        notifier.noteChatOpened()
        router.showChat = true
    }

    /// While the button is up and the app in front, look for new messages now and then, so its dot is
    /// current on any screen (the Together tab and a foreground refresh are the only other looks).
    private func poll() async {
        guard shown, scenePhase == .active else { return }
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(LowPower.on ? 120 : 60))
            guard !Task.isCancelled else { return }
            await notifier.refresh(notify: false)
        }
    }
}

/// The chat as a full page over the app, for the floating button: the same screen the Together tab pushes,
/// with a way back. (A sheet left the page behind it showing at the top, which read as a pop-up.)
struct BMChatScreen: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            BMChatView()
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button { dismiss() } label: {
                            Label("Back", systemImage: "chevron.left")
                        }
                    }
                }
        }
    }
}

private struct HidesChatButton: ViewModifier {
    @Environment(AppRouter.self) private var router: AppRouter?
    @State private var id = UUID()

    func body(content: Content) -> some View {
        content
            .onAppear { router?.hideChatButton(id, true) }
            .onDisappear { router?.hideChatButton(id, false) }
    }
}

extension View {
    /// The floating chat button steps aside while this screen is up — it is the chat, or a page the
    /// button would sit on top of.
    func hidesChatButton() -> some View { modifier(HidesChatButton()) }
}
