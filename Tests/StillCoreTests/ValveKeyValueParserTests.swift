import XCTest
@testable import StillCore

final class ValveKeyValueParserTests: XCTestCase {
    func testParsesSteamManifestAndEscapedLibraryPath() throws {
        let document = try ValveKeyValueParser().parse(
            #"""
            // Steam writes quoted Valve KeyValue files.
            "AppState"
            {
                "appid" "275850"
                "name" "No Man's Sky"
                "StateFlags" "4"
                "installdir" "No Man's Sky"
            }
            "libraryfolders"
            {
                "1"
                {
                    "path" "D:\\SteamLibrary"
                }
            }
            """#
        )

        XCTAssertEqual(document["AppState"]?["appid"]?.stringValue, "275850")
        XCTAssertEqual(
            document["libraryfolders"]?["1"]?["path"]?.stringValue,
            #"D:\SteamLibrary"#
        )
    }
}
