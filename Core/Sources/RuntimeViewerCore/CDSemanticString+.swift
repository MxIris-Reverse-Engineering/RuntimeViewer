import Foundation
import Semantic
import ClassDumpRuntime

extension CDSemanticString {
    public var semanticString: SemanticString {
        var result = SemanticString()
        enumerateTypes { string, type in
            switch type {
            case .standard:
                result.append(string, type: .standard)
            case .comment:
                result.append(string, type: .comment)
            case .keyword:
                result.append(string, type: .keyword)
            case .variable:
                result.append(string, type: .variable)
            case .recordName:
                result.append(string, type: .typeName)
            case .class:
                result.append(string, type: .typeName)
            case .protocol:
                result.append(string, type: .typeName)
            case .numeric:
                result.append(string, type: .numeric)
            case .method:
                result.append(string, type: .functionDeclaration)
            case .methodArgument:
                result.append(string, type: .argument)
            default:
                break
            }
        }
        return result
    }
}
