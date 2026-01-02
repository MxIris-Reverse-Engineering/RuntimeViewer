import Foundation
public import Semantic
public import ClassDumpRuntime

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
                result.append(string, type: .type(.other, .name))
            case .class:
                result.append(string, type: .type(.class, .name))
            case .protocol:
                result.append(string, type: .type(.protocol, .name))
            case .numeric:
                result.append(string, type: .numeric)
            case .method:
                result.append(string, type: .function(.declaration))
            case .methodArgument:
                result.append(string, type: .argument)
            default:
                break
            }
        }
        return result
    }
}
