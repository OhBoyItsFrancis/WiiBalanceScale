/*********************************************************************************
WiiBalanceScale

MIT License

Copyright (c) 2017-2023 Bernhard Schelling
Copyright (c) 2023 Carl Ansell

Wii Remote protocol details ported from WiimoteLib by Brian Peek (MIT License)
and documented at https://wiibrew.org/wiki/Wiimote
**********************************************************************************/

import Foundation

/// Encoding and decoding of the HID reports spoken by Wii Remotes and the Wii Balance Board.
///
/// All report byte arrays in this file start with the report ID. The Bluetooth HID transaction
/// header (`0xA2` for output, `0xA1` for input) is added/removed by the transport.
public enum WiiProtocol {
    /// Bluetooth names advertised by Nintendo devices that speak the Wii Remote protocol.
    public static let balanceBoardName = "Nintendo RVL-WBC-01"
    public static let deviceNamePrefix = "Nintendo RVL-"

    /// HID header byte for reports sent to the device (DATA | OUTPUT).
    public static let outputHeader: UInt8 = 0xA2
    /// HID header byte for reports received from the device (DATA | INPUT).
    public static let inputHeader: UInt8 = 0xA1

    /// L2CAP channels used by Bluetooth HID devices.
    public static let controlPSM: UInt16 = 0x11
    public static let interruptPSM: UInt16 = 0x13

    /// Extension identifier reported by the Balance Board at register 0xA400FA.
    public static let balanceBoardExtensionID: UInt64 = 0x0000_A420_0402

    public enum Register {
        public static let extensionInit1: UInt32 = 0x04A4_00F0
        public static let extensionInit2: UInt32 = 0x04A4_00FB
        public static let extensionType: UInt32 = 0x04A4_00FA
        public static let extensionCalibration: UInt32 = 0x04A4_0020
    }

    public enum OutputReportID: UInt8 {
        case leds = 0x11
        case reportType = 0x12
        case status = 0x15
        case writeMemory = 0x16
        case readMemory = 0x17
    }

    public enum InputReportID: UInt8 {
        case status = 0x20
        case readData = 0x21
        case acknowledge = 0x22
        case buttons = 0x30
        case buttonsAccel = 0x31
        case buttonsExtension = 0x32
        case buttonsAccelIR = 0x33
        case buttonsExtension19 = 0x34
        case buttonsAccelExtension = 0x35
        case buttonsIRExtension = 0x36
        case buttonsAccelIRExtension = 0x37
        case extensionOnly = 0x3D
    }

    // MARK: Output reports

    /// Turns on the given LEDs (bit 0 = LED 1). The Balance Board only has LED 1, the blue power LED.
    public static func setLEDs(_ leds: UInt8) -> [UInt8] {
        [OutputReportID.leds.rawValue, (leds & 0x0F) << 4]
    }

    public static func requestStatus() -> [UInt8] {
        [OutputReportID.status.rawValue, 0x00]
    }

    public static func setReportType(_ type: InputReportID, continuous: Bool) -> [UInt8] {
        [OutputReportID.reportType.rawValue, continuous ? 0x04 : 0x00, type.rawValue]
    }

    public static func readMemory(address: UInt32, size: UInt16) -> [UInt8] {
        [
            OutputReportID.readMemory.rawValue,
            UInt8((address >> 24) & 0xFF),
            UInt8((address >> 16) & 0xFF),
            UInt8((address >> 8) & 0xFF),
            UInt8(address & 0xFF),
            UInt8(size >> 8),
            UInt8(size & 0xFF),
        ]
    }

    public static func writeMemory(address: UInt32, data: [UInt8]) -> [UInt8] {
        precondition(data.count >= 1 && data.count <= 16, "A memory write carries 1 to 16 bytes")
        var report: [UInt8] = [
            OutputReportID.writeMemory.rawValue,
            UInt8((address >> 24) & 0xFF),
            UInt8((address >> 16) & 0xFF),
            UInt8((address >> 8) & 0xFF),
            UInt8(address & 0xFF),
            UInt8(data.count),
        ]
        report += data
        report += [UInt8](repeating: 0, count: 16 - data.count)
        return report
    }

    // MARK: Input reports

    /// Strips the Bluetooth HID input header if present.
    public static func stripInputHeader(_ packet: [UInt8]) -> [UInt8] {
        if let first = packet.first, first == inputHeader { return Array(packet.dropFirst()) }
        return packet
    }
}

public struct StatusReport: Equatable {
    public var buttons: UInt16
    public var flags: UInt8
    public var batteryRaw: UInt8

    public var extensionConnected: Bool { flags & 0x02 != 0 }
}

public struct ReadDataReport: Equatable {
    public var buttons: UInt16
    /// Number of valid bytes in `data` (1-16).
    public var size: Int
    /// 0 on success, 7 when reading a write-only register, 8 when the address does not exist.
    public var errorCode: UInt8
    /// Lower 16 bits of the address of the first byte in `data`.
    public var offset: UInt16
    public var data: [UInt8]
}

public enum InputReport: Equatable {
    case status(StatusReport)
    case readData(ReadDataReport)
    case acknowledge(reportID: UInt8, errorCode: UInt8)
    /// A data report containing extension bytes (for the Balance Board: the four load sensors).
    case extensionData(buttons: UInt16, bytes: [UInt8])
    case other(reportID: UInt8)

    /// Parses a report that starts with its report ID. Returns nil for truncated reports.
    public init?(_ report: [UInt8]) {
        guard let id = report.first else { return nil }
        func buttons() -> UInt16 { UInt16(report[1]) << 8 | UInt16(report[2]) }

        switch WiiProtocol.InputReportID(rawValue: id) {
        case .status:
            guard report.count >= 7 else { return nil }
            self = .status(StatusReport(buttons: buttons(), flags: report[3], batteryRaw: report[6]))
        case .readData:
            guard report.count >= 6 else { return nil }
            let size = Int(report[3] >> 4) + 1
            let available = max(0, min(size, report.count - 6))
            self = .readData(ReadDataReport(
                buttons: buttons(),
                size: size,
                errorCode: report[3] & 0x0F,
                offset: UInt16(report[4]) << 8 | UInt16(report[5]),
                data: Array(report[6..<(6 + available)])))
        case .acknowledge:
            guard report.count >= 5 else { return nil }
            self = .acknowledge(reportID: report[3], errorCode: report[4])
        case .buttonsExtension, .buttonsExtension19:
            guard report.count >= 11 else { return nil }
            self = .extensionData(buttons: buttons(), bytes: Array(report[3...]))
        case .buttonsAccelExtension:
            guard report.count >= 14 else { return nil }
            self = .extensionData(buttons: buttons(), bytes: Array(report[6...]))
        case .buttonsAccelIRExtension:
            guard report.count >= 25 else { return nil }
            self = .extensionData(buttons: buttons(), bytes: Array(report[16...]))
        case .extensionOnly:
            guard report.count >= 9 else { return nil }
            self = .extensionData(buttons: 0, bytes: Array(report[1...]))
        default:
            self = .other(reportID: id)
        }
    }
}

/// Collects the (possibly multiple) read-data reports answering one memory read request.
public struct MemoryReadAssembler: Equatable {
    public enum Progress: Equatable {
        case incomplete
        case complete([UInt8])
        case failed(errorCode: UInt8)
    }

    public let address: UInt32
    public let size: Int
    private var buffer: [UInt8]

    public init(address: UInt32, size: Int) {
        self.address = address
        self.size = size
        self.buffer = [UInt8](repeating: 0, count: size)
    }

    public mutating func accept(_ report: ReadDataReport) -> Progress {
        if report.errorCode != 0 { return .failed(errorCode: report.errorCode) }
        let start = Int(report.offset) - Int(address & 0xFFFF)
        guard start >= 0, start < size else { return .incomplete } // not part of this read
        let count = min(report.data.count, size - start)
        buffer.replaceSubrange(start..<(start + count), with: report.data[0..<count])
        // Like WiimoteLib, the read is done when the chunk ending at the last requested byte arrives.
        return (start + count == size) ? .complete(buffer) : .incomplete
    }
}
