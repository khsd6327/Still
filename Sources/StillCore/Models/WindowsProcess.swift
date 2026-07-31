import Foundation

public struct WindowsProcess: Hashable, Identifiable, Sendable {
    public let name: String
    public let processID: Int32

    public var id: Int32 {
        processID
    }

    public init(name: String, processID: Int32) {
        self.name = name
        self.processID = processID
    }
}

public enum WindowsProcessListParser {
    public static func parse(_ output: String) -> [WindowsProcess] {
        output
            .split(whereSeparator: \.isNewline)
            .compactMap { line in
                let fields = csvFields(String(line))
                guard fields.count >= 2 else { return nil }
                let name = fields[0].trimmingCharacters(in: .whitespaces)
                let pidText = fields[1]
                    .trimmingCharacters(in: .whitespaces)
                    .replacingOccurrences(of: ",", with: "")
                guard !name.isEmpty, let processID = Int32(pidText) else {
                    return nil
                }
                return WindowsProcess(name: name, processID: processID)
            }
            .sorted {
                if $0.name.caseInsensitiveCompare($1.name) == .orderedSame {
                    return $0.processID < $1.processID
                }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
    }

    private static func csvFields(_ line: String) -> [String] {
        var fields: [String] = []
        var current = ""
        var isQuoted = false
        var index = line.startIndex

        while index < line.endIndex {
            let character = line[index]
            if character == "\"" {
                let next = line.index(after: index)
                if isQuoted, next < line.endIndex, line[next] == "\"" {
                    current.append("\"")
                    index = line.index(after: next)
                    continue
                }
                isQuoted.toggle()
            } else if character == ",", !isQuoted {
                fields.append(current)
                current = ""
            } else {
                current.append(character)
            }
            index = line.index(after: index)
        }
        fields.append(current)
        return fields
    }
}
