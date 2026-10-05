import PDFKit
import SwiftUI

/// One document window: page thumbnails in the sidebar, the editable pages in the detail.
struct DocumentWindow: View {
    @ObservedObject var document: HwpDocument
    @StateObject private var viewer = Viewer()
    @State private var pageField = ""

    var body: some View {
        NavigationSplitView {
            PageThumbnails(document: document, viewer: viewer)
                .navigationSplitViewColumnWidth(min: 120, ideal: 150, max: 220)
        } detail: {
            Canvas(canvas: viewer.canvas, document: document)
                .frame(minWidth: 480, minHeight: 400)
                .safeAreaInset(edge: .top, spacing: 0) {
                    if viewer.finding { FindBar(document: document, viewer: viewer) }
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    HStack {
                        Spacer()
                        Text("\(viewer.page + 1) / \(document.reply.pageCount)쪽")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .font(.callout)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                    .background(.bar)
                }
        }
        .alert("쪽으로 이동", isPresented: $viewer.goingToPage) {
            TextField("쪽", text: $pageField)
            Button("이동") { Int(pageField).map { viewer.go(toPage: $0 - 1) } }
            Button("취소", role: .cancel) {}
        }
        .sheet(isPresented: $viewer.insertingTable) { TableSheet(viewer: viewer) }
        .sheet(isPresented: Binding(get: { viewer.pageSetup != nil }, set: { if !$0 { viewer.pageSetup = nil } })) {
            if let setup = viewer.pageSetup { PageSetupSheet(section: setup.section, page: setup.page, viewer: viewer) }
        }
        .focusedSceneObject(document)
        .focusedSceneObject(viewer)
        .toolbar {
            FormatBar(document: document, editor: viewer.canvas.editor)
            if let first = document.reply.suspectPages.first {
                ToolbarItem {
                    Button { viewer.canvas.go(to: Int(first)) } label: {
                        Label("배치 확인", systemImage: "exclamationmark.triangle")
                    }
                    .help(document.reply.suspectPages.map { "\($0 + 1)쪽" }.joined(separator: ", "))
                }
            }
            ToolbarItem {
                Menu("\(viewer.zoomPercent)%") { ZoomItems(viewer: viewer) }
                .help("확대/축소")
            }
        }
    }
}

/// Zoom choices shared by the toolbar and the View menu.
struct ZoomItems: View {
    @ObservedObject var viewer: Viewer

    var body: some View {
        ForEach([50, 75, 100, 125, 150, 200, 300], id: \.self) { percent in
            Toggle("\(percent)%", isOn: Binding(get: { viewer.zoomPercent == percent && viewer.canvas.fit == nil },
                                                set: { _ in viewer.canvas.setZoom(CGFloat(percent) / 100) }))
        }
        Divider()
        Toggle("쪽 맞춤", isOn: Binding(get: { viewer.canvas.fit == .page }, set: { _ in viewer.canvas.fit(.page) }))
        Toggle("폭 맞춤", isOn: Binding(get: { viewer.canvas.fit == .width }, set: { _ in viewer.canvas.fit(.width) }))
    }
}

/// Owns the window's canvas and publishes what the toolbar, sidebar and find bar show.
@MainActor
final class Viewer: ObservableObject {
    let canvas = DocumentCanvas(frame: .zero)
    @Published private(set) var zoomPercent = 100
    /// Zero-based page in view.
    @Published private(set) var page = 0
    /// Pages side by side.
    @Published var columns = 1 {
        didSet { canvas.columns = columns }
    }
    @Published var goingToPage = false
    @Published var insertingTable = false
    /// The section and paper 편집 용지 is showing.
    @Published var pageSetup: (section: UInt32, page: PageSetup)?

    // Find and replace.
    @Published var finding = false
    @Published var replacing = false
    @Published var query = ""
    @Published var replacement = ""
    /// Matches of `query` in the latest revision.
    @Published private(set) var matches: [EditSelection] = []

    private var document: HwpDocument? { canvas.editor.model }
    private var undoManager: UndoManager? { canvas.editor.undoManager }

    init() {
        canvas.onViewChange = { [weak self] in
            guard let self else { return }
            let zoom = Int((canvas.zoom * 100).rounded()), page = canvas.currentPage
            if zoom != zoomPercent { zoomPercent = zoom }
            if page != self.page { self.page = page }
        }
    }
}

extension Viewer {
    /// Shows the find bar; `replace` also shows the replacement field.
    func showFind(replace: Bool) {
        replacing = replace || (finding && replacing)
        finding = true
    }
    func closeFind() {
        finding = false
        canvas.window?.makeFirstResponder(canvas.editor)
    }
    /// Finds with the selected text.
    func findSelection() {
        guard let document, let selection = document.selection, selection.anchor != selection.focus else { return NSSound.beep() }
        Task {
            guard let text = try? await document.text(of: selection) else { return }
            query = text
        }
    }
    func search() async {
        matches = query.isEmpty ? [] : (try? await document?.find(query)) ?? []
    }

    /// Selects the match after the selection (or before it), wrapping around the document.
    /// Matches are looked up after queued edits, so it follows a replacement correctly.
    func findNext(backward: Bool = false) {
        guard let document, !query.isEmpty else { return NSSound.beep() }
        let query = query
        document.select { [weak self] document in
            let matches = try await document.find(query)
            self?.matches = matches
            guard !matches.isEmpty else {
                NSSound.beep()
                return nil
            }
            guard let selection = document.selection else { return matches[0] }
            if backward {
                let start = selection.ordered.start.order
                return matches.last { !start.lexicographicallyPrecedes($0.ordered.end.order) } ?? matches.last
            }
            let end = selection.ordered.end.order
            return matches.first { !$0.ordered.start.order.lexicographicallyPrecedes(end) } ?? matches.first
        }
    }
    /// Replaces the selected match and moves to the next one.
    func replace() {
        guard let document, let selection = document.selection, matches.contains(selection) else { return findNext() }
        let text = replacement
        document.edit(undoManager) { $0 == selection ? .replace(selection, text: text) : nil }
        findNext()
    }
    func replaceAll() {
        guard !query.isEmpty else { return NSSound.beep() }
        document?.replaceAll(query, with: replacement, undoManager)
    }

    /// Shows a zero-based page and puts the caret at its top.
    func go(toPage index: Int) {
        guard let document, !document.pages.isEmpty else { return }
        let page = min(max(index, 0), document.pages.count - 1)
        canvas.go(to: page)
        document.select { try await .caret($0.hitTest(page: page, x: 0, y: 0)) }
    }
}

/// The find bar above the pages: the query with match count and arrows, and when
/// replacing, the replacement with its buttons.
private struct FindBar: View {
    @ObservedObject var document: HwpDocument
    @ObservedObject var viewer: Viewer
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                TextField("찾기", text: $viewer.query)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .onSubmit { viewer.findNext() }
                if !viewer.query.isEmpty {
                    let current = document.selection.flatMap { viewer.matches.firstIndex(of: $0) }
                    Text(current.map { "\($0 + 1)/\(viewer.matches.count)" } ?? "\(viewer.matches.count)")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                ControlGroup {
                    Button { viewer.findNext(backward: true) } label: { Label("이전 찾기", systemImage: "chevron.left") }
                    Button { viewer.findNext() } label: { Label("다음 찾기", systemImage: "chevron.right") }
                }
                .fixedSize()
                .disabled(viewer.matches.isEmpty)
                Button("완료") { viewer.closeFind() }
                    .keyboardShortcut(.cancelAction)
            }
            if viewer.replacing {
                HStack {
                    TextField("바꾸기", text: $viewer.replacement)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { viewer.replace() }
                    Button("바꾸기") { viewer.replace() }
                    Button("모두 바꾸기") { viewer.replaceAll() }
                }
                .disabled(viewer.matches.isEmpty)
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
        .onAppear { focused = true }
        .onChange(of: viewer.finding) { if viewer.finding { focused = true } }
        .task(id: "\(viewer.query)\u{0}\(document.revision)") { await viewer.search() }
    }
}

extension EditPosition {
    /// Sort key in document order across the body and table cells; a table's cells come
    /// after the text of the paragraph holding it.
    var order: [Int] {
        [Int(target.section), Int(target.paragraph), target.cell.map { Int($0.control) } ?? -1,
         Int(target.cell?.cell ?? 0), Int(target.cell?.paragraph ?? 0), Int(scalar)]
    }
}

private struct Canvas: NSViewRepresentable {
    let canvas: DocumentCanvas
    let document: HwpDocument
    func makeNSView(context: Context) -> DocumentCanvas { canvas }
    func updateNSView(_ view: DocumentCanvas, context: Context) { view.bind(document) }
}

/// Page thumbnails; a page's image is redrawn only when the engine replaced that page.
private struct PageThumbnails: View {
    @ObservedObject var document: HwpDocument
    @ObservedObject var viewer: Viewer

    var body: some View {
        let pages = document.pages
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(pages.indices, id: \.self) { index in
                        let page = pages[index]
                        Button { viewer.canvas.go(to: index) } label: {
                                VStack(spacing: 4) {
                                    Thumbnail(page: page)
                                        .id(page.id)
                                        .padding(3)
                                        .background(RoundedRectangle(cornerRadius: 4)
                                            .fill(index == viewer.page ? Color.accentColor.opacity(0.35) : .clear))
                                    Text("\(index + 1)").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .buttonStyle(.plain)
                            .id(index)
                    }
                }
                .padding(.vertical, 12)
            }
            .onChange(of: viewer.page) { proxy.scrollTo(viewer.page) }
        }
    }
}

/// Draws off the main actor once a page has stopped changing, keeping the previous image
/// meanwhile, so typing never waits for a thumbnail.
private struct Thumbnail: View {
    let page: RenderedPage
    @State private var image: CGImage?

    var body: some View {
        let size = Self.size(of: page)
        Group {
            if let image { Image(decorative: image, scale: 2) } else { Color.white }
        }
        .frame(width: size.width, height: size.height)
        .shadow(color: .black.opacity(0.2), radius: 1, y: 1)
        .task(id: page.id) {
            if image != nil { try? await Task.sleep(for: .milliseconds(400)) }
            guard !Task.isCancelled else { return }
            let page = page
            let drawn = await Task.detached(priority: .utility) { Drawn(Self.render(page, size: size)) }.value
            if !Task.isCancelled { image = drawn.image }
        }
    }

    nonisolated private static func size(of page: RenderedPage) -> CGSize {
        let scale = min(110 / page.size.width, 150 / page.size.height)
        return CGSize(width: (page.size.width * scale).rounded(), height: (page.size.height * scale).rounded())
    }
    nonisolated private static func render(_ page: RenderedPage, size: CGSize) -> CGImage? {
        guard let context = CGContext(data: nil, width: Int(size.width * 2), height: Int(size.height * 2), bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(.white)
        context.fill(CGRect(x: 0, y: 0, width: size.width * 2, height: size.height * 2))
        context.translateBy(x: 0, y: size.height * 2)
        context.scaleBy(x: 2, y: -2)
        page.draw(in: context, rect: CGRect(origin: .zero, size: size))
        return context.makeImage()
    }
}

private struct Drawn: @unchecked Sendable {
    let image: CGImage?
    init(_ image: CGImage?) { self.image = image }
}
