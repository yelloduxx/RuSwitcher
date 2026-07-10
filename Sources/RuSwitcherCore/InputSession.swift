import Foundation

public enum EditorIntegrity: Equatable, Sendable {
    case clean
    case invalidated
}

public enum InputSessionState: Equatable, Sendable {
    case idle(revision: UInt64)
    case typing(revision: UInt64)
    case invalidated(revision: UInt64)
    case committing(revision: UInt64)
}

public enum InputEvent: Equatable, Sendable {
    case printable(TypedKey)
    case plainBackspace
    case modifiedDeletion
    case boundary(InputBoundary)
    case navigation
    case clipboardCommand
    case undo
    case focusChanged
    case tapRecovered
    case external
}

public enum InputBoundary: Equatable, Sendable {
    case space(count: Int)
    case enter
    case tab
    case punctuation(String)

    public var text: String {
        switch self {
        case let .space(count):
            return String(repeating: " ", count: max(1, count))
        case .enter:
            return "\n"
        case .tab:
            return "\t"
        case let .punctuation(text):
            return text
        }
    }

    /// Space is consumed and replayed after the replacement. Enter and Tab keep
    /// their native application semantics and are passed through.
    public var shouldConsumeOriginalEvent: Bool {
        if case .space = self { return true }
        return false
    }

    /// Space is replayed as a separate marked key event after replacement.
    public var replayText: String {
        if case .space = self { return text }
        return ""
    }

    public var isIncludedInTokenKeys: Bool {
        if case .punctuation = self { return true }
        return false
    }
}

public struct InputContextToken: Equatable, Sendable {
    public let text: String
    public let language: String?
    public let wasConverted: Bool

    public init(text: String, language: String? = nil, wasConverted: Bool = false) {
        self.text = text
        self.language = language
        self.wasConverted = wasConverted
    }
}

public struct FocusedElementIdentity: Equatable, Sendable {
    public let processID: Int32
    public let bundleID: String?
    public let identifier: String?

    public init(processID: Int32, bundleID: String?, identifier: String? = nil) {
        self.processID = processID
        self.bundleID = bundleID
        self.identifier = identifier
    }
}

public struct TokenSnapshot: Equatable, Sendable {
    public let keys: [TypedKey]
    public let context: [InputContextToken]
    public let boundary: InputBoundary
    public let focus: FocusedElementIdentity
    public let sequence: UInt64
    public let capturedAt: Date
    public let languageState: TypingLanguageState
    public let languageBelief: LanguageBelief
    public let editRevision: UInt64
    public let integrity: EditorIntegrity

    public var producedText: String? {
        let values = keys.compactMap(\.producedText)
        return values.count == keys.count ? values.joined() : nil
    }

    public var sourceLayoutID: String? {
        let ids = Set(keys.compactMap(\.sourceLayoutID))
        return ids.count == 1 ? ids.first : nil
    }

    public var deliveredKeyCount: Int {
        max(0, keys.count - (boundary.isIncludedInTokenKeys ? 1 : 0))
    }

    public init(
        keys: [TypedKey],
        context: [InputContextToken],
        boundary: InputBoundary,
        focus: FocusedElementIdentity,
        sequence: UInt64,
        capturedAt: Date = Date(),
        languageState: TypingLanguageState = .neutral,
        languageBelief: LanguageBelief = .neutral,
        editRevision: UInt64 = 0,
        integrity: EditorIntegrity = .clean
    ) {
        self.keys = keys
        self.context = context
        self.boundary = boundary
        self.focus = focus
        self.sequence = sequence
        self.capturedAt = capturedAt
        self.languageState = languageState
        self.languageBelief = languageBelief
        self.editRevision = editRevision
        self.integrity = integrity
    }
}

public struct TokenDraft: Equatable, Sendable {
    public let keys: [TypedKey]
    public let context: [InputContextToken]
    public let focus: FocusedElementIdentity
    public let sequence: UInt64
    public let languageState: TypingLanguageState
    public let languageBelief: LanguageBelief
    public let editRevision: UInt64
    public let integrity: EditorIntegrity

    public init(
        keys: [TypedKey],
        context: [InputContextToken],
        focus: FocusedElementIdentity,
        sequence: UInt64,
        languageState: TypingLanguageState,
        languageBelief: LanguageBelief,
        editRevision: UInt64,
        integrity: EditorIntegrity
    ) {
        self.keys = keys
        self.context = context
        self.focus = focus
        self.sequence = sequence
        self.languageState = languageState
        self.languageBelief = languageBelief
        self.editRevision = editRevision
        self.integrity = integrity
    }

    public var sourceLayoutID: String? {
        let ids = Set(keys.compactMap(\.sourceLayoutID))
        return ids.count == 1 ? ids.first : nil
    }
}

public struct TokenHandlingResult: Equatable, Sendable {
    public let consumeBoundary: Bool
    public let finalizeToken: Bool
    public let resolvedText: String?
    public let resolvedLanguage: String?
    public let wasConverted: Bool
    public let invalidateSession: Bool

    public static let passThrough = TokenHandlingResult(
        consumeBoundary: false,
        finalizeToken: true,
        resolvedText: nil,
        resolvedLanguage: nil,
        wasConverted: false,
        invalidateSession: false
    )

    public init(
        consumeBoundary: Bool,
        finalizeToken: Bool = true,
        resolvedText: String?,
        resolvedLanguage: String?,
        wasConverted: Bool,
        invalidateSession: Bool = false
    ) {
        self.consumeBoundary = consumeBoundary
        self.finalizeToken = finalizeToken
        self.resolvedText = resolvedText
        self.resolvedLanguage = resolvedLanguage
        self.wasConverted = wasConverted
        self.invalidateSession = invalidateSession
    }
}

/// Pure keystroke/session state. A completed token is copied into an immutable
/// snapshot before any callback runs, so later key events cannot mutate the work.
public struct InputSession: Equatable, Sendable {
    public private(set) var currentKeys: [TypedKey] = []
    public private(set) var context: [InputContextToken] = []
    public private(set) var sequence: UInt64 = 0
    public private(set) var languageState: TypingLanguageState = .neutral
    public private(set) var languageBelief: LanguageBelief = .neutral
    public private(set) var editRevision: UInt64 = 0
    public private(set) var integrity: EditorIntegrity = .clean
    public private(set) var state: InputSessionState = .idle(revision: 0)
    public let contextLimit: Int

    public init(contextLimit: Int = 5) {
        self.contextLimit = max(1, contextLimit)
    }

    public func draft(focus: FocusedElementIdentity) -> TokenDraft? {
        guard !currentKeys.isEmpty else { return nil }
        return TokenDraft(
            keys: currentKeys,
            context: context,
            focus: focus,
            sequence: sequence,
            languageState: languageState,
            languageBelief: languageBelief,
            editRevision: editRevision,
            integrity: integrity
        )
    }

    public mutating func append(_ key: TypedKey) {
        sequence &+= 1
        if integrity == .invalidated {
            currentKeys.removeAll(keepingCapacity: true)
            integrity = .clean
        }
        currentKeys.append(key)
        state = .typing(revision: editRevision)
    }

    public mutating func removeLast() {
        sequence &+= 1
        editRevision &+= 1
        if !currentKeys.isEmpty {
            currentKeys.removeLast()
            integrity = .clean
            state = currentKeys.isEmpty
                ? .idle(revision: editRevision)
                : .typing(revision: editRevision)
        } else {
            invalidate(clearContext: true, incrementRevision: false)
        }
    }

    public mutating func noteExternalEvent() {
        sequence &+= 1
        if currentKeys.isEmpty {
            integrity = .clean
            state = .idle(revision: editRevision)
        }
    }

    public mutating func handle(_ event: InputEvent) {
        switch event {
        case let .printable(key): append(key)
        case .plainBackspace: removeLast()
        case .modifiedDeletion, .navigation, .clipboardCommand, .undo, .focusChanged, .tapRecovered:
            invalidate(clearContext: true)
        case .boundary:
            noteExternalEvent()
        case .external:
            invalidate(clearContext: false)
        }
    }

    public mutating func invalidate(clearContext: Bool, incrementRevision: Bool = true) {
        sequence &+= 1
        if incrementRevision { editRevision &+= 1 }
        currentKeys.removeAll(keepingCapacity: true)
        integrity = .invalidated
        state = .invalidated(revision: editRevision)
        if clearContext {
            context.removeAll(keepingCapacity: true)
            languageState = .neutral
            languageBelief = .neutral
        }
    }

    public mutating func beginCommit(expectedRevision: UInt64) -> Bool {
        guard expectedRevision == editRevision, integrity == .clean, !currentKeys.isEmpty else { return false }
        state = .committing(revision: editRevision)
        return true
    }

    public func snapshot(boundary: InputBoundary, focus: FocusedElementIdentity) -> TokenSnapshot? {
        guard !currentKeys.isEmpty else { return nil }
        return TokenSnapshot(
            keys: currentKeys,
            context: context,
            boundary: boundary,
            focus: focus,
            sequence: sequence,
            languageState: languageState,
            languageBelief: languageBelief,
            editRevision: editRevision,
            integrity: integrity
        )
    }

    public mutating func complete(
        resolvedText: String?,
        language: String?,
        wasConverted: Bool
    ) {
        sequence &+= 1
        if let resolvedText, !resolvedText.isEmpty {
            context.append(InputContextToken(
                text: resolvedText,
                language: language,
                wasConverted: wasConverted
            ))
            if context.count > contextLimit {
                context.removeFirst(context.count - contextLimit)
            }
        }
        languageState.observe(language: language, weight: wasConverted ? 1.4 : 1.0)
        languageBelief.observe(language: language, weight: wasConverted ? 1.4 : 1.0)
        currentKeys.removeAll(keepingCapacity: true)
        integrity = .clean
        state = .idle(revision: editRevision)
    }

    public mutating func reset(keepContext: Bool = false) {
        sequence &+= 1
        editRevision &+= 1
        currentKeys.removeAll(keepingCapacity: true)
        integrity = .clean
        state = .idle(revision: editRevision)
        if !keepContext {
            context.removeAll(keepingCapacity: true)
            languageState = .neutral
            languageBelief = .neutral
        }
    }
}
