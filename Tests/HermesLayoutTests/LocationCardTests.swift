import AppKit
import XCTest
@testable import HermesThumbnailUI

@MainActor
final class LocationCardTests: XCTestCase {
    private let a = MediaLocationCard.Coordinate(latitude: 31.3064, longitude: 120.7051)
    private let b = MediaLocationCard.Coordinate(latitude: 37.3349, longitude: -122.0090)

    func testLateResponseCannotReplaceTheNewCoordinatesCaption() async throws {
        var pending: [MediaLocationCard.Coordinate: CheckedContinuation<MediaLocationCard.Place, any Error>] = [:]
        let card = MediaLocationCard { coordinate in
            try await withCheckedThrowingContinuation { pending[coordinate] = $0 }
        }
        card.show(a)
        await Task.yield()
        card.show(b)
        await Task.yield()
        try XCTUnwrap(pending[b]).resume(returning: .init(title: "新地点", address: "新地址"))
        await Task.yield()
        try XCTUnwrap(pending[a]).resume(returning: .init(title: "旧地点", address: "旧地址"))
        await Task.yield()
        XCTAssertEqual(card.coordinate, b)
        XCTAssertEqual(card.displayedTitle, "新地点")
        XCTAssertEqual(card.displayedAddress, "新地址")
        XCTAssertEqual(card.mapView.annotations.first?.coordinate.latitude, b.latitude)
        XCTAssertEqual(card.mapView.annotations.first?.coordinate.longitude, b.longitude)
        XCTAssertTrue(card.resolutionSucceeded)
    }

    func testInspectorRefreshKeepsOneRequestAndHidingCancelsAndResumesIt() async throws {
        var calls = 0
        var pending: [CheckedContinuation<MediaLocationCard.Place, any Error>] = []
        let card = MediaLocationCard { _ in
            calls += 1
            return try await withCheckedThrowingContinuation { pending.append($0) }
        }
        card.show(a)
        await Task.yield()
        card.show(a)
        XCTAssertEqual(calls, 1)
        card.cancelResolution()
        XCTAssertFalse(card.isResolving)
        card.resumeResolution()
        await Task.yield()
        XCTAssertEqual(calls, 2)
        pending[0].resume(returning: .init(title: "取消的地点", address: nil))
        pending[1].resume(returning: .init(title: "当前地点", address: nil))
        await Task.yield()
        card.show(a)
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(card.displayedTitle, "当前地点")
        XCTAssertNil(card.displayedAddress)
    }

    func testNoGPSClearsPinAndTextEvenWithAnUncancellableProvider() async throws {
        var pending: CheckedContinuation<MediaLocationCard.Place, any Error>?
        let card = MediaLocationCard { _ in
            try await withCheckedThrowingContinuation { pending = $0 }
        }
        card.show(a)
        await Task.yield()
        card.show(nil)
        try XCTUnwrap(pending).resume(returning: .init(title: "迟到地点", address: "迟到地址"))
        await Task.yield()
        XCTAssertTrue(card.isHidden)
        XCTAssertNil(card.coordinate)
        XCTAssertEqual(card.displayedTitle, "")
        XCTAssertNil(card.displayedAddress)
        XCTAssertTrue(card.mapView.annotations.isEmpty)
        XCTAssertFalse(card.isResolving)
    }

    func testCaptionWrapsInsideTheSameRoundedCardAndFailureStaysBoundToThePin() async throws {
        _ = NSApplication.shared
        let card = MediaLocationCard { _ in
            .init(title: "一个完整且很长的地点名称", address: "一条完整的系统格式地址，在很窄的信息栏中也必须换行显示，不使用省略号截断")
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 500),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        defer { window.orderOut(nil) }
        let root = NSView()
        window.contentView = root
        root.addSubview(card)
        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            card.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            card.topAnchor.constraint(equalTo: root.topAnchor, constant: 16)
        ])
        window.orderFront(nil)
        card.show(a)
        await Task.yield()
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            window.appearance = NSAppearance(named: appearance)
            for width in [CGFloat(270), 320, 560] {
                window.setContentSize(NSSize(width: width, height: 500))
                root.layoutSubtreeIfNeeded()
                root.layoutSubtreeIfNeeded()
                XCTAssertEqual(card.layer?.cornerRadius, 10)
                XCTAssertEqual(card.layer?.masksToBounds, true)
                XCTAssertEqual(card.mapView.frame.height, 180, accuracy: 0.5)
                for field in card.textFields {
                    let frame = field.convert(field.bounds, to: card)
                    XCTAssertGreaterThanOrEqual(frame.minX, 0)
                    XCTAssertLessThanOrEqual(frame.maxX, card.bounds.width + 0.5)
                    XCTAssertGreaterThanOrEqual(frame.height + 0.5, field.fittingSize.height)
                }
            }
        }
        card.show(b, simulateFailure: true)
        XCTAssertEqual(card.coordinate, b)
        XCTAssertEqual(card.mapView.annotations.first?.coordinate.latitude, b.latitude)
        XCTAssertEqual(card.displayedAddress, "暂时无法获取地点名称")
        XCTAssertFalse(card.resolutionSucceeded)
        XCTAssertFalse(card.isHidden)
    }
}
