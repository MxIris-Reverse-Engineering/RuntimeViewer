import CrossReferenceAnalysis

/// Whether an Objective-C send can reach a given method, and how surely —
/// the precision rules of the cross references proposal, §4.
///
/// A send names a selector, never a method. What else the analysis knows is
/// the receiver: the sending method's own `self` (whose class is the one the
/// sending method belongs to, or a subclass), a class literal
/// (`[NSWindow alloc]`, whose receiver is the class object), or nothing. A
/// send whose receiver is known to be an instance cannot reach a class
/// method, nor the other way round — except that a class object reaches its
/// root class's instance methods.
///
/// The class hierarchy is not consulted: a known receiver of another class
/// may be a subclass, so it matches by selector rather than being excluded.
enum ObjectiveCSendMatching {
    /// What a send can be said to reach `method` with; `nil` when it cannot
    /// reach it.
    ///
    /// - Parameters:
    ///   - receiver: The analysis's hint about the receiver.
    ///   - isSuperSend: A send through `objc_msgSendSuper2`, which goes to the
    ///     sending method's superclass with `self` as the receiver.
    ///   - sendingMethods: Every Objective-C method the sending function is —
    ///     several when identical code folding merged them. A send matches
    ///   when it matches as any of them.
    static func precision(
        ofSendWith receiver: ReceiverClassHint,
        isSuperSend: Bool,
        from sendingMethods: [ObjectiveCMethodName],
        to method: ObjectiveCMethodName
    ) -> RuntimeCrossReferencePrecision? {
        if isSuperSend {
            // The class the send starts looking in is the sending method's
            // superclass, which this analysis does not know.
            guard !sendingMethods.isEmpty else { return .matchedBySelector }
            let reaches = sendingMethods.contains { canReceive(method, onClassObject: $0.isClassMethod) }
            return reaches ? .matchedBySelector : nil
        }
        switch receiver {
        case .classLiteral(let className):
            guard canReceive(method, onClassObject: true) else { return nil }
            return method.isClassMethod && className == method.className ? .exact : .matchedBySelector
        case .methodReceiver:
            guard !sendingMethods.isEmpty else { return .matchedBySelector }
            var best: RuntimeCrossReferencePrecision?
            for sendingMethod in sendingMethods where canReceive(method, onClassObject: sendingMethod.isClassMethod) {
                let sameKindOfReceiver = sendingMethod.isClassMethod == method.isClassMethod
                if sameKindOfReceiver, sendingMethod.className == method.className { return .exact }
                best = .matchedBySelector
            }
            return best
        case .unknown:
            return .matchedBySelector
        }
    }

    /// The class the receiver is known to belong to, when it is known: a
    /// class literal's, or the sending method's own for its `self`.
    static func receiverClassName(of receiver: ReceiverClassHint, isSuperSend: Bool, from sendingMethods: [ObjectiveCMethodName]) -> String? {
        guard !isSuperSend else { return nil }
        switch receiver {
        case .classLiteral(let className):
            return className
        case .methodReceiver:
            return sendingMethods.first?.className
        case .unknown:
            return nil
        }
    }

    /// Whether a receiver of the given kind can run `method` at all.
    private static func canReceive(_ method: ObjectiveCMethodName, onClassObject: Bool) -> Bool {
        if onClassObject == method.isClassMethod { return true }
        // A class object reaches its root class's instance methods; an
        // instance never reaches a class method.
        return onClassObject && method.isOfRootClass
    }
}
