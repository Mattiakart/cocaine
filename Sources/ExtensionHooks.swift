// Seams between features built side by side: each one is a closure the feature that owns the capability fills in at launch, and the
// features that use it call it only when it is set (so each can be built, tested and merged on its own).

import Foundation

/// The AI-context basket (Sources/MCP*.swift fills these in). The clipboard and the shelf offer "Use as AI context" when `add` is set.
enum AIContextHook {
    /// Adds items to the basket the user is choosing for AI tools: (kind: "clip" | "file" | "text", id or path, title).
    static var add: (([(kind: String, ref: String, title: String)]) -> Void)?
    /// How many items are in the basket now (for badges).
    static var count: () -> Int = { 0 }
}

/// Uploading shelf files to a cloud service and getting links back (Sources/ShareProviders*.swift fills these in).
enum CloudShareHook {
    /// The configured providers, in menu order: (id, title).
    static var providers: () -> [(id: String, title: String)] = { [] }
    /// Uploads `files` with the provider `id`; the completion gets the share links (or why it failed). Called on the main thread.
    static var upload: ((_ files: [URL], _ provider: String, _ completion: @escaping (Result<[URL], Error>) -> Void) -> Void)?
}

/// Pasting the contents of a clipboard item or snippet into the app in front (Sources/Clipboard*.swift fills this in).
enum PasteHook {
    static var paste: ((_ clipID: String, _ plain: Bool) -> Void)?
}
