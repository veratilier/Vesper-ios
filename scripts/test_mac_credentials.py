#!/usr/bin/env python3
"""Exercise the signed, sandboxed Keychain bridge without production credentials.
Usage: DEVELOPER_DIR=... python3 scripts/test_mac_credentials.py SIGNING_IDENTITY
Requires an unlocked login Keychain and a local Apple Development identity.
"""
import os, plistlib, subprocess, sys, tempfile
from pathlib import Path
root = Path(__file__).resolve().parents[1]
identity = sys.argv[1]
def run(*args, **kwargs):
    return subprocess.run(args, check=True, text=True, **kwargs)
with tempfile.TemporaryDirectory(prefix='vesper-credentials-') as directory:
    base = Path(directory)
    app = base / 'CredentialTest.app'
    executable = app / 'Contents/MacOS/probe'
    helper = app / 'Contents/Helpers/VesperCredentials'
    executable.parent.mkdir(parents=True); helper.parent.mkdir(parents=True)
    (app / 'Contents/Info.plist').write_bytes(plistlib.dumps(dict(
        CFBundleIdentifier='com.vera.vesper.credentialtest', CFBundleExecutable='probe', CFBundlePackageType='APPL')))
    entitlements = base / 'parent.entitlements'
    entitlements.write_bytes(plistlib.dumps({'com.apple.security.app-sandbox': True}))
    main = base / 'Test.swift'
    main.write_text('''import Foundation
@main struct Test {
    static func main() throws {
        let operation = CommandLine.arguments[1]
        let response = try MacCredentialBridge.perform(.init(operation: operation,
            account: "persistence-self-test", value: operation == "save" ? "synthetic-regression-fixture" : nil),
            helperURL: URL(fileURLWithPath: CommandLine.arguments[2]))
        let expected = Int32(CommandLine.arguments[3])!
        guard response.status == expected else { print("Unexpected status: \\(response.status)"); exit(1) }
        if operation == "read" && expected == 0 {
            guard response.value == "synthetic-regression-fixture" else { exit(2) }
        }
        print("Passed: \\(operation), status \\(expected)")
    }
}
''')
    run('xcrun','--sdk','macosx','swiftc','-D','VESPER_CREDENTIAL_TEST',str(root/'Vesper/Core/MacCredentialBridge.swift'),str(main),'-o',str(executable))
    def build_helper(test):
        flags = ['-D','VESPER_CREDENTIAL_TEST'] if test else []
        run('xcrun','--sdk','macosx','swiftc',*flags,str(root/'MacCredentials/main.swift'),'-o',str(helper))
        run('codesign','--force','--sign',identity,'--identifier','com.vera.vesper.mac.credentials',
            '--entitlements',str(root/'MacCredentials/Helper.entitlements'),str(helper))
        run('codesign','--force','--sign',identity,'--identifier','com.vera.vesper.credentialtest',
            '--entitlements',str(entitlements),str(app))
    def invoke(operation, status=0): run(str(executable),operation,str(helper),str(status))
    build_helper(True)
    try:
        invoke('save'); invoke('read')
        build_helper(True)  # Recompile/resign; the Keychain ACL must survive app updates.
        invoke('read')
        invoke('save'); invoke('read')  # Existing-item update.
    finally:
        invoke('delete'); invoke('read',-25300)
    build_helper(False)
    invoke('read',-25293)  # Production helper rejects any app other than signed Vesper Mac.
print('Credential persistence, update, deletion and caller validation passed.')
