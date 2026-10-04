import Foundation

/// Safe inline arithmetic evaluator for the overlay search bar.
///
/// Supports `+`, `-`, `*`, `/`, `%` (modulo), `^` (right-associative power),
/// unary `+`/`-`, decimal numbers, and parentheses. A query qualifies as a
/// calculator query only when the *entire* (trimmed) string parses and the
/// result is finite — anything else returns `nil` and normal search proceeds.
public enum Calculator {

    /// Evaluate a query string. Returns `nil` if the input is not a complete,
    /// valid arithmetic expression or if the result is not finite.
    public static func evaluate(_ query: String) -> Double? {
        var parser = Parser(tokens: tokenize(query))
        guard let value = parser.parseExpression(), parser.isAtEnd else { return nil }
        return value.isFinite ? value : nil
    }

    /// Human-facing display string for a result, e.g. `= 4`, `= 2.5`.
    /// Floating-point noise is trimmed to at most 10 decimal places and
    /// trailing zeros are dropped (`2.5`, not `2.5000000000`).
    public static func displayString(for value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.maximumFractionDigits = 10
        let text = formatter.string(from: NSNumber(value: value)) ?? "\(value)"
        return "= \(text)"
    }

    // MARK: - Tokenizer

    private enum Token {
        case number(Double)
        case leftParen
        case rightParen
        case op(Character) // + - * / % ^
    }

    private static func tokenize(_ input: String) -> [Token] {
        var tokens: [Token] = []
        var iterator = input.makeIterator()
        var pending: Character? = iterator.next()

        func advance() { pending = iterator.next() }

        while let ch = pending {
            switch ch {
            case " ", "\t":
                advance()
            case "+": tokens.append(.op("+")); advance()
            case "-": tokens.append(.op("-")); advance()
            case "*": tokens.append(.op("*")); advance()
            case "/": tokens.append(.op("/")); advance()
            case "%": tokens.append(.op("%")); advance()
            case "^": tokens.append(.op("^")); advance()
            case "(": tokens.append(.leftParen); advance()
            case ")": tokens.append(.rightParen); advance()
            case "0"..."9", ".":
                var digits = ""
                var dotSeen = false
                while let d = pending, d.isNumber || (d == "." && !dotSeen) {
                    if d == "." { dotSeen = true }
                    digits.append(d)
                    advance()
                }
                tokens.append(.number(Double(digits) ?? .nan))
            default:
                return [] // any other character disqualifies the query
            }
        }
        return tokens
    }

    // MARK: - Parser (recursive descent)

    private struct Parser {
        let tokens: [Token]
        var index = 0

        init(tokens: [Token]) {
            self.tokens = tokens
        }

        var isAtEnd: Bool { index >= tokens.count }

        mutating func parseExpression() -> Double? {
            guard var left = parseTerm() else { return nil }
            while !isAtEnd, case .op(let op) = tokens[index], op == "+" || op == "-" {
                index += 1
                guard let right = parseTerm() else { return nil }
                left = op == "+" ? left + right : left - right
            }
            return left
        }

        private mutating func parseTerm() -> Double? {
            guard var left = parseFactor() else { return nil }
            while !isAtEnd, case .op(let op) = tokens[index], op == "*" || op == "/" || op == "%" {
                index += 1
                guard let right = parseFactor() else { return nil }
                switch op {
                case "*": left = left * right
                case "/": left = left / right
                default:  left = right == 0 ? .nan : left.truncatingRemainder(dividingBy: right)
                }
            }
            return left
        }

        private mutating func parseFactor() -> Double? {
            guard let base = parseUnary() else { return nil }
            // `^` is right-associative: 2^3^2 == 2^(3^2) == 512
            if !isAtEnd, case .op("^") = tokens[index] {
                index += 1
                guard let exponent = parseFactor() else { return nil }
                return pow(base, exponent)
            }
            return base
        }

        private mutating func parseUnary() -> Double? {
            if !isAtEnd, case .op(let op) = tokens[index], op == "-" || op == "+" {
                index += 1
                guard let value = parseUnary() else { return nil }
                return op == "-" ? -value : value
            }
            return parsePrimary()
        }

        private mutating func parsePrimary() -> Double? {
            guard !isAtEnd else { return nil }
            switch tokens[index] {
            case .number(let value):
                guard value.isFinite else { return nil }
                index += 1
                return value
            case .leftParen:
                index += 1
                guard let value = parseExpression() else { return nil }
                guard !isAtEnd, case .rightParen = tokens[index] else { return nil }
                index += 1
                return value
            default:
                return nil
            }
        }
    }
}
