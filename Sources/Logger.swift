import Foundation

public final class Logger: @unchecked Sendable {
    public static let shared = Logger()
    
    private var fileHandle: FileHandle?
    private let logFileURL: URL
    private let backupFileURL: URL
    private let queue = DispatchQueue(label: "com.aichalkboard.logger", qos: .utility)
    private let dateFormatter: DateFormatter
    
    // Capped at 5 MB max per log file (total max disk space: 10 MB with 1 backup)
    private let maxFileSizeBytes: UInt64 = 5 * 1024 * 1024
    
    private init() {
        let fileManager = FileManager.default
        let logsDir = fileManager.urls(for: .libraryDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Logs")
            .appendingPathComponent("AIChalkboard")
        
        try? fileManager.createDirectory(at: logsDir, withIntermediateDirectories: true)
        
        logFileURL = logsDir.appendingPathComponent("ai_chalkboard.log")
        backupFileURL = logsDir.appendingPathComponent("ai_chalkboard.1.log")
        
        if !fileManager.fileExists(atPath: logFileURL.path) {
            fileManager.createFile(atPath: logFileURL.path, contents: nil)
        }
        
        fileHandle = try? FileHandle(forWritingTo: logFileURL)
        fileHandle?.seekToEndOfFile()
        
        dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        
        log("==================================================")
        log("AI Chalkboard Logger Initialized (PID: \(ProcessInfo.processInfo.processIdentifier))")
        log("Log File: \(logFileURL.path)")
        log("Log Max Size Cap: 5 MB (Auto-rotating)")
        log("==================================================")
    }
    
    public func log(_ message: String, level: String = "INFO") {
        let timestamp = dateFormatter.string(from: Date())
        let pid = ProcessInfo.processInfo.processIdentifier
        let line = "[\(timestamp)] [PID: \(pid)] [\(level)] \(message)\n"
        
        // Write to stderr
        if let data = line.data(using: .utf8) {
            FileHandle.standardError.write(data)
        }
        
        // Write to log file asynchronously with size-cap rotation
        queue.async { [weak self] in
            guard let self = self else { return }
            self.rotateIfNeeded()
            
            if let handle = self.fileHandle, let data = line.data(using: .utf8) {
                handle.write(data)
                try? handle.synchronize()
            }
        }
    }
    
    private func rotateIfNeeded() {
        guard let handle = fileHandle else { return }
        let currentSize = handle.offsetInFile
        
        if currentSize >= maxFileSizeBytes {
            try? handle.close()
            
            let fm = FileManager.default
            if fm.fileExists(atPath: backupFileURL.path) {
                try? fm.removeItem(at: backupFileURL)
            }
            try? fm.moveItem(at: logFileURL, to: backupFileURL)
            fm.createFile(atPath: logFileURL.path, contents: nil)
            
            fileHandle = try? FileHandle(forWritingTo: logFileURL)
            fileHandle?.seekToEndOfFile()
            
            if let newHandle = fileHandle,
               let rotationMsg = "[\(dateFormatter.string(from: Date()))] [PID: \(ProcessInfo.processInfo.processIdentifier)] [INFO] Log file rotated: 5 MB limit reached. Oldest logs moved to ai_chalkboard.1.log\n".data(using: .utf8) {
                newHandle.write(rotationMsg)
                try? newHandle.synchronize()
            }
        }
    }
    
    public var logFilePath: String {
        return logFileURL.path
    }
}
