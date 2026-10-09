#!/usr/bin/env bash
# Run the focused summary cases with Swift assertions when XCTest is unavailable.
set -euo pipefail
task_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$task_root"
swift build -c debug --target SwitchGPTAppCore
build_directory="$(swift build -c debug --show-bin-path)"
check_directory="$(mktemp -d "${TMPDIR:-/tmp}/switchgpt-summary-check.XXXXXX")"
trap 'rm -rf "$check_directory"' EXIT
python3 - "$check_directory/check.swift" <<'PY'
import pathlib, sys
source = pathlib.Path('Tests/SwitchGPTSafetyCoreTests/AllAccountsTokenActivityTests.swift').read_text()
source = source.replace('import XCTest', '''import Foundation
class XCTestCase {}
func XCTAssertEqual<T: Equatable>(_ actual: T, _ expected: T) {
  precondition(actual == expected, "Expected \\(expected), got \\(actual)")
}
func XCTAssertNil(_ value: Any?) { precondition(value == nil, "Expected nil") }
func XCTAssertTrue(_ value: Bool) { precondition(value, "Expected true") }
func XCTAssertFalse(_ value: Bool) { precondition(!value, "Expected false") }
''').replace('@testable import SwitchGPTAppCore', 'import SwitchGPTAppCore')
source += '''
@main struct SummaryRegressionCheck {
  @MainActor static func main() async {
    let tests = AllAccountsTokenActivityTests()
    tests.testSumsEveryMetricAndDailyRecordsAcrossAccounts()
    tests.testExcludesFailedAccountsEvenWhenTheyHaveOldSnapshots()
    tests.testUnknownValuesStayUnknownAndPartialDataIsIdentified()
    tests.testDuplicateDateWithinOneAccountUsesLatestValueBeforeSummingAccounts()
    await tests.testSummaryNeverFetchesAndFollowsBothExistingRefreshPathsAndRemoval()
    print("PASS: 5 token summary regression cases (standalone Swift assertions)")
  }
}
'''
pathlib.Path(sys.argv[1]).write_text(source)
PY
swiftc -parse-as-library -I "$build_directory/Modules" \
  "$check_directory/check.swift" \
  "$build_directory"/SwitchGPTAppCore.build/*.swift.o \
  "$build_directory"/SwitchGPTDesktopIntegration.build/*.swift.o \
  "$build_directory"/SwitchGPTSafetyCore.build/*.swift.o \
  -o "$check_directory/check"
"$check_directory/check"
