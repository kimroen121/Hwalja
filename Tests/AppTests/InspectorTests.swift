import Testing
import Foundation
import AppKit
import SwiftUI
@testable import HwaljaKit

/// The inspector and the 퀵 메뉴: which tabs show, and that what their controls send
/// changes the document as shown.
@MainActor
struct InspectorTests {
    /// The tabs follow what is chosen, as Pages's: a selected object has only its own, a
    /// table has 텍스트 among its own, and 개체 is the last tab wherever it shows.
    @Test func tabsFollowTheSelection() {
        #expect(Inspector.contextTabs(EditingContext()) == [])
        #expect(Inspector.contextTabs(EditingContext(inTable: true)) == ["표", "셀", "개체"])
        #expect(Inspector.contextTabs(EditingContext(inTable: true, object: .picture)) == ["스타일", "이미지", "개체"])
        #expect(Inspector.contextTabs(EditingContext(object: .shape)) == ["도형", "개체"])
        #expect(Inspector.contextTabs(EditingContext(object: .shape, chart: true)) == ["차트", "개체"])
        #expect(Inspector.contextTabs(EditingContext(object: .equation)) == ["수식", "개체"])
        #expect(Inspector.contextTabs(EditingContext(inHeaderFooter: true)) == ["머리말/꼬리말"])
        #expect(Inspector.contextTabs(EditingContext(inNote: true)) == ["주석"])
        #expect(Inspector.tabs(EditingContext()) == ["텍스트"])
        #expect(Inspector.tabs(EditingContext(object: .picture)) == ["스타일", "이미지", "개체"])
        #expect(Inspector.tabs(EditingContext(inTable: true)) == ["표", "셀", "텍스트", "개체"])
        #expect(Inspector.tabs(EditingContext(inNote: true)) == ["텍스트", "주석"])
        for context in [EditingContext(object: .picture), EditingContext(object: .shape), EditingContext(object: .equation),
                        EditingContext(inTable: true)] {
            #expect(Inspector.tabs(context).last == "개체")
        }
        #expect(InspectorPane.allCases.map(\.rawValue) == ["서식", "문서"])
    }

    /// The 퀵 메뉴 lies over the window, not the zoomed pages, once text is selected, and goes
    /// with the selection.
    @Test func quickMenuShowsOverSelectedTextOnly() async throws {
        let document = try HwpDocument(data: fixture("hwpx"))
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 900))
        let canvas = DocumentCanvas(frame: container.bounds)
        container.addSubview(canvas)
        let window = NSWindow(contentRect: container.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = container
        canvas.bind(document)
        canvas.setZoom(1)
        canvas.tile()
        let bar = NSHostingView(rootView: Color.clear.frame(width: 120, height: 36))
        canvas.editor.quickMenu = { bar }
        document.selection = .caret(EditPosition(target: body, scalar: 0))
        await document.settle()
        #expect(bar.superview == nil)
        document.move(.wordRight, extend: true)
        await document.settle()
        canvas.editor.scrollToVisible(canvas.editor.frame(ofPage: 0)!.insetBy(dx: 0, dy: 200).offsetBy(dx: 0, dy: -200))
        #expect(bar.superview === container)
        #expect(bar.frame.size == NSSize(width: 120, height: 36) && container.bounds.contains(bar.frame), "\(bar.frame)")
        // Scrolled away from the selection, the bar goes; back, it comes again.
        canvas.setZoom(4)
        canvas.editor.scroll(NSPoint(x: 0, y: canvas.editor.bounds.maxY))
        for _ in 0..<50 where bar.superview != nil { try await Task.sleep(for: .milliseconds(20)) }
        #expect(bar.superview == nil)
        canvas.setZoom(1)
        canvas.editor.scroll(.zero)
        #expect(bar.superview === container)
        document.move(.left, extend: false)
        await document.settle()
        for _ in 0..<50 where bar.superview != nil { try await Task.sleep(for: .milliseconds(20)) }
        #expect(bar.superview == nil)
    }

    /// 캡션 from the inspector goes in and out while the picture stays chosen.
    @Test func captionsGoInWhileThePictureStaysChosen() async throws {
        let document = try HwpDocument(data: fixture("hwpx"))
        let viewer = Viewer()
        viewer.canvas.bind(document)
        let picture = try await insertedPicture(document)
        viewer.insertCaption("Bottom")
        await document.settle()
        #expect(document.object?.object == picture.object)
        #expect(try await document.objectProps(picture.object).caption == "Bottom")
        viewer.insertCaption("None")
        await document.settle()
        #expect(document.object?.object == picture.object)
        #expect(try await document.objectProps(picture.object).caption == "None")
    }

    /// 글자처럼 취급 off and on again, then 본문과의 배치, 위치 and 회전 as 개체 sends them.
    @Test func picturesLeaveAndRejoinTheLine() async throws {
        let document = try HwpDocument(data: fixture("hwpx"))
        let viewer = Viewer()
        viewer.canvas.bind(document)
        let picture = try await insertedPicture(document)
        #expect(try await document.objectProps(picture.object).treatAsChar == true)
        viewer.arrange(ObjectProps(treatAsChar: false, textWrap: "Square"))
        await document.settle()
        let floating = try #require(viewer.arrangedObject)
        var props = try await document.objectProps(floating)
        #expect(props.treatAsChar == false && props.textWrap == "Square")
        viewer.arrange(ObjectProps(horzOffset: 1_000, vertOffset: 2_000))
        await document.settle()
        props = try await document.objectProps(try #require(viewer.arrangedObject))
        #expect(props.horzOffset == 1_000 && props.vertOffset == 2_000)
        // As in 한/글, a turned picture's place is its bounding box's, around the same center.
        viewer.arrange(ObjectProps(rotationAngle: 30))
        await document.settle()
        let turned = try await document.objectProps(try #require(viewer.arrangedObject))
        let grown = (Int32(turned.width ?? 0) - Int32(props.width ?? 0)) / 2
        #expect(turned.rotationAngle == 30 && grown > 0)
        #expect(abs(turned.horzOffset! - (1_000 - grown)) <= 1 && abs(turned.vertOffset! - (2_000 - grown)) <= 1)
        viewer.arrange(ObjectProps(treatAsChar: true))
        await document.settle()
        #expect(try await document.objectProps(try #require(viewer.arrangedObject)).treatAsChar == true)
        // From each 본문과의 배치 back into the line.
        for wrap in ["TopAndBottom", "BehindText", "InFrontOfText"] {
            viewer.arrange(ObjectProps(treatAsChar: false, textWrap: wrap))
            await document.settle()
            #expect(try await document.objectProps(try #require(viewer.arrangedObject)).textWrap == wrap)
            viewer.arrange(ObjectProps(treatAsChar: true))
            await document.settle()
            #expect(try await document.objectProps(try #require(viewer.arrangedObject)).treatAsChar == true, "from \(wrap)")
        }
    }

    /// 크기 and 원래 크기.
    @Test func picturesAreSizedAndGoBackToTheirSize() async throws {
        let document = try HwpDocument(data: fixture("hwpx"))
        let viewer = Viewer()
        viewer.canvas.bind(document)
        let picture = try await insertedPicture(document)
        viewer.arrange(ObjectProps(width: 9_000, height: 6_000))
        await document.settle()
        var props = try await document.objectProps(picture.object)
        #expect(props.width == 9_000 && props.height == 6_000)
        viewer.arrange(ObjectProps(width: props.originalWidth, height: props.originalHeight))
        await document.settle()
        props = try await document.objectProps(picture.object)
        #expect(props.width == props.originalWidth && props.height == props.originalHeight)
    }

    /// 스타일's 테두리 and 이미지's 조절 and 재설정.
    @Test func pictureBordersAndAdjustmentsApply() async throws {
        let document = try HwpDocument(data: fixture("hwpx"))
        let viewer = Viewer()
        viewer.canvas.bind(document)
        let picture = try await insertedPicture(document)
        viewer.arrange(ObjectProps(borderColor: 0x0000ff, borderWidth: 100, lineType: 1))
        viewer.adjustPicture { ($0.effect, $0.brightness, $0.contrast) = ("GrayScale", 20, -10) }
        // adjustPicture reads the picture before it sends the change.
        var props = try await document.objectProps(picture.object)
        for _ in 0..<50 where props.effect != "GrayScale" {
            try await Task.sleep(for: .milliseconds(20))
            await document.settle()
            props = try await document.objectProps(picture.object)
        }
        #expect(props.lineType == 1 && props.borderColor == 0x0000ff && props.borderWidth == 100)
        #expect(props.effect == "GrayScale" && props.brightness == 20 && props.contrast == -10)
        viewer.adjustPicture { ($0.effect, $0.brightness, $0.contrast) = ("RealPic", 0, 0) }
        for _ in 0..<50 where props.effect != "RealPic" {
            try await Task.sleep(for: .milliseconds(20))
            await document.settle()
            props = try await document.objectProps(picture.object)
        }
        #expect(props.effect == "RealPic" && props.brightness == 0 && props.contrast == 0)
    }

    /// 수식's 글자 크기 and 글자 색, sent with the script as 수식 편집기 sends them.
    @Test func equationsTakeTheirSizeAndColor() async throws {
        let document = try HwpDocument(data: fixture("hwpx"))
        let viewer = Viewer()
        viewer.canvas.bind(document)
        let start = EditPosition(target: body, scalar: 0)
        document.selection = .caret(start)
        document.edit(nil) { _ in .insertEquation(start, script: "x^2", fontSize: 1_000, color: 0) }
        await document.settle()
        let equation = try #require(try await placedObject(document, .equation))
        choose(equation, in: document)
        await document.settle()
        viewer.setObject(equation.object, ObjectProps(script: "x^2", fontSize: 2_000, color: 0x0000ff))
        await document.settle()
        let props = try await document.objectProps(equation.object)
        #expect(props.script == "x^2" && props.fontSize == 2_000 && props.color == 0x0000ff)
    }

    /// 표: 제목 줄 자동 반복, 쪽 경계에서 and 표 윤곽.
    @Test func tableOptionsAndOutlineApply() async throws {
        let document = HwpDocument()
        let viewer = Viewer()
        viewer.canvas.bind(document)
        document.select { _ in .caret(EditPosition(target: body, scalar: 0)) }
        await document.settle()
        viewer.insertTable(rows: 2, columns: 2)
        await document.settle()
        let table = try #require(viewer.arrangedObject)
        let red = BorderSide(line: 1, width: 5, color: "#ff0000")
        viewer.arrange(ObjectProps(pageBreak: 1, repeatHeader: true))
        viewer.arrange(ObjectProps(tableBorder: CellBorder(sides: [red, red, red, red, nil, nil])))
        await document.settle()
        let props = try await document.objectProps(table)
        #expect(props.pageBreak == 1 && props.repeatHeader == true)
        #expect(props.tableBorder?.sides.prefix(4).allSatisfy { $0 == red } == true)
    }

    /// 셀: 채우기, a 테두리 side and 높이 go on the caret's cell alone when no block is chosen.
    @Test func cellChangesStayInTheCaretCell() async throws {
        let document = HwpDocument()
        let viewer = Viewer()
        viewer.canvas.bind(document)
        document.select { _ in .caret(EditPosition(target: body, scalar: 0)) }
        await document.settle()
        viewer.insertTable(rows: 2, columns: 2)
        await document.settle()
        let caret = try #require(document.selection?.focus.target)
        var other = caret
        other.cell?.cell = 3
        let blue = BorderSide(line: 1, width: 3, color: "#0000ff")
        var border = CellBorder(fill: PageFill(color: "#ffeecc", patternColor: "#000000", pattern: 0))
        border.sides[3] = blue
        viewer.setCellBorder(border, all: false, one: false)
        viewer.setCell(caret, CellProps(height: 3_000))
        await document.settle()
        let changed = try await document.cellBorder(caret), untouched = try await document.cellBorder(other)
        #expect(changed.sides[3] == blue && changed.fill == border.fill)
        #expect(untouched.sides[3] != blue && untouched.fill != border.fill)
        #expect(try await document.cellProps(caret).height ?? 0 >= 3_000)
    }
}

extension InspectorTests {
    /// A picture in a table cell leaves the line and comes back as one in the body does.
    @Test func picturesInCellsLeaveAndRejoinTheLine() async throws {
        let document = HwpDocument()
        let viewer = Viewer()
        viewer.canvas.bind(document)
        document.select { _ in .caret(EditPosition(target: body, scalar: 0)) }
        await document.settle()
        viewer.insertTable(rows: 1, columns: 1)
        await document.settle()
        let cell = try #require(document.selection?.focus)
        document.edit(nil) { _ in .insertPicture(cell, data: png, width: 7_500, height: 7_500, naturalWidth: 1, naturalHeight: 1,
                                                  extension: "png", description: "p.png") }
        await document.settle()
        choose(try await placedObject(document, .picture), in: document)
        await document.settle()
        let picture = try #require(document.object)
        #expect(picture.object.cell != nil)
        viewer.arrange(ObjectProps(treatAsChar: false, textWrap: "Square"))
        await document.settle()
        #expect(try await document.objectProps(try #require(viewer.arrangedObject)).treatAsChar == false)
        viewer.arrange(ObjectProps(treatAsChar: true))
        await document.settle()
        #expect(try await document.objectProps(try #require(viewer.arrangedObject)).treatAsChar == true)
    }

    /// Choosing an object changes neither the revision nor the caret; the inspector still
    /// reads the object's properties for it.
    @Test func choosingAnObjectReadsItsProperties() async throws {
        let document = try HwpDocument(data: fixture("hwpx"))
        let viewer = Viewer()
        viewer.canvas.bind(document)
        let picture = try await insertedPicture(document)
        choose(nil, in: document)
        await document.settle()
        let before = Inspector.readKey(document, viewer)
        choose(picture, in: document)
        await document.settle()
        #expect(Inspector.readKey(document, viewer) != before)
    }

    /// The inspector open before the picture is chosen shows what one opened after it does:
    /// its properties read, on the tab last chosen for a picture.
    @Test func inspectorOpenBeforeChoosingShowsThePicture() async throws {
        let document = try HwpDocument(data: fixture("hwpx"))
        let viewer = Viewer()
        viewer.canvas.bind(document)
        let picture = try await insertedPicture(document)
        choose(nil, in: document)
        await document.settle()
        viewer.inspectorTabs["스타일 이미지 개체"] = "개체"
        let open = hosted(Inspector(document: document, viewer: viewer))
        try await Task.sleep(for: .milliseconds(300))
        choose(picture, in: document)
        await document.settle()
        let fresh = hosted(Inspector(document: document, viewer: viewer, tab: "개체"))
        var same = false
        for _ in 0..<50 where !same {
            try await Task.sleep(for: .milliseconds(40))
            same = pixels(open) == pixels(fresh)
        }
        if !same, let folder = ProcessInfo.processInfo.environment["HWP_SNAPSHOT_DIR"] {
            for (name, view) in [("open", open), ("fresh", fresh)] as [(String, NSView)] {
                let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
                view.cacheDisplay(in: view.bounds, to: rep)
                try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(folder)/\(name).png"))
            }
        }
        #expect(same)
    }

    /// What the inspector's own controls change shows in it at once, with the picture still
    /// chosen: 글자처럼 취급 off, then 글 뒤로.
    @Test func inspectorFollowsEditsToTheChosenPicture() async throws {
        let document = try HwpDocument(data: fixture("hwpx"))
        let viewer = Viewer()
        viewer.canvas.bind(document)
        _ = try await insertedPicture(document)
        let open = hosted(Inspector(document: document, viewer: viewer, tab: "개체"))
        try await Task.sleep(for: .milliseconds(300))
        for change in [ObjectProps(treatAsChar: false, textWrap: "Square"), ObjectProps(treatAsChar: false, textWrap: "BehindText")] {
            viewer.arrange(change)
            await document.settle()
            let fresh = hosted(Inspector(document: document, viewer: viewer, tab: "개체"))
            var same = false
            for _ in 0..<50 where !same {
                try await Task.sleep(for: .milliseconds(40))
                same = pixels(open) == pixels(fresh)
            }
            #expect(same, "after \(change.textWrap ?? "")")
        }
    }

    private func hosted(_ view: Inspector) -> NSHostingView<some View> {
        let host = NSHostingView(rootView: view.frame(width: 280, height: 1100).background(Color(nsColor: .windowBackgroundColor)))
        let window = NSWindow(contentRect: NSRect(x: -6000, y: -6000, width: 280, height: 1100), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        // Ordered in, as the app's is (SwiftUI starts a view's tasks again only then), out of sight.
        window.orderFrontRegardless()
        host.layoutSubtreeIfNeeded()
        return host
    }
    private func pixels(_ view: NSView) -> Data? {
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep.bitmapData.map { Data(bytes: $0, count: rep.bytesPerRow * rep.pixelsHigh) }
    }
}
