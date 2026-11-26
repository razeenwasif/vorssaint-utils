// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import SwiftUI

/// Dynamic Island view for Hadron's `todos.json` two-way sync and one-click Fairy goal promotion.
struct NotchTasksView: View {
    @ObservedObject private var todos = HadronTodoSyncService.shared
    let size: CGSize
    var interactive = true

    @State private var draft = ""
    @State private var hoveredID: Int64?

    private var activeCount: Int {
        todos.items.filter { !$0.done }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let err = todos.lastSyncError {
                Text(err)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.orange)
                    .lineLimit(1)
                    .padding(.horizontal, 4)
            }

            if interactive {
                quickAddBar
            }

            let visible = todos.filteredItems
            if visible.isEmpty {
                NotchEmptyView(
                    symbol: "checklist",
                    message: todos.selectedProfile == "All"
                        ? "No Hadron tasks yet"
                        : "No tasks in \(todos.selectedProfile)"
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 5) {
                        ForEach(visible) { item in
                            taskRow(item)
                        }
                    }
                    .padding(.horizontal, 2)
                    .padding(.bottom, 6)
                }
                .scrollIndicators(.hidden)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        .notchBand(leading: {
            profilePicker
        }, trailing: {
            HStack(spacing: 4) {
                Text("\(activeCount) open")
                    .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.65))
                    .padding(.horizontal, 7)
                    .frame(height: 22)
                    .background(.white.opacity(0.08), in: Capsule())
                if interactive {
                    NotchIconButton(symbol: "arrow.clockwise", title: "Reload Hadron Tasks") {
                        todos.reloadFromDisk()
                    }
                }
            }
        })
        .onAppear {
            if interactive {
                todos.reloadFromDisk()
            }
        }
    }

    private var profilePicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(todos.profiles, id: \.self) { profile in
                    let selected = todos.selectedProfile == profile
                    Button {
                        todos.selectedProfile = profile
                    } label: {
                        Text(profile)
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(selected ? .white : .white.opacity(0.62))
                            .padding(.horizontal, 8)
                            .frame(height: 22)
                            .background(
                                selected ? Color.accentColor.opacity(0.32) : Color.white.opacity(0.06),
                                in: Capsule()
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(maxWidth: 210)
    }

    private var quickAddBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "plus.circle.fill")
                .font(.system(size: 13))
                .foregroundStyle(Color(red: 0.35, green: 0.65, blue: 1.0))
            TextField("Add task (e.g. friday 5pm !1 ~30m)…", text: $draft)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(.white)
                .onSubmit(submitDraft)

            if !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button("Add", action: submitDraft)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 9)
                    .frame(height: 22)
                    .background(Color.accentColor.opacity(0.85), in: Capsule())
                    .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(.white.opacity(0.08), lineWidth: 0.75)
        }
        .padding(.horizontal, 2)
    }

    private func submitDraft() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        todos.addTask(rawInput: trimmed)
        draft = ""
    }

    private func taskRow(_ item: HadronTodoItem) -> some View {
        let isHovered = hoveredID == item.id
        return HStack(spacing: 8) {
            Button {
                guard interactive else { return }
                todos.toggleDone(id: item.id)
            } label: {
                Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(item.done ? .mint : .white.opacity(0.55))
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.system(size: 12, weight: .medium))
                    .strikethrough(item.done, color: .white.opacity(0.45))
                    .foregroundStyle(.white.opacity(item.done ? 0.45 : 0.95))
                    .lineLimit(2)

                if item.priority > 0 || !item.due.isEmpty || item.minutes > 0 || (todos.selectedProfile == "All" && !item.profile.isEmpty) {
                    HStack(spacing: 5) {
                        if item.priority > 0 {
                            badge("!\(item.priority)", tint: priorityColor(item.priority))
                        }
                        if !item.due.isEmpty {
                            let label = item.time.isEmpty ? item.due : "\(item.due) \(item.time)"
                            badge(label, tint: .white.opacity(0.75))
                        }
                        if item.minutes > 0 {
                            badge("~\(item.minutes)m", tint: Color(red: 0.45, green: 0.78, blue: 1.0))
                        }
                        if todos.selectedProfile == "All", !item.profile.isEmpty {
                            badge(item.profile, tint: .white.opacity(0.55))
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if interactive, (isHovered || !item.done) {
                HStack(spacing: 4) {
                    Button {
                        todos.promoteToFairyGoal(item)
                    } label: {
                        Image(systemName: "sparkles")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color(red: 0.45, green: 0.72, blue: 1.0))
                            .frame(width: 22, height: 22)
                            .background(Color(red: 0.16, green: 0.42, blue: 0.96).opacity(isHovered ? 0.28 : 0.14), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .help("Start as Fairy Goal")

                    if isHovered {
                        Button {
                            todos.deleteTask(id: item.id)
                        } label: {
                            Image(systemName: "trash")
                                .font(.system(size: 10.5))
                                .foregroundStyle(.white.opacity(0.6))
                                .frame(width: 22, height: 22)
                                .background(.white.opacity(0.08), in: Circle())
                        }
                        .buttonStyle(.plain)
                        .help("Delete Task")
                    }
                }
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(.white.opacity(isHovered ? 0.08 : 0.045), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(.white.opacity(isHovered ? 0.14 : 0.05), lineWidth: 0.75)
        }
        .onHover { over in
            hoveredID = over ? item.id : (hoveredID == item.id ? nil : hoveredID)
        }
    }

    private func badge(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.system(size: 9.5, weight: .semibold).monospacedDigit())
            .foregroundStyle(tint)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(tint.opacity(0.14), in: Capsule())
    }

    private func priorityColor(_ priority: Int) -> Color {
        switch priority {
        case 1: return Color(red: 1.0, green: 0.42, blue: 0.42)
        case 2: return .orange
        default: return Color(red: 0.45, green: 0.72, blue: 1.0)
        }
    }
}
