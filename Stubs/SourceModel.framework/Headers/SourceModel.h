// Minimal Objective-C surface of Xcode's private SourceModel framework.
//
// Only what the bridge needs to retype parsed nodes: the item, and the registry that maps a
// node type name to its numeric id. Everything else the framework exposes is deliberately
// absent — this is a stub, not a reconstruction.
//
// These declarations are hand-written from the framework's own headers as exported by
// RuntimeViewer; no Apple source or binary is redistributed here.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// One node of a parsed source model: a range of the buffer plus the type the parser assigned
/// it. `nodeType` is the whole point — retyping a node is how a lexical guess becomes semantic.
@interface SMSourceModelItem : NSObject
@property (nonatomic) NSRange range;
- (short)nodeType;
- (void)setNodeType:(short)nodeType;
@end

/// Node types are registered by name, and the names are exactly the theme's syntax keys —
/// `xcode.syntax.identifier.class`, `xcode.syntax.identifier.class.system`, and so on. Ids are
/// assigned in registration order, so resolve them by name rather than hardcoding numbers.
@interface SMSourceNodeTypes : NSObject
+ (long long)nodeTypesCount;
+ (nullable NSString *)nodeTypeNameForId:(short)identifier;
@end

NS_ASSUME_NONNULL_END
