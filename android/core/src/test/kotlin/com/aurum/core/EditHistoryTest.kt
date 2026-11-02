package com.aurum.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class EditHistoryTest {
    private fun doc(lookID: String) = TestSupport.document().applyLook(lookID)

    @Test fun undoAndRedo() {
        val history = EditHistory(TestSupport.document())
        history.commit(doc("film.a"))
        history.commit(doc("film.b"))
        assertTrue(history.canUndo)
        assertEquals("film.a", history.undo()?.lookApplications?.first()?.lookID)
        assertEquals(0, history.undo()?.lookApplications?.size)
        assertNull(history.undo())
        assertEquals("film.a", history.redo()?.lookApplications?.first()?.lookID)
    }

    @Test fun committingAfterUndoDropsTheRedoBranch() {
        val history = EditHistory(TestSupport.document())
        history.commit(doc("film.a"))
        history.commit(doc("film.b"))
        history.undo()
        history.commit(doc("noir.a"))
        assertFalse(history.canRedo)
        assertEquals(3, history.snapshots.size)
    }

    @Test fun unchangedCommitIsIgnored() {
        val history = EditHistory(TestSupport.document())
        history.commit(TestSupport.document())
        assertFalse(history.canUndo)
    }

    @Test fun sliderDragIsOneUndoStep() {
        val start = doc("film.a")
        val history = EditHistory(start)
        history.beginTransaction()
        var d = start
        var value = 0.8
        while (value >= 0.2 - 1e-9) {
            d = d.setActiveLookIntensity(value)
            history.update(d)
            assertFalse("no undo while dragging", history.canUndo)
            value -= 0.1
        }
        history.commit(d)
        assertEquals(2, history.snapshots.size)
        assertEquals(start, history.undo())
    }

    @Test fun cancelledTransactionRestoresTheDocument() {
        val start = doc("film.a")
        val history = EditHistory(start)
        history.update(start.setActiveLookIntensity(0.1))
        history.cancelTransaction()
        assertEquals(start, history.current)
        assertFalse(history.canUndo)
    }

    @Test fun historyIsCapped() {
        val history = EditHistory(TestSupport.document(), limit = 5)
        for (i in 0 until 20) history.commit(TestSupport.document().applyLook("film.a", i / 20.0))
        assertEquals(5, history.snapshots.size)
        assertEquals(4, history.cursor)
    }
}
