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

struct AirDropTransferCapsule: View {
    @ObservedObject var monitor: AirDropTransferMonitor

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "airdrop")
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                if let fileURL = monitor.fileURL {
                    Text(fileURL.lastPathComponent)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.68))
                        .lineLimit(1)
                }
                if monitor.phase == .sending || monitor.phase == .receiving {
                    ProgressView(value: monitor.fractionCompleted)
                        .progressViewStyle(.linear)
                        .tint(.white)
                        .frame(maxWidth: 180)
                        .accessibilityLabel(monitor.fractionCompleted.map { "隔空投送进度 \(Int($0 * 100))%" } ?? "隔空投送进行中")
                }
            }
            Spacer(minLength: 6)
            if monitor.phase == .received {
                Button("打开") { monitor.openReceivedFile() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                Button("在访达中显示") { monitor.showReceivedFileInFinder() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            } else {
                if let fraction = monitor.fractionCompleted, monitor.phase == .sending || monitor.phase == .receiving {
                    Text("\(Int(fraction * 100))%")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                }
                if monitor.phase == .failed {
                    Text("未能发送").font(.system(size: 12, weight: .medium)).foregroundStyle(.orange)
                }
                Button {
                    monitor.dismiss()
                } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.65))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(minWidth: 340, maxWidth: 580, alignment: .leading)
        .foregroundStyle(.white)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 1))
        .shadow(color: .black.opacity(0.25), radius: 18, y: 8)
        .transition(.move(edge: .top).combined(with: .opacity).combined(with: .scale(scale: 0.96)))
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
