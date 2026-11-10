#!/usr/bin/env bash
# Execute the same reliability fixtures on Command Line Tools hosts without XCTest.
set -euo pipefail
repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repository_root"
swift build --product switchgpt
build_directory="$(swift build --show-bin-path)"
check_directory="$(mktemp -d "${TMPDIR:-/tmp}/switchgpt-details-check.XXXXXX")"
trap 'rm -rf "$check_directory"' EXIT
python3 - "$check_directory/check.swift" <<'PY'
from pathlib import Path
import re, sys
source = Path('Tests/SwitchGPTSafetyCoreTests/AccountDetailsReliabilityTests.swift').read_text()
source = source.replace('import XCTest', '''
class XCTestCase {}
func XCTAssertEqual<T: Equatable>(_ actual: T, _ expected: T) {
  precondition(actual == expected, "Expected \\(expected), got \\(actual)")
}
func XCTAssertNil(_ value: Any?) { precondition(value == nil, "Expected nil") }
func XCTAssertTrue(_ value: Bool) { precondition(value, "Expected true") }
''')
methods = re.findall(r'func (test\w+)\(\) async throws', source)
assert len(methods) == 11, 'Update runner when adding or changing reliability cases'
calls = '\n'.join(f'    try await tests.{name}()\n    print("PASS: {name}")\n    fflush(nil)' for name in methods)
source += '''
@main struct DetailsRegressionCheck {
  @MainActor static func main() async throws {
    let tests = AccountDetailsReliabilityTests()
''' + calls + '''
    print("PASS: 11 account-details reliability cases (standalone Swift assertions)")
  }
}
'''
Path(sys.argv[1]).write_text(source)
PY
swiftc -parse-as-library -I "$build_directory/Modules" \
  "$check_directory/check.swift" \
  "$build_directory"/SwitchGPTAppCore.build/*.swift.o \
  "$build_directory"/SwitchGPTDesktopIntegration.build/*.swift.o \
  "$build_directory"/SwitchGPTSafetyCore.build/*.swift.o \
  -o "$check_directory/check"
"$check_directory/check"
