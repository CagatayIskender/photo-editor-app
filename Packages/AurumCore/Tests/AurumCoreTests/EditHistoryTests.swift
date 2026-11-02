import XCTest
@testable import AurumCore

final class EditHistoryTests: XCTestCase {
    private func doc(lookID: String) -> EditDocument {
        var d = TestSupport.document()
        d.applyLook(lookID)
        return d
    }

    func testUndoAndRedo() {
        var history = EditHistory(initial: TestSupport.document())
        history.commit(doc(lookID: "film.a"))
        history.commit(doc(lookID: "film.b"))
        XCTAssertTrue(history.canUndo)
        XCTAssertEqual(history.undo()?.lookApplications.first?.lookID, "film.a")
        XCTAssertEqual(history.undo()?.lookApplications.count, 0)
        XCTAssertNil(history.undo())
        XCTAssertEqual(history.redo()?.lookApplications.first?.lookID, "film.a")
    }

    func testCommittingAfterUndoDropsTheRedoBranch() {
        var history = EditHistory(initial: TestSupport.document())
        history.commit(doc(lookID: "film.a"))
        history.commit(doc(lookID: "film.b"))
        history.undo()
        history.commit(doc(lookID: "noir.a"))
        XCTAssertFalse(history.canRedo)
        XCTAssertEqual(history.snapshots.count, 3)
    }

    func testUnchangedCommitIsIgnored() {
        var history = EditHistory(initial: TestSupport.document())
        history.commit(TestSupport.document())
        XCTAssertFalse(history.canUndo)
    }

    func testSliderDragIsOneUndoStep() {
        let start = doc(lookID: "film.a")
        var history = EditHistory(initial: start)
        history.beginTransaction()
        var d = start
        for value in stride(from: 0.8, through: 0.2, by: -0.1) {
            d.setActiveLookIntensity(value)
            history.update(d)
            XCTAssertFalse(history.canUndo, "no undo while dragging")
        }
        history.commit(d)
        XCTAssertEqual(history.snapshots.count, 2)
        XCTAssertEqual(history.undo(), start)
    }

    func testCancelledTransactionRestoresTheDocument() {
        let start = doc(lookID: "film.a")
        var history = EditHistory(initial: start)
        var d = start
        d.setActiveLookIntensity(0.1)
        history.update(d)
        history.cancelTransaction()
        XCTAssertEqual(history.current, start)
        XCTAssertFalse(history.canUndo)
    }

    func testHistoryIsCapped() {
        var history = EditHistory(initial: TestSupport.document(), limit: 5)
        for i in 0..<20 {
            var d = TestSupport.document()
            d.applyLook("film.a", intensity: Double(i) / 20)
            history.commit(d)
        }
        XCTAssertEqual(history.snapshots.count, 5)
        XCTAssertEqual(history.cursor, 4)
    }
}
