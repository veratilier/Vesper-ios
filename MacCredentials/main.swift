// Native macOS helper: Catalyst cannot use the login Keychain directly.
// Only stdin/stdout carry credentials; never argv, environment, files or logs.
import Foundation
import Security

// The helper must not become a credential-reading CLI for unrelated processes.
func authorizedParent() -> Bool {
    var ownCode: SecCode?
    var information: CFDictionary?
    var staticCode: SecStaticCode?
    guard SecCodeCopySelf([], &ownCode) == errSecSuccess, let ownCode,
          SecCodeCopyStaticCode(ownCode, [], &staticCode) == errSecSuccess, let staticCode,
          SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
          let team = (information as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String,
          !team.isEmpty, team.allSatisfy({ $0.isASCII && $0.isLetter || $0.isNumber }) else { return false }
    var parent: SecCode?
    let attributes = [kSecGuestAttributePid as String: getppid()] as CFDictionary
    guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &parent) == errSecSuccess, let parent else { return false }
    var requirement: SecRequirement?
    #if VESPER_CREDENTIAL_TEST
    let parentIdentifier = "com.vera.vesper.credentialtest"
    #else
    let parentIdentifier = "com.vera.vesper.mac"
    #endif
    let rule = "identifier \"\(parentIdentifier)\" and anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
    guard SecRequirementCreateWithString(rule as CFString, [], &requirement) == errSecSuccess, let requirement else { return false }
    return SecCodeCheckValidity(parent, [], requirement) == errSecSuccess
}

struct Request: Decodable { let operation: String; let account: String; let value: String? }
struct Response: Encodable { let status: OSStatus; var value: String? = nil }
func perform(_ request: Request) -> Response {
    let accounts = ["device-token", "netease-music-u", "call-voice-configuration", "vesper-mcp-owner", "usage-elevenlabs-api-key", "persistence-self-test"]
    guard accounts.contains(request.account) else { return Response(status: errSecParam) }
    let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "com.vera.vesper.mac.credentials",
        kSecAttrAccount as String: request.account, kSecUseDataProtectionKeychain as String: false]
    switch request.operation {
    case "read":
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query.merging([kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne]) { _, new in new } as CFDictionary, &item)
        return Response(status: status, value: (item as? Data).flatMap { String(data: $0, encoding: .utf8) })
    case "save":
        guard let value = request.value, value.utf8.count <= 32768 else { return Response(status: errSecParam) }
        let values: [String: Any] = [kSecValueData as String: Data(value.utf8)]
        let status = SecItemUpdate(query as CFDictionary, values as CFDictionary)
        if status == errSecItemNotFound {
            return Response(status: SecItemAdd(query.merging(values) { _, new in new } as CFDictionary, nil))
        }
        return Response(status: status)
    case "delete": return Response(status: SecItemDelete(query as CFDictionary))
    default: return Response(status: errSecParam)
    }
}
guard authorizedParent() else {
    FileHandle.standardOutput.write(try JSONEncoder().encode(Response(status: errSecAuthFailed)))
    exit(1)
}
let input = FileHandle.standardInput.readData(ofLength: 65537)
let response: Response
if input.count <= 65536, let request = try? JSONDecoder().decode(Request.self, from: input) {
    response = perform(request)
} else { response = Response(status: errSecParam) }
if let output = try? JSONEncoder().encode(response) { FileHandle.standardOutput.write(output) }
