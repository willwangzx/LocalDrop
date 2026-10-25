import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import CoreTransferable

struct ImportedMedia: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .data) { received in
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let target = directory.appendingPathComponent(received.file.lastPathComponent)
            try FileManager.default.copyItem(at: received.file, to: target)
            return ImportedMedia(url: target)
        }
    }
}
struct ContentView: View {
    @StateObject private var model = TransferModel()
    @State private var showFiles = false
    @State private var photos: [PhotosPickerItem] = []
    @State private var preparingPhotos = false
    private var working: Bool { model.busy || preparingPhotos }
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Your files. Across devices.").font(.title2.bold())
                    Text("Direct transfers on your local network.").foregroundStyle(.secondary)
                }
                Section("Connect to Windows") {
                    TextField("http://192.168.1.20:45872", text: $model.address)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                        .disabled(working)
                    SecureField("Pairing secret", text: $model.secret)
                        .textInputAutocapitalization(.characters).autocorrectionDisabled().disabled(working)
                    Button(model.connected ? "Reconnect" : "Connect") { Task { await model.connect() } }.disabled(working)
                    Text("Use the address and secret shown in LocalDrop on Windows. Keep both devices on a trusted private network; this prototype uses unencrypted local HTTP.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if model.connected {
                    Section("Send to \(model.computer)") {
                        PhotosPicker(selection: $photos, maxSelectionCount: 100, matching: .any(of: [.images, .videos]), preferredItemEncoding: .current) {
                            Label("Choose photos & videos", systemImage: "photo.on.rectangle")
                        }.disabled(working)
                        Button { showFiles = true } label: { Label("Choose files", systemImage: "doc") }.disabled(working)
                    }
                    Section {
                        if model.files.isEmpty { Text("Add files in the Windows app to see them here.").foregroundStyle(.secondary) }
                        ForEach(model.files) { file in
                            Button { Task { await model.download(file) } } label: {
                                HStack {
                                    Image(systemName: "arrow.down.circle.fill")
                                    VStack(alignment: .leading) {
                                        Text(file.name).lineLimit(2)
                                        Text(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file)).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }.disabled(working)
                        }
                        Button("Refresh shared files") { Task { await model.refresh() } }.disabled(working)
                    } header: { Text("From Windows") }
                }
                Section("Transfer status") {
                    if working { ProgressView(value: model.progress) }
                    Text(model.status).font(.callout)
                    if working { Text("Keep LocalDrop open until the transfer finishes.").font(.caption).foregroundStyle(.secondary) }
                }
                if !model.received.isEmpty {
                    Section("Received on this iPhone") {
                        ForEach(model.received, id: \.self) { url in
                            ShareLink(item: url) { Label(url.lastPathComponent, systemImage: "square.and.arrow.up").lineLimit(2) }
                        }
                        Text("Use Share to save to Files or Photos when supported. Downloads are also in Files → On My iPhone → LocalDrop.").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("LocalDrop")
            .tint(.mint)
            .fileImporter(isPresented: $showFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
                switch result {
                case .success(let urls): Task { await model.send(urls) }
                case .failure(let error): model.status = error.localizedDescription
                }
            }
            .onChange(of: photos) { _, selection in
                guard !selection.isEmpty else { return }
                preparingPhotos = true
                Task {
                    defer { preparingPhotos = false; photos = [] }
                    // Prepare and transfer one item at a time to bound temporary disk usage.
                    for (index, item) in selection.enumerated() {
                        model.status = "Preparing photo/video \(index + 1) of \(selection.count)…"
                        do {
                            guard let media = try await item.loadTransferable(type: ImportedMedia.self) else {
                                model.status = "This photo format could not be loaded."; break
                            }
                            let sent = await model.send([media.url])
                            try? FileManager.default.removeItem(at: media.url.deletingLastPathComponent())
                            if !sent { break }
                            model.status = "Sent photo/video \(index + 1) of \(selection.count)."
                        } catch { model.status = error.localizedDescription; break }
                    }
                }
            }
        }.preferredColorScheme(.dark)
    }
}
