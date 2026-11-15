import XCTest
import SwiftUI
import AppKit
@testable import DiskScout

@MainActor
final class LayoutTests: XCTestCase {
    /// A split-view column takes its minimum size from its content, measured with no room at all.
    /// Wrapping text that's allowed to grow downwards then reports the height of one character per
    /// line. That once made the window lay itself out thousands of points tall, which pushed the
    /// sidebar, header and inspector off-screen. `layoutContained` is what stops it.
    func testWrappingTextCannotForceAColumnTaller() {
        let text = String(repeating: "Instagram keeps direct messages on its servers. ", count: 6)
        let screen = HStack(alignment: .top, spacing: 8) {
            Text("1").frame(width: 18, height: 18)
            Text(text).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
        }
        .card(padding: 18)
        .frame(maxWidth: 660)
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)

        let bare = NSHostingController(rootView: screen).sizeThatFits(in: .zero)
        XCTAssertGreaterThan(bare.height, 1000, "the problem this guards against")

        let contained = NSHostingController(rootView: screen.layoutContained()).sizeThatFits(in: .zero)
        XCTAssertEqual(contained, .zero)
        // Given real room, it simply fills it.
        let roomy = NSHostingController(rootView: screen.layoutContained()).sizeThatFits(in: CGSize(width: 700, height: 500))
        XCTAssertEqual(roomy, CGSize(width: 700, height: 500))
    }
}
