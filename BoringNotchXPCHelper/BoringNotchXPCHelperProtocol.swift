//
//  BoringNotchXPCHelperProtocol.swift
//  BoringNotchXPCHelper
//
//  Created by Alexander on 2025-11-16.
//

import Foundation

/// The protocol that this service will vend as its API. This protocol will also need to be visible to the process hosting the service.
@objc protocol BoringNotchXPCHelperProtocol {
    func isAccessibilityAuthorized(with reply: @escaping (Bool) -> Void)
    func requestAccessibilityAuthorization()
    func ensureAccessibilityAuthorization(_ promptIfNeeded: Bool, with reply: @escaping (Bool) -> Void)
    // Keyboard backlight / CoreBrightness access (performed by the helper)
    func isKeyboardBrightnessAvailable(with reply: @escaping (Bool) -> Void)
    func currentKeyboardBrightness(with reply: @escaping (NSNumber?) -> Void)
    func setKeyboardBrightness(_ value: Float, with reply: @escaping (Bool) -> Void)
    // Screen brightness access (performed by the helper)
    func isScreenBrightnessAvailable(with reply: @escaping (Bool) -> Void)
    func currentScreenBrightness(with reply: @escaping (NSNumber?) -> Void)
    func setScreenBrightness(_ value: Float, with reply: @escaping (Bool) -> Void)
    // AI coding-agent bridge (runs outside the app sandbox)
    func startAgentBridge(with reply: @escaping (NSString?) -> Void)
    func stopAgentBridge()
    func agentSessionsRevision(_ detailSessionID: NSString?, with reply: @escaping (NSNumber) -> Void)
    func agentSessionsJSON(_ detailSessionID: NSString?, with reply: @escaping (NSData) -> Void)
    func codexUsageJSON(with reply: @escaping (NSData) -> Void)
    func respondToAgent(_ sessionID: String, responseJSON: NSData, with reply: @escaping (Bool) -> Void)
    func installAgentHooks(with reply: @escaping (NSArray) -> Void)
    func jumpToAgentTerminal(_ sessionID: String, with reply: @escaping (Bool) -> Void)
    func closeAgentSession(_ sessionID: String, with reply: @escaping (Bool) -> Void)
    func sendAgentMessage(_ sessionID: NSString?, source: String, cwd: NSString?, message: String, with reply: @escaping (NSString?) -> Void)
}

/*
 To use the service from an application or other process, use NSXPCConnection to establish a connection to the service by doing something like this:

     connectionToService = NSXPCConnection(serviceName: "theboringteam.boringnotch.BoringNotchXPCHelper")
     connectionToService.remoteObjectInterface = NSXPCInterface(with: (any BoringNotchXPCHelperProtocol).self)
     connectionToService.resume()

 Once you have a connection to the service, you can use it like this:

     if let proxy = connectionToService.remoteObjectProxy as? BoringNotchXPCHelperProtocol {
         proxy.performCalculation(firstNumber: 23, secondNumber: 19) { result in
             NSLog("Result of calculation is: \(result)")
         }
     }

 And, when you are finished with the service, clean up the connection like this:

     connectionToService.invalidate()
*/
