/// The brief a model needs to use Septena's MCP tools, shown and copied in
/// Settings ▸ MCP Skills. The tasks brief is `TasksSkill.skill`.
public struct SectionSkill: Sendable, Hashable, Identifiable {
  public let key: String
  /// One-sentence summary of what an AI can do.
  public let summary: String
  /// MCP tool names (in display order).
  public let tools: [Tool]
  /// Markdown body: conventions, examples, gotchas. Rendered as `Text(.init(...))`.
  public let body: String

  public var id: String { key }

  public init(key: String, summary: String, tools: [Tool], body: String) {
    self.key = key
    self.summary = summary
    self.tools = tools
    self.body = body
  }

  public struct Tool: Sendable, Hashable {
    public let name: String
    public let blurb: String
    /// Compact parameter listing, formatted: `required: a, b · optional: c, d (enum: x|y|z)`.
    /// Pass `nil` for tools that take no parameters.
    public let inputs: String?
    public init(_ name: String, _ blurb: String, inputs: String? = nil) {
      self.name = name
      self.blurb = blurb
      self.inputs = inputs
    }
  }

  /// Connection-wide preamble, prepended when the user copies the brief.
  public static let preamble: String = """
  ## Septena MCP

  Connect: `https://api.septena.app/mcp` (sign in with your Septena account)

  The tools read and write your Septena tasks, areas and projects.

  ### Conventions
  - **Dates**: `YYYY-MM-DD`.
  - **IDs**: opaque strings. List before you act, and never make one up.
  """
}
