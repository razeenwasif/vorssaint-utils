// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import SwiftUI

/// Searchable Dynamic Island cheat sheet listing live Fairy, Global Tool,
/// Radial Menu, and Dynamic Island page shortcuts.
struct NotchShortcutsView: View {
    @ObservedObject var service: NotchService
    let size: CGSize
    var interactive = true

    @ObservedObject private var l10n = L10n.shared
    @State private var query = ""
    @State private var showInactive = false

    private struct ShortcutRow: Identifiable {
        let id: String
        let section: String
        let title: String
        let shortcut: String
        let symbol: String
        let isEnabled: Bool
        let targetModule: NotchModule?
    }

    var body: some View {
        let grouped = filteredSections
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if grouped.isEmpty {
                    NotchEmptyView(
                        symbol: "keyboard",
                        message: query.isEmpty ? "No active shortcuts" : "No matching shortcuts"
                    )
                    .frame(minHeight: max(120, size.height - 20))
                } else {
                    ForEach(grouped, id: \.title) { group in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(group.title.uppercased())
                                .font(.system(size: 9.5, weight: .bold))
                                .tracking(0.6)
                                .foregroundStyle(.white.opacity(0.40))
                                .padding(.horizontal, 4)

                            ForEach(group.rows) { row in
                                rowView(row)
                            }
                        }
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
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.45))
                    TextField("Filter shortcuts…", text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.white)
                    if !query.isEmpty {
                        Button {
                            query = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(.white.opacity(0.45))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 9)
                .frame(height: 26)
                .background(Color.white.opacity(0.08), in: Capsule())
                .frame(maxWidth: 190)
            }
        }, trailing: {
            if interactive {
                Button {
                    showInactive.toggle()
                } label: {
                    Text(showInactive ? "All" : "Active")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(showInactive ? Color(red: 0.45, green: 0.72, blue: 1.0) : .white.opacity(0.75))
                        .padding(.horizontal, 8)
                        .frame(height: 24)
                        .background(
                            (showInactive ? Color(red: 0.16, green: 0.42, blue: 0.96).opacity(0.24) : Color.white.opacity(0.09)),
                            in: Capsule()
                        )
                }
                .buttonStyle(.plain)
                .help(showInactive ? "Showing active and inactive shortcuts" : "Showing active shortcuts only")

                NotchIconButton(symbol: "gearshape", title: "Open Settings") {
                    service.openSettings()
                }
            }
        })
    }

    private func rowView(_ row: ShortcutRow) -> some View {
        let content = HStack(spacing: 9) {
            Image(systemName: row.symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(row.isEnabled ? Color(red: 0.45, green: 0.72, blue: 1.0) : .white.opacity(0.35))
                .frame(width: 22, height: 22)
                .background(
                    (row.isEnabled ? Color(red: 0.16, green: 0.42, blue: 0.96).opacity(0.16) : Color.white.opacity(0.05)),
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                )

            Text(row.title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(row.isEnabled ? 0.92 : 0.48))
                .lineLimit(1)

            if !row.isEnabled {
                Text("Off")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.42))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background(Color.white.opacity(0.06), in: Capsule())
            }

            Spacer(minLength: 6)

            Text(row.shortcut)
                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(row.isEnabled ? 0.88 : 0.45))
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Color.white.opacity(row.isEnabled ? 0.11 : 0.05), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .modifier(NotchControlSurface(cornerRadius: 11, interactive: interactive && row.targetModule != nil))

        return Group {
            if let target = row.targetModule, interactive {
                Button {
                    service.select(target)
                } label: {
                    content
                }
                .buttonStyle(NotchButtonStyle(cornerRadius: 11, lifts: true))
            } else {
                content
            }
        }
    }

    private var filteredSections: [(title: String, rows: [ShortcutRow])] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let rows = allRows.filter { row in
            guard trimmed.isEmpty else {
                return row.title.localizedCaseInsensitiveContains(trimmed)
                    || row.shortcut.localizedCaseInsensitiveContains(trimmed)
                    || row.section.localizedCaseInsensitiveContains(trimmed)
            }
            return true
        }
        var order: [String] = []
        var grouped: [String: [ShortcutRow]] = [:]
        for row in rows {
            if grouped[row.section] == nil { order.append(row.section) }
            grouped[row.section, default: []].append(row)
        }
        return order.compactMap { title in
            guard let items = grouped[title], !items.isEmpty else { return nil }
            return (title: title, rows: items)
        }
    }

    private var allRows: [ShortcutRow] {
        let defaults = UserDefaults.standard
        let strings = l10n.s
        var rows: [ShortcutRow] = [
            ShortcutRow(id: "fairy.area", section: "Fairy & Baryon", title: "Drag over what to ask", shortcut: "⌃⌥A", symbol: "viewfinder", isEnabled: true, targetModule: nil),
            ShortcutRow(id: "fairy.box", section: "Fairy & Baryon", title: "Ask Fairy", shortcut: "⌥⌘", symbol: "sparkles", isEnabled: true, targetModule: nil),
            ShortcutRow(id: "fairy.talk", section: "Fairy & Baryon", title: "Talk & circle / Explain", shortcut: "⌃⌥", symbol: "waveform", isEnabled: true, targetModule: nil),
            ShortcutRow(id: "fairy.bar", section: "Fairy & Baryon", title: "Ask Fairy in Command Bar", shortcut: "? query", symbol: "text.bubble", isEnabled: true, targetModule: nil),
            ShortcutRow(id: "fairy.trio", section: "Fairy & Baryon", title: "AI Launcher Research Trio", shortcut: "⌘↩", symbol: "sparkles.rectangle.stack", isEnabled: true, targetModule: nil),
        ]

        for role in GlobalShortcutRole.allCases where role.feature.isAvailable && role != .radialMenu {
            guard let shortcut = role.assignedShortcut()?.displayString, !shortcut.isEmpty else { continue }
            let enabled = role.requiredEnableKeys.allSatisfy { defaults.bool(forKey: $0) }
            guard enabled || showInactive else { continue }
            rows.append(ShortcutRow(
                id: "role.\(role.storageKey)",
                section: "Global Shortcuts",
                title: role.title(strings),
                shortcut: shortcut,
                symbol: role.feature.symbolName,
                isEnabled: enabled,
                targetModule: nil
            ))
        }

        if AppFeature.radialMenu.isAvailable {
            let radialEnabled = defaults.bool(forKey: DefaultsKey.radialMenuEnabled)
            if radialEnabled || showInactive {
                let profiles = RadialMenuSupport.decodeProfiles(
                    defaults.data(forKey: DefaultsKey.radialMenuProfiles),
                    defaults: defaults
                )
                let radialStrings = FeatureStrings.radialMenu(l10n.language)
                for profile in profiles {
                    var triggers: [String] = []
                    if let key = GlobalShortcut(storageValue: profile.shortcut)?.displayString {
                        triggers.append(key)
                    }
                    let mouse = RadialMenuMouseTrigger.sanitized(profile.mouseButton)
                    if mouse != .off {
                        triggers.append(mouseLabel(mouse))
                    }
                    if profile.trackpadTap {
                        triggers.append("4-finger tap")
                    }
                    guard !triggers.isEmpty else { continue }
                    rows.append(ShortcutRow(
                        id: "radial.\(profile.id.uuidString)",
                        section: "Radial Menu",
                        title: profile.displayName(radialStrings),
                        shortcut: triggers.joined(separator: " · "),
                        symbol: "circle.hexagongrid",
                        isEnabled: radialEnabled,
                        targetModule: nil
                    ))
                }
            }
        }

        for module in NotchSupport.modules(in: defaults) {
            rows.append(ShortcutRow(
                id: "notch.\(module.rawValue)",
                section: "Dynamic Island Pages",
                title: module.title(l10n.language),
                shortcut: "⌥⌘\(module.shortcutKey.uppercased())",
                symbol: module.symbol,
                isEnabled: true,
                targetModule: module
            ))
        }

        return rows
    }

    private func mouseLabel(_ trigger: RadialMenuMouseTrigger) -> String {
        switch trigger {
        case .off: return ""
        case .back: return "Mouse Back"
        case .forward: return "Mouse Forward"
        case .button(let number): return "Mouse \(number)"
        }
    }
}
