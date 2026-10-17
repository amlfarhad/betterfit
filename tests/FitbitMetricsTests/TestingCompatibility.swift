// The Command Line Tools distribution includes Swift Testing but not XCTest.
// Full Xcode runs the tests with native XCTest; this fallback runs the same
// assertions locally without changing the package's iOS deployment target.
#if !canImport(XCTest)
import Testing
import Foundation

class MetricsTestBase {}
struct UnwrapFailure: Error {}

func XCTAssertEqual<T: Equatable>(_ lhs: T, _ rhs: T, _ message: String = "",
                                  sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(lhs == rhs, Comment(rawValue: message), sourceLocation: sourceLocation)
}
func XCTAssertEqual(_ lhs: Double, _ rhs: Double, accuracy: Double,
                    sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(abs(lhs - rhs) <= accuracy, sourceLocation: sourceLocation)
}
func XCTAssertNotEqual<T: Equatable>(_ lhs: T, _ rhs: T,
                                     sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(lhs != rhs, sourceLocation: sourceLocation)
}
func XCTAssertGreaterThan(_ lhs: Double, _ rhs: Double,
                          sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(lhs > rhs, sourceLocation: sourceLocation)
}
func XCTAssertTrue(_ condition: Bool, _ message: String = "",
                   sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(condition, Comment(rawValue: message), sourceLocation: sourceLocation)
}
func XCTAssertNotNil<T>(_ value: T?, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(value != nil, sourceLocation: sourceLocation)
}
func XCTUnwrap<T>(_ value: T?, sourceLocation: SourceLocation = #_sourceLocation) throws -> T {
    guard let value else { Issue.record("Expected non-nil value", sourceLocation: sourceLocation); throw UnwrapFailure() }
    return value
}
func XCTAssertThrowsError<T>(_ expression: @autoclosure () throws -> T, _ message: String = "",
                             sourceLocation: SourceLocation = #_sourceLocation) {
    do {
        _ = try expression()
        Issue.record(Comment(rawValue: "Expected an error. \(message)"), sourceLocation: sourceLocation)
    } catch {}
}
#endif
