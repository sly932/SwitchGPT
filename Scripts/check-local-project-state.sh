#!/usr/bin/env bash
# Run the project-state and desktop-integration fixtures when XCTest is unavailable.
set -euo pipefail
repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repository_root"
swift build -c debug --target SwitchGPTDesktopIntegration
build_directory="$(swift build -c debug --show-bin-path)"
check_directory="$(mktemp -d "${TMPDIR:-/tmp}/switchgpt-project-state-check.XXXXXX")"
trap 'rm -rf "$check_directory"' EXIT

python3 - "$check_directory" <<'PY'
from pathlib import Path
import re
import sys

directory = Path(sys.argv[1])
files = [
    Path('Tests/SwitchGPTSafetyCoreTests/LocalProjectStateTests.swift'),
    Path('Tests/SwitchGPTSafetyCoreTests/DesktopIntegrationTests.swift'),
]
calls = []
for path in files:
    source = path.read_text()
    classes = re.findall(r'\bclass\s+(\w+)\s*:\s*XCTestCase\b', source)
    if len(classes) != 1:
        raise SystemExit(f'Expected one XCTestCase class in {path}')
    methods = re.findall(
        r'\bfunc\s+(test\w+)\s*\(\s*\)\s*(async\s+)?(throws\s+)?\{', source
    )
    declared = re.findall(r'\bfunc\s+(test\w+)\b', source)
    if not methods or declared != [name for name, _, _ in methods]:
        raise SystemExit(f'Unsupported test signature in {path}; update this runner')
    if any(async_modifier for _, async_modifier, _ in methods):
        raise SystemExit(f'Async tests require an explicit runner update for {path}')
    directory.joinpath(path.name).write_text(source.replace('import XCTest', ''))
    for name, _, throws_modifier in methods:
        invocation = f'test.{name}()'
        if throws_modifier:
            invocation = f'''do {{
        try {invocation}
      }} catch {{
        test.tearDown()
        try? test.tearDownWithError()
        throw error
      }}'''
        calls.append(f'''
    do {{
      let test = {classes[0]}()
      try test.setUpWithError()
      test.setUp()
      {invocation}
      test.tearDown()
      try test.tearDownWithError()
      print("PASS: {classes[0]}.{name}")
    }}''')

shim = r'''
import Foundation

class XCTestCase {
  func setUpWithError() throws {}
  func tearDownWithError() throws {}
  func setUp() {}
  func tearDown() {}
}

private func fail(_ message: String, file: StaticString, line: UInt) -> Never {
  fatalError(message, file: file, line: line)
}

func XCTAssertEqual<T: Equatable>(
  _ actual: @autoclosure () throws -> T,
  _ expected: @autoclosure () throws -> T,
  _ message: String = "",
  file: StaticString = #filePath,
  line: UInt = #line
) {
  do {
    let actualValue = try actual()
    let expectedValue = try expected()
    guard actualValue == expectedValue else {
      fail("Expected \(expectedValue), got \(actualValue). \(message)", file: file, line: line)
    }
  } catch {
    fail("Unexpected error: \(error). \(message)", file: file, line: line)
  }
}

func XCTAssertTrue(
  _ expression: @autoclosure () throws -> Bool,
  _ message: String = "",
  file: StaticString = #filePath,
  line: UInt = #line
) {
  XCTAssertEqual(try expression(), true, message, file: file, line: line)
}

func XCTAssertNotEqual<T: Equatable>(
  _ actual: @autoclosure () throws -> T,
  _ expected: @autoclosure () throws -> T,
  _ message: String = "",
  file: StaticString = #filePath,
  line: UInt = #line
) {
  XCTAssertFalse(try actual() == expected(), message, file: file, line: line)
}

func XCTAssertFalse(
  _ expression: @autoclosure () throws -> Bool,
  _ message: String = "",
  file: StaticString = #filePath,
  line: UInt = #line
) {
  XCTAssertEqual(try expression(), false, message, file: file, line: line)
}

func XCTAssertNil<T>(
  _ expression: @autoclosure () throws -> T?,
  _ message: String = "",
  file: StaticString = #filePath,
  line: UInt = #line
) {
  XCTAssertTrue(try expression() == nil, message, file: file, line: line)
}

func XCTAssertNotNil<T>(
  _ expression: @autoclosure () throws -> T?,
  _ message: String = "",
  file: StaticString = #filePath,
  line: UInt = #line
) {
  XCTAssertTrue(try expression() != nil, message, file: file, line: line)
}

func XCTAssertThrowsError<T>(
  _ expression: @autoclosure () throws -> T,
  _ message: String = "",
  file: StaticString = #filePath,
  line: UInt = #line,
  _ handler: (Error) -> Void = { _ in }
) {
  do {
    _ = try expression()
  } catch {
    handler(error)
    return
  }
  fail("Expected an error. \(message)", file: file, line: line)
}

func XCTAssertNoThrow<T>(
  _ expression: @autoclosure () throws -> T,
  _ message: String = "",
  file: StaticString = #filePath,
  line: UInt = #line
) {
  do {
    _ = try expression()
  } catch {
    fail("Unexpected error: \(error). \(message)", file: file, line: line)
  }
}

func XCTFail(
  _ message: String = "Assertion failed",
  file: StaticString = #filePath,
  line: UInt = #line
) {
  fail(message, file: file, line: line)
}

func XCTUnwrap<T>(
  _ expression: @autoclosure () throws -> T?,
  _ message: String = "",
  file: StaticString = #filePath,
  line: UInt = #line
) throws -> T {
  guard let value = try expression() else {
    fail("Expected a value. \(message)", file: file, line: line)
  }
  return value
}

@main struct ProjectStateRegressionCheck {
  @MainActor static func main() throws {
'''
shim += '\n'.join(calls)
shim += f'\n    print("PASS: {len(calls)} project-state and desktop-integration cases (standalone Swift assertions)")\n'
shim += '  }\n}\n'
directory.joinpath('Runner.swift').write_text(shim)
PY

swiftc -parse-as-library -I "$build_directory/Modules" \
  "$check_directory"/*.swift \
  "$build_directory"/SwitchGPTDesktopIntegration.build/*.swift.o \
  "$build_directory"/SwitchGPTSafetyCore.build/*.swift.o \
  -o "$check_directory/check"
"$check_directory/check"
