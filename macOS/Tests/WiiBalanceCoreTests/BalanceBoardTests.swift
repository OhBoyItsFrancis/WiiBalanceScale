import XCTest
@testable import WiiBalanceCore

/// A fake Balance Board that answers the session's output reports like the real hardware.
final class SimulatedBoard {
    var calibrationBlock: [UInt8]
    var extensionType: [UInt8] = [0x00, 0x00, 0xA4, 0x20, 0x04, 0x02]
    var extensionConnected = true
    private(set) var received: [[UInt8]] = []
    private(set) var reportMode: UInt8?
    var deliver: ([UInt8]) -> Void = { _ in }

    init(calibration: BalanceBoardCalibration) {
        var block = [UInt8](repeating: 0, count: 32)
        let quads = [calibration.kg0, calibration.kg17, calibration.kg34]
        for (q, quad) in quads.enumerated() {
            for (i, value) in [quad.topRight, quad.bottomRight, quad.topLeft, quad.bottomLeft].enumerated() {
                block[4 + q * 8 + i * 2] = UInt8(value >> 8)
                block[4 + q * 8 + i * 2 + 1] = UInt8(value & 0xFF)
            }
        }
        calibrationBlock = block
    }

    func receive(_ report: [UInt8]) {
        received.append(report)
        switch WiiProtocol.OutputReportID(rawValue: report[0]) {
        case .status:
            deliver([0xA1, 0x20, 0x00, 0x00, extensionConnected ? 0x02 : 0x00, 0x00, 0x00, 0x83])
        case .writeMemory:
            deliver([0xA1, 0x22, 0x00, 0x00, 0x16, 0x00])
        case .readMemory:
            let address = UInt32(report[1]) << 24 | UInt32(report[2]) << 16 | UInt32(report[3]) << 8 | UInt32(report[4])
            let size = Int(report[5]) << 8 | Int(report[6])
            let memory: [UInt8]
            let base: UInt32
            if address == WiiProtocol.Register.extensionType {
                (memory, base) = (extensionType, address)
            } else {
                (memory, base) = (calibrationBlock, address)
            }
            var sent = 0
            while sent < size {
                let chunk = min(16, size - sent)
                let offset = UInt16((base & 0xFFFF) + UInt32(sent))
                var reply: [UInt8] = [0xA1, 0x21, 0x00, 0x00, UInt8((chunk - 1) << 4), UInt8(offset >> 8), UInt8(offset & 0xFF)]
                reply += memory[sent..<(sent + chunk)]
                reply += [UInt8](repeating: 0, count: 16 - chunk)
                deliver(reply)
                sent += chunk
            }
        case .reportType:
            reportMode = report[2]
        default:
            break
        }
    }

    func sendSensors(_ raw: SensorValues<Int>) {
        var report: [UInt8] = [0xA1, 0x32, 0x00, 0x00]
        for value in [raw.topRight, raw.bottomRight, raw.topLeft, raw.bottomLeft] {
            report += [UInt8(value >> 8), UInt8(value & 0xFF)]
        }
        report += [UInt8](repeating: 0, count: 8)
        deliver(report)
    }
}

final class BalanceBoardTests: XCTestCase {
    let calibration = BalanceBoardCalibration(
        kg0: SensorValues(topRight: 1000, bottomRight: 1100, topLeft: 1200, bottomLeft: 1300),
        kg17: SensorValues(topRight: 2700, bottomRight: 2800, topLeft: 2900, bottomLeft: 3000),
        kg34: SensorValues(topRight: 4400, bottomRight: 4500, topLeft: 4600, bottomLeft: 4700))

    func testOutputReports() {
        XCTAssertEqual(WiiProtocol.setLEDs(0x01), [0x11, 0x10])
        XCTAssertEqual(WiiProtocol.requestStatus(), [0x15, 0x00])
        XCTAssertEqual(WiiProtocol.setReportType(.buttonsExtension, continuous: true), [0x12, 0x04, 0x32])
        XCTAssertEqual(WiiProtocol.readMemory(address: 0x04A4_0020, size: 32), [0x17, 0x04, 0xA4, 0x00, 0x20, 0x00, 0x20])
        let write = WiiProtocol.writeMemory(address: 0x04A4_00F0, data: [0x55])
        XCTAssertEqual(write.count, 22)
        XCTAssertEqual(Array(write.prefix(7)), [0x16, 0x04, 0xA4, 0x00, 0xF0, 0x01, 0x55])
    }

    func testParsesInputReports() {
        XCTAssertEqual(InputReport([0x20, 0x00, 0x08, 0x02, 0x00, 0x00, 0x83]),
                       .status(StatusReport(buttons: 0x0008, flags: 0x02, batteryRaw: 0x83)))
        XCTAssertEqual(InputReport([0x22, 0x00, 0x00, 0x16, 0x00]), .acknowledge(reportID: 0x16, errorCode: 0))
        XCTAssertNil(InputReport([0x20, 0x00]))
        XCTAssertNil(InputReport([]))

        guard case .readData(let read)? = InputReport([0x21, 0, 0, 0x50, 0x00, 0xFA, 1, 2, 3, 4, 5, 6] + [UInt8](repeating: 0, count: 10)) else {
            return XCTFail("expected read data")
        }
        XCTAssertEqual(read.size, 6)
        XCTAssertEqual(read.offset, 0x00FA)
        XCTAssertEqual(read.data, [1, 2, 3, 4, 5, 6])

        guard case .extensionData(_, let bytes)? = InputReport([0x32, 0, 0, 1, 2, 3, 4, 5, 6, 7, 8]) else {
            return XCTFail("expected extension data")
        }
        XCTAssertEqual(bytes, [1, 2, 3, 4, 5, 6, 7, 8])
        XCTAssertEqual(WiiProtocol.stripInputHeader([0xA1, 0x30, 0, 0]), [0x30, 0, 0])
    }

    func testMemoryReadAssemblesChunks() {
        var assembler = MemoryReadAssembler(address: 0x04A4_0020, size: 20)
        let first = ReadDataReport(buttons: 0, size: 16, errorCode: 0, offset: 0x0020, data: Array(0..<16))
        let second = ReadDataReport(buttons: 0, size: 4, errorCode: 0, offset: 0x0030, data: Array(16..<20))
        XCTAssertEqual(assembler.accept(first), .incomplete)
        XCTAssertEqual(assembler.accept(second), .complete(Array(0..<20)))

        var failing = MemoryReadAssembler(address: 0x04A4_00FA, size: 6)
        XCTAssertEqual(failing.accept(ReadDataReport(buttons: 0, size: 1, errorCode: 8, offset: 0xFA, data: [0])), .failed(errorCode: 8))
    }

    func testCalibrationConversion() {
        let at0 = calibration.totalKilograms(extensionBytes: bytes(calibration.kg0))!
        let at17 = calibration.totalKilograms(extensionBytes: bytes(calibration.kg17))!
        let at34 = calibration.totalKilograms(extensionBytes: bytes(calibration.kg34))!
        XCTAssertEqual(at0, 0, accuracy: 1e-9)
        XCTAssertEqual(at17, 68, accuracy: 1e-9)
        XCTAssertEqual(at34, 136, accuracy: 1e-9)
        // Above the 34 kg point the curve keeps extrapolating linearly.
        let heavy = SensorValues(topRight: 6100, bottomRight: 6200, topLeft: 6300, bottomLeft: 6400)
        XCTAssertEqual(calibration.totalKilograms(extensionBytes: bytes(heavy))!, 204, accuracy: 1e-9)
        XCTAssertEqual(BalanceBoardCalibration(bytes: SimulatedBoard(calibration: calibration).calibrationBlock), calibration)
    }

    func testSessionHandshakeAndStreaming() {
        let board = SimulatedBoard(calibration: calibration)
        var states: [BalanceBoardSession.State] = []
        let session = BalanceBoardSession(send: board.receive)
        session.onStateChange = { states.append($0) }
        board.deliver = session.handle(report:)

        session.start()
        XCTAssertEqual(session.calibration, calibration)
        XCTAssertEqual(board.reportMode, 0x32)
        XCTAssertEqual(session.state, .initializing)

        board.sendSensors(calibration.kg17)
        XCTAssertEqual(session.state, .streaming)
        XCTAssertEqual(session.latestKilograms!, 68, accuracy: 1e-9)
        XCTAssertEqual(states, [.initializing, .streaming])

        // An unsolicited status report stops continuous reporting; the session must re-enable it.
        let before = board.received.count
        session.handle(report: [0xA1, 0x20, 0, 0, 0x02, 0, 0, 0x83])
        XCTAssertEqual(board.received.count, before + 1)
        XCTAssertEqual(board.received.last, [0x12, 0x04, 0x32])

        session.stop()
        XCTAssertEqual(session.state, .idle)
        XCTAssertNil(session.latestKilograms)
        board.sendSensors(calibration.kg17)
        XCTAssertEqual(session.state, .idle, "a stopped session ignores late reports")
        XCTAssertNil(session.latestKilograms)
    }

    func testSessionRejectsPlainWiiRemote() {
        let board = SimulatedBoard(calibration: calibration)
        board.extensionConnected = false
        let session = BalanceBoardSession(send: board.receive)
        board.deliver = session.handle(report:)
        session.start()
        guard case .failed = session.state else { return XCTFail("expected failure") }
    }

    func testSessionRejectsOtherExtension() {
        let board = SimulatedBoard(calibration: calibration)
        board.extensionType = [0x00, 0x00, 0xA4, 0x20, 0x00, 0x00] // Nunchuk
        let session = BalanceBoardSession(send: board.receive)
        board.deliver = session.handle(report:)
        session.start()
        guard case .failed = session.state else { return XCTFail("expected failure") }
        XCTAssertNil(session.calibration)
    }

    private func bytes(_ values: SensorValues<Int>) -> [UInt8] {
        [values.topRight, values.bottomRight, values.topLeft, values.bottomLeft].flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] }
    }
}
