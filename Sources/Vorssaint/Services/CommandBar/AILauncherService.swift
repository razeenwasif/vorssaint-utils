// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import Foundation

/// Ported AI Launcher catalogue: desktop AI apps (including Baryon) and
/// terminal CLI agents launched inside Ghostty (or Terminal.app fallback).
struct AILauncherTool: Identifiable, Equatable {
    enum Launch: Equatable {
        case app(paths: [String])
        case cli(command: String, iconPath: String)
    }

    let id: String
    let name: String
    let subtitle: String
    let launch: Launch

    var isCLI: Bool {
        if case .cli = launch { return true }
        return false
    }

    var resolvedAppPath: String? {
        switch launch {
        case .app(let paths):
            return paths.first { path in
                let expanded = (path as NSString).expandingTildeInPath
                return FileManager.default.fileExists(atPath: expanded)
            }.map { ($0 as NSString).expandingTildeInPath }
        case .cli:
            return nil
        }
    }

    var iconPath: String {
        switch launch {
        case .app(let paths):
            return resolvedAppPath ?? ((paths.first ?? "") as NSString).expandingTildeInPath
        case .cli(_, let path):
            let expanded = (path as NSString).expandingTildeInPath
            return FileManager.default.fileExists(atPath: expanded) ? expanded : "/Applications/Ghostty.app"
        }
    }

    var isInstalled: Bool {
        switch launch {
        case .app:
            return resolvedAppPath != nil
        case .cli:
            return true
        }
    }
}

final class AILauncherService: ObservableObject {
    static let shared = AILauncherService()

    static let tools: [AILauncherTool] = [
        AILauncherTool(
            id: "baryon",
            name: "Baryon",
            subtitle: "Fairy AI companion",
            launch: .app(paths: ["~/Applications/Baryon.app", "/Applications/Baryon.app"])
        ),
        AILauncherTool(
            id: "claude",
            name: "Claude",
            subtitle: "Chat, Cowork & Code",
            launch: .app(paths: ["/Applications/Claude.app"])
        ),
        AILauncherTool(
            id: "claude-science",
            name: "Claude Science",
            subtitle: "Research workspace",
            launch: .app(paths: ["/Applications/Claude Science.app"])
        ),
        AILauncherTool(
            id: "codex",
            name: "ChatGPT Codex",
            subtitle: "OpenAI desktop",
            launch: .app(paths: ["/Applications/ChatGPT.app"])
        ),
        AILauncherTool(
            id: "gemini",
            name: "Gemini",
            subtitle: "Google desktop · Antigravity",
            launch: .app(paths: ["/Applications/Gemini.app"])
        ),
        AILauncherTool(
            id: "deepseek",
            name: "DeepSeek Harness",
            subtitle: "DeepSeek desktop",
            launch: .app(paths: ["/Applications/DeepSeek Harness.app"])
        ),
        AILauncherTool(
            id: "grok",
            name: "Grok Bot",
            subtitle: "xAI desktop",
            launch: .app(paths: ["/Applications/Grok Bot.app"])
        ),
        AILauncherTool(
            id: "kimi",
            name: "Kimi",
            subtitle: "Moonshot desktop",
            launch: .app(paths: ["/Applications/Kimi.app"])
        ),
        AILauncherTool(
            id: "claude-code",
            name: "Claude Code",
            subtitle: "claude",
            launch: .cli(command: "claude", iconPath: "/Applications/Claude.app")
        ),
        AILauncherTool(
            id: "codex-cli",
            name: "Codex CLI",
            subtitle: "codex",
            launch: .cli(command: "codex", iconPath: "/Applications/ChatGPT.app")
        ),
        AILauncherTool(
            id: "gemini-cli",
            name: "Gemini CLI",
            subtitle: "gemini",
            launch: .cli(command: "gemini", iconPath: "/Applications/Gemini.app")
        ),
    ]

    /// The PI / Lab Engineer / Sandbox agents from ~/AGENTS.md.
    static let researchTrioIDs = ["claude", "codex", "gemini"]

    @Published var cliFolder: URL {
        didSet {
            UserDefaults.standard.set(cliFolder.path, forKey: "cliFolder")
        }
    }

    private init() {
        let saved = UserDefaults.standard.string(forKey: "cliFolder")
        let fallback = (NSHomeDirectory() as NSString).appendingPathComponent("Github")
        cliFolder = URL(fileURLWithPath: (saved?.isEmpty == false ? saved : nil) ?? fallback)
    }

    var desktopApps: [AILauncherTool] {
        Self.tools.filter { !$0.isCLI }
    }

    var cliAgents: [AILauncherTool] {
        Self.tools.filter(\.isCLI)
    }

    func launch(_ tool: AILauncherTool) {
        guard tool.isInstalled else {
            NSSound.beep()
            return
        }
        switch tool.launch {
        case .app:
            guard let path = tool.resolvedAppPath else {
                NSSound.beep()
                return
            }
            let url = URL(fileURLWithPath: path)
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                if error != nil { DispatchQueue.main.async { NSSound.beep() } }
            }
        case .cli(let command, _):
            runInTerminal(command, folder: cliFolder)
        }
    }

    func launch(at index: Int) {
        guard Self.tools.indices.contains(index) else { return }
        launch(Self.tools[index])
    }

    func launchResearchTrio() {
        for id in Self.researchTrioIDs {
            if let tool = Self.tools.first(where: { $0.id == id }), tool.isInstalled {
                launch(tool)
            }
        }
        QuickToolHUD.show(icon: "sparkles.rectangle.stack", message: "Research Trio launched")
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = cliFolder
        panel.prompt = "Use Folder"
        panel.message = "Terminal agents (Claude Code, Codex CLI, Gemini CLI) start in this folder."
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            cliFolder = url
            QuickToolHUD.show(icon: "folder", message: url.lastPathComponent)
        }
    }

    /// Opens a new Ghostty window running `command` in a login shell, falling back to Terminal.app.
    private func runInTerminal(_ command: String, folder: URL) {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let dir = folder.path.replacingOccurrences(of: "'", with: "'\\''")
        let ghostty = URL(fileURLWithPath: "/Applications/Ghostty.app")
        if FileManager.default.fileExists(atPath: ghostty.path) {
            let config = NSWorkspace.OpenConfiguration()
            config.createsNewApplicationInstance = true
            config.arguments = ["-e", shell, "-lic", "cd '\(dir)' && \(command); exec \(shell) -l"]
            NSWorkspace.shared.openApplication(at: ghostty, configuration: config)
        } else {
            let source = """
            tell application "Terminal"
                activate
                do script "cd '\(dir)' && \(command)"
            end tell
            """
            NSAppleScript(source: source)?.executeAndReturnError(nil)
        }
    }
}
