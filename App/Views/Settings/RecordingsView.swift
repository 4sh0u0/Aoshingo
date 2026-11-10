// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import UniformTypeIdentifiers

/// Developer recordings of received advertisements (JSON Lines), for field tests and test fixtures.
struct RecordingsView: View {
    @Environment(AppModel.self) private var model
    @State private var recordings: [URL] = []
    @State private var showingImporter = false

    var body: some View {
        Form {
            Section {
                Toggle("受信データを記録する", isOn: Binding(
                    get: { model.isRecording },
                    set: { model.setRecording($0) }
                ))
                .disabled(model.source != .live && !model.isRecording)
                if let error = model.recordingError {
                    Text(error).foregroundStyle(.red)
                }
            } footer: {
                Text("実機受信中のパケットだけを記録します。記録には位置情報を含まず、送信機は E1、E2… と表記します。記録は共有するまで端末の外に出ません。")
            }

            Section("記録ファイル") {
                if recordings.isEmpty {
                    Text("まだありません").foregroundStyle(.secondary)
                }
                ForEach(recordings, id: \.self) { url in
                    ShareLink(item: url) {
                        Label(url.lastPathComponent, systemImage: "square.and.arrow.up")
                    }
                }
                .onDelete { offsets in
                    for index in offsets {
                        try? FileManager.default.removeItem(at: recordings[index])
                    }
                    reload()
                }
            }

            Section {
                Button("記録ファイルを再生", systemImage: "doc.badge.clock") {
                    showingImporter = true
                }
            } footer: {
                Text("再生中のデータは実測データとして送信しません。")
            }
        }
        .navigationTitle("受信データの記録")
        .onAppear(perform: reload)
        .onChange(of: model.isRecording) { reload() }
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.json, .plainText, .data]) { result in
            if case .success(let url) = result {
                model.startReplay(url)
            }
        }
    }

    private func reload() {
        recordings = AdvertisementRecorder.recordings()
    }
}
