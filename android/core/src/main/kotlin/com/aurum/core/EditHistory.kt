package com.aurum.core

import kotlin.math.max

/**
 * Undo and redo as a list of snapshots, with the same transaction model as
 * iOS: a continuous gesture calls [beginTransaction], [update] while it runs
 * and [commit] at the end, which records one undo step.
 *
 * Mutable (unlike the documents it holds); the Studio keeps one per session.
 */
open class Undoable<T>(initial: T, limit: Int = 100) {
    val limit: Int = max(2, limit)
    private val _snapshots = mutableListOf(initial)
    val snapshots: List<T> get() = _snapshots
    var cursor: Int = 0
        private set
    private var transactionBase: T? = null
    private var inTransaction = false

    /** The value as it is now, including any change in progress. */
    val current: T get() = _snapshots[cursor]
    val canUndo: Boolean get() = cursor > 0 && !inTransaction
    val canRedo: Boolean get() = cursor < _snapshots.size - 1 && !inTransaction
    val isInTransaction: Boolean get() = inTransaction

    /** Records a finished change as one step; an unchanged value is ignored. */
    fun commit(value: T) {
        if (inTransaction) {
            @Suppress("UNCHECKED_CAST")
            val base = transactionBase as T
            inTransaction = false
            transactionBase = null
            _snapshots[cursor] = base
            if (value == base) return
        } else if (value == current) {
            return
        }
        push(value)
    }

    fun beginTransaction() {
        if (inTransaction) return
        transactionBase = current
        inTransaction = true
    }

    /** Shows an in-progress value without creating an undo step. */
    fun update(value: T) {
        if (!inTransaction) beginTransaction()
        _snapshots[cursor] = value
    }

    /** Abandons a continuous change and restores the value from before it. */
    fun cancelTransaction() {
        if (!inTransaction) return
        @Suppress("UNCHECKED_CAST")
        _snapshots[cursor] = transactionBase as T
        transactionBase = null
        inTransaction = false
    }

    private fun push(value: T) {
        while (_snapshots.size > cursor + 1) _snapshots.removeAt(_snapshots.size - 1)
        _snapshots.add(value)
        if (_snapshots.size > limit) repeat(_snapshots.size - limit) { _snapshots.removeAt(0) }
        cursor = _snapshots.size - 1
    }

    fun undo(): T? {
        if (!canUndo) return null
        cursor -= 1
        return current
    }

    fun redo(): T? {
        if (!canRedo) return null
        cursor += 1
        return current
    }
}

/** Undo history for photo edits. */
class EditHistory(initial: EditDocument, limit: Int = DEFAULT_LIMIT) : Undoable<EditDocument>(initial, limit) {
    companion object {
        const val DEFAULT_LIMIT = 100
    }
}
