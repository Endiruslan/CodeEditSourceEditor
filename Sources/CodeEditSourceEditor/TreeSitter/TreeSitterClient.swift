//
//  TreeSitterClient.swift
//  CodeEditSourceEditor
//
//  Created by Khan Winter on 9/12/22.
//

import Foundation
import CodeEditTextView
import CodeEditLanguages
import SwiftTreeSitter
import OSLog
import AppKit

/// # TreeSitterClient
///
/// ``TreeSitterClient`` is an class that manages a tree-sitter syntax tree and provides an API for notifying that
/// tree of edits and querying the tree. This type also conforms to ``HighlightProviding`` to provide syntax
/// highlighting.
///
/// The APIs this object provides can perform either asynchronously or synchronously. All calls to this object must
/// first be dispatched from the main queue to ensure serial access to internal properties. Any synchronous methods
/// can throw an ``TreeSitterClientExecutor/Error/syncUnavailable`` error if an asynchronous or synchronous call is
/// already being made on the object. In those cases it is up to the caller to decide whether or not to retry
/// asynchronously.
///
/// The only exception to the above rule is the ``HighlightProviding`` conformance methods. The methods for that
/// implementation may return synchronously or asynchronously depending on a variety of factors such as document
/// length, edit length, highlight length and if the object is available for a synchronous call.
public final class TreeSitterClient: HighlightProviding {
    static let logger: Logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "", category: "TreeSitterClient")

    enum TreeSitterClientError: Error {
        case invalidEdit
    }

    // MARK: - Properties

    /// A callback to use to efficiently fetch portions of text.
    var readBlock: Parser.ReadBlock?

    /// A callback used to fetch text for queries.
    var readCallback: SwiftTreeSitter.Predicate.TextProvider?

    /// A cached read callback built from an immutable text snapshot taken during setUp.
    /// Used for initial highlight queries to avoid main-thread synchronization.
    /// Cleared on first edit when the snapshot becomes stale.
    internal var cachedReadCallback: SwiftTreeSitter.Predicate.TextProvider?

    /// The internal tree-sitter layer tree object.
    var state: TreeSitterState?

    package var executor: TreeSitterExecutor = .init()

    /// The end point of the previous edit.
    private var oldEndPoint: Point?

    package var pendingEdits: Atomic<[InputEdit]> = Atomic([])

    /// Optional flag to force every operation to be done on the caller's thread.
    package var forceSyncOperation: Bool = false

    public init() { }

    // MARK: - Constants

    public enum Constants {
        /// The maximum amount of limits a cursor can match during a query.
        ///
        /// Used to ensure performance in large files, even though we generally limit the query to the visible range.
        /// Neovim encountered this issue and uses 64 for their limit. Helix uses 256 due to issues with some
        /// languages when using 64.
        /// See: [github.com/neovim](https://github.com/neovim/neovim/issues/14897)
        /// And: [github.com/helix-editor](https://github.com/helix-editor/helix/pull/4830)
        public static var matchLimit = 256

        /// The timeout for parsers to re-check if a task is canceled. This constant represents the period between
        /// checks and is directly related to editor responsiveness.
        public static var parserTimeout: TimeInterval = 0.05

        /// The maximum length of an edit before it must be processed asynchronously
        public static var maxSyncEditLength: Int = 1024

        /// The maximum length a document can be before all queries and edits must be processed asynchronously.
        public static var maxSyncContentLength: Int = 1_000_000

        /// The maximum document length that will be parsed synchronously during initial setup.
        /// Documents at or below this length are parsed on the main thread during setUp for instant highlights.
        public static var maxSyncInitialParseLength: Int = 500_000

        /// The maximum document length for which an NSString snapshot is taken during initial setup.
        /// Documents above maxSyncInitialParseLength but at or below this are parsed asynchronously
        /// using a snapshot to avoid main-thread contention.
        public static var maxSnapshotParseLength: Int = 1_000_000

        /// The maximum length a query can be before it must be performed asynchronously.
        public static var maxSyncQueryLength: Int = 4096

        /// The number of characters to read in a read block.
        ///
        /// This has diminishing returns on the number of times the read block is called as this number gets large.
        public static let charsToReadInBlock: Int = 4096

        /// The duration before a long parse notification is sent.
        public static var longParseTimeout: Duration = .seconds(0.5)

        /// The notification name sent when a long parse is detected.
        public static let longParse: Notification.Name = .init("CodeEditSourceEditor.longParseNotification")

        /// The notification name sent when a long parse is finished.
        public static let longParseFinished: Notification.Name = .init(
            "CodeEditSourceEditor.longParseFinishedNotification"
        )

        /// The duration tasks sleep before checking if they're runnable.
        ///
        /// Lower than 1ms starts causing bad lock contention, much higher reduces responsiveness with diminishing
        /// returns on CPU efficiency.
        public static let taskSleepDuration: Duration = .milliseconds(10)
    }

    // MARK: - Snapshot Helpers

    /// Creates read callbacks from a text snapshot taken on the current (main) thread.
    ///
    /// Since ``NSTextStorage`` is backed by an ``NSMutableString``, any snapshot copy is O(n).
    /// The benefit is that the closures returned here never call ``DispatchQueue.main.sync``,
    /// so long background parses don't block the main thread at all during initial setup.
    ///
    /// - Parameter textContent: An immutable copy of the document text taken on the main thread.
    /// - Returns: A tuple of (readBlock, readCallback) backed by the snapshot.
    private static func makeSnapshotCallbacks(
        from textContent: String
    ) -> (readBlock: Parser.ReadBlock, readCallback: SwiftTreeSitter.Predicate.TextProvider) {
        let utf16 = textContent.utf16
        let utf16Count = utf16.count

        let readBlock: Parser.ReadBlock = { byteOffset, _ in
            let location = byteOffset / 2
            let end = min(location + Constants.charsToReadInBlock, utf16Count)
            guard location < end else { return nil }
            let startIdx = utf16.index(utf16.startIndex, offsetBy: location)
            let endIdx = utf16.index(utf16.startIndex, offsetBy: end)
            return String(utf16[startIdx..<endIdx])?.data(using: String.nativeUTF16Encoding)
        }
        let readCallback: SwiftTreeSitter.Predicate.TextProvider = { range, _ in
            guard range.location >= 0,
                  range.location + range.length <= utf16Count else { return nil }
            let startIdx = utf16.index(utf16.startIndex, offsetBy: range.location)
            let endIdx = utf16.index(utf16.startIndex, offsetBy: range.location + range.length)
            return String(utf16[startIdx..<endIdx])
        }
        return (readBlock, readCallback)
    }

    // MARK: - HighlightProviding

    /// Set up the client with a text view and language.
    /// - Parameters:
    ///   - textView: The text view to use as a data source.
    ///               A weak reference will be kept for the lifetime of this object.
    ///   - codeLanguage: The language to use for parsing.
    public func setUp(textView: TextView, codeLanguage: CodeLanguage) {
        Self.logger.debug("TreeSitterClient setting up with language: \(codeLanguage.id.rawValue, privacy: .public)")

        let liveReadBlock = textView.createReadBlock()
        let liveReadCallback = textView.createReadCallback()
        self.readBlock = liveReadBlock
        self.readCallback = liveReadCallback
        self.cachedReadCallback = nil

        executor.cancelAll(below: .all)

        let documentLength = textView.documentRange.length

        if documentLength <= Constants.maxSyncInitialParseLength || forceSyncOperation {
            // Small documents: parse synchronously on the main thread.
            // Highlights are queryable immediately — no flash.
            let state = TreeSitterState(
                codeLanguage: codeLanguage,
                readCallback: liveReadCallback,
                readBlock: liveReadBlock
            )
            self.state = state
            print("USING SYNC PARSE")
        } else if documentLength <= Constants.maxSnapshotParseLength {
            // Medium documents: parse asynchronously using a text snapshot taken on the main thread.
            // The O(n) copy happens once here; the background parse then runs at full speed with
            // no DispatchQueue.main.sync round-trips per read block call.
            let snapshot = Self.makeSnapshotCallbacks(from: textView.string)
            self.cachedReadCallback = snapshot.readCallback

            let operation = { [weak self] in
                let state = TreeSitterState(
                    codeLanguage: codeLanguage,
                    readCallback: snapshot.readCallback,
                    readBlock: snapshot.readBlock
                )
                self?.state = state
            }
            print("USING SNAPSHOT PARSE")
            executor.execAsync(priority: .reset, operation: operation, onCancel: {})
        } else {
            // Large documents: parse asynchronously with live read blocks.
            let operation = { [weak self] in
                let state = TreeSitterState(
                    codeLanguage: codeLanguage,
                    readCallback: liveReadCallback,
                    readBlock: liveReadBlock
                )
                self?.state = state
            }
            print("USING PURE ASYNC PARSE")
            executor.execAsync(priority: .reset, operation: operation, onCancel: {})
        }
    }

    // MARK: - HighlightProviding

    /// Notifies the highlighter of an edit and in exchange gets a set of indices that need to be re-highlighted.
    /// The returned `IndexSet` should include all indexes that need to be highlighted, including any inserted text.
    /// - Parameters:
    ///   - textView: The text view to use.
    ///   - range: The range of the edit.
    ///   - delta: The length of the edit, can be negative for deletions.
    ///   - completion: The function to call with an `IndexSet` containing all Indices to invalidate.
    public func applyEdit(
        textView: TextView,
        range: NSRange,
        delta: Int,
        completion: @escaping @MainActor (Result<IndexSet, Error>) -> Void
    ) {
        // Clear cached callback on first edit - the snapshot text is now stale.
        self.cachedReadCallback = nil

        let oldEndPoint: Point = self.oldEndPoint ?? textView.pointForLocation(range.max) ?? .zero
        guard let edit = InputEdit(range: range, delta: delta, oldEndPoint: oldEndPoint, textView: textView) else {
            completion(.failure(TreeSitterClientError.invalidEdit))
            return
        }

        let operation = { [weak self] in
            return self?.applyEdit(edit: edit) ?? IndexSet()
        }

        let longEdit = range.length > Constants.maxSyncEditLength
        let longDocument = textView.documentRange.length > Constants.maxSyncContentLength
        let execAsync = longEdit || longDocument

        if !execAsync || forceSyncOperation {
            let result = executor.execSync(operation)
            if case .success(let invalidatedRanges) = result {
                DispatchQueue.dispatchMainIfNot { completion(.success(invalidatedRanges)) }
                return
            }
        }

        if !forceSyncOperation {
            executor.cancelAll(below: .reset) // Cancel all edits, add it to the pending edit queue
            executor.execAsync(
                priority: .edit,
                operation: { completion(.success(operation())) },
                onCancel: { [weak self] in
                    self?.pendingEdits.mutate { edits in
                        edits.append(edit)
                    }
                    DispatchQueue.dispatchMainIfNot {
                        completion(.failure(HighlightProvidingError.operationCancelled))
                    }
                }
            )
        }
    }

    /// Called before an edit is sent. We use this to set the ``oldEndPoint`` variable so tree-sitter knows where
    /// the document used to end.
    /// - Parameters:
    ///   - textView: The text view used.
    ///   - range: The range that will be edited.
    public func willApplyEdit(textView: TextView, range: NSRange) {
        oldEndPoint = textView.pointForLocation(range.max)
    }

    /// Initiates a highlight query.
    /// - Parameters:
    ///   - textView: The text view to use.
    ///   - range: The range to limit the highlights to.
    ///   - completion: Called when the query completes.
    public func queryHighlightsFor(
        textView: TextView,
        range: NSRange,
        completion: @escaping @MainActor (Result<[HighlightRange], Error>) -> Void
    ) {
        let operation = { [weak self] in
            return (self?.queryHighlightsForRange(range: range) ?? []).sorted { $0.range.location < $1.range.location }
        }

        let longQuery = range.length > Constants.maxSyncQueryLength
        let longDocument = textView.documentRange.length > Constants.maxSyncContentLength
        let execAsync = longQuery || longDocument

        if !execAsync || forceSyncOperation {
            let result = executor.execSync(operation)
            if case .success(let highlights) = result {
                DispatchQueue.dispatchMainIfNot { completion(.success(highlights)) }
                return
            }
        }

        if !forceSyncOperation {
            executor.execAsync(
                priority: .access,
                operation: {
                    DispatchQueue.dispatchMainIfNot { completion(.success(operation())) }
                },
                onCancel: {
                    DispatchQueue.dispatchMainIfNot {
                        completion(.failure(HighlightProvidingError.operationCancelled))
                    }
                }
            )
        }
    }
}
