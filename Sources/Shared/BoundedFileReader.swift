import Darwin
import Foundation

/// Reads a regular file into memory using a single file descriptor, verifying file type
/// and size via `fstat` and enforcing the byte cap on the read loop itself.
/// Avoids memory-mapped I/O (`SIGBUS` on truncated or network-backed files).
enum BoundedFileReader {
    enum ReadError: Error {
        case fileTooLarge
    }

    static func dataContents(of url: URL, maxByteCount: Int) throws -> Data {
        guard maxByteCount >= 0 else {
            throw ReadError.fileTooLarge
        }
        guard url.isFileURL else {
            throw CocoaError(.fileReadUnsupportedScheme)
        }
        let fd = url.withUnsafeFileSystemRepresentation { pathPtr -> Int32 in
            guard let pathPtr else { return -1 }
            return Darwin.open(pathPtr, O_RDONLY | O_NONBLOCK)
        }
        guard fd >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        defer { _ = Darwin.close(fd) }

        var st = stat()
        guard Darwin.fstat(fd, &st) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        guard (st.st_mode & S_IFMT) == S_IFREG else {
            throw CocoaError(.fileReadUnknown)
        }
        guard st.st_size >= 0, st.st_size <= Int64(maxByteCount) else {
            throw ReadError.fileTooLarge
        }

        let declaredSize = Int(st.st_size)
        var data = Data()
        data.reserveCapacity(min(declaredSize, 4 * 1024 * 1024))

        let chunkSize = 64 * 1024
        var buffer = [UInt8](repeating: 0, count: chunkSize)
        while true {
            let remaining = maxByteCount - data.count
            let toRead = min(chunkSize, remaining + 1)
            let bytesRead: Int = buffer.withUnsafeMutableBytes { raw in
                Darwin.read(fd, raw.baseAddress, toRead)
            }
            if bytesRead > 0 {
                if bytesRead > remaining {
                    throw ReadError.fileTooLarge
                }
                data.append(buffer, count: bytesRead)
            } else if bytesRead == 0 {
                break
            } else {
                let err = errno
                if err == EINTR {
                    continue
                }
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(err))
            }
        }
        return data
    }
}
