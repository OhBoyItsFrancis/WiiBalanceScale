/*********************************************************************************
WiiBalanceScale

MIT License

Copyright (c) 2017-2023 Bernhard Schelling

Balance Board handling ported from WiimoteLib by Brian Peek (MIT License).
**********************************************************************************/

import Foundation

/// The four load sensors, in the order the board transmits them.
public struct SensorValues<Value: Equatable>: Equatable {
    public var topRight: Value
    public var bottomRight: Value
    public var topLeft: Value
    public var bottomLeft: Value

    public init(topRight: Value, bottomRight: Value, topLeft: Value, bottomLeft: Value) {
        self.topRight = topRight
        self.bottomRight = bottomRight
        self.topLeft = topLeft
        self.bottomLeft = bottomLeft
    }

    /// Reads four big endian 16 bit values starting at `offset`.
    init?(bigEndian bytes: [UInt8], offset: Int) where Value == Int {
        guard bytes.count >= offset + 8 else { return nil }
        func value(_ i: Int) -> Int { Int(bytes[offset + i * 2]) << 8 | Int(bytes[offset + i * 2 + 1]) }
        self.init(topRight: value(0), bottomRight: value(1), topLeft: value(2), bottomLeft: value(3))
    }
}

/// Factory calibration of the Balance Board: raw sensor readings at 0, 17 and 34 kg per sensor.
public struct BalanceBoardCalibration: Equatable {
    public var kg0: SensorValues<Int>
    public var kg17: SensorValues<Int>
    public var kg34: SensorValues<Int>

    public init(kg0: SensorValues<Int>, kg17: SensorValues<Int>, kg34: SensorValues<Int>) {
        self.kg0 = kg0
        self.kg17 = kg17
        self.kg34 = kg34
    }

    /// Parses the calibration block read from register 0xA40020 (at least 28 bytes).
    public init?(bytes: [UInt8]) {
        guard let kg0 = SensorValues(bigEndian: bytes, offset: 4),
              let kg17 = SensorValues(bigEndian: bytes, offset: 12),
              let kg34 = SensorValues(bigEndian: bytes, offset: 20) else { return nil }
        self.init(kg0: kg0, kg17: kg17, kg34: kg34)
    }

    /// Converts one raw sensor value to kilograms by interpolating between the calibration points.
    static func kilograms(raw: Int, min: Int, mid: Int, max: Int) -> Double {
        if max == mid || mid == min { return 0 }
        if raw < mid {
            return 17.0 * Double(raw - min) / Double(mid - min)
        }
        return 17.0 * Double(raw - mid) / Double(max - mid) + 17.0
    }

    public func sensorKilograms(raw: SensorValues<Int>) -> SensorValues<Double> {
        SensorValues(
            topRight: Self.kilograms(raw: raw.topRight, min: kg0.topRight, mid: kg17.topRight, max: kg34.topRight),
            bottomRight: Self.kilograms(raw: raw.bottomRight, min: kg0.bottomRight, mid: kg17.bottomRight, max: kg34.bottomRight),
            topLeft: Self.kilograms(raw: raw.topLeft, min: kg0.topLeft, mid: kg17.topLeft, max: kg34.topLeft),
            bottomLeft: Self.kilograms(raw: raw.bottomLeft, min: kg0.bottomLeft, mid: kg17.bottomLeft, max: kg34.bottomLeft))
    }

    /// Total weight on the board in kilograms for the extension bytes of a data report.
    public func totalKilograms(extensionBytes: [UInt8]) -> Double? {
        guard let raw = SensorValues(bigEndian: extensionBytes, offset: 0) else { return nil }
        let kg = sensorKilograms(raw: raw)
        return kg.topRight + kg.bottomRight + kg.topLeft + kg.bottomLeft
    }
}

/// Drives the initialization handshake with a connected Balance Board and turns its data
/// reports into weight readings. Transport independent: feed it incoming reports and it
/// hands outgoing reports to `send`.
public final class BalanceBoardSession {
    public enum State: Equatable {
        case idle
        case initializing
        case streaming
        case failed(String)
    }

    private enum Step: Equatable {
        case waitingForStatus
        case writingInit1
        case writingInit2
        case readingType(MemoryReadAssembler)
        case readingCalibration(MemoryReadAssembler)
        case done
        case stopped
    }

    /// Called with each outgoing report (starting with the report ID).
    public var send: ([UInt8]) -> Void
    public var onStateChange: ((State) -> Void)?

    public private(set) var state: State = .idle {
        didSet { if state != oldValue { onStateChange?(state) } }
    }
    public private(set) var calibration: BalanceBoardCalibration?
    /// Most recent total weight in kilograms (not zeroed or filtered).
    public private(set) var latestKilograms: Double?
    public private(set) var reportCount = 0
    public private(set) var batteryRaw: UInt8?

    private var step: Step = .waitingForStatus

    public init(send: @escaping ([UInt8]) -> Void) {
        self.send = send
    }

    /// Starts the handshake: light the LED and ask for a status report, which tells us whether
    /// the "extension" (the board's load sensors) is present.
    public func start() {
        step = .waitingForStatus
        calibration = nil
        latestKilograms = nil
        reportCount = 0
        state = .initializing
        send(WiiProtocol.setLEDs(0x01))
        send(WiiProtocol.requestStatus())
    }

    /// Forgets the connection, e.g. after the board disconnected.
    public func stop() {
        step = .stopped
        latestKilograms = nil
        state = .idle
    }

    public func handle(report bytes: [UInt8]) {
        guard let report = InputReport(WiiProtocol.stripInputHeader(bytes)) else { return }
        switch report {
        case .status(let status):
            batteryRaw = status.batteryRaw
            handleStatus(status)
        case .acknowledge(let reportID, let errorCode):
            handleAcknowledge(reportID: reportID, errorCode: errorCode)
        case .readData(let data):
            handleReadData(data)
        case .extensionData(_, let extensionBytes):
            guard step != .stopped, let calibration,
                  let kg = calibration.totalKilograms(extensionBytes: extensionBytes) else { return }
            latestKilograms = kg
            reportCount += 1
            if state == .initializing, step == .done { state = .streaming }
        case .other:
            break
        }
    }

    private func handleStatus(_ status: StatusReport) {
        switch step {
        case .waitingForStatus:
            guard status.extensionConnected else {
                fail("The connected device is not a Wii Balance Board.")
                return
            }
            step = .writingInit1
            send(WiiProtocol.writeMemory(address: WiiProtocol.Register.extensionInit1, data: [0x55]))
        case .done:
            // Any status report stops continuous reporting, so request it again.
            send(WiiProtocol.setReportType(.buttonsExtension, continuous: true))
        default:
            break
        }
    }

    private func handleAcknowledge(reportID: UInt8, errorCode: UInt8) {
        guard reportID == WiiProtocol.OutputReportID.writeMemory.rawValue else { return }
        // Write errors during init are not fatal (WiimoteLib ignores them too); the type read decides.
        switch step {
        case .writingInit1:
            step = .writingInit2
            send(WiiProtocol.writeMemory(address: WiiProtocol.Register.extensionInit2, data: [0x00]))
        case .writingInit2:
            step = .readingType(MemoryReadAssembler(address: WiiProtocol.Register.extensionType, size: 6))
            send(WiiProtocol.readMemory(address: WiiProtocol.Register.extensionType, size: 6))
        default:
            break
        }
    }

    private func handleReadData(_ data: ReadDataReport) {
        switch step {
        case .readingType(var assembler):
            switch assembler.accept(data) {
            case .incomplete:
                step = .readingType(assembler)
            case .failed(let code):
                fail("Could not read the extension type (error \(code)).")
            case .complete(let bytes):
                let type = bytes.reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
                guard type == WiiProtocol.balanceBoardExtensionID else {
                    fail("The connected device is not a Wii Balance Board.")
                    return
                }
                step = .readingCalibration(MemoryReadAssembler(address: WiiProtocol.Register.extensionCalibration, size: 32))
                send(WiiProtocol.readMemory(address: WiiProtocol.Register.extensionCalibration, size: 32))
            }
        case .readingCalibration(var assembler):
            switch assembler.accept(data) {
            case .incomplete:
                step = .readingCalibration(assembler)
            case .failed(let code):
                fail("Could not read the Balance Board calibration (error \(code)).")
            case .complete(let bytes):
                calibration = BalanceBoardCalibration(bytes: bytes)
                step = .done
                send(WiiProtocol.setReportType(.buttonsExtension, continuous: true))
            }
        default:
            break
        }
    }

    private func fail(_ message: String) {
        step = .stopped
        state = .failed(message)
    }
}
