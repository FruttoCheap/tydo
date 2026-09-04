import Foundation

/// Prompt for turning a whole document into a list of actionable todos — the
/// document-import front door that feeds the same manual-capture path.
enum DocumentPrompts {
    static let extractSystem = """
    You extract actionable to-do items from a document for a personal task app.

    Rules:
    - List every concrete action, task, or commitment a person needs to do.
    - Ignore narrative, background, or descriptive text that isn't an action.
    - Split multi-part sentences into separate items; one action per item.
    - Keep each item short and self-contained, in the SAME language as the document.
    - Do NOT invent items the text doesn't support.
    - Return ONLY a JSON array of strings, no markdown, no commentary. \
    Example: ["Call the plumber", "Send the invoice to Marco"]
    - If there are no actionable items, return [].
    """
}
