import SwiftUI
import MediaPlayer
import AVFoundation

struct MusicLibraryPicker: UIViewControllerRepresentable {
    var onSelection: (MPMediaItem?) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(onSelection) }
    func makeUIViewController(context: Context) -> MPMediaPickerController {
        let picker = MPMediaPickerController(mediaTypes: .music)
        picker.allowsPickingMultipleItems = false
        picker.showsCloudItems = false
        picker.showsItemsWithProtectedAssets = false
        picker.prompt = tr("Choose a downloaded, DRM-free song")
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ uiViewController: MPMediaPickerController, context: Context) {}
    final class Coordinator: NSObject, MPMediaPickerControllerDelegate {
        let selection: (MPMediaItem?) -> Void
        init(_ selection: @escaping (MPMediaItem?) -> Void) { self.selection = selection }
        func mediaPicker(_ mediaPicker: MPMediaPickerController, didPickMediaItems collection: MPMediaItemCollection) { selection(collection.items.first) }
        func mediaPickerDidCancel(_ mediaPicker: MPMediaPickerController) { selection(nil) }
    }
}

@MainActor enum MusicImport {
    static func file(_ url: URL) throws -> URL {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let target = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension(url.pathExtension)
        try FileManager.default.copyItem(at: url, to: target)
        do { _ = try AVAudioFile(forReading: target) }
        catch { try? FileManager.default.removeItem(at: target); throw error }
        return target
    }
    static func library(_ item: MPMediaItem) async throws -> URL {
        guard !item.hasProtectedAsset, !item.isCloudItem, let url = item.assetURL else { throw AudioSourceFailure.unsupported }
        let asset = AVURLAsset(url: url)
        guard try await !asset.load(.hasProtectedContent),
              let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else { throw AudioSourceFailure.unsupported }
        let target = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("m4a")
        do {
            try await exporter.export(to: target, as: .m4a)
            _ = try AVAudioFile(forReading: target)
            return target
        } catch { try? FileManager.default.removeItem(at: target); throw error }
    }
}
