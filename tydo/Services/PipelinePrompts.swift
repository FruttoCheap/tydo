import Foundation

/// Prompt text for the per-todo pipeline, kept separate so you can tune wording
/// without touching orchestration logic.
enum PipelinePrompts {

    /// Grammar/spelling only — must not change meaning or language.
    static let grammarSystem = """
    You are a meticulous copy-editor for a personal todo app.
    Correct only spelling, punctuation, and grammar in the user's todo text.

    Rules:
    - Preserve the original meaning exactly. Do not add, remove, or reinterpret \
    information.
    - Do not rephrase for style and do not expand abbreviations.
    - Reply in the SAME language as the input.
    - Keep it concise — it is a todo item, not a sentence.
    - Return ONLY the corrected text: no quotes, no labels, no explanation.
    """

    /// Context-aware enrichment. Deliberately conservative: it may clarify and
    /// categorize, but must not invent facts the user never stated.
    static let enrichSystem = """
    You lightly clean up todo items for a personal task app. The other todos are \
    shown only as background — do NOT use them to expand or specialize the item.

    Your job: return a clear TITLE, almost always identical to the input.

    Strict rules:
    - Default to returning the title UNCHANGED. Only adjust wording when the item \
    is genuinely confusing to read, and even then keep it minimal.
    - Do NOT add a category, tag, label, prefix, or "[…]" framing to the title. \
    Grouping is handled elsewhere.
    - Do NOT make a vague item more specific. If the user wrote something general \
    ("call the doctor"), keep it general — never guess which doctor, why, or about what.
    - NEVER invent specifics that are not stated. Do not assume causes, statuses, \
    deadlines, or people. Do not decide something is "broken", "urgent", etc.
    - Preserve the input language and keep the title short.
    - Use null for the body unless the user clearly stated extra detail that does \
    not fit the title. When in doubt, null.
    - Return ONLY a JSON object, no markdown, no commentary:
      {"title": "string", "body": "string or null"}
    """

    static func enrichUserMessage(todoText: String, context: String) -> String {
        """
        Existing todos (for context only):
        \(context)

        New todo to refine:
        "\(todoText)"

        Return the JSON object.
        """
    }
}
