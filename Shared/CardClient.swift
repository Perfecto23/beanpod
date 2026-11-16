import BeanKit
@preconcurrency import CoreBluetooth
import Foundation

/// 附近找到的一张得到录音卡。
struct FoundCard: Identifiable, Equatable {
    let id: UUID
    var name: String
    var rssi: Int
}

/// 得到 AI 录音卡的蓝牙这一层：找到它、连上、收发帧、读电量。
///
/// 和录音豆的 BLEClient 分开：两种设备可以同时连着，互不影响。协议见 BeanKit/GetSeed.swift。
/// 录音卡没有绑定、不用配对；同一时间只能被一台设备连着，手机 App 连着时要先关手机蓝牙。
final class CardClient: NSObject, @preconcurrency CBCentralManagerDelegate, @preconcurrency CBPeripheralDelegate {
    typealias Link = BLEClient.Link

    var onLink: (Link) -> Void = { _ in }
    var onFound: ([FoundCard]) -> Void = { _ in }
    var onFrame: (GetSeedFrame) -> Void = { _ in }
    var onBattery: (Int) -> Void = { _ in }
    var onLog: (String) -> Void = { _ in }

    private(set) var link: Link = .idle { didSet { if link != oldValue { onLink(link) } } }
    private var central: CBCentralManager!
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var found: [UUID: FoundCard] = [:]
    private var active: CBPeripheral?
    private var writeChar: CBCharacteristic?
    private var notifyChar: CBCharacteristic?
    private var batteryChar: CBCharacteristic?
    private var reassembler = GetSeedReassembler()
    private var wantsScan = false
    private var pendingServices = 0
    /// 正在等上次那张卡出现（按系统给的标识或名字认）。
    private var awaiting = false

    private static let lastIDKey = "lastCardID"
    private static let lastNameKey = "lastCardName"
    private static let batteryService = CBUUID(string: "180F")
    private static let batteryLevel = CBUUID(string: "2A19")

    func start() {
        guard central == nil else { return }
        central = CBCentralManager(delegate: self, queue: .main)
    }

    var connectedName: String? { active?.name }
    var hasRememberedCard: Bool { UserDefaults.standard.string(forKey: Self.lastIDKey) != nil }

    // MARK: 扫描

    func scan() {
        wantsScan = true
        guard central?.state == .poweredOn, active == nil else { return }
        found.removeAll(); onFound([])
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        link = .scanning
    }

    func stopScan() {
        wantsScan = false
        if central?.isScanning == true, !awaiting { central.stopScan() }
        if link == .scanning { link = .idle }
    }

    // MARK: 连接

    func connect(_ id: UUID) {
        guard let p = peripherals[id] ?? central.retrievePeripherals(withIdentifiers: [id]).first else { return }
        peripherals[id] = p
        if central.isScanning { central.stopScan() }
        wantsScan = false; awaiting = false
        active = p
        p.delegate = self
        link = .connecting
        onLog("录音卡：连接 \(p.name ?? id.uuidString)")
        central.connect(p)
    }

    /// 上次连过的卡：蓝牙就绪后一边扫描一边等它出现，出现就连。
    private func awaitLast() -> Bool {
        guard hasRememberedCard, central.state == .poweredOn, active == nil else { return false }
        awaiting = true
        found.removeAll()
        central.scanForPeripherals(withServices: nil, options: nil)
        link = .connecting
        onLog("录音卡：等待上次的卡出现")
        return true
    }

    func reconnect() { if active == nil, central?.state == .poweredOn { _ = awaitLast() } }

    func disconnect(forget: Bool) {
        awaiting = false
        if central?.isScanning == true { central.stopScan() }
        if forget {
            UserDefaults.standard.removeObject(forKey: Self.lastIDKey)
            UserDefaults.standard.removeObject(forKey: Self.lastNameKey)
        }
        if let p = active { central.cancelPeripheralConnection(p) }
        teardown()
        link = central?.state == .poweredOn ? .idle : .off
    }

    private func teardown() {
        active?.delegate = nil
        active = nil; writeChar = nil; notifyChar = nil; batteryChar = nil
        reassembler.reset()
    }

    // MARK: 发送

    func send(_ frame: Data) {
        guard let p = active, let c = writeChar, link == .ready else { return }
        let type: CBCharacteristicWriteType = c.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
        let mtu = max(20, p.maximumWriteValueLength(for: type))
        onLog("录音卡 → \(Array(frame.prefix(48)).hex)")
        var offset = 0
        while offset < frame.count {
            let end = min(offset + mtu, frame.count)
            p.writeValue(frame.subdata(in: (frame.startIndex + offset)..<(frame.startIndex + end)), for: c, type: type)
            offset = end
        }
    }

    // MARK: CBCentralManagerDelegate

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            link = .idle
            if active == nil, !awaitLast(), wantsScan { scan() }
        case .unauthorized:
            teardown(); link = .unauthorized
        default:
            teardown(); link = .off
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData adv: [String: Any], rssi RSSI: NSNumber) {
        let name = (adv[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name ?? ""
        let mfg = [UInt8](adv[CBAdvertisementDataManufacturerDataKey] as? Data ?? Data())
        // 广播里没有服务 UUID：名字是 Get- 开头，或者厂商 ID 是 0x544A（小端 4A 54）
        let byName = name.hasPrefix(GetSeed.namePrefix)
        let byMark = mfg.count >= 2 && UInt16(mfg[0]) | UInt16(mfg[1]) << 8 == GetSeed.companyID
        guard byName || byMark else { return }

        let card = FoundCard(id: peripheral.identifier, name: name.isEmpty ? String(localized: "得到录音卡") : name, rssi: RSSI.intValue)
        peripherals[peripheral.identifier] = peripheral
        found[peripheral.identifier] = card
        if awaiting {
            let d = UserDefaults.standard
            if peripheral.identifier.uuidString == d.string(forKey: Self.lastIDKey)
                || (!name.isEmpty && name == d.string(forKey: Self.lastNameKey)) {
                connect(peripheral.identifier)
            }
            return
        }
        onFound(found.values.sorted { $0.rssi > $1.rssi })
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        onLog("录音卡：已建立连接，查找服务")
        peripheral.discoverServices([CBUUID(string: GetSeed.service), Self.batteryService])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        onLog("录音卡：连接失败：\(error?.localizedDescription ?? "未知原因")")
        teardown(); link = .idle
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard peripheral.identifier == active?.identifier else { return }
        onLog("录音卡：连接断开" + (error.map { "：\($0.localizedDescription)" } ?? ""))
        teardown()
        link = .idle
        // 意外断开（走远了、没电了）：挂着等它回来
        if error != nil { _ = awaitLast() }
    }

    // MARK: CBPeripheralDelegate

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        let services = peripheral.services ?? []
        pendingServices = services.count
        if services.isEmpty { fail("这张卡没有提供录音通道（服务 9100）"); return }
        services.forEach { peripheral.discoverCharacteristics(nil, for: $0) }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        for c in service.characteristics ?? [] {
            if c.uuid == CBUUID(string: GetSeed.write) { writeChar = c }
            if c.uuid == CBUUID(string: GetSeed.notify) { notifyChar = c }
            if c.uuid == Self.batteryLevel { batteryChar = c }
        }
        pendingServices -= 1
        guard pendingServices <= 0 else { return }
        guard let notifyChar, writeChar != nil else { fail("没找到录音卡的控制通道（9101 / 9102）"); return }
        peripheral.setNotifyValue(true, for: notifyChar)
        // 标准电量服务：有就读一次，再订阅变化（订阅不了也没关系）
        if let batteryChar {
            peripheral.readValue(for: batteryChar)
            if batteryChar.properties.contains(.notify) { peripheral.setNotifyValue(true, for: batteryChar) }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == notifyChar?.uuid else { return }
        if let error { fail("录音卡：无法订阅通知：\(error.localizedDescription)"); return }
        guard characteristic.isNotifying, link != .ready else { return }
        UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: Self.lastIDKey)
        if let name = peripheral.name, !name.isEmpty { UserDefaults.standard.set(name, forKey: Self.lastNameKey) }
        onLog("录音卡：通道就绪")
        link = .ready
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let data = characteristic.value else { return }
        if characteristic.uuid == Self.batteryLevel, let level = data.first {
            onBattery(Int(level))
            return
        }
        guard characteristic.uuid == notifyChar?.uuid else { return }
        for frame in reassembler.feed(data) { onFrame(frame) }
    }

    private func fail(_ why: String) {
        onLog(why)
        if let p = active { central.cancelPeripheralConnection(p) }
        teardown(); link = .idle
    }
}
