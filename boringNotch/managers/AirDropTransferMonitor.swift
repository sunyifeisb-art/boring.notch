import AppKit
import Combine
import Darwin
import Foundation
import SwiftUI

@MainActor
final class AirDropTransferMonitor: ObservableObject {
    static let shared = AirDropTransferMonitor()

    enum Phase {
        case receiving
        case sending
        case received
        case sent
        case failed
    }

    @Published private(set) var phase: Phase?
    @Published private(set) var fileURL: URL?
    @Published private(set) var fractionCompleted: Double?

    private struct ObservedProgress {
        var subscriber: Any?
        let progress: Progress
        let observation: NSKeyValueObservation
    }

    private var incomingSubscriber: Any?
    private var subscriberByID: [UUID: Any] = [:]
    private var progressByID: [UUID: ObservedProgress] = [:]
    private var directorySource: DispatchSourceFileSystemObject?
    private var directoryDescriptor: Int32 = -1
    private let directoryQueue = DispatchQueue(label: "theboringteam.boringnotch.airdrop-directory", qos: .utility)
    private var directoryScanWorkItem: DispatchWorkItem?
    private var hideTask: Task<Void, Never>?
    private var knownDirectoryFileNames = Set<String>()
    private var didStart = false
    private var hasInitialDirectorySnapshot = false
    private var directoryChangedDuringSnapshot = false

    private init() {}

    func start() {
        guard !didStart else { return }
        didStart = true
        // Use the real user Downloads directory: URL.downloadsDirectory resolves
        // to the app container's private Downloads folder for sandboxed apps.
        let downloadsURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Downloads", isDirectory: true)

        incomingSubscriber = Progress.addSubscriber(forFileURL: downloadsURL) { [weak self] progress in
            let url = progress.userInfo[.fileURLKey] as? URL
            let id = UUID()
            Task { @MainActor [weak self] in
                guard let self, let url else { return }
                self.attach(progress, id: id, subscriber: nil, for: url, phase: .receiving)
            }
            return { [weak self] in
                Task { @MainActor [weak self] in self?.removeProgressObserver(id: id) }
            }
        }

        directoryDescriptor = open(downloadsURL.path, O_EVTONLY)
        if directoryDescriptor >= 0 {
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: directoryDescriptor,
                eventMask: [.write, .rename, .delete],
                queue: directoryQueue
            )
            source.setEventHandler { [weak self] in
                Task { @MainActor [weak self] in self?.scheduleDirectoryScan(in: downloadsURL) }
            }
            source.setCancelHandler { [descriptor = directoryDescriptor] in close(descriptor) }
            directorySource = source
            source.resume()
        }

        // A large Downloads folder must never be enumerated synchronously on the
        // UI actor. Retain only filenames, not a set of URL objects.
        directoryQueue.async { [weak self] in
            let existingFiles = Self.directoryFileNames(in: downloadsURL)
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.knownDirectoryFileNames = existingFiles
                self.hasInitialDirectorySnapshot = true
                if self.directoryChangedDuringSnapshot {
                    self.directoryChangedDuringSnapshot = false
                    self.scheduleDirectoryScan(in: downloadsURL)
                }
            }
        }
    }

    func beginSending(items: [Any]) {
        hideTask?.cancel()
        clearProgressObservers()
        fileURL = items.compactMap { $0 as? URL }.first(where: \.isFileURL)
        fractionCompleted = nil
        withAnimation(.snappy(duration: 0.28)) { phase = .sending }
        for url in items.compactMap({ $0 as? URL }).filter(\.isFileURL) {
            observeProgress(for: url, phase: .sending)
        }
    }

    func finishSending(error: Error? = nil) {
        guard phase == .sending else { return }
        clearProgressObservers()
        fractionCompleted = error == nil ? 1 : nil
        withAnimation(.snappy(duration: 0.28)) { phase = error == nil ? .sent : .failed }
        scheduleHide(after: error == nil ? 4 : 6)
    }

    func dismiss() {
        hideTask?.cancel()
        clearProgressObservers()
        withAnimation(.snappy(duration: 0.24)) {
            phase = nil
            fileURL = nil
            fractionCompleted = nil
        }
    }

    func openReceivedFile() {
        guard let fileURL else { dismiss(); return }
        NSWorkspace.shared.open(fileURL)
        dismiss()
    }

    func showReceivedFileInFinder() {
        guard let fileURL else { dismiss(); return }
        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
        dismiss()
    }

    private func scheduleDirectoryScan(in directoryURL: URL) {
        guard hasInitialDirectorySnapshot else {
            directoryChangedDuringSnapshot = true
            return
        }
        directoryScanWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            let currentFiles = Self.directoryFileNames(in: directoryURL)
            Task { @MainActor [weak self] in
                self?.processDirectorySnapshot(currentFiles, in: directoryURL)
            }
        }
        directoryScanWorkItem = workItem
        directoryQueue.asyncAfter(deadline: .now() + .milliseconds(250), execute: workItem)
    }

    private func processDirectorySnapshot(_ fileNames: Set<String>, in directoryURL: URL) {
        knownDirectoryFileNames.formIntersection(fileNames)
        let newlyCreatedNames = fileNames.subtracting(knownDirectoryFileNames)
        knownDirectoryFileNames.formUnion(newlyCreatedNames)

        for fileName in newlyCreatedNames {
            let url = directoryURL.appendingPathComponent(fileName)
            guard Self.isAirDropFile(url) else { continue }
            let activeProgress = progressByID.values.first {
                $0.progress.userInfo[.fileURLKey] as? URL == url && !$0.progress.isFinished
            }
            if let activeProgress {
                fileURL = url
                fractionCompleted = activeProgress.progress.isIndeterminate
                    ? nil : activeProgress.progress.fractionCompleted
                withAnimation(.snappy(duration: 0.28)) { phase = .receiving }
                continue
            }
            clearProgressObservers()
            fileURL = url
            fractionCompleted = 1
            withAnimation(.snappy(duration: 0.3)) { phase = .received }
            scheduleHide(after: 18)
        }
    }

    nonisolated private static func directoryFileNames(in directoryURL: URL) -> Set<String> {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        return Set(files.map(\.lastPathComponent))
    }

    private func observeProgress(for url: URL, phase: Phase) {
        let id = UUID()
        let subscriber = Progress.addSubscriber(forFileURL: url) { [weak self] progress in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.attach(progress, id: id, subscriber: nil, for: url, phase: phase)
            }
            return { [weak self] in
                Task { @MainActor [weak self] in self?.removeProgressObserver(id: id) }
            }
        }
        subscriberByID[id] = subscriber
    }

    private func attach(_ progress: Progress, id: UUID, subscriber: Any?, for url: URL, phase: Phase) {
        guard progressByID[id] == nil else { return }
        let observation = progress.observe(\.fractionCompleted, options: [.initial, .new]) { [weak self] progress, _ in
            let fraction = progress.isIndeterminate ? nil : min(1, max(0, progress.fractionCompleted))
            Task { @MainActor [weak self] in
                guard let self else { return }
                if phase == .receiving && !Self.isAirDropFile(url) {
                    if progress.isFinished { self.removeProgressObserver(id: id) }
                    return
                }
                self.fileURL = url
                self.fractionCompleted = fraction
                if self.phase == nil || (phase == .receiving && self.phase != .received) {
                    withAnimation(.snappy(duration: 0.28)) { self.phase = phase }
                }
                if phase == .receiving && progress.isFinished {
                    self.fractionCompleted = 1
                    withAnimation(.snappy(duration: 0.28)) { self.phase = .received }
                    self.scheduleHide(after: 18)
                }
                if progress.isFinished { self.removeProgressObserver(id: id) }
            }
        }
        let registeredSubscriber = subscriber ?? subscriberByID.removeValue(forKey: id)
        progressByID[id] = ObservedProgress(
            subscriber: registeredSubscriber,
            progress: progress,
            observation: observation
        )
    }

    nonisolated private static func isAirDropFile(_ url: URL) -> Bool {
        var length = getxattr(url.path, "com.apple.quarantine", nil, 0, 0, 0)
        guard length > 0 else { return false }
        var bytes = [UInt8](repeating: 0, count: length)
        length = bytes.withUnsafeMutableBytes { buffer in
            getxattr(url.path, "com.apple.quarantine", buffer.baseAddress, buffer.count, 0, 0)
        }
        guard length > 0 else { return false }
        return String(decoding: bytes.prefix(length), as: UTF8.self)
            .localizedCaseInsensitiveContains("sharingd")
    }

    private func scheduleHide(after seconds: UInt64) {
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.dismiss()
        }
    }

    private func clearProgressObservers() {
        for value in progressByID.values {
            if let subscriber = value.subscriber { Progress.removeSubscriber(subscriber) }
        }
        progressByID.removeAll()
        for subscriber in subscriberByID.values { Progress.removeSubscriber(subscriber) }
        subscriberByID.removeAll()
    }

    private func removeProgressObserver(id: UUID) {
        guard let value = progressByID.removeValue(forKey: id) else { return }
        if let subscriber = value.subscriber { Progress.removeSubscriber(subscriber) }
    }
}

struct AirDropTransferHUD: View {
    @ObservedObject var monitor: AirDropTransferMonitor

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 9) {
                Image(systemName: "airdrop")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 20)
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 8)
                if let fraction = monitor.fractionCompleted,
                   monitor.phase == .sending || monitor.phase == .receiving {
                    Text("\(Int(fraction * 100))%")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                }
                if monitor.phase != .received {
                    Button { monitor.dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .bold))
                            .frame(width: 22, height: 22)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white.opacity(0.7))
                    .accessibilityLabel("关闭隔空投送状态")
                }
            }
            .foregroundStyle(.white)
            .frame(height: 34)

            VStack(alignment: .leading, spacing: 10) {
                if let fileURL = monitor.fileURL {
                    Text(fileURL.lastPathComponent)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if monitor.phase == .sending || monitor.phase == .receiving {
                    ProgressView(value: monitor.fractionCompleted)
                        .progressViewStyle(.linear)
                        .tint(.black)
                        .accessibilityLabel(monitor.fractionCompleted.map { "隔空投送进度 \(Int($0 * 100))%" } ?? "隔空投送进行中")
                } else if monitor.phase == .failed {
                    Text("传输失败")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.red)
                }

                if monitor.phase == .received {
                    HStack(spacing: 8) {
                        Button("打开") { monitor.openReceivedFile() }
                            .buttonStyle(.borderedProminent)
                            .tint(.black)
                            .controlSize(.small)
                        Button("在访达中显示") { monitor.showReceivedFileInFinder() }
                            .buttonStyle(.bordered)
                            .tint(.black)
                            .controlSize(.small)
                    }
                }
            }
            .font(.system(size: 12))
            .foregroundStyle(.black)
            .padding(.horizontal, 13)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 14)
        .frame(minWidth: 360, maxWidth: 560, alignment: .top)
        .background(.black)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    private var title: String {
        switch monitor.phase {
        case .receiving: "正在接收隔空投送"
        case .sending: "正在发送隔空投送"
        case .received: "隔空投送已接收"
        case .sent: "隔空投送已发送"
        case .failed: "隔空投送失败"
        case .none: "隔空投送"
        }
    }
}
