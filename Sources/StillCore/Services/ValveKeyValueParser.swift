import Foundation

public enum ValveKeyValue: Equatable, Sendable {
    case string(String)
    case object([String: ValveKeyValue])

    public subscript(key: String) -> ValveKeyValue? {
        guard case .object(let values) = self else { return nil }
        return values[key]
    }

    public var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }
}

public struct ValveKeyValueParser: Sendable {
    private enum Token: Equatable {
        case value(String)
        case openBrace
        case closeBrace
    }

    public init() {}

    public func parse(_ text: String) throws -> ValveKeyValue {
        let tokens = try tokenize(text)
        var index = 0
        let values = try parseObject(tokens, index: &index, expectsClosingBrace: false)
        guard index == tokens.count else {
            throw StillCoreError.invalidValveKeyValue("Unexpected trailing token.")
        }
        return .object(values)
    }

    private func parseObject(
        _ tokens: [Token],
        index: inout Int,
        expectsClosingBrace: Bool
    ) throws -> [String: ValveKeyValue] {
        var result: [String: ValveKeyValue] = [:]

        while index < tokens.count {
            if tokens[index] == .closeBrace {
                guard expectsClosingBrace else {
                    throw StillCoreError.invalidValveKeyValue(
                        "Unexpected closing brace."
                    )
                }
                index += 1
                return result
            }

            guard case .value(let key) = tokens[index] else {
                throw StillCoreError.invalidValveKeyValue("Expected a key.")
            }
            index += 1
            guard index < tokens.count else {
                throw StillCoreError.invalidValveKeyValue(
                    "Missing value for key '\(key)'."
                )
            }

            switch tokens[index] {
            case .value(let value):
                result[key] = .string(value)
                index += 1
            case .openBrace:
                index += 1
                result[key] = .object(
                    try parseObject(
                        tokens,
                        index: &index,
                        expectsClosingBrace: true
                    )
                )
            case .closeBrace:
                throw StillCoreError.invalidValveKeyValue(
                    "Missing value for key '\(key)'."
                )
            }
        }

        if expectsClosingBrace {
            throw StillCoreError.invalidValveKeyValue("Missing closing brace.")
        }
        return result
    }

    private func tokenize(_ text: String) throws -> [Token] {
        var tokens: [Token] = []
        var index = text.startIndex

        func advance() {
            index = text.index(after: index)
        }

        while index < text.endIndex {
            let character = text[index]
            if character.isWhitespace {
                advance()
                continue
            }
            if character == "/" {
                let next = text.index(after: index)
                if next < text.endIndex, text[next] == "/" {
                    index = text[next...].firstIndex(of: "\n") ?? text.endIndex
                    continue
                }
            }
            if character == "{" {
                tokens.append(.openBrace)
                advance()
                continue
            }
            if character == "}" {
                tokens.append(.closeBrace)
                advance()
                continue
            }
            guard character == "\"" else {
                throw StillCoreError.invalidValveKeyValue(
                    "Expected a quoted string."
                )
            }

            advance()
            var value = ""
            var closed = false
            while index < text.endIndex {
                let current = text[index]
                if current == "\"" {
                    closed = true
                    advance()
                    break
                }
                if current == "\\" {
                    let next = text.index(after: index)
                    if next < text.endIndex {
                        let escaped = text[next]
                        if escaped == "\\" || escaped == "\"" {
                            value.append(escaped)
                            index = text.index(after: next)
                            continue
                        }
                    }
                }
                value.append(current)
                advance()
            }
            guard closed else {
                throw StillCoreError.invalidValveKeyValue(
                    "Unterminated quoted string."
                )
            }
            tokens.append(.value(value))
        }

        return tokens
    }
}
