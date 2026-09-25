import AppKit
import AudioToolbox
import CoreBluetooth
import CoreAudio
import IOBluetooth
import SwiftUI

@MainActor
final class BluetoothAccessoryMonitor: NSObject, ObservableObject {
    static let shared = BluetoothAccessoryMonitor()

    @Published private(set) var isVisible = false
    @Published private(set) var accessoryName = "蓝牙耳机"
    @Published private(set) var batteryPercent: Int?
    @Published private(set) var batteryLookupCompleted = false

    private let batteryService = CBUUID(string: "180F")
    private let batteryCharacteristic = CBUUID(string: "2A19")
    private var central: CBCentralManager?
    private var batteryPeripheral: CBPeripheral?
    private var hideTask: Task<Void, Never>?
    private var batteryLookupTask: Task<Void, Never>?
    private var didStart = false
    private var defaultOutputListener: AudioObjectPropertyListenerBlock?
    private var bluetoothConnectNotification: IOBluetoothUserNotification?
    private let listenerQueue = DispatchQueue.main

    private override init() {
        super.init()
    }

    func start() {
        guard !didStart else { return }
        didStart = true
        bluetoothConnectNotification = IOBluetoothDevice.register(
            forConnectNotifications: self,
            selector: #selector(bluetoothDeviceConnected(_:device:))
        )

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in self?.refreshOutputRoute() }
        }
        defaultOutputListener = listener
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, listenerQueue, listener
        )
        refreshOutputRoute()
    }

    private func refreshOutputRoute() {
        let deviceID = defaultOutputDeviceID()
        guard deviceID != kAudioObjectUnknown,
              readUInt32(deviceID: deviceID, selector: kAudioDevicePropertyTransportType)
                .map(isBluetoothTransport) == true else {
            hideTask?.cancel()
            withAnimation(.snappy(duration: 0.28)) { isVisible = false }
            if let batteryPeripheral {
                central?.cancelPeripheralConnection(batteryPeripheral)
            }
            batteryLookupTask?.cancel()
            batteryPeripheral = nil
            batteryPercent = nil
            batteryLookupCompleted = false
            central = nil
            return
        }

        showAccessory(name: readDeviceName(deviceID: deviceID) ?? "蓝牙耳机")
    }

    @objc private func bluetoothDeviceConnected(
        _ notification: IOBluetoothUserNotification,
        device: IOBluetoothDevice
    ) {
        guard device.deviceClassMajor == kBluetoothDeviceClassMajorAudio else { return }
        showAccessory(name: device.nameOrAddress ?? "蓝牙耳机")
    }

    private func showAccessory(name: String) {
        accessoryName = name
        batteryPercent = nil
        batteryLookupCompleted = false
        batteryLookupTask?.cancel()
        hideTask?.cancel()
        withAnimation(.snappy(duration: 0.32)) { isVisible = true }
        lookupBatteryForConnectedAccessories()
        batteryLookupTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.batteryLookupCompleted = true
        }
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled else { return }
            self?.isVisible = false
        }
    }

    private func lookupBatteryForConnectedAccessories() {
        if central == nil {
            central = CBCentralManager(delegate: self, queue: .main)
        } else if central?.state == .poweredOn {
            retrieveBatteryServicePeripherals()
        }
    }

    private func retrieveBatteryServicePeripherals() {
        guard let central, central.state == .poweredOn else {
            batteryLookupCompleted = true
            return
        }
        let peripherals = central.retrieveConnectedPeripherals(withServices: [batteryService])
        guard let peripheral = peripherals.first else {
            batteryLookupCompleted = true
            return
        }
        batteryPeripheral = peripheral
        peripheral.delegate = self
        central.connect(peripheral)
    }

    private func defaultOutputDeviceID() -> AudioObjectID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
        )
        return status == noErr ? deviceID : kAudioObjectUnknown
    }

    private func readUInt32(deviceID: AudioObjectID, selector: AudioObjectPropertySelector) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(deviceID, &address) else { return nil }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value) == noErr else {
            return nil
        }
        return value
    }

    private func readDeviceName(deviceID: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &name) == noErr else {
            return nil
        }
        let value = name as String
        return value.isEmpty ? nil : value
    }

    private func isBluetoothTransport(_ transport: UInt32) -> Bool {
        transport == kAudioDeviceTransportTypeBluetooth
            || transport == kAudioDeviceTransportTypeBluetoothLE
    }
}

extension BluetoothAccessoryMonitor: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor [weak self] in
            guard central.state == .poweredOn else { return }
            self?.retrieveBatteryServicePeripherals()
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([CBUUID(string: "180F")])
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        Task { @MainActor [weak self] in
            guard self?.batteryPeripheral?.identifier == peripheral.identifier else { return }
            self?.batteryLookupCompleted = true
        }
    }
}

extension BluetoothAccessoryMonitor: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil,
              let service = peripheral.services?.first(where: { $0.uuid == CBUUID(string: "180F") }) else { return }
        peripheral.discoverCharacteristics([CBUUID(string: "2A19")], for: service)
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        guard error == nil,
              let characteristic = service.characteristics?.first(where: { $0.uuid == CBUUID(string: "2A19") }) else { return }
        peripheral.readValue(for: characteristic)
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard error == nil,
              characteristic.uuid == CBUUID(string: "2A19"),
              let rawValue = characteristic.value?.first else { return }
        let percent = min(100, Int(rawValue))
        Task { @MainActor [weak self] in
            guard self?.batteryPeripheral?.identifier == peripheral.identifier else { return }
            self?.batteryPercent = percent
            self?.batteryLookupCompleted = true
        }
    }
}

struct BluetoothAccessoryHUD: View {
    let name: String
    let batteryPercent: Int?
    let isBatteryResolved: Bool

    var body: some View {
        HStack(spacing: 13) {
            Image(systemName: "headphones")
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 3) {
                Text(name).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                Text(statusText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            if let batteryPercent {
                Image(systemName: "battery.\(batterySymbolLevel(batteryPercent))")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(batteryPercent <= 20 ? .orange : .white)
                Text("\(batteryPercent)%")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .monospacedDigit()
            } else {
                Image(systemName: "battery.0")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
            }
        }
        .padding(.horizontal, 17)
        .frame(width: 330, height: 64)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(.white.opacity(0.1), lineWidth: 0.7))
        .shadow(color: .black.opacity(0.3), radius: 16, y: 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(batteryPercent.map { "\(name)，电量\($0)%" } ?? "\(name)，\(statusText)")
    }

    private var statusText: String {
        if let batteryPercent { return "耳机电量  \(batteryPercent)%" }
        return isBatteryResolved ? "已连接 · 耳机未提供电量" : "已连接 · 正在读取电量…"
    }

    private func batterySymbolLevel(_ percent: Int) -> Int {
        switch percent {
        case 0..<25: 0
        case 25..<50: 25
        case 50..<75: 50
        default: 100
        }
    }
}
