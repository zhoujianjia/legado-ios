import Foundation

// legado-E / MD3 `SourceCallBack` events the reader sends (`SourceCallBackService`):
// startRead when the book opens, saveRead from its own progress saves, endRead on a real exit.
extension ReaderView {

    /// The online book on screen: the shelf record, or the reader's snapshot of a book read
    /// without adding it.
    private var callBackBook: ReadingBook? {
        let current = book ?? snapshotBook
        guard let current, current.isOnline else { return nil }
        return current
    }

    func notifySourceStartRead() {
        // However the reader is left later, its source hears endRead once.
        readerNavigator?.readerClosingHandler = { notifySourceEndRead() }
        guard !sourceReadStarted, !isRestoringPosition, let book = callBackBook else { return }
        sourceReadStarted = true
        let position = sourceCallBackPosition
        let chapter = sourceCallBackChapter(in: book, position: position)
        SourceCallBackService.notify(
            .startRead, book: book, chapter: chapter.map(SourceCallBackService.chapterSnapshot),
            chapterID: chapter?.id, position: position,
            positionStore: dependencies.readingPositionStore, store: store
        )
    }

    func notifySourceSaveRead(isPageTurn: Bool) {
        guard let book = callBackBook else { return }
        let position = sourceCallBackPosition
        SourceCallBackService.noteSaveRead(book: book, chapter: sourceCallBackChapter(in: book, position: position),
            isPageTurn: isPageTurn, store: store, position: position, positionStore: dependencies.readingPositionStore)
    }

    /// From the real exit — the coordinator's close, or `dismissReaderPresentation` for a
    /// reader presented without one — not `onDisappear`, which also fires when the reader is
    /// only covered by a sheet or a pushed page.
    func notifySourceEndRead() {
        guard let book = callBackBook else { return }
        let position = sourceCallBackPosition
        let chapter = sourceCallBackChapter(in: book, position: position)
        SourceCallBackService.notify(
            .endRead, book: book, chapter: chapter.map(SourceCallBackService.chapterSnapshot),
            chapterID: chapter?.id, position: position,
            positionStore: dependencies.readingPositionStore, store: store
        )
    }

    /// Copy the actual Navigator/visible-engine position; this does not save or
    /// flush it. Before restore completes the service reads the same file owner.
    private var sourceCallBackPosition: CoreTextReadingPosition? {
        guard !isRestoringPosition else { return nil }
        if let engine = epubRenderer.engine, usesCoreTextEPUB {
            let shown = displayedCoreTextPosition(in: engine)
            return .init(spineIndex: shown.spineIndex, charOffset: shown.charOffset)
        }
        return readerSessionCoordinator?.navigator.currentLocation
    }

    private func sourceCallBackChapter(in book: ReadingBook, position: CoreTextReadingPosition?) -> OnlineChapterRef? {
        guard let position else { return currentOnlineChapter }
        guard let chapters = book.onlineChapters, chapters.indices.contains(position.spineIndex) else { return nil }
        return chapters[position.spineIndex]
    }

    /// The online book's source, for its `customButton`.
    var readerSource: BookSource? {
        guard let id = callBackBook?.bookSourceId else { return nil }
        return BookSourceStore.shared.source(id: id)
    }

    /// The reader menu's 自訂按鈕 (legado `ReadMenu.tvCustomBtn`): clickCustomButton with the
    /// chapter on screen. A page the script builds shows in the 段評 sheet.
    func runSourceCustomButton() {
        guard let book = callBackBook, let source = readerSource else { return }
        let chapter = currentOnlineChapter.map(SourceCallBackService.chapterSnapshot)
        Task { @MainActor in
            let outcome = await SourceCallBackService.tap(
                .clickCustomButton, source: source,
                book: SourceCallBackService.snapshot(of: book, chapter: chapter),
                runtimeVariables: book.runtimeVariables ?? [:], chapter: chapter
            )
            if let page = outcome.page {
                reviewTarget = page
            }
        }
    }
}
