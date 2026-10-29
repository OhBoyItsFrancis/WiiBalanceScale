import Foundation
import IOBluetooth
import WiiBalanceCore

protocol BluetoothTransportDelegate: AnyObject {
    func transport(_ transport: BluetoothTransport, didChangeStatus status: BluetoothTransport.Status)
    func transportDidConnect(_ transport: BluetoothTransport)
    func transport(_ transport: BluetoothTransport, didReceive report: [UInt8])
    func transportDidDisconnect(_ transport: BluetoothTransport)
}

/// Finds a Wii Balance Board with a Bluetooth inquiry and talks to it over the two L2CAP
/// channels used by Bluetooth HID devices. The board does not need to be paired with the Mac:
/// pressing its red SYNC button makes it discoverable and accept the connection.
///
/// This replaces WiimoteLib's Windows HID access and the Windows `ConnectionManager`.
/// All callbacks arrive on the main run loop.
final class BluetoothTransport: NSObject {
    enum Status: Equatable {
        case idle
        case unavailable(String)
        case searching
        case connecting(String)
        case connected(String)
    }

    weak var delegate: BluetoothTransportDelegate?

    private(set) var status: Status = .idle {
        didSet {
            if status != oldValue { delegate?.transport(self, didChangeStatus: status) }
        }
    }

    private var inquiry: IOBluetoothDeviceInquiry?
    private var device: IOBluetoothDevice?
    private var deviceName = ""
    private var controlChannel: IOBluetoothL2CAPChannel?
    private var interruptChannel: IOBluetoothL2CAPChannel?
    private var wantsConnection = false
    private var retryScheduled = false
    /// Devices that turned out not to be balance boards (e.g. Wii Remotes); skipped from now on.
    private var ignoredAddresses = Set<String>()

    // MARK: Public interface

    /// Starts searching and keeps (re)connecting until `stop()` is called.
    func start() {
        wantsConnection = true
        startInquiry()
    }

    func stop() {
        wantsConnection = false
        inquiry?.stop()
        closeConnection()
        status = .idle
    }

    /// Drops the current connection and searches again, optionally ignoring the device.
    func reconnect(ignoringCurrentDevice: Bool = false) {
        if ignoringCurrentDevice, let address = device?.addressString {
            ignoredAddresses.insert(address)
        }
        let wasConnected = device != nil
        closeConnection()
        if wasConnected { delegate?.transportDidDisconnect(self) }
        status = .searching
        scheduleRetry(after: 1)
    }

    /// Sends an output report (starting with its report ID) on the interrupt channel.
    func send(_ report: [UInt8]) {
        // Defer to the next run loop pass: sends are often triggered from inside a receive
        // callback and IOBluetooth does not like re-entrant synchronous writes there.
        DispatchQueue.main.async { [weak self] in
            guard let channel = self?.interruptChannel else { return }
            var packet = [WiiProtocol.outputHeader] + report
            let length = UInt16(packet.count)
            let result = packet.withUnsafeMutableBytes { buffer in
                channel.writeSync(buffer.baseAddress, length: length)
            }
            if result != kIOReturnSuccess {
                NSLog("WiiBalanceScale: write failed (0x%08x)", result)
            }
        }
    }

    // MARK: Discovery

    private func startInquiry() {
        retryScheduled = false
        guard wantsConnection, device == nil else { return }

        guard let controller = IOBluetoothHostController.default(), controller.addressAsString() != nil else {
            status = .unavailable("No Bluetooth adapter was found.")
            scheduleRetry(after: 3)
            return
        }
        guard controller.powerState == kBluetoothHCIPowerStateON else {
            status = .unavailable("Bluetooth is turned off. Turn it on in System Settings.")
            scheduleRetry(after: 3)
            return
        }

        if inquiry == nil {
            inquiry = IOBluetoothDeviceInquiry(delegate: self)
            inquiry?.inquiryLength = 4
            inquiry?.updateNewDeviceNames = true
        }
        // Forget earlier results so a board seen before (e.g. a failed attempt) is reported again.
        inquiry?.clearFoundDevices()
        guard let inquiry, inquiry.start() == kIOReturnSuccess else {
            status = .unavailable("Could not start a Bluetooth search.")
            scheduleRetry(after: 3)
            return
        }
        status = .searching
    }

    private func scheduleRetry(after seconds: Double) {
        guard wantsConnection, !retryScheduled else { return }
        retryScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            self?.startInquiry()
        }
    }

    private func consider(_ candidate: IOBluetoothDevice?) {
        guard wantsConnection, device == nil, let candidate,
              let name = candidate.name, name.hasPrefix(WiiProtocol.deviceNamePrefix),
              !ignoredAddresses.contains(candidate.addressString ?? "") else { return }
        inquiry?.stop()
        connect(to: candidate, name: name)
    }

    // MARK: Connection

    private func connect(to candidate: IOBluetoothDevice, name: String) {
        device = candidate
        deviceName = name == WiiProtocol.balanceBoardName ? "Wii Balance Board" : name
        status = .connecting(deviceName)

        // The interrupt channel is opened once the control channel is up (see l2capChannelOpenComplete).
        var channel: IOBluetoothL2CAPChannel?
        let result = candidate.openL2CAPChannelAsync(&channel, withPSM: BluetoothL2CAPPSM(WiiProtocol.controlPSM), delegate: self)
        guard result == kIOReturnSuccess else {
            connectionFailed()
            return
        }
        controlChannel = channel
    }

    private func openInterruptChannel() {
        guard let device else { return }
        var channel: IOBluetoothL2CAPChannel?
        let result = device.openL2CAPChannelAsync(&channel, withPSM: BluetoothL2CAPPSM(WiiProtocol.interruptPSM), delegate: self)
        guard result == kIOReturnSuccess else {
            connectionFailed()
            return
        }
        interruptChannel = channel
    }

    private func connectionFailed() {
        closeConnection()
        status = .searching
        scheduleRetry(after: 1)
    }

    private func closeConnection() {
        for channel in [interruptChannel, controlChannel] {
            guard let channel else { continue }
            channel.setDelegate(nil)
            channel.close()
        }
        interruptChannel = nil
        controlChannel = nil
        device?.closeConnection()
        device = nil
    }
}

extension BluetoothTransport: IOBluetoothDeviceInquiryDelegate {
    func deviceInquiryDeviceFound(_ sender: IOBluetoothDeviceInquiry!, device: IOBluetoothDevice!) {
        consider(device)
    }

    func deviceInquiryDeviceNameUpdated(_ sender: IOBluetoothDeviceInquiry!, device: IOBluetoothDevice!, devicesRemaining: UInt32) {
        consider(device)
    }

    func deviceInquiryComplete(_ sender: IOBluetoothDeviceInquiry!, error: IOReturn, aborted: Bool) {
        // Nothing found yet: keep looking until the user presses SYNC on the board.
        if device == nil { scheduleRetry(after: 0.5) }
    }
}

extension BluetoothTransport: IOBluetoothL2CAPChannelDelegate {
    func l2capChannelOpenComplete(_ l2capChannel: IOBluetoothL2CAPChannel!, status error: IOReturn) {
        guard device != nil else { return }
        guard error == kIOReturnSuccess else {
            NSLog("WiiBalanceScale: opening L2CAP channel failed (0x%08x)", error)
            connectionFailed()
            return
        }
        if l2capChannel === controlChannel {
            openInterruptChannel()
        } else if l2capChannel === interruptChannel {
            status = .connected(deviceName)
            delegate?.transportDidConnect(self)
        }
    }

    func l2capChannelData(_ l2capChannel: IOBluetoothL2CAPChannel!, data dataPointer: UnsafeMutableRawPointer!, length dataLength: Int) {
        guard l2capChannel === interruptChannel, let dataPointer, dataLength > 0 else { return }
        let report = [UInt8](UnsafeRawBufferPointer(start: dataPointer, count: dataLength))
        delegate?.transport(self, didReceive: report)
    }

    func l2capChannelClosed(_ l2capChannel: IOBluetoothL2CAPChannel!) {
        guard l2capChannel === interruptChannel || l2capChannel === controlChannel else { return }
        // The board was switched off, ran out of battery or went out of range.
        closeConnection()
        delegate?.transportDidDisconnect(self)
        status = .searching
        scheduleRetry(after: 1)
    }
}
