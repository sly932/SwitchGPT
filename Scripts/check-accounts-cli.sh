#!/usr/bin/env bash
# Focused real Swift cases for Command Line Tools installations without XCTest.
set -euo pipefail
repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repository_root"
swift build --product switchgpt
build_directory="$(swift build --show-bin-path)"
check_directory="$(mktemp -d "${TMPDIR:-/tmp}/switchgpt-cli-check.XXXXXX")"
trap 'rm -rf "$check_directory"' EXIT
python3 - "$check_directory/check.swift" <<'PY'
from pathlib import Path
import sys
source = Path('Tests/SwitchGPTSafetyCoreTests/AccountReportTests.swift').read_text()
app_tests = Path('Tests/SwitchGPTSafetyCoreTests/AppCoreTests.swift').read_text()
start = app_tests.index('  func testCodexQuotaReaderKeepsHealthyAccountWhenAnotherAccountFails()')
end = app_tests.index('  func testTokenActivityDecoderPreservesUnknownFields()', start)
source += '\nclass ReaderRegressionTests: XCTestCase {\n' + app_tests[start:end] + '\n}\n'
source = source.replace('import XCTest', '''import Foundation
class XCTestCase {}
func XCTAssertEqual<T: Equatable>(_ actual: T, _ expected: T) {
  precondition(actual == expected, "Expected \\(expected), got \\(actual)")
}
func XCTAssertNil(_ value: Any?) { precondition(value == nil, "Expected nil") }
func XCTAssertNotNil(_ value: Any?) { precondition(value != nil, "Expected a value") }
func XCTAssertTrue(_ value: Bool) { precondition(value, "Expected true") }
func XCTAssertFalse(_ value: Bool) { precondition(!value, "Expected false") }
''')
source += '''
@main struct CLIRegressionCheck {
  static func main() async throws {
    let tests = AccountReportTests()
    try await tests.testFailureDoesNotHideOtherAccountsAndOrderIsStable()
    await tests.testAllFailuresStillProduceReport()
    try await tests.testQuotaOmitsTokenActivityAndEncodesRemainingPercent()
    await tests.testCachedDataDoesNotCallReaderAndMissingTimestampIsNotFresh()
    await tests.testEmptyAccountsAndMissingOptionalUsage()
    try await ReaderRegressionTests().testCodexQuotaReaderKeepsHealthyAccountWhenAnotherAccountFails()
    print("PASS: 6 account-report and app-server regression cases (standalone Swift assertions)")
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
python3 - "$build_directory/switchgpt" <<'PY'
import json, subprocess, sys, tempfile
from pathlib import Path
cli = sys.argv[1]
with tempfile.TemporaryDirectory(prefix='switchgpt-cli-contract-') as directory:
    state = Path(directory) / 'preview-state.json'
    def run(*args):
        return subprocess.run([cli, *args, '--state-file', str(state)], capture_output=True, text=True)
    empty = run('quota')
    assert empty.returncode == 0 and json.loads(empty.stdout)['accounts'] == []
    account = dict(id={'rawValue': 'fixture'}, displayName='Fixture', detail='',
                   planName='Plus', symbolName='person', accent='blue',
                   source={'codexHome': {'path': str(Path(directory) / 'missing')}},
                   identityHash='012345abcdef', usageRefreshedAt='2026-11-01T00:00:00Z',
                   usage={'weekly': {'usedPercent': 27, 'resetAt': '2026-11-06T00:00:00Z'}})
    state.write_text(json.dumps(dict(schemaVersion=1, accounts=[account])))
    state.chmod(0o600)
    original = state.read_bytes()
    cached = run('quota', '--cached')
    assert cached.returncode == 0, cached.stderr
    report = json.loads(cached.stdout)
    assert report['accounts'][0]['quota']['weekly']['remainingPercent'] == 73
    assert report['source'] == 'cache'
    partial = run('usage', '--cached')
    assert partial.returncode == 0 and json.loads(partial.stdout)['partialCount'] == 1
    failed = run('quota')
    assert failed.returncode == 0 and json.loads(failed.stdout)['errorCount'] == 1
    assert 'quota' not in json.loads(failed.stdout)['accounts'][0]
    assert state.read_bytes() == original
    invalid = run('quota', '--timeout', '0')
    assert invalid.returncode == 2 and not invalid.stdout
    state.chmod(0o644)
    insecure = run('quota', '--cached')
    assert insecure.returncode == 1 and not insecure.stdout
    assert json.loads(insecure.stderr)['error']['code'] == 'state_unavailable'
    state.chmod(0o600)
    state.write_text('{broken')
    assert run('quota').returncode == 1
print('PASS: CLI JSON, exit codes, all-failed isolation, cache, private permissions and read-only contract')
PY
