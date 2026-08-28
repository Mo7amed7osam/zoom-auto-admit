import AppKit
import Foundation
import OSLog
import ZoomAXSupport

enum AccessibilityDiagnosticClassification: String {
    case trusted
    case notTrusted
    case appBundleMismatch
    case possibleStaleTCCEntry
    case relaunchRequired
}

struct CodeSignatureSnapshot {
    let valid: Bool
    let identity: String
    let teamIdentifier: String
    let cdHash: String
    let status: String

    static func inspect(appURL: URL) -> CodeSignatureSnapshot {
        let display = runCodesign(arguments: ["-dv", "--verbose=4", appURL.path])
        let verify = runCodesign(arguments: ["--verify", "--deep", "--strict", "--verbose=2", appURL.path])
        let fields = parseFields(display.output)

        let identity: String
        if let authority = fields["Authority"] {
            identity = authority
        } else if fields["Signature"] == "adhoc" {
            identity = "ad-hoc"
        } else {
            identity = fields["Signature"] ?? "unknown"
        }

        return CodeSignatureSnapshot(
            valid: verify.exitCode == 0,
            identity: identity,
            teamIdentifier: fields["TeamIdentifier"] ?? "not set",
            cdHash: fields["CDHash"] ?? fields["CandidateCDHash sha256"] ?? "unavailable",
            status: verify.exitCode == 0 ? "valid" : "invalid (codesign exit \(verify.exitCode))"
        )
    }

    private static func parseFields(_ output: String) -> [String: String] {
        output.split(whereSeparator: \.isNewline).reduce(into: [:]) { result, line in
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return }
            // codesign prints the leaf signer first, followed by intermediate
            // and root authorities. Preserve the first value for diagnostics.
            if result[parts[0]] == nil {
                result[parts[0]] = parts[1]
            }
        }
    }

    private static func runCodesign(arguments: [String]) -> (exitCode: Int32, output: String) {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return (process.terminationStatus, String(decoding: data, as: UTF8.self))
        } catch {
            return (-1, "codesign could not run: \(error.localizedDescription)")
        }
    }
}

struct AccessibilityDiagnosticsSnapshot {
    static let expectedBundleURL = URL(fileURLWithPath: "/Applications/Zoom Auto Admit.app", isDirectory: true)
    static let expectedBundleIdentifier = "com.mohamedhosam.ZoomAutoAdmit"

    let trust: ZoomAXSupport.AccessibilityTrustSnapshot
    let bundlePath: String
    let bundleIdentifier: String
    let executablePath: String
    let processID: pid_t
    let installedBundleExists: Bool
    let installedBundleIdentifier: String
    let installedExecutablePath: String
    let runningInstalledCopy: Bool
    let runtimeSignature: CodeSignatureSnapshot
    let installedSignature: CodeSignatureSnapshot?
    let previousRuntimeCDHash: String?
    let userInitiatedRecheck: Bool
    let classification: AccessibilityDiagnosticClassification

    static func capture(
        previousRuntimeCDHash: String?,
        userInitiatedRecheck: Bool
    ) -> AccessibilityDiagnosticsSnapshot {
        let trust = ZoomAXSupport.accessibilityTrustSnapshot(prompt: false)
        let bundleURL = Bundle.main.bundleURL.standardizedFileURL.resolvingSymlinksInPath()
        let expectedURL = expectedBundleURL.standardizedFileURL.resolvingSymlinksInPath()
        let installedBundle = Bundle(url: expectedBundleURL)
        let installedExists = FileManager.default.fileExists(atPath: expectedBundleURL.path)
        let runtimeIdentifier = Bundle.main.bundleIdentifier ?? "missing"
        let installedIdentifier = installedBundle?.bundleIdentifier ?? "missing"
        let runningInstalledCopy = bundleURL.path == expectedURL.path
        let runtimeSignature = CodeSignatureSnapshot.inspect(appURL: bundleURL)
        let installedSignature = installedExists ? CodeSignatureSnapshot.inspect(appURL: expectedBundleURL) : nil

        let bundleMatches = runningInstalledCopy
            && runtimeIdentifier == expectedBundleIdentifier
            && installedIdentifier == expectedBundleIdentifier
        let classification: AccessibilityDiagnosticClassification
        if !bundleMatches {
            classification = .appBundleMismatch
        } else if trust.isUsableWithoutRelaunch {
            classification = .trusted
        } else if trust.relaunchAppearsRequired {
            classification = .relaunchRequired
        } else if userInitiatedRecheck
                    || runtimeSignature.identity == "ad-hoc"
                    || (previousRuntimeCDHash != nil && previousRuntimeCDHash != runtimeSignature.cdHash) {
            // Public Accessibility APIs cannot read the Accessibility pane or
            // TCC database. When the user explicitly rechecks, or the app's code
            // identity changed, a stale signature-bound TCC record is the likely
            // actionable diagnosis, but is intentionally labelled "possible".
            classification = .possibleStaleTCCEntry
        } else {
            classification = .notTrusted
        }

        return AccessibilityDiagnosticsSnapshot(
            trust: trust,
            bundlePath: bundleURL.path,
            bundleIdentifier: runtimeIdentifier,
            executablePath: Bundle.main.executableURL?.path ?? "missing",
            processID: getpid(),
            installedBundleExists: installedExists,
            installedBundleIdentifier: installedIdentifier,
            installedExecutablePath: installedBundle?.executableURL?.path ?? "missing",
            runningInstalledCopy: runningInstalledCopy,
            runtimeSignature: runtimeSignature,
            installedSignature: installedSignature,
            previousRuntimeCDHash: previousRuntimeCDHash,
            userInitiatedRecheck: userInitiatedRecheck,
            classification: classification
        )
    }

    func logLines(source: String) -> [String] {
        var lines = [
            "Accessibility diagnostic source=\(source)",
            "AXIsProcessTrusted() = \(trust.isProcessTrusted)",
            "AXIsProcessTrustedWithOptions(prompt=false) = \(trust.isProcessTrustedWithOptions)",
            "System-wide AX probe result = \(trust.systemWideProbeResult.diagnosticDescription)",
            "System-wide AX probe is diagnostic only (it reads the frontmost app, not this app) = true",
            "System-wide AX probe failed for a benign, non-permission reason = \(trust.systemWideProbeFailedBenignly)",
            "Accessibility API disabled for this process = \(trust.accessibilityAPIDisabled)",
            "App bundle path = \(bundlePath)",
            "Bundle identifier = \(bundleIdentifier)",
            "Executable path = \(executablePath)",
            "Process PID = \(processID)",
            "Trust APIs executed by this app PID (not Terminal) = true",
            "Running /Applications copy = \(runningInstalledCopy)",
            "Runtime code-sign status = \(runtimeSignature.status)",
            "Runtime signing identity = \(runtimeSignature.identity)",
            "Runtime TeamIdentifier = \(runtimeSignature.teamIdentifier)",
            "Runtime CDHash = \(runtimeSignature.cdHash)",
            "Previous runtime CDHash = \(previousRuntimeCDHash ?? "none recorded")",
            "Runtime CDHash changed = \(previousRuntimeCDHash != nil && previousRuntimeCDHash != runtimeSignature.cdHash)",
            "User-initiated Check Again = \(userInitiatedRecheck)",
            "Installed copy exists = \(installedBundleExists)",
            "Installed bundle identifier = \(installedBundleIdentifier)",
            "Installed executable path = \(installedExecutablePath)"
        ]
        if let installedSignature {
            lines.append("Installed code-sign status = \(installedSignature.status)")
            lines.append("Installed signing identity = \(installedSignature.identity)")
            lines.append("Installed TeamIdentifier = \(installedSignature.teamIdentifier)")
            lines.append("Installed CDHash = \(installedSignature.cdHash)")
            lines.append("Runtime/installed CDHash match = \(runtimeSignature.cdHash == installedSignature.cdHash)")
        }
        lines.append("Accessibility diagnosis = \(classification.rawValue)")
        return lines
    }
}

final class AccessibilityDiagnosticLog {
    static let shared = AccessibilityDiagnosticLog()

    let fileURL: URL
    private let logger = Logger(subsystem: "com.mohamedhosam.ZoomAutoAdmit", category: "accessibility")
    private let queue = DispatchQueue(label: "com.mohamedhosam.ZoomAutoAdmit.diagnostic-log")

    private init() {
        let logsDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Zoom Auto Admit", isDirectory: true)
        try? FileManager.default.createDirectory(at: logsDirectory, withIntermediateDirectories: true)
        fileURL = logsDirectory.appendingPathComponent("accessibility.log")
    }

    func write(_ lines: [String]) {
        lines.forEach { logger.notice("\($0, privacy: .public)") }
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let block = (["[\(timestamp)]"] + lines + [""]).joined(separator: "\n")

        queue.async { [fileURL] in
            let manager = FileManager.default
            if let attributes = try? manager.attributesOfItem(atPath: fileURL.path),
               let size = attributes[.size] as? NSNumber,
               size.intValue > 1_000_000 {
                try? manager.removeItem(at: fileURL)
            }
            if !manager.fileExists(atPath: fileURL.path) {
                manager.createFile(atPath: fileURL.path, contents: nil)
            }
            guard let handle = try? FileHandle(forWritingTo: fileURL) else { return }
            defer { try? handle.close() }
            do {
                try handle.seekToEnd()
                try handle.write(contentsOf: Data(block.utf8))
            } catch {
                // Unified logging above remains available if the file cannot be written.
            }
        }
    }
}
