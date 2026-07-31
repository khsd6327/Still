import XCTest
@testable import StillCore

final class WindowsProcessListParserTests: XCTestCase {
    func testParsesWineTaskListCSV() {
        let output = """
        "steam.exe","1024","Console","1","120,000 K"
        "steamwebhelper.exe","2048","Console","1","80,000 K"
        """

        XCTAssertEqual(
            WindowsProcessListParser.parse(output),
            [
                WindowsProcess(name: "steam.exe", processID: 1024),
                WindowsProcess(name: "steamwebhelper.exe", processID: 2048)
            ]
        )
    }

    func testIgnoresDiagnosticsAndMalformedRows() {
        let output = """
        wine: configuration in L"/tmp/prefix" has been updated.
        "game.exe","4096"
        """

        XCTAssertEqual(
            WindowsProcessListParser.parse(output),
            [WindowsProcess(name: "game.exe", processID: 4096)]
        )
    }
}
