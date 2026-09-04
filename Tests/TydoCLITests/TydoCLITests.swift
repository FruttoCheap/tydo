import Darwin
import Foundation
import XCTest

final class TydoCLITests: XCTestCase {
    struct Result {
        let status: Int32
        let stdout: Data
        let stderr: Data

        var output: [String: Any] {
            get throws { try XCTUnwrap(JSONSerialization.jsonObject(with: stdout) as? [String: Any]) }
        }

        var error: [String: Any] {
            get throws { try XCTUnwrap(JSONSerialization.jsonObject(with: stderr) as? [String: Any]) }
        }
    }

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tydo-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// The three provider slots and the guard that keeps API keys out of argv.
    func testProviderSlotsAndDoctor() throws {
        let initial = try data(run("config", "get"))
        XCTAssertEqual(initial["embeddingBaseURL"] as? String, "", "empty means 'same server as chat'")
        XCTAssertEqual(initial["chatAPIKeyConfigured"] as? Bool, false)
        XCTAssertEqual(initial["embeddingAPIKeyConfigured"] as? Bool, false)

        // Keys are Keychain-only and stdin-only: argv would leak them to `ps`.
        for key in ["chat-api-key", "embedding-api-key", "reasoning-api-key"] {
            let rejected = try run("config", "set", key, "sk-secret")
            XCTAssertNotEqual(rejected.status, 0, "\(key) must not be settable as an argument")
            XCTAssertEqual(try rejected.error["code"] as? String, "invalid_request")
        }

        // Chat hosted, embeddings still local — the combination OpenRouter forces.
        let updated = try data(run("config", "update", stdin: """
        {"baseURL":"https://openrouter.ai/api/v1","embeddingBaseURL":"http://localhost:11434/v1","chatAPIKey":"sk-test"}
        """))
        XCTAssertEqual(updated["baseURL"] as? String, "https://openrouter.ai/api/v1")
        XCTAssertEqual(updated["embeddingBaseURL"] as? String, "http://localhost:11434/v1")
        XCTAssertEqual(updated["chatAPIKeyConfigured"] as? Bool, true)

        // An explicit "" sends embeddings back to the chat server.
        let cleared = try data(run("config", "update", stdin: #"{"embeddingBaseURL":""}"#))
        XCTAssertEqual(cleared["embeddingBaseURL"] as? String, "")

        // Back to localhost so doctor fails on a refused connection instead of
        // making a real call to openrouter.ai from the test suite.
        _ = try run("config", "update", stdin: #"{"baseURL":"http://localhost:11434/v1","chatAPIKey":null}"#)

        // doctor reports failures as data, so the command itself still succeeds
        // even with no provider running.
        let doctor = try run("doctor")
        XCTAssertEqual(doctor.status, 0, "doctor must not exit non-zero on failed checks")
        let report = try data(doctor)
        let names = Set((report["checks"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String })
        XCTAssertEqual(names, ["store", "chat", "embedding", "reasoning"])
        XCTAssertNotNil(report["ok"] as? Bool)
    }

    func testVersionSnapshotAndCodedErrors() throws {
        let version = try run("version")
        XCTAssertEqual(version.status, 0)
        let versionData = try data(version)
        XCTAssertEqual(versionData["cli"] as? String, "1.2.0")
        XCTAssertEqual(versionData["protocolVersion"] as? Int, 1)

        let trailing = try run("version", "extra")
        XCTAssertNotEqual(trailing.status, 0)
        XCTAssertEqual(try trailing.error["code"] as? String, "invalid_request")
        XCTAssertTrue(trailing.stdout.isEmpty)

        let snapshot = try data(run("snapshot"))
        XCTAssertEqual((snapshot["todos"] as? [Any])?.count, 0)
        let groups = try XCTUnwrap(snapshot["groups"] as? [[String: Any]])
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0]["name"] as? String, "General")
        XCTAssertEqual(try dataArray(run("clarification", "list")).count, 0)

        let missing = try run("todo", "show", UUID().uuidString)
        XCTAssertEqual(try missing.error["code"] as? String, "not_found")
    }

    func testTodoAndGroupContract() throws {
        let work = try data(run("group", "create", "Work"))
        let groupID = try XCTUnwrap(work["id"] as? String)
        let duplicate = try run("group", "create", "wOrK")
        XCTAssertEqual(try duplicate.error["code"] as? String, "conflict")

        let added = try data(run("todo", "add", "Ship", "release"))
        let todoID = try XCTUnwrap(added["id"] as? String)
        let moved = try data(run("todo", "move", todoID, groupID))
        XCTAssertEqual(moved["stage"] as? String, "grouped")
        XCTAssertEqual(moved["groupName"] as? String, "Work")

        let unassigned = try data(run("todo", "unassign", todoID))
        XCTAssertNil(unassigned["groupID"] as? String)
        XCTAssertNotEqual(unassigned["stage"] as? String, "grouped")
        XCTAssertEqual(try data(run("todo", "unassign", todoID))["id"] as? String, todoID)
        XCTAssertEqual(try run("group", "delete", groupID, "--yes").status, 0)

        let many = try dataArray(run("todo", "add-many", stdin: #"["one","two"]"#))
        XCTAssertEqual(many.count, 2)
        XCTAssertEqual(try dataArray(run("todo", "list", "all")).count, 3)

        _ = try data(run("todo", "complete", todoID))
        XCTAssertEqual(try data(run("todo", "reopen", todoID))["status"] as? String, "active")
        XCTAssertEqual(try data(run("todo", "rename", todoID, "Release", "now"))["title"] as? String, "Release now")
        XCTAssertEqual(try run("todo", "delete", todoID, "--yes").status, 0)

        let groups = try XCTUnwrap(try data(run("snapshot"))["groups"] as? [[String: Any]])
        let general = try XCTUnwrap(groups.first { $0["isGeneral"] as? Bool == true })
        let generalID = try XCTUnwrap(general["id"] as? String)
        XCTAssertEqual(try run("group", "rename", generalID, "Other").error["code"] as? String, "conflict")
        XCTAssertEqual(try run("group", "delete", generalID, "--yes").error["code"] as? String, "conflict")
    }

    func testConfigUpdateIsValidatedBeforeMutationAndClearsKey() throws {
        let original = try data(run("config", "get"))
        let invalid = try run("config", "update", stdin: #"{"chatModel":"changed","retentionDays":0}"#)
        XCTAssertEqual(try invalid.error["code"] as? String, "invalid_request")
        XCTAssertEqual(try data(run("config", "get"))["chatModel"] as? String, original["chatModel"] as? String)
        XCTAssertEqual(try run("config", "update", stdin: "{").error["code"] as? String, "invalid_request")

        let secret = "do-not-print-this-secret"
        let updated = try run("config", "update", stdin: "{\"baseURL\":\"https://example.com/v1\",\"chatModel\":\"chat\",\"embeddingModel\":\"embed\",\"reasoningBaseURL\":\"https://example.com/v1\",\"reasoningChatModel\":\"reason\",\"reasoningAPIKey\":\"\(secret)\",\"retentionDays\":365}")
        XCTAssertEqual(updated.status, 0)
        XCTAssertFalse(String(decoding: updated.stdout, as: UTF8.self).contains(secret))
        XCTAssertTrue(try data(updated)["reasoningAPIKeyConfigured"] as? Bool == true)

        let cleared = try data(run("config", "update", stdin: #"{"reasoningAPIKey":null}"#))
        XCTAssertEqual(cleared["reasoningAPIKeyConfigured"] as? Bool, false)
    }

    func testDocumentAndMastermindInputContracts() throws {
        let unsupported = directory.appendingPathComponent("input.exe")
        try Data("text".utf8).write(to: unsupported)
        let document = try run("document", "extract", unsupported.path)
        XCTAssertEqual(try document.error["code"] as? String, "invalid_request")
        XCTAssertEqual(try run("document", "extract", unsupported.path, "extra").error["code"] as? String, "invalid_request")
        let oversized = directory.appendingPathComponent("large.txt")
        try Data(count: 5 * 1024 * 1024 + 1).write(to: oversized)
        XCTAssertEqual(try run("document", "extract", oversized.path).error["code"] as? String, "invalid_request")

        let badProtocol = try run("mastermind", "accept", stdin: #"{"version":2}"#)
        XCTAssertEqual(try badProtocol.error["code"] as? String, "invalid_request")

        let proposalID = UUID().uuidString
        let proposal = "{\"id\":\"\(proposalID)\",\"title\":\"Next action\",\"body\":null,\"rationale\":\"Useful\",\"group\":\"General\"}"
        let first = try data(run("mastermind", "accept", stdin: proposal))
        let second = try data(run("mastermind", "accept", stdin: proposal))
        XCTAssertEqual(first["id"] as? String, second["id"] as? String)
    }

    func testConcurrentWritesAndBoundedBusyFailure() throws {
        _ = try run("snapshot")
        let processes = (0..<8).map { process(["todo", "add", "item-\($0)"]) }
        processes.forEach { try? $0.run() }
        processes.forEach { $0.waitUntilExit() }
        XCTAssertTrue(processes.allSatisfy { $0.terminationStatus == 0 })
        XCTAssertEqual(try dataArray(run("todo", "list", "all")).count, 8)

        let lockPath = directory.appendingPathComponent("tydo-store.lock").path
        let descriptor = open(lockPath, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        XCTAssertEqual(flock(descriptor, LOCK_EX), 0)
        let start = Date()
        let busy = try run("maintenance")
        flock(descriptor, LOCK_UN)
        close(descriptor)
        XCTAssertEqual(try busy.error["code"] as? String, "busy")
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(start), 1.8)
        XCTAssertLessThan(Date().timeIntervalSince(start), 4)
        let maintained = try data(run("maintenance"))
        XCTAssertEqual((maintained["todos"] as? [[String: Any]])?.count, 8)
    }

    private func run(_ arguments: String..., stdin: String? = nil) throws -> Result {
        try run(arguments, stdin: stdin)
    }

    private func run(_ arguments: [String], stdin: String? = nil) throws -> Result {
        let task = process(arguments)
        let output = Pipe(), error = Pipe(), input = Pipe()
        task.standardOutput = output
        task.standardError = error
        if let stdin {
            task.standardInput = input
            try task.run()
            try input.fileHandleForWriting.write(contentsOf: Data(stdin.utf8))
            try input.fileHandleForWriting.close()
        } else {
            try task.run()
        }
        task.waitUntilExit()
        return Result(status: task.terminationStatus,
                      stdout: output.fileHandleForReading.readDataToEndOfFile(),
                      stderr: error.fileHandleForReading.readDataToEndOfFile())
    }

    private func process(_ arguments: [String]) -> Process {
        let task = Process()
        task.executableURL = Bundle(for: Self.self).bundleURL
            .deletingLastPathComponent().appendingPathComponent("tydo")
        task.arguments = arguments
        task.environment = ProcessInfo.processInfo.environment.merging(["TYDO_DATA_DIR": directory.path]) { _, new in new }
        return task
    }

    private func data(_ result: Result) throws -> [String: Any] {
        XCTAssertEqual(result.status, 0, String(decoding: result.stderr, as: UTF8.self))
        let envelope = try result.output
        XCTAssertEqual(envelope["version"] as? Int, 1)
        return try XCTUnwrap(envelope["data"] as? [String: Any])
    }

    private func dataArray(_ result: Result) throws -> [[String: Any]] {
        XCTAssertEqual(result.status, 0, String(decoding: result.stderr, as: UTF8.self))
        return try XCTUnwrap(try result.output["data"] as? [[String: Any]])
    }
}
