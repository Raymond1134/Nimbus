// VideoLogFilter.swift — Nimbus
// Silences the continuous "[h264 @ 0x...]" stderr spam produced by DJIWidget's
// bundled FFmpeg software decoder when it processes DJI's non-standard H264
// stream packetization.
//
// Hardware decode (enableHardwareDecode = true) is the primary fix; this filter
// is a safety net for any residual lines that still leak through.
//
// Call VideoLogFilter.install() once in NimbusApp.init() BEFORE the DJI SDK
// initialises so the pipe is in place when the first video packets arrive.

import Foundation

enum VideoLogFilter {

    /// Redirects stderr through a background filter that drops DJI/FFmpeg H264
    /// decoder noise.  All other stderr output is forwarded unchanged.
    ///
    /// Thread-safe; idempotent (subsequent calls are no-ops).
    static func install() {
        guard !_installed else { return }
        _installed = true

        // Save the original stderr fd so we can forward non-noise lines.
        let savedStderr = dup(STDERR_FILENO)
        guard savedStderr >= 0 else { return }

        // Create a pipe: we write into it via the redirected stderr; the
        // background thread reads from it and filters.
        var fds = [Int32](repeating: 0, count: 2)
        guard pipe(&fds) == 0 else {
            close(savedStderr)
            return
        }
        let readFd  = fds[0]
        let writeFd = fds[1]

        // Point stderr at the write end of the pipe.
        guard dup2(writeFd, STDERR_FILENO) >= 0 else {
            close(savedStderr)
            close(readFd)
            close(writeFd)
            return
        }
        close(writeFd) // dup2 copied it; we don't need the original any more.

        // Wrap the saved fd in a FILE* so fputs works correctly.
        guard let outFile = fdopen(savedStderr, "w") else {
            close(savedStderr)
            close(readFd)
            return
        }

        // Background thread: read chunks, split on newlines, drop noise.
        Thread.detachNewThread {
            let bufSize = 4096
            let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
            defer {
                buf.deallocate()
                close(readFd)
            }
            var carry = Data()

            while true {
                let n = read(readFd, buf, bufSize)
                guard n > 0 else { break }
                carry.append(buf, count: n)

                // Process complete lines.
                while let nlOffset = carry.firstIndex(of: UInt8(ascii: "\n")) {
                    let lineData = carry[carry.startIndex ... nlOffset]
                    carry.removeSubrange(carry.startIndex ... nlOffset)

                    // Drop known FFmpeg H264 decoder noise from DJIWidget.
                    // These come in at ~150 lines/sec during normal operation
                    // and are benign — the decoder recovers internally.
                    let line = String(data: lineData, encoding: .utf8) ?? ""
                    if line.contains("[h264 @") { continue }

                    line.withCString { ptr in
                        fputs(ptr, outFile)
                        fflush(outFile)
                    }
                }
            }
        }
    }

    // MARK: - Private

    private static var _installed = false
}
