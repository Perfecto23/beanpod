import BeanKit
@preconcurrency import CoreBluetooth
import Foundation

struct FoundDevice: Identifiable, Equatable {
    let id: UUID
    var name: String
    var rssi: Int
    var mac: String?
    var bound: Bool
    var isBean: Bool
}

/// 蓝牙这一层只管三件事：找到录音豆、连上它、收发完整的帧。
final class BLEClient: NSObject, @preconcurrency CBCentralManagerDelegate, @preconcurrency CBPeripheralDelegate {
    enum Link: Equatable { case off, unauthorized, idle, scanning, connecting, ready }

    var onLink: (Link) -> Void = { _ in }
    var onFound: ([FoundDevice]) -> Void = { _ in }
    var onPacket: (Packet) -> Void = { _ in }
    var onLog: (String) -> Void = { _ in }

    private(set) var link: Link = .idle { didSet { if link != oldValue { onLink(link) } } }
    private var central: CBCentralManager!
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var found: [UUID: FoundDevice] = [:]
    private var active: CBPeripheral?
    private var writeChar: CBCharacteristic?
    private var notifyChar: CBCharacteristic?
    private var reassembler = Reassembler()
    private var wantsScan = false
    private var pendingServices = 0
    private var pendingMAC: String?

    private static let lastDeviceKey = "lastDeviceID"
    private static let lastMACKey = "lastDeviceMAC"
    /// 正在等上次那台设备出现：一边扫描，一边按 MAC 认它。
    /// 设备休眠后系统给它的标识可能会变，光靠标识回连会一直等不到。
    private var awaiting = false

    func start() {
        guard central == nil else { return }
        central = CBCentralManager(delegate: self, queue: .main)
    }

    var connectedName: String? { active?.name }

    // MARK: 扫描

    func scan() {
        wantsScan = true
        guard central?.state == .poweredOn, active == nil else { return }
        found.removeAll(); onFound([])
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        link = .scanning
        // 系统已经连着的设备不会再广播，单独捞一遍
        for p in central.retrieveConnectedPeripherals(withServices: [CBUUID(string: "020CF5DA")]) {
            peripherals[p.identifier] = p
            found[p.identifier] = FoundDevice(id: p.identifier, name: p.name ?? "soundcore Work", rssi: 0, mac: nil, bound: true, isBean: true)
        }
        publishFound()
    }

    func stopScan() {
        wantsScan = false
        if central?.isScanning == true { central.stopScan() }
        if link == .scanning { link = .idle }
    }

    private func publishFound() {
        onFound(found.values.sorted { ($0.isBean ? 1 : 0, $0.rssi) > ($1.isBean ? 1 : 0, $1.rssi) })
    }

    // MARK: 连接

    func connect(_ id: UUID) {
        guard let p = peripherals[id] ?? central.retrievePeripherals(withIdentifiers: [id]).first else { return }
        peripherals[id] = p
        if central.isScanning { central.stopScan() }
        wantsScan = false; awaiting = false
        pendingMAC = found[id]?.mac
        active = p
        p.delegate = self
        link = .connecting
        onLog("连接 \(p.name ?? id.uuidString)")
        central.connect(p)
    }

    /// 上次连过的设备，蓝牙就绪后自动回连。
    private func reconnectLast() -> Bool {
        guard UserDefaults.standard.string(forKey: Self.lastMACKey) != nil, central.state == .poweredOn, active == nil else { return false }
        awaiting = true
        found.removeAll()
        central.scanForPeripherals(withServices: nil, options: nil)
        link = .connecting
        onLog("等待上次的设备出现")
        return true
    }

    var hasRememberedDevice: Bool { UserDefaults.standard.string(forKey: Self.lastMACKey) != nil }

    func disconnect(forget: Bool) {
        awaiting = false
        if central?.isScanning == true { central.stopScan() }
        if forget {
            UserDefaults.standard.removeObject(forKey: Self.lastDeviceKey)
            UserDefaults.standard.removeObject(forKey: Self.lastMACKey)
        }
        if let p = active { central.cancelPeripheralConnection(p) }
        teardown()
        link = central?.state == .poweredOn ? .idle : .off
    }

    private func teardown() {
        active?.delegate = nil
        active = nil; writeChar = nil; notifyChar = nil
        reassembler.reset()
    }

    // MARK: 发送

    func send(_ frame: Data) {
        guard let p = active, let c = writeChar, link == .ready else { return }
        let type: CBCharacteristicWriteType = c.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
        let mtu = max(20, p.maximumWriteValueLength(for: type))
        onLog("→ \(Array(frame).hex)")
        var offset = 0
        while offset < frame.count {
            let end = min(offset + mtu, frame.count)
            p.writeValue(frame.subdata(in: (frame.startIndex + offset)..<(frame.startIndex + end)), for: c, type: type)
            offset = end
        }
    }

    // MARK: CBCentralManagerDelegate

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        onLog("蓝牙状态 \(central.state.rawValue)")
        switch central.state {
        case .poweredOn:
            link = .idle
            if active == nil, !reconnectLast(), wantsScan { scan() }
        case .unauthorized:
            teardown(); link = .unauthorized
        default:
            teardown(); link = .off
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData adv: [String: Any], rssi RSSI: NSNumber) {
        var uuids = (adv[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? [])
        uuids += adv[CBAdvertisementDataOverflowServiceUUIDsKey] as? [CBUUID] ?? []
        uuids += Array((adv[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data] ?? [:]).keys)
        let mfg = [UInt8](adv[CBAdvertisementDataManufacturerDataKey] as? Data ?? Data())
        let name = (adv[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name ?? ""

        let byService = uuids.contains { $0.uuidString.uppercased().contains("F5DA") }
        let byMark = mfg.count >= 14 && String(decoding: mfg[8..<14], as: UTF8.self).lowercased() == "soundc"
        let byName = name.lowercased().contains("soundcore")
        let isBean = byService || byMark || byName
        guard isBean || !name.isEmpty else { return }

        var device = FoundDevice(id: peripheral.identifier, name: name, rssi: RSSI.intValue, mac: nil, bound: false, isBean: isBean)
        if isBean, mfg.count >= 7 {
            device.mac = mfg[0..<6].map { String(format: "%02X", $0) }.joined(separator: ":")
            device.bound = mfg[6] & 0x80 != 0
        }
        if isBean, name.isEmpty {
            device.name = "soundcore Work" + (device.mac.map { " · " + $0.suffix(5).replacingOccurrences(of: ":", with: "") } ?? "")
        }
        peripherals[peripheral.identifier] = peripheral
        found[peripheral.identifier] = device
        if awaiting {
            let d = UserDefaults.standard
            let sameMAC = device.mac != nil && device.mac == d.string(forKey: Self.lastMACKey)
            if isBean, sameMAC || peripheral.identifier.uuidString == d.string(forKey: Self.lastDeviceKey) {
                connect(peripheral.identifier)
            }
            return
        }
        publishFound()
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        onLog("已建立连接，查找服务")
        peripheral.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        onLog("连接失败：\(error?.localizedDescription ?? "未知原因")")
        teardown(); link = .idle
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard peripheral.identifier == active?.identifier else { return }
        onLog("连接断开" + (error.map { "：\($0.localizedDescription)" } ?? ""))
        let id = peripheral.identifier
        teardown()
        link = .idle
        // 意外断开（走远、放回充电盒）就挂一个不超时的回连，设备回来会自动连上
        _ = id
        if error != nil { _ = reconnectLast() }
    }

    // MARK: CBPeripheralDelegate

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        let services = peripheral.services ?? []
        pendingServices = services.count
        if services.isEmpty { fail("设备没有提供任何服务") }
        services.forEach { peripheral.discoverCharacteristics(nil, for: $0) }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        for c in service.characteristics ?? [] {
            if c.uuid == CBUUID(string: BLEID.write) { writeChar = c }
            if c.uuid == CBUUID(string: BLEID.notify) { notifyChar = c }
        }
        pendingServices -= 1
        guard pendingServices <= 0 else { return }
        if let notifyChar, writeChar != nil {
            peripheral.setNotifyValue(true, for: notifyChar)
        } else {
            fail("没找到通信通道（7777 / 8888），这可能不是 D3200")
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == notifyChar?.uuid else { return }
        if let error { fail("无法订阅通知：\(error.localizedDescription)"); return }
        guard characteristic.isNotifying, link != .ready else { return }
        UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: Self.lastDeviceKey)
        if let pendingMAC { UserDefaults.standard.set(pendingMAC, forKey: Self.lastMACKey) }
        onLog("通道就绪")
        link = .ready
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let data = characteristic.value, characteristic.uuid == notifyChar?.uuid else { return }
        for packet in reassembler.feed(data) { onPacket(packet) }
    }

    private func fail(_ why: String) {
        onLog(why)
        if let p = active { central.cancelPeripheralConnection(p) }
        teardown(); link = .idle
    }
}
