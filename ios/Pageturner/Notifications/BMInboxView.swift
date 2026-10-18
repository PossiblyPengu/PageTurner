import SwiftUI

/// The notifications list: everything the reader has been told, newest first, with what is unread marked.
/// Reached from the bell on the Together tab and from Settings → Notifications.
struct BMInboxView: View {
    @Environment(AppRouter.self) private var router
    private let store = BMInboxStore.shared

    var body: some View {
        Group {
            if store.items.isEmpty {
                ContentUnavailableView(
                    "No notifications",
                    systemImage: "bell",
                    description: Text("Messages, suggestions and news from the other apps show up here."))
            } else {
                list
            }
        }
        .navigationTitle("Notifications")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Mark All as Read") { store.markAllRead() }
                    Button("Clear All", role: .destructive) { store.clear() }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .disabled(store.items.isEmpty)
                .accessibilityLabel("More")
            }
        }
        .onAppear { store.loadIfNeeded() }
        // having looked, they are read
        .onDisappear { store.markAllRead() }
    }

    private var list: some View {
        let now = Date().timeIntervalSince1970
        return List {
            ForEach(store.items) { item in
                Button { router.open(item) } label: { row(item, now: now) }
                    .buttonStyle(.plain)
                    .swipeActions {
                        Button(role: .destructive) { store.remove(id: item.id) } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
            }
        }
    }

    private func row(_ item: BMInboxItem, now: Double) -> some View {
        HStack(alignment: .top, spacing: 12) {
            BMDot(tone: BMSuite.dotTone(forApp: item.app), size: 9)
                .opacity(item.read ? 0 : 1)
                .padding(.top, 6)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.subheadline.weight(item.read ? .regular : .semibold))
                Text(item.body)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                Text(BMInbox.ago(item.at, now: now))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.read ? "" : "Unread. ")\(item.title). \(item.body). \(BMInbox.ago(item.at, now: now))")
    }
}

/// A notification arriving while Pageturner is open: a card at the top that says it, goes where it leads when
/// tapped, and goes by itself after a few seconds. Not over a book being read — it waits for the reader to
/// come out (and is in the list either way).
struct BMBannerHost: View {
    @Environment(AppRouter.self) private var router
    private let notifier = Notifier.shared

    var body: some View {
        Group {
            if let item = notifier.banner, !router.readerOpen {
                BMBanner(
                    item: item,
                    open: {
                        router.open(item)
                        notifier.dismissBanner()
                    },
                    dismiss: { notifier.dismissBanner() })
                    .id(item.id)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .task(id: item.id) {
                        try? await Task.sleep(for: .seconds(5))
                        if notifier.banner?.id == item.id { notifier.dismissBanner() }
                    }
            }
        }
        .ptAnimation(.smooth(duration: 0.3), value: notifier.banner?.id)
    }
}

private struct BMBanner: View {
    let item: BMInboxItem
    let open: () -> Void
    let dismiss: () -> Void
    @State private var drag: CGFloat = 0

    var body: some View {
        Button(action: open) {
            HStack(alignment: .top, spacing: 10) {
                BMDot(tone: BMSuite.dotTone(forApp: item.app), size: 10)
                    .padding(.top, 5)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title).font(.subheadline.weight(.semibold))
                    Text(item.body)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .ptGlass(in: RoundedRectangle(cornerRadius: 18, style: .continuous), interactive: true)
            .shadow(color: .black.opacity(0.15), radius: 8, y: 3)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .offset(y: min(0, drag))
        .gesture(
            DragGesture()
                .onChanged { drag = $0.translation.height }
                .onEnded { value in
                    if value.translation.height < -20 { dismiss() }
                    drag = 0
                })
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.title). \(item.body)")
        .accessibilityHint("Opens it")
        .accessibilityAddTraits(.isButton)
    }
}
