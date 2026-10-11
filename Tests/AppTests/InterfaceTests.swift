import Testing
import Foundation
import AppKit
import SwiftUI
@testable import HwaljaKit

/// The 빠른 메뉴 (right click), and what the menus offer.
@MainActor
struct InterfaceTests {
    /// The 빠른 메뉴 offers what fits the selection.
    @Test func quickMenuFollowsTheSelection() {
        let titles = { (context: EditingContext) in MenuItems.quickMenu(Viewer(), context).compactMap { $0?.title } }
        let text = titles(EditingContext(hasSelection: true, hasRange: true))
        #expect(text.starts(with: ["오려두기", "복사하기", "붙여넣기", "삭제"]) && text.contains("글자 모양…") && text.contains("문자표…"))
        #expect(!text.contains("개체 속성…"))
        let picture = titles(EditingContext(hasSelection: true, object: .picture))
        #expect(picture.contains("원본 그림으로") && picture.last == "개체 속성…" && !picture.contains("글자 모양…"))
        #expect(titles(EditingContext(hasSelection: true, inTable: true)).contains("표/셀 속성…"))
    }

    /// In a 하이퍼링크 the 빠른 메뉴 offers 하이퍼링크 고치기 and 지우기; links go to web addresses.
    @Test func quickMenuOffersLinkCommandsInALink() {
        let link = Hyperlink(text: "한컴", uri: "https://www.hancom.com")
        let titles = MenuItems.quickMenu(Viewer(), EditingContext(hasSelection: true), link: link).compactMap { $0?.title }
        #expect(titles.contains("하이퍼링크 고치기…") && titles.contains("하이퍼링크 지우기"))
        #expect(!MenuItems.quickMenu(Viewer(), EditingContext(hasSelection: true)).contains { $0?.title == "하이퍼링크 지우기" })
        #expect(Hyperlink.isWebAddress("https://www.hancom.com/a?b#c") && Hyperlink.isWebAddress("HTTP://x.kr"))
        #expect(!Hyperlink.isWebAddress("www.hancom.com") && !Hyperlink.isWebAddress("mailto:a@b.c")
            && !Hyperlink.isWebAddress("https:// a.b") && !Hyperlink.isWebAddress("https://"))
    }

    @Test func quickMenuOffersDeletionForObjects() {
        let titles = MenuItems.quickMenu(Viewer(), EditingContext(hasSelection: true, object: .shape)).compactMap { $0?.title }
        #expect(titles.contains("삭제"))
    }

    @Test func quickMenuKeepsCopyButDisablesMutationsInLockedDocuments() throws {
        // A 배포용 문서 has no body or table to edit, so its context has neither.
        let context = EditingContext(hasSelection: true, hasRange: true, locked: true)
        let items = MenuItems.quickMenu(Viewer(), context).compactMap { $0 }
        let enabled = { (title: String) in items.first { $0.title == title }?.enabled }
        #expect(enabled("복사하기") == true)
        #expect(enabled("오려두기") == false)
        #expect(enabled("붙여넣기") == false)
        #expect(enabled("삭제") == false)
    }
}
