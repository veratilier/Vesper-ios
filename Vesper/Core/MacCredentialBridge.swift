#if targetEnvironment(macCatalyst) || VESPER_CREDENTIAL_TEST
import Foundation
import Darwin

/// Runs the bundled, separately signed native macOS Keychain helper. No shell is used.
/// Catalyst only supports the data-protection Keychain, which requires provisioning;
/// this local Mac distribution uses the user's encrypted login Keychain instead.
enum MacCredentialBridge {
    struct Request: Encodable { let operation: String; let account: String; var value: String? = nil }
    struct Response: Decodable { let status: Int32; let value: String? }
    static func perform(_ request: Request, helperURL: URL? = nil) throws -> Response {
        let path = (helperURL ?? Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/VesperCredentials")).path
        let data = try JSONEncoder().encode(request)
        guard data.count <= 65536 else { throw failure("Credential is too large.") }
        var input: [Int32] = [0, 0], output: [Int32] = [0, 0]
        guard pipe(&input) == 0 else { throw failure("Cannot open the secure credential connection.") }
        guard pipe(&output) == 0 else { close(input[0]); close(input[1]); throw failure("Cannot open the secure credential connection.") }
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, input[0], STDIN_FILENO)
        posix_spawn_file_actions_adddup2(&actions, output[1], STDOUT_FILENO)
        for fd in input + output { posix_spawn_file_actions_addclose(&actions, fd) }
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT))
        var pid: pid_t = 0
        let argument = strdup(path)
        defer { free(argument) }
        var arguments: [UnsafeMutablePointer<CChar>?] = [argument, nil]
        var environment: [UnsafeMutablePointer<CChar>?] = [nil]
        let status = posix_spawn(&pid, path, &actions, &attributes, &arguments, &environment)
        close(input[0]); close(output[1])
        guard status == 0 else {
            close(input[1]); close(output[0])
            throw failure("Cannot open Keychain storage (\(status)). Reinstall the signed Mac app.")
        }
        let writer = FileHandle(fileDescriptor: input[1], closeOnDealloc: true)
        let reader = FileHandle(fileDescriptor: output[0], closeOnDealloc: true)
        // A crashed helper must return an error rather than terminate the app with SIGPIPE.
        _ = fcntl(input[1], F_SETNOSIGPIPE, 1)
        defer {
            try? writer.close(); try? reader.close()
            var exitStatus: Int32 = 0
            while waitpid(pid, &exitStatus, 0) == -1 && errno == EINTR {}
        }
        try writer.write(contentsOf: data)
        try writer.close()
        let result = try reader.readToEnd() ?? Data()
        guard result.count <= 65536, let response = try? JSONDecoder().decode(Response.self, from: result) else {
            throw failure("Keychain storage is unavailable. Reinstall the signed Mac app.")
        }
        return response
    }
    private static func failure(_ message: String) -> NSError {
        NSError(domain: "VesperCredentials", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
#endif
