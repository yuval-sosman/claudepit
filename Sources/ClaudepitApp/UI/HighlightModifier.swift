import SwiftUI
import ClaudepitCore

/// Wraps section content in a ScrollViewReader and scrolls to + flashes a pending highlight.
struct HighlightScroll<Content: View>: View {
    @ObservedObject var app: AppState
    let sectionRaw: String
    @ViewBuilder var content: Content

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                content
            }
            .onChange(of: app.pendingHighlight) { _, target in
                guard let t = target, t.sectionRaw == sectionRaw else { return }
                withAnimation { proxy.scrollTo(rowID(t.itemID), anchor: .center) }
            }
            .onAppear {
                if let t = app.pendingHighlight, t.sectionRaw == sectionRaw {
                    proxy.scrollTo(rowID(t.itemID), anchor: .center)
                }
            }
        }
    }

    private func rowID(_ id: String) -> String { "\(sectionRaw)::\(id)" }
}

extension View {
    /// Tag a row so HighlightScroll can scroll to it, and flash when it's the pending target.
    func sessionHighlight(sectionRaw: String, id: String, app: AppState) -> some View {
        modifier(HighlightRow(sectionRaw: sectionRaw, id: id, app: app))
    }
}

private struct HighlightRow: ViewModifier {
    let sectionRaw: String
    let id: String
    @ObservedObject var app: AppState
    @State private var flash = false

    func body(content: Content) -> some View {
        content
            .id("\(sectionRaw)::\(id)")
            .background(flash ? Color.accentColor.opacity(0.28) : .clear,
                        in: RoundedRectangle(cornerRadius: 6))
            .onChange(of: app.pendingHighlight) { _, t in maybeFlash(t) }
            .onAppear { maybeFlash(app.pendingHighlight) }
    }

    private func maybeFlash(_ t: HighlightTarget?) {
        guard let t, t.sectionRaw == sectionRaw, t.itemID == id else { return }
        flash = true
        withAnimation(.easeOut(duration: 1.2)) { flash = false }
        // clear the signal so it doesn't re-flash on next appear
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            if app.pendingHighlight == t { app.pendingHighlight = nil }
        }
    }
}
