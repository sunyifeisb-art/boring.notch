import Foundation
import Cocoa
import ApplicationServices
import AsyncXPCConnection

final class XPCHelperClient: NSObject {
    nonisolated static let shared = XPCHelperClient()
    
    private let serviceName = "theboringteam.boringnotch.BoringNotchXPCHelper"
    
    private var remoteService: RemoteXPCService<BoringNotchXPCHelperProtocol>?
    private var connection: NSXPCConnection?
    private var lastKnownAuthorization: Bool?
    private var authorizationActivationObserver: NSObjectProtocol?
    
    deinit {
        connection?.invalidate()
        stopMonitoringAccessibilityAuthorization()
    }
    
    // MARK: - Connection Management (Main Actor Isolated)
    
    @MainActor
    private func ensureRemoteService() -> RemoteXPCService<BoringNotchXPCHelperProtocol> {
        if let existing = remoteService {
            return existing
        }
        
        let conn = NSXPCConnection(serviceName: serviceName)
        
        conn.interruptionHandler = { [weak self] in
            Task { @MainActor in
                self?.connection = nil
                self?.remoteService = nil
            }
        }
        
        conn.invalidationHandler = { [weak self] in
            Task { @MainActor in
                self?.connection = nil
                self?.remoteService = nil
            }
        }
        
        conn.resume()
        
        let service = RemoteXPCService<BoringNotchXPCHelperProtocol>(
            connection: conn,
            remoteInterface: BoringNotchXPCHelperProtocol.self
        )
        
        connection = conn
        remoteService = service
        return service
    }
    
    @MainActor
    private func getRemoteService() -> RemoteXPCService<BoringNotchXPCHelperProtocol>? {
        remoteService
    }
    
    @MainActor
    private func notifyAuthorizationChange(_ granted: Bool) {
        guard lastKnownAuthorization != granted else { return }
        lastKnownAuthorization = granted
        NotificationCenter.default.post(
            name: .accessibilityAuthorizationChanged,
            object: nil,
            userInfo: ["granted": granted]
        )
    }

    // MARK: - Monitoring
    nonisolated func startMonitoringAccessibilityAuthorization() {
        stopMonitoringAccessibilityAuthorization()
        authorizationActivationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { _ = await self?.isAccessibilityAuthorized() }
        }
        // Probe once when monitoring begins, then only when the app is active
        // again after the user may have changed the setting.
        Task { _ = await isAccessibilityAuthorized() }
    }

    nonisolated func stopMonitoringAccessibilityAuthorization() {
        if let authorizationActivationObserver {
            NotificationCenter.default.removeObserver(authorizationActivationObserver)
            self.authorizationActivationObserver = nil
        }
    }
    
    // MARK: - Accessibility
    
    nonisolated func requestAccessibilityAuthorization() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    nonisolated func isAccessibilityAuthorized() async -> Bool {
        let result = AXIsProcessTrusted()
        await MainActor.run { notifyAuthorizationChange(result) }
        return result
    }
    
    nonisolated func ensureAccessibilityAuthorization(promptIfNeeded: Bool) async -> Bool {
        if AXIsProcessTrusted() {
            await MainActor.run { notifyAuthorizationChange(true) }
            return true
        }

        if promptIfNeeded {
            requestAccessibilityAuthorization()
            // TCC authorization is granted asynchronously in System Settings. Keep
            // the HUD toggle pending while the user approves it instead of querying
            // the unrelated XPC helper process and immediately disabling the toggle.
            for _ in 0..<120 {
                try? await Task.sleep(for: .milliseconds(500))
                if Task.isCancelled { return false }
                if AXIsProcessTrusted() {
                    await MainActor.run { notifyAuthorizationChange(true) }
                    return true
                }
            }
        }

        await MainActor.run { notifyAuthorizationChange(false) }
        return false
    }
    
    // MARK: - Keyboard Brightness
    
    nonisolated func isKeyboardBrightnessAvailable() async -> Bool {
        do {
            let service = await MainActor.run {
                ensureRemoteService()
            }
            return try await service.withContinuation { service, continuation in
                service.isKeyboardBrightnessAvailable { available in
                    continuation.resume(returning: available)
                }
            }
        } catch {
            return false
        }
    }
    
    nonisolated func currentKeyboardBrightness() async -> Float? {
        do {
            let service = await MainActor.run {
                ensureRemoteService()
            }
            let result: NSNumber? = try await service.withContinuation { service, continuation in
                service.currentKeyboardBrightness { value in
                    continuation.resume(returning: value)
                }
            }
            return result?.floatValue
        } catch {
            return nil
        }
    }
    
    nonisolated func setKeyboardBrightness(_ value: Float) async -> Bool {
        do {
            let service = await MainActor.run {
                ensureRemoteService()
            }
            return try await service.withContinuation { service, continuation in
                service.setKeyboardBrightness(value) { success in
                    continuation.resume(returning: success)
                }
            }
        } catch {
            return false
        }
    }
    
    // MARK: - Screen Brightness
    
    nonisolated func isScreenBrightnessAvailable() async -> Bool {
        do {
            let service = await MainActor.run {
                ensureRemoteService()
            }
            return try await service.withContinuation { service, continuation in
                service.isScreenBrightnessAvailable { available in
                    continuation.resume(returning: available)
                }
            }
        } catch {
            return false
        }
    }
    
    nonisolated func currentScreenBrightness() async -> Float? {
        do {
            let service = await MainActor.run {
                ensureRemoteService()
            }
            let result: NSNumber? = try await service.withContinuation { service, continuation in
                service.currentScreenBrightness { value in
                    continuation.resume(returning: value)
                }
            }
            return result?.floatValue
        } catch {
            return nil
        }
    }
    
    nonisolated func setScreenBrightness(_ value: Float) async -> Bool {
        do {
            let service = await MainActor.run {
                ensureRemoteService()
            }
            return try await service.withContinuation { service, continuation in
                service.setScreenBrightness(value) { success in
                    continuation.resume(returning: success)
                }
            }
        } catch {
            return false
        }
    }

    // MARK: - AI Agent Bridge

    nonisolated func startAgentBridge() async -> String? {
        do {
            let service = await MainActor.run { ensureRemoteService() }
            let result: NSString? = try await service.withContinuation { service, continuation in
                service.startAgentBridge { error in
                    continuation.resume(returning: error)
                }
            }
            return result as String?
        } catch {
            return error.localizedDescription
        }
    }

    nonisolated func stopAgentBridge() {
        Task {
            let service = await MainActor.run { ensureRemoteService() }
            try? await service.withService { service in
                service.stopAgentBridge()
            }
        }
    }

    nonisolated func agentSessionsJSON(detailSessionID: String?) async -> Data {
        do {
            let service = await MainActor.run { ensureRemoteService() }
            let result: NSData = try await service.withContinuation { service, continuation in
                service.agentSessionsJSON(detailSessionID as NSString?) { data in
                    continuation.resume(returning: data)
                }
            }
            return result as Data
        } catch {
            return Data("[]".utf8)
        }
    }

    nonisolated func agentSessionsRevision(detailSessionID: String?) async -> UInt64? {
        do {
            let service = await MainActor.run { ensureRemoteService() }
            let result: NSNumber = try await service.withContinuation { service, continuation in
                service.agentSessionsRevision(detailSessionID as NSString?) { revision in
                    continuation.resume(returning: revision)
                }
            }
            return result.uint64Value
        } catch {
            return nil
        }
    }

    nonisolated func codexUsageJSON() async -> Data {
        do {
            let service = await MainActor.run { ensureRemoteService() }
            let result: NSData = try await service.withContinuation { service, continuation in
                service.codexUsageJSON { data in continuation.resume(returning: data) }
            }
            return result as Data
        } catch {
            return Data("{\"fiveHourRemainingPercent\":null,\"weeklyRemainingPercent\":null,\"updatedAt\":null,\"error\":\"额度服务连接失败\"}".utf8)
        }
    }

    nonisolated func widgetCatalogJSON() async -> Data {
        do {
            let service = await MainActor.run { ensureRemoteService() }
            let result: NSData = try await service.withContinuation { service, continuation in
                service.widgetCatalogJSON { data in continuation.resume(returning: data) }
            }
            return result as Data
        } catch {
            return Data("[]".utf8)
        }
    }

    nonisolated func shortcutNamesJSON() async -> Data {
        do {
            let service = await MainActor.run { ensureRemoteService() }
            let result: NSData = try await service.withContinuation { service, continuation in
                service.shortcutNamesJSON { data in continuation.resume(returning: data) }
            }
            return result as Data
        } catch {
            return Data("[]".utf8)
        }
    }

    nonisolated func runShortcut(_ name: String) async -> Data {
        do {
            let service = await MainActor.run { ensureRemoteService() }
            let result: NSData = try await service.withContinuation { service, continuation in
                service.runShortcut(name) { data in continuation.resume(returning: data) }
            }
            return result as Data
        } catch {
            return (try? JSONEncoder().encode(ShortcutActionExecution(output: nil, error: error.localizedDescription)))
                ?? Data("{}".utf8)
        }
    }

    nonisolated func respondToAgent(sessionID: String, responseJSON: Data) async -> Bool {
        do {
            let service = await MainActor.run { ensureRemoteService() }
            return try await service.withContinuation { service, continuation in
                service.respondToAgent(sessionID, responseJSON: responseJSON as NSData) { success in
                    continuation.resume(returning: success)
                }
            }
        } catch {
            return false
        }
    }

    nonisolated func installAgentHooks() async -> [String] {
        do {
            let service = await MainActor.run { ensureRemoteService() }
            let result: NSArray = try await service.withContinuation { service, continuation in
                service.installAgentHooks { messages in
                    continuation.resume(returning: messages)
                }
            }
            return result.compactMap { $0 as? String }
        } catch {
            return ["Hook install failed: \(error.localizedDescription)"]
        }
    }

    nonisolated func jumpToAgentTerminal(sessionID: String) async -> Bool {
        do {
            let service = await MainActor.run { ensureRemoteService() }
            return try await service.withContinuation { service, continuation in
                service.jumpToAgentTerminal(sessionID) { success in
                    continuation.resume(returning: success)
                }
            }
        } catch {
            return false
        }
    }

    nonisolated func closeAgentSession(sessionID: String) async -> Bool {
        do {
            let service = await MainActor.run { ensureRemoteService() }
            return try await service.withContinuation { service, continuation in
                service.closeAgentSession(sessionID) { success in
                    continuation.resume(returning: success)
                }
            }
        } catch {
            return false
        }
    }

    nonisolated func sendAgentMessage(sessionID: String?, source: String, cwd: String?, message: String) async -> String? {
        do {
            let service = await MainActor.run { ensureRemoteService() }
            let result: NSString? = try await service.withContinuation { service, continuation in
                service.sendAgentMessage(sessionID as NSString?, source: source, cwd: cwd as NSString?, message: message) { identifier in
                    continuation.resume(returning: identifier)
                }
            }
            return result as String?
        } catch {
            return nil
        }
    }
}

extension Notification.Name {
    static let accessibilityAuthorizationChanged = Notification.Name("accessibilityAuthorizationChanged")
}
