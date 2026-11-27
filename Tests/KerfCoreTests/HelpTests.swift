import Foundation
import XCTest
@testable import KerfCore

final class HelpTests: XCTestCase {
    func testTopicIDsAreUniqueAndFindable() {
        let ids = HelpLibrary.topics.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
        for id in ids { XCTAssertEqual(HelpLibrary.topic(id)?.id, id) }
        XCTAssertNil(HelpLibrary.topic("no-such-topic"))
    }

    func testEveryTopicHasContent() {
        for topic in HelpLibrary.topics {
            XCTAssertFalse(topic.title.isEmpty, topic.id)
            XCTAssertFalse(topic.summary.isEmpty, topic.id)
            XCTAssertFalse(topic.blocks.isEmpty, topic.id)
        }
    }

    func testTextIsValidMarkdown() throws {
        for topic in HelpLibrary.topics {
            for block in topic.blocks {
                let strings: [String]
                switch block {
                case .heading(let s), .text(let s), .tip(let s), .warning(let s): strings = [s]
                case .steps(let list), .bullets(let list): strings = list
                case .keys(let list): strings = list.map(\.action)
                }
                for s in strings {
                    let parsed = try AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
                    XCTAssertFalse(String(parsed.characters).contains("**"), "Unbalanced bold in \(topic.id): \(s)")
                }
            }
        }
    }

    func testSearchMatchesAllWords() {
        XCTAssertEqual(HelpLibrary.search("").count, HelpLibrary.topics.count)
        XCTAssertTrue(HelpLibrary.search("holding tabs").contains { $0.id == "cnc" })
        XCTAssertTrue(HelpLibrary.search("PES").contains { $0.id == "embroidery" })
        XCTAssertTrue(HelpLibrary.search("WEEDING").contains { $0.id == "vinyl" })
        XCTAssertTrue(HelpLibrary.search("zzqx nothing").isEmpty)
    }
}
