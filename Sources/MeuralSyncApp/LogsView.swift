import AppKit
import SwiftUI

struct LogsView: View {
    @Bindable var appState: AppState
    @State private var followLogs = true

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Sync Logs")
                    .font(.headline)
                Spacer()
                Toggle(isOn: $followLogs) {
                    Label("Follow", systemImage: "arrow.down.to.line")
                }
                .toggleStyle(.button)
                .help("Automatically scroll to new log entries")

                Button("Copy All") {
                    let text = appState.logs
                        .map { "[\($0.timestamp.formatted(date: .omitted, time: .standard))] \($0.message)" }
                        .joined(separator: "\n")
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
                .disabled(appState.logs.isEmpty)

                Button("Clear") {
                    appState.clearLogs()
                }
                .disabled(appState.logs.isEmpty)
            }
            .padding(10)

            Divider()

            if appState.logs.isEmpty {
                ContentUnavailableView("No Logs Yet", systemImage: "doc.text")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    List(appState.logs) { entry in
                        HStack(alignment: .top, spacing: 8) {
                            Text(entry.timestamp.formatted(date: .omitted, time: .standard))
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                            Text(entry.message)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                        }
                        .id(entry.id)
                    }
                    .onAppear {
                        if followLogs, let lastID = appState.logs.last?.id {
                            proxy.scrollTo(lastID, anchor: .bottom)
                        }
                    }
                    .onChange(of: appState.logs.last?.id) { _, lastID in
                        if followLogs, let lastID {
                            proxy.scrollTo(lastID, anchor: .bottom)
                        }
                    }
                    .onChange(of: followLogs) { _, isFollowing in
                        if isFollowing, let lastID = appState.logs.last?.id {
                            proxy.scrollTo(lastID, anchor: .bottom)
                        }
                    }
                }
            }
        }
    }
}
