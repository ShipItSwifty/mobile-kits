import Foundation
import SwiftParser
import SwiftSyntax

/// Declarations parsed from Swift source: classes, extensions, enums, functions, properties,
/// imports, and the calls inside function bodies.
///
/// Syntax only: no type checking, macro expansion, or cross-module resolution. Code in every
/// `#if` branch is indexed, since which branch compiles is unknown here.
public struct SwiftDeclarationIndex: Sendable {
    public enum Access: String, Codable, Sendable, Comparable {
        case `private`, `fileprivate`, `internal`, `package`, `public`, `open`

        static let order: [Access] = [.private, .fileprivate, .internal, .package, .public, .open]
        public static func < (lhs: Self, rhs: Self) -> Bool {
            (order.firstIndex(of: lhs) ?? 0) < (order.firstIndex(of: rhs) ?? 0)
        }

        /// Usable from another file of the same module, e.g. a generated subclass.
        public var isVisibleToModule: Bool { self >= .internal }
    }

    public struct Parameter: Sendable, Hashable {
        /// The argument label (`_` when unlabeled).
        public var label: String
        public var name: String
        public var type: String
        public var defaultValue: String?
    }

    public struct Function: Sendable, Hashable {
        public var name: String
        public var access: Access
        public var isOverride: Bool
        public var isStatic: Bool
        public var isFinal: Bool
        public var parameters: [Parameter]
        public var returnType: String?
        /// `app.launch`, `launch`, `XCTAssertTrue`, … for every call in the body.
        public var calls: [String]
        public var file: String
        public var line: Int

        /// `waitForExistence(_:timeout:)`.
        public var selector: String { "\(name)(\(parameters.map { $0.label + ":" }.joined()))" }
    }

    public struct Property: Sendable, Hashable {
        public var name: String
        public var access: Access
        public var isStatic: Bool
        public var isLet: Bool
        public var type: String?
        /// The literal value when the initializer is a plain string literal.
        public var stringLiteral: String?
        public var initializer: String?
        public var file: String
        public var line: Int
    }

    /// A class, struct, enum, or extension with its members.
    public struct TypeDeclaration: Sendable, Hashable {
        public enum Kind: String, Sendable { case `class`, `struct`, `enum`, `extension`, `protocol`, `actor` }
        public var kind: Kind
        public var name: String
        /// `Outer.Inner` for nested declarations.
        public var qualifiedName: String
        public var inherited: [String]
        public var access: Access
        public var isFinal: Bool
        public var functions: [Function]
        public var properties: [Property]
        public var file: String
        public var line: Int
    }

    public struct Import: Sendable, Hashable {
        public var module: String
        public var file: String
        public var line: Int
    }

    public var types: [TypeDeclaration]
    public var imports: [Import]
    /// Every file parsed, relative to the indexed root.
    public var files: [String]
    /// Identifier tokens per file, for cheap "does this file mention X" checks.
    public var identifiersByFile: [String: Set<String>]

    public init(types: [TypeDeclaration] = [], imports: [Import] = [], files: [String] = [], identifiersByFile: [String: Set<String>] = [:])
    {
        self.types = types
        self.imports = imports
        self.files = files
        self.identifiersByFile = identifiersByFile
    }

    /// Parses `source` as file `path` and adds its declarations.
    public mutating func add(source: String, path: String) {
        let tree = Parser.parse(source: source)
        let collector = DeclarationCollector(file: path, converter: SourceLocationConverter(fileName: path, tree: tree))
        collector.walk(tree)
        types += collector.types
        imports += collector.imports
        files.append(path)
        var names: Set<String> = []
        for token in tree.tokens(viewMode: .sourceAccurate) {
            if case .identifier(let name) = token.tokenKind { names.insert(name) }
        }
        identifiersByFile[path] = names
    }

    /// Classes by name; a name declared more than once maps to every declaration.
    public func classes(named name: String) -> [TypeDeclaration] {
        types.filter { $0.kind == .class && ($0.name == name || $0.qualifiedName == name) }
    }

    /// The local superclass chain of `type`, nearest first, while the superclass is declared in
    /// the index exactly once.
    public func superclassChain(of type: TypeDeclaration) -> [TypeDeclaration] {
        var chain: [TypeDeclaration] = []
        var current = type
        var seen: Set<String> = [type.qualifiedName]
        while let parent = current.inherited.first {
            let matches = classes(named: parent)
            guard matches.count == 1, let next = matches.first, seen.insert(next.qualifiedName).inserted else { break }
            chain.append(next)
            current = next
        }
        return chain
    }

    /// Whether `type` inherits from `ancestor`, locally or through its first, unresolved superclass name.
    public func inherits(_ type: TypeDeclaration, from ancestor: String) -> Bool {
        if type.inherited.first == ancestor { return true }
        return superclassChain(of: type).contains { $0.name == ancestor || $0.inherited.first == ancestor }
    }
}

/// Walks one file's syntax tree.
final class DeclarationCollector: SyntaxVisitor {
    let file: String
    let converter: SourceLocationConverter
    var types: [SwiftDeclarationIndex.TypeDeclaration] = []
    var imports: [SwiftDeclarationIndex.Import] = []
    private var stack: [Int] = []

    init(file: String, converter: SourceLocationConverter) {
        self.file = file
        self.converter = converter
        super.init(viewMode: .sourceAccurate)
    }

    private func line(_ node: some SyntaxProtocol) -> Int {
        node.startLocation(converter: converter).line
    }

    private static func access(
        _ modifiers: DeclModifierListSyntax, default value: SwiftDeclarationIndex.Access = .internal
    )
        -> SwiftDeclarationIndex.Access
    {
        for modifier in modifiers {
            // `private(set)` restricts the setter only.
            if modifier.detail != nil { continue }
            if let access = SwiftDeclarationIndex.Access(rawValue: modifier.name.text) { return access }
        }
        return value
    }

    private static func has(_ keyword: String, _ modifiers: DeclModifierListSyntax) -> Bool {
        modifiers.contains { $0.name.text == keyword }
    }

    private func push(
        _ kind: SwiftDeclarationIndex.TypeDeclaration.Kind,
        name: String,
        inherited: InheritanceClauseSyntax?,
        modifiers: DeclModifierListSyntax,
        node: some SyntaxProtocol
    ) {
        let outer = stack.last.map { types[$0].qualifiedName }
        types.append(
            .init(
                kind: kind, name: name, qualifiedName: outer.map { "\($0).\(name)" } ?? name,
                inherited: inherited?.inheritedTypes.map { $0.type.trimmedDescription } ?? [],
                access: Self.access(modifiers), isFinal: Self.has("final", modifiers), functions: [], properties: [], file: file,
                line: line(node)))
        stack.append(types.count - 1)
    }

    override func visit(_ node: ImportDeclSyntax) -> SyntaxVisitorContinueKind {
        imports.append(.init(module: node.path.map(\.name.text).joined(separator: "."), file: file, line: line(node)))
        return .skipChildren
    }

    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        push(.class, name: node.name.text, inherited: node.inheritanceClause, modifiers: node.modifiers, node: node)
        return .visitChildren
    }
    override func visitPost(_ node: ClassDeclSyntax) { stack.removeLast() }

    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        push(.struct, name: node.name.text, inherited: node.inheritanceClause, modifiers: node.modifiers, node: node)
        return .visitChildren
    }
    override func visitPost(_ node: StructDeclSyntax) { stack.removeLast() }

    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
        push(.enum, name: node.name.text, inherited: node.inheritanceClause, modifiers: node.modifiers, node: node)
        return .visitChildren
    }
    override func visitPost(_ node: EnumDeclSyntax) { stack.removeLast() }

    override func visit(_ node: ActorDeclSyntax) -> SyntaxVisitorContinueKind {
        push(.actor, name: node.name.text, inherited: node.inheritanceClause, modifiers: node.modifiers, node: node)
        return .visitChildren
    }
    override func visitPost(_ node: ActorDeclSyntax) { stack.removeLast() }

    override func visit(_ node: ProtocolDeclSyntax) -> SyntaxVisitorContinueKind {
        push(.protocol, name: node.name.text, inherited: node.inheritanceClause, modifiers: node.modifiers, node: node)
        return .visitChildren
    }
    override func visitPost(_ node: ProtocolDeclSyntax) { stack.removeLast() }

    override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
        push(
            .extension, name: node.extendedType.trimmedDescription, inherited: node.inheritanceClause, modifiers: node.modifiers, node: node
        )
        return .visitChildren
    }
    override func visitPost(_ node: ExtensionDeclSyntax) { stack.removeLast() }

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        let calls = node.body.map { CallCollector.calls(in: $0) } ?? []
        let function = SwiftDeclarationIndex.Function(
            name: node.name.text,
            access: Self.access(node.modifiers),
            isOverride: Self.has("override", node.modifiers),
            isStatic: Self.has("static", node.modifiers) || Self.has("class", node.modifiers),
            isFinal: Self.has("final", node.modifiers),
            parameters: node.signature.parameterClause.parameters.map {
                .init(
                    label: $0.firstName.text, name: ($0.secondName ?? $0.firstName).text, type: $0.type.trimmedDescription,
                    defaultValue: $0.defaultValue?.value.trimmedDescription)
            },
            returnType: node.signature.returnClause?.type.trimmedDescription,
            calls: calls, file: file, line: line(node))
        if let index = stack.last { types[index].functions.append(function) }
        // Nested declarations inside function bodies are local; do not index them as members.
        return .skipChildren
    }

    override func visit(_ node: InitializerDeclSyntax) -> SyntaxVisitorContinueKind { .skipChildren }

    override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
        guard let index = stack.last else { return .skipChildren }
        for binding in node.bindings {
            guard let pattern = binding.pattern.as(IdentifierPatternSyntax.self) else { continue }
            let initializer = binding.initializer?.value
            types[index].properties.append(
                .init(
                    name: pattern.identifier.text, access: Self.access(node.modifiers),
                    isStatic: Self.has("static", node.modifiers) || Self.has("class", node.modifiers),
                    isLet: node.bindingSpecifier.text == "let", type: binding.typeAnnotation?.type.trimmedDescription,
                    stringLiteral: initializer.flatMap(Self.literal), initializer: initializer?.trimmedDescription, file: file,
                    line: line(node)))
        }
        return .skipChildren
    }

    /// The value of a string literal without interpolation.
    static func literal(_ expression: ExprSyntax) -> String? {
        guard let string = expression.as(StringLiteralExprSyntax.self) else { return nil }
        var value = ""
        for segment in string.segments {
            guard let text = segment.as(StringSegmentSyntax.self) else { return nil }
            value += text.content.text
        }
        return value
    }
}

/// Collects called names (`app.launch`, `XCTAssertTrue`) inside a body.
final class CallCollector: SyntaxVisitor {
    var calls: [String] = []

    static func calls(in node: some SyntaxProtocol) -> [String] {
        let collector = CallCollector(viewMode: .sourceAccurate)
        collector.walk(node)
        return collector.calls
    }

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        if let member = node.calledExpression.as(MemberAccessExprSyntax.self) {
            let base = member.base?.trimmedDescription
            calls.append([base, member.declName.baseName.text].compactMap { $0 }.joined(separator: "."))
        } else if let reference = node.calledExpression.as(DeclReferenceExprSyntax.self) {
            calls.append(reference.baseName.text)
        }
        return .visitChildren
    }
}
