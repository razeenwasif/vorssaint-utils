// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import SwiftUI

/// Notch-integrated AI Launcher mode: launches installed AI desktop apps,
/// terminal CLI agents in Ghostty under `cliFolder`, and the Research Trio (⌘↩).
struct NotchAILauncherView: View {
    @ObservedObject var service: AILauncherService
    @ObservedObject var notch: NotchService
    let size: CGSize
    var interactive = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                sectionHeader("AI APPS")
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 156, maximum: 220), spacing: 8)], spacing: 6) {
                    ForEach(Array(service.desktopApps.enumerated()), id: \.element.id) { index, tool in
                        toolTile(tool, shortcutIndex: index)
                    }
                }

                sectionHeader("TERMINAL AGENTS · \(service.cliFolder.lastPathComponent)")
                    .padding(.top, 2)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 156, maximum: 220), spacing: 8)], spacing: 6) {
                    let appCount = service.desktopApps.count
                    ForEach(Array(service.cliAgents.enumerated()), id: \.element.id) { offset, tool in
                        toolTile(tool, shortcutIndex: appCount + offset)
                    }
                }
            }
            .padding(.horizontal, 4)
            .padding(.bottom, 6)
        }
        .scrollIndicators(.hidden)
        .frame(width: size.width, height: size.height, alignment: .top)
        .notchBand(leading: {
            if interactive {
                Button {
                    service.chooseFolder()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "folder")
                            .font(.system(size: 11, weight: .semibold))
                        Text(service.cliFolder.lastPathComponent)
                            .font(.system(size: 11.5, weight: .medium))
                            .lineLimit(1)
                    }
                    .foregroundStyle(.white.opacity(0.8))
                    .padding(.horizontal, 9)
                    .frame(height: 26)
                    .background(Color.white.opacity(0.08), in: Capsule())
                }
                .buttonStyle(.plain)
                .help("Terminal agents start in \(service.cliFolder.path)")
            }
        }, trailing: {
            if interactive {
                Button {
                    notch.collapse()
                    service.launchResearchTrio()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 10.5, weight: .semibold))
                        Text("Trio")
                            .font(.system(size: 11, weight: .semibold))
                        Text("⌘↩")
                            .font(.system(size: 9.5, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.55))
                    }
                    .foregroundStyle(Color(red: 0.45, green: 0.72, blue: 1.0))
                    .padding(.horizontal, 9)
                    .frame(height: 26)
                    .background(Color(red: 0.16, green: 0.42, blue: 0.96).opacity(0.22), in: Capsule())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.return, modifiers: .command)
                .help("Launch Claude, ChatGPT Codex, and Gemini together")
            }
        })
        .background {
            if interactive {
                ForEach(0..<min(10, AILauncherService.tools.count), id: \.self) { index in
                    Button("") {
                        notch.collapse()
                        service.launch(at: index)
                    }
                    .keyboardShortcut(KeyEquivalent(Character("\((index + 1) % 10)")), modifiers: .command)
                    .opacity(0)
                    .frame(width: 0, height: 0)
                }
            }
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 9.5, weight: .bold))
            .tracking(0.6)
            .foregroundStyle(.white.opacity(0.38))
            .padding(.horizontal, 4)
    }

    private func toolTile(_ tool: AILauncherTool, shortcutIndex: Int) -> some View {
        Button {
            guard interactive else { return }
            notch.collapse()
            service.launch(tool)
        } label: {
            HStack(spacing: 9) {
                Image(nsImage: CommandBarIconCache.icon(forPath: tool.iconPath))
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 24, height: 24)
                    .overlay(alignment: .bottomTrailing) {
                        if tool.isCLI {
                            Image(systemName: "terminal.fill")
                                .font(.system(size: 7.5, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(2)
                                .background(.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 3))
                                .offset(x: 2, y: 2)
                        }
                    }

                VStack(alignment: .leading, spacing: 1) {
                    Text(tool.name)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(tool.isInstalled ? tool.subtitle : "Not installed")
                        .font(.system(size: 10, design: tool.isCLI ? .monospaced : .default))
                        .foregroundStyle(.white.opacity(tool.isInstalled ? 0.52 : 0.32))
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                if shortcutIndex < 10 {
                    Text("⌘\((shortcutIndex + 1) % 10)")
                        .font(.system(size: 9.5, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.34))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .modifier(NotchControlSurface(cornerRadius: 12, interactive: interactive && tool.isInstalled))
            .opacity(tool.isInstalled ? 1 : 0.45)
        }
        .buttonStyle(NotchButtonStyle(cornerRadius: 12, lifts: interactive && tool.isInstalled))
        .disabled(!interactive || !tool.isInstalled)
    }
}
