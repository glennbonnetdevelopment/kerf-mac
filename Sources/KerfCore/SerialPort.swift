#if canImport(Darwin)
import Darwin
import Foundation
import IOKit
import IOKit.serial

public enum SerialError: Error, LocalizedError {
    case open(String, Int32)
    case configure(String)
    case write(Int32)
    case notOpen

    public var errorDescription: String? {
        switch self {
        case .open(let path, let code): return "Could not open \(path): \(String(cString: strerror(code)))"
        case .configure(let why): return "Could not configure the port: \(why)"
        case .write(let code): return "Write failed: \(String(cString: strerror(code)))"
        case .notOpen: return "The port is not open."
        }
    }
}

/// A POSIX serial port (USB-serial adapters appear as /dev/cu.*).
public final class SerialPort: @unchecked Sendable {
    public let path: String
    private var fd: Int32 = -1
    private var source: DispatchSourceRead?
    private let ioQueue = DispatchQueue(label: "kerf.serial.io")
    private let writeQueue = DispatchQueue(label: "kerf.serial.write")

    /// Called on the I/O queue when bytes arrive.
    public var onData: ((Data) -> Void)?
    /// Called on the I/O queue when the device disappears.
    public var onClose: (() -> Void)?

    public init(path: String) {
        self.path = path
    }

    deinit { close() }

    public var isOpen: Bool { fd >= 0 }

    /// Serial devices currently present, callout (`cu.`) devices only.
    /// Uses IOKit, which works inside the App Sandbox (listing /dev does not).
    public static func availablePorts() -> [String] {
        var paths = ioKitPorts()
        if paths.isEmpty {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? []
            paths = names.filter { $0.hasPrefix("cu.") }.map { "/dev/" + $0 }
        }
        return Array(Set(paths)).filter { !$0.contains("Bluetooth") && !$0.contains("debug-console") }.sorted()
    }

    static func ioKitPorts() -> [String] {
        guard let matching = IOServiceMatching(kIOSerialBSDServiceValue) else { return [] }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(mach_port_t(MACH_PORT_NULL), matching, &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var out: [String] = []
        var service = IOIteratorNext(iterator)
        while service != 0 {
            if let value = IORegistryEntryCreateCFProperty(service, kIOCalloutDeviceKey as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? String {
                out.append(value)
            }
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
        return out
    }

    public func open(baudRate: Int, flowControl: FlowControl) throws {
        guard fd < 0 else { return }
        let handle = Darwin.open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard handle >= 0 else { throw SerialError.open(path, errno) }

        var t = termios()
        guard tcgetattr(handle, &t) == 0 else {
            Darwin.close(handle)
            throw SerialError.configure("tcgetattr failed")
        }
        cfmakeraw(&t)
        t.c_cflag |= tcflag_t(CS8 | CLOCAL | CREAD)
        t.c_cflag &= ~tcflag_t(PARENB | CSTOPB)
        t.c_cflag &= ~tcflag_t(CCTS_OFLOW | CRTS_IFLOW)
        t.c_iflag &= ~tcflag_t(IXON | IXOFF | IXANY)
        switch flowControl {
        case .none: break
        case .hardware: t.c_cflag |= tcflag_t(CCTS_OFLOW | CRTS_IFLOW)
        case .software: t.c_iflag |= tcflag_t(IXON | IXOFF)
        }
        cfsetspeed(&t, speed_t(baudRate))
        guard tcsetattr(handle, TCSANOW, &t) == 0 else {
            Darwin.close(handle)
            throw SerialError.configure("unsupported settings (baud \(baudRate))")
        }
        tcflush(handle, TCIOFLUSH)
        fd = handle

        let src = DispatchSource.makeReadSource(fileDescriptor: handle, queue: ioQueue)
        src.setEventHandler { [weak self] in
            guard let self, self.fd >= 0 else { return }
            var buf = [UInt8](repeating: 0, count: 4096)
            let n = read(self.fd, &buf, buf.count)
            if n > 0 {
                self.onData?(Data(buf[0..<n]))
            } else if n == 0 || (n < 0 && errno != EAGAIN && errno != EINTR) {
                // Device unplugged.
                self.close()
                self.onClose?()
            }
        }
        source = src
        src.resume()
    }

    public func close() {
        source?.cancel()
        source = nil
        if fd >= 0 {
            Darwin.close(fd)
            fd = -1
        }
    }

    /// Writes all bytes, waiting while the OS buffer is full. Blocks the caller.
    public func writeAll(_ data: Data) throws {
        guard fd >= 0 else { throw SerialError.notOpen }
        var offset = 0
        let bytes = [UInt8](data)
        while offset < bytes.count {
            let n = bytes.withUnsafeBufferPointer { ptr in
                Darwin.write(fd, ptr.baseAddress! + offset, bytes.count - offset)
            }
            if n > 0 {
                offset += n
            } else if n < 0 && (errno == EAGAIN || errno == EINTR) {
                usleep(2000)
            } else {
                throw SerialError.write(errno)
            }
            if fd < 0 { throw SerialError.notOpen }
        }
    }

    /// Queues a write on a background queue; errors are reported through `completion`.
    public func write(_ data: Data, completion: ((Error?) -> Void)? = nil) {
        writeQueue.async { [weak self] in
            guard let self else { return }
            do {
                try self.writeAll(data)
                completion?(nil)
            } catch {
                completion?(error)
            }
        }
    }

    public func write(_ string: String, completion: ((Error?) -> Void)? = nil) {
        write(Data(string.utf8), completion: completion)
    }

    /// Blocks until the OS has transmitted everything written so far.
    public func drainOutput() {
        if fd >= 0 { tcdrain(fd) }
    }

    /// Waits until queued writes have been handed to the OS.
    public func drainWrites() {
        writeQueue.sync {}
    }
}
#endif
