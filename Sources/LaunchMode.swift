import Foundation

/// Central place to determine which mode this process was launched in.
/// Claude Desktop launches this binary as `AIChalkboard --mcp`; a normal GUI
/// launch passes no argument. Kept in the core module because both lifecycle
/// policy and cross-process quit scoping depend on the same answer.
public enum LaunchMode {
    public static let isMCPMode = CommandLine.arguments.contains("--mcp")
}
