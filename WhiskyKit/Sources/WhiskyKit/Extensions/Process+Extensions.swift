//
//  Process+Extensions.swift
//  WhiskyKit
//
//  This file is part of Whisky.
//
//  Whisky is free software: you can redistribute it and/or modify it under the terms
//  of the GNU General Public License as published by the Free Software Foundation,
//  either version 3 of the License, or (at your option) any later version.
//
//  Whisky is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY;
//  without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
//  See the GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License along with Whisky.
//  If not, see https://www.gnu.org/licenses/.
//

import Foundation
import os.log

public enum ProcessOutput: Hashable {
    case started(Process)
    case message(String)
    case error(String)
    case terminated(Process)
}

public extension Process {
    /// Run the process returning a stream output
    func runStream(name: String, fileHandle: FileHandle?) throws -> AsyncStream<ProcessOutput> {
        let stream = makeStream(name: name, fileHandle: fileHandle)
        self.logProcessInfo(name: name)
        fileHandle?.writeInfo(for: self)
        try run()
        return stream
    }

    private func makeStream(name: String, fileHandle: FileHandle?) -> AsyncStream<ProcessOutput> {
        let pipe = Pipe()
        let errorPipe = Pipe()
        standardOutput = pipe
        standardError = errorPipe

        return AsyncStream<ProcessOutput> { continuation in
            continuation.onTermination = { termination in
                switch termination {
                case .finished:
                    break
                case .cancelled:
                    guard self.isRunning else { return }
                    self.terminate()
                @unknown default:
                    break
                }
            }

            continuation.yield(.started(self))

            pipe.fileHandleForReading.readabilityHandler = { pipe in
                guard let line = pipe.nextLine() else { return }
                continuation.yield(.message(line))
                guard !line.isEmpty else { return }
                Logger.wineKit.info("\(line, privacy: .public)")
                fileHandle?.write(line: line)
            }

            errorPipe.fileHandleForReading.readabilityHandler = { pipe in
                guard let line = pipe.nextLine() else { return }
                continuation.yield(.error(line))
                guard !line.isEmpty else { return }
                Logger.wineKit.warning("\(line, privacy: .public)")
                fileHandle?.write(line: line)
            }

            terminationHandler = { (process: Process) in
                Self.drainPipe(pipe, as: .message, continuation: continuation, fileHandle: fileHandle)
                Self.drainPipe(errorPipe, as: .error, continuation: continuation, fileHandle: fileHandle)
                process.logTermination(name: name, fileHandle: fileHandle)
                try? fileHandle?.close()
                continuation.yield(.terminated(process))
                continuation.finish()
            }
        }
    }

    private static func drainPipe(
        _ pipe: Pipe,
        as kind: PipeKind,
        continuation: AsyncStream<ProcessOutput>.Continuation,
        fileHandle: FileHandle?
    ) {
        guard let remaining = try? pipe.fileHandleForReading.readToEnd(),
              let text = String(data: remaining, encoding: .utf8),
              !text.isEmpty else { return }

        switch kind {
        case .message:
            continuation.yield(.message(text))
            Logger.wineKit.info("\(text, privacy: .public)")
        case .error:
            continuation.yield(.error(text))
            Logger.wineKit.warning("\(text, privacy: .public)")
        }
        fileHandle?.write(line: text)
    }

    private func logTermination(name: String, fileHandle: FileHandle? = nil) {
        let reason: String
        switch terminationReason {
        case .exit:
            reason = "exit"
        case .uncaughtSignal:
            reason = "uncaught signal (crash)"
        @unknown default:
            reason = "unknown"
        }

        let status = terminationStatus
        let message = "\nProcess \(name) terminated: status=\(status), reason=\(reason)\n"

        if status == 0 && terminationReason == .exit {
            Logger.wineKit.info("Terminated \(name) with status '\(status, privacy: .public)'")
        } else {
            let detail = "status=\(status) reason=\(reason)"
            Logger.wineKit.warning("Terminated \(name): \(detail, privacy: .public)")
        }

        fileHandle?.write(line: message)
    }

    private func logProcessInfo(name: String) {
        Logger.wineKit.info("Running process \(name)")

        if let arguments = arguments {
            Logger.wineKit.info("Arguments: `\(arguments.joined(separator: " "))`")
        }
        if let executableURL = executableURL {
            Logger.wineKit.info("Executable: `\(executableURL.path(percentEncoded: false))`")
        }
        if let directory = currentDirectoryURL {
            Logger.wineKit.info("Directory: `\(directory.path(percentEncoded: false))`")
        }
        if let environment = environment {
            Logger.wineKit.info("Environment: \(environment)")
        }
    }
}

private enum PipeKind {
    case message
    case error
}

extension FileHandle {
    func nextLine() -> String? {
        guard let line = String(data: availableData, encoding: .utf8) else { return nil }
        if !line.isEmpty {
            return line
        } else {
            return nil
        }
    }
}
