//
//  ScriptLibraryView.swift
//  FlowCue
//
//  UI for managing saved scripts.
//

import SwiftUI

struct ScriptLibraryView: View {
    @State private var library = ScriptLibrary.shared
    @State private var editingScript: Script?
    @State private var renameText: String = ""
    @State private var showingRename = false
    var onLoad: ((String) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Script Library")
                    .font(.headline)
                    .foregroundStyle(.primary)
                Spacer()
                Text("\(library.scripts.count) scripts")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if library.scripts.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "doc.text")
                        .font(.system(size: 32))
                        .foregroundStyle(.tertiary)
                    Text("No saved scripts")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("Scripts are auto-saved when you start playback")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(library.scripts.sorted(by: { $0.updatedAt > $1.updatedAt })) { script in
                            ScriptRow(
                                script: script,
                                onLoad: {
                                    onLoad?(script.content)
                                },
                                onRename: {
                                    editingScript = script
                                    renameText = script.title
                                    showingRename = true
                                },
                                onDelete: {
                                    withAnimation {
                                        library.delete(script)
                                    }
                                }
                            )
                        }
                    }
                }
                .frame(maxHeight: 300)
            }
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .alert("Rename Script", isPresented: $showingRename) {
            TextField("Title", text: $renameText)
            Button("Save") {
                if let script = editingScript {
                    library.rename(script, to: renameText)
                }
            }
            Button("Cancel", role: .cancel) {}
        }
    }
}

struct ScriptRow: View {
    let script: Script
    var onLoad: () -> Void
    var onRename: () -> Void
    var onDelete: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(script.title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(script.updatedAt, style: .relative)
                    Text("•")
                    Text("\(script.content.split(separator: " ").count) words")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }

            Spacer()

            Button(action: onLoad) {
                Image(systemName: "arrow.up.doc")
                    .font(.system(size: 14))
            }
            .buttonStyle(.plain)
            .help("Load script")

            Menu {
                Button("Rename", action: onRename)
                Divider()
                Button("Delete", role: .destructive, action: onDelete)
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .menuStyle(.borderlessButton)
            .frame(width: 24)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
}
