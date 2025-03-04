// Copyright (c) 2015, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:io';

import 'package:analyzer/dart/analysis/features.dart';
import 'package:analyzer/dart/ast/token.dart';
import 'package:analyzer/dart/constant/value.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/type_provider.dart';
import 'package:analyzer/dart/element/type_system.dart';
import 'package:analyzer/diagnostic/diagnostic.dart';
import 'package:analyzer/error/error.dart';
import 'package:analyzer/error/listener.dart';
import 'package:analyzer/file_system/file_system.dart' as file_system;
import 'package:analyzer/file_system/physical_file_system.dart' as file_system;
import 'package:analyzer/source/line_info.dart';
import 'package:analyzer/src/dart/ast/ast.dart';
import 'package:analyzer/src/dart/ast/token.dart';
import 'package:analyzer/src/dart/constant/compute.dart';
import 'package:analyzer/src/dart/constant/constant_verifier.dart';
import 'package:analyzer/src/dart/constant/evaluation.dart';
import 'package:analyzer/src/dart/constant/potentially_constant.dart';
import 'package:analyzer/src/dart/constant/utilities.dart';
import 'package:analyzer/src/dart/constant/value.dart';
import 'package:analyzer/src/dart/element/element.dart';
import 'package:analyzer/src/dart/element/inheritance_manager3.dart';
import 'package:analyzer/src/dart/element/type_system.dart';
import 'package:analyzer/src/error/codes.dart';
import 'package:analyzer/src/generated/engine.dart'
    show AnalysisErrorInfo, AnalysisErrorInfoImpl;
import 'package:analyzer/src/lint/analysis.dart';
import 'package:analyzer/src/lint/io.dart';
import 'package:analyzer/src/lint/linter_visitor.dart' show NodeLintRegistry;
import 'package:analyzer/src/lint/pub.dart';
import 'package:analyzer/src/lint/registry.dart';
import 'package:analyzer/src/lint/state.dart';
import 'package:analyzer/src/workspace/workspace.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;

export 'package:analyzer/src/lint/linter_visitor.dart' show NodeLintRegistry;
export 'package:analyzer/src/lint/state.dart'
    show dart2_12, dart3, dart3_3, State;

typedef Printer = void Function(String msg);

/// Dart source linter, only for package:linter's tools and tests.
class DartLinter implements AnalysisErrorListener {
  final errors = <AnalysisError>[];

  final LinterOptions options;
  final file_system.ResourceProvider _resourceProvider;
  final Reporter reporter;

  /// The total number of sources that were analyzed.  Only valid after
  /// [lintFiles] has been called.
  late int numSourcesAnalyzed;

  DartLinter(
    this.options, {
    file_system.ResourceProvider? resourceProvider,
    this.reporter = const PrintingReporter(),
  }) : _resourceProvider =
            resourceProvider ?? file_system.PhysicalResourceProvider.INSTANCE;

  Future<Iterable<AnalysisErrorInfo>> lintFiles(List<File> files) async {
    List<AnalysisErrorInfo> errors = [];
    var lintDriver = LintDriver(options, _resourceProvider);
    errors.addAll(await lintDriver.analyze(files.where((f) => isDartFile(f))));
    numSourcesAnalyzed = lintDriver.numSourcesAnalyzed;
    files.where((f) => isPubspecFile(f)).forEach((path) {
      numSourcesAnalyzed++;
      var errorsForFile = lintPubspecSource(
        contents: path.readAsStringSync(),
        sourcePath: _resourceProvider.pathContext.normalize(path.absolute.path),
      );
      errors.addAll(errorsForFile);
    });
    return errors;
  }

  @visibleForTesting
  Iterable<AnalysisErrorInfo> lintPubspecSource(
      {required String contents, String? sourcePath}) {
    var results = <AnalysisErrorInfo>[];

    var sourceUrl = sourcePath == null ? null : p.toUri(sourcePath);

    var spec = Pubspec.parse(contents, sourceUrl: sourceUrl);

    for (var lint in options.enabledRules) {
      var rule = lint;
      var visitor = rule.getPubspecVisitor();
      if (visitor != null) {
        // Analyzer sets reporters; if this file is not being analyzed,
        // we need to set one ourselves.  (Needless to say, when pubspec
        // processing gets pushed down, this hack can go away.)
        if (sourceUrl != null) {
          var source = createSource(sourceUrl);
          rule.reporter = ErrorReporter(this, source);
        }
        try {
          spec.accept(visitor);
        } on Exception catch (e) {
          reporter.exception(LinterException(e.toString()));
        }
        if (rule._locationInfo.isNotEmpty) {
          results.addAll(rule._locationInfo);
          rule._locationInfo.clear();
        }
      }
    }

    return results;
  }

  @override
  void onError(AnalysisError error) => errors.add(error);
}

class Group implements Comparable<Group> {
  /// Defined rule groups.
  static const Group errors =
      Group._('errors', description: 'Possible coding errors.');
  static const Group pub = Group._('pub',
      description: 'Pub-related rules.',
      link: Hyperlink('See the <strong>Pubspec Format</strong>',
          'https://dart.dev/tools/pub/pubspec'));
  static const Group style = Group._('style',
      description:
          'Matters of style, largely derived from the official Dart Style Guide.',
      link: Hyperlink('See the <strong>Style Guide</strong>',
          'https://dart.dev/guides/language/effective-dart/style'));

  /// List of builtin groups in presentation order.
  static const Iterable<Group> builtin = [errors, style, pub];

  final String name;
  final bool custom;
  final String description;
  final Hyperlink? link;

  factory Group(String name, {String description = '', Hyperlink? link}) {
    var n = name.toLowerCase();
    return builtin.firstWhere((g) => g.name == n,
        orElse: () =>
            Group._(name, custom: true, description: description, link: link));
  }

  const Group._(this.name,
      {this.custom = false, required this.description, this.link});

  @override
  int compareTo(Group other) => name.compareTo(other.name);
}

class Hyperlink {
  final String label;
  final String href;
  final bool bold;

  const Hyperlink(this.label, this.href, {this.bold = false});

  String get html => '<a href="$href">${_emph(label)}</a>';

  String _emph(String msg) => bold ? '<strong>$msg</strong>' : msg;
}

/// The result of attempting to evaluate an expression.
class LinterConstantEvaluationResult {
  /// The value of the expression, or `null` if has [errors].
  final DartObject? value;

  /// The errors reported during the evaluation.
  final List<AnalysisError> errors;

  LinterConstantEvaluationResult(this.value, this.errors);
}

/// Provides access to information needed by lint rules that is not available
/// from AST nodes or the element model.
abstract class LinterContext {
  List<LinterContextUnit> get allUnits;

  LinterContextUnit get currentUnit;

  InheritanceManager3 get inheritanceManager;

  WorkspacePackage? get package;

  TypeProvider get typeProvider;

  TypeSystem get typeSystem;

  /// Returns whether the [feature] is enabled in the library being linted.
  bool isEnabled(Feature feature);
}

class LinterContextImpl implements LinterContext {
  @override
  final List<LinterContextUnit> allUnits;

  @override
  final LinterContextUnit currentUnit;

  @override
  final WorkspacePackage? package;
  @override
  final TypeProvider typeProvider;

  @override
  final TypeSystemImpl typeSystem;

  @override
  final InheritanceManager3 inheritanceManager;

  LinterContextImpl(
    this.allUnits,
    this.currentUnit,
    this.typeProvider,
    this.typeSystem,
    this.inheritanceManager,
    this.package,
  );

  @override
  bool isEnabled(Feature feature) {
    var unitElement = currentUnit.unit.declaredElement!;
    return unitElement.library.featureSet.isEnabled(feature);
  }
}

class LinterContextParsedImpl implements LinterContext {
  @override
  final List<LinterContextUnit> allUnits;

  @override
  final LinterContextUnit currentUnit;

  @override
  final WorkspacePackage? package = null;

  @override
  final InheritanceManager3 inheritanceManager = InheritanceManager3();

  LinterContextParsedImpl(
    this.allUnits,
    this.currentUnit,
  );

  @override
  TypeProvider get typeProvider =>
      throw UnsupportedError('LinterContext with parsed results');

  @override
  TypeSystem get typeSystem =>
      throw UnsupportedError('LinterContext with parsed results');

  @override
  bool isEnabled(Feature feature) =>
      throw UnsupportedError('LinterContext with parsed results');
}

class LinterContextUnit {
  final String content;

  final CompilationUnit unit;

  final ErrorReporter errorReporter;

  LinterContextUnit(this.content, this.unit, this.errorReporter);
}

/// Thrown when an error occurs in linting.
class LinterException implements Exception {
  /// A message describing the error.
  final String? message;

  /// Creates a new LinterException with an optional error [message].
  const LinterException([this.message]);

  @override
  String toString() =>
      message == null ? "LinterException" : "LinterException: $message";
}

class LinterOptions extends DriverOptions {
  final Iterable<LintRule> enabledRules;
  final String? analysisOptions;
  LintFilter? filter;

  // TODO(pq): consider migrating to named params (but note Linter dep).
  LinterOptions({
    Iterable<LintRule>? enabledRules,
    this.analysisOptions,
    this.filter,
  }) : enabledRules = enabledRules ?? Registry.ruleRegistry;
}

/// Filtered lints are omitted from linter output.
abstract class LintFilter {
  bool filter(AnalysisError lint);
}

/// Describes a lint rule.
abstract class LintRule implements Comparable<LintRule>, NodeLintRule {
  /// Used to report lint warnings.
  /// NOTE: this is set by the framework before any node processors start
  /// visiting nodes.
  late ErrorReporter _reporter;

  /// Description (in markdown format) suitable for display in a detailed lint
  /// description.
  final String details;

  /// Short description suitable for display in console output.
  final String description;

  /// Lint group (for example, 'style').
  final Group group;

  /// Lint name.
  final String name;

  /// The documentation for the lint that should appear on the Diagnostic
  /// messages page. This field should never be accessed in any code in `lib` or
  /// `bin`.
  final String? documentation;

  /// A flag indicating whether this lint has documentation on the Diagnostic
  /// messages page.
  final bool hasDocumentation;

  /// Until pubspec analysis is pushed into the analyzer proper, we need to
  /// do some extra book-keeping to keep track of details that will help us
  /// constitute AnalysisErrorInfos.
  final List<AnalysisErrorInfo> _locationInfo = <AnalysisErrorInfo>[];

  /// The state of a lint, and optionally since when the state began.
  final State state;

  LintRule({
    required this.name,
    required this.group,
    required this.description,
    required this.details,
    State? state,
    this.documentation,
    this.hasDocumentation = false,
  }) : state = state ?? State.stable();

  /// Indicates whether the lint rule can work with just the parsed information
  /// or if it requires a resolved unit.
  bool get canUseParsedResult => false;

  /// A list of incompatible rule ids.
  List<String> get incompatibleRules => const [];

  /// The lint code associated with this linter.
  LintCode get lintCode => _LintCode(name, description);

  /// The lint codes associated with this lint rule.
  List<LintCode> get lintCodes => [lintCode];

  @protected
  // Protected so that lint rule visitors do not access this directly.
  // TODO(srawlins): With the new availability of an ErrorReporter on
  // LinterContextUnit, we should probably remove this reporter. But whatever
  // the new API would be is not yet decided. It might also change with the
  // notion of post-processing lint rules that have access to all unit
  // reporters at once.
  ErrorReporter get reporter => _reporter;

  set reporter(ErrorReporter value) => _reporter = value;

  @override
  int compareTo(LintRule other) {
    var g = group.compareTo(other.group);
    if (g != 0) {
      return g;
    }
    return name.compareTo(other.name);
  }

  /// Return a visitor to be passed to pubspecs to perform lint
  /// analysis.
  /// Lint errors are reported via this [Linter]'s error [reporter].
  PubspecVisitor? getPubspecVisitor() => null;

  @override
  void registerNodeProcessors(
      NodeLintRegistry registry, LinterContext context) {}

  void reportLint(AstNode? node,
      {List<Object> arguments = const [],
      List<DiagnosticMessage>? contextMessages,
      ErrorCode? errorCode,
      bool ignoreSyntheticNodes = true}) {
    if (node != null && (!node.isSynthetic || !ignoreSyntheticNodes)) {
      reporter.atNode(
        node,
        errorCode ?? lintCode,
        arguments: arguments,
        contextMessages: contextMessages,
      );
    }
  }

  void reportLintForOffset(int offset, int length,
      {List<Object> arguments = const [],
      List<DiagnosticMessage>? contextMessages,
      ErrorCode? errorCode}) {
    reporter.atOffset(
      offset: offset,
      length: length,
      errorCode: errorCode ?? lintCode,
      arguments: arguments,
      contextMessages: contextMessages,
    );
  }

  void reportLintForToken(Token? token,
      {List<Object> arguments = const [],
      List<DiagnosticMessage>? contextMessages,
      ErrorCode? errorCode,
      bool ignoreSyntheticTokens = true}) {
    if (token != null && (!token.isSynthetic || !ignoreSyntheticTokens)) {
      reporter.atToken(
        token,
        errorCode ?? lintCode,
        arguments: arguments,
        contextMessages: contextMessages,
      );
    }
  }

  void reportPubLint(PSNode node,
      {List<Object> arguments = const [],
      List<DiagnosticMessage> contextMessages = const [],
      ErrorCode? errorCode}) {
    var source = node.source;
    // Cache error and location info for creating AnalysisErrorInfos
    AnalysisError error = AnalysisError.tmp(
      source: source,
      offset: node.span.start.offset,
      length: node.span.length,
      errorCode: errorCode ?? lintCode,
      arguments: arguments,
      contextMessages: contextMessages,
    );
    LineInfo lineInfo = LineInfo.fromContent(source.contents.data);

    _locationInfo.add(AnalysisErrorInfoImpl([error], lineInfo));

    // Then do the reporting
    reporter.reportError(error);
  }
}

/// [LintRule]s that implement this interface want to process only some types
/// of AST nodes, and will register their processors in the registry.
abstract class NodeLintRule {
  /// This method is invoked to let the [LintRule] register node processors
  /// in the given [registry].
  ///
  /// The node processors may use the provided [context] to access information
  /// that is not available from the AST nodes or their associated elements.
  void registerNodeProcessors(NodeLintRegistry registry, LinterContext context);
}

class PrintingReporter implements Reporter {
  final Printer _print;

  const PrintingReporter([this._print = print]);

  @override
  void exception(LinterException exception) {
    _print('EXCEPTION: $exception');
  }

  @override
  void warn(String message) {
    _print('WARN: $message');
  }
}

abstract class Reporter {
  void exception(LinterException exception);

  void warn(String message);
}

/// An error listener that only records whether any constant related errors have
/// been reported.
class _ConstantAnalysisErrorListener extends AnalysisErrorListener {
  /// A flag indicating whether any constant related errors have been reported
  /// to this listener.
  bool hasConstError = false;

  @override
  void onError(AnalysisError error) {
    ErrorCode errorCode = error.errorCode;
    if (errorCode is CompileTimeErrorCode) {
      switch (errorCode) {
        case CompileTimeErrorCode
              .CONST_CONSTRUCTOR_CONSTANT_FROM_DEFERRED_LIBRARY:
        case CompileTimeErrorCode
              .CONST_CONSTRUCTOR_WITH_FIELD_INITIALIZED_BY_NON_CONST:
        case CompileTimeErrorCode.CONST_EVAL_EXTENSION_METHOD:
        case CompileTimeErrorCode.CONST_EVAL_METHOD_INVOCATION:
        case CompileTimeErrorCode.CONST_EVAL_PROPERTY_ACCESS:
        case CompileTimeErrorCode.CONST_EVAL_TYPE_BOOL:
        case CompileTimeErrorCode.CONST_EVAL_TYPE_BOOL_INT:
        case CompileTimeErrorCode.CONST_EVAL_TYPE_BOOL_NUM_STRING:
        case CompileTimeErrorCode.CONST_EVAL_TYPE_INT:
        case CompileTimeErrorCode.CONST_EVAL_TYPE_NUM:
        case CompileTimeErrorCode.CONST_EVAL_TYPE_NUM_STRING:
        case CompileTimeErrorCode.CONST_EVAL_TYPE_STRING:
        case CompileTimeErrorCode.CONST_EVAL_THROWS_EXCEPTION:
        case CompileTimeErrorCode.CONST_EVAL_THROWS_IDBZE:
        case CompileTimeErrorCode.CONST_EVAL_FOR_ELEMENT:
        case CompileTimeErrorCode.CONST_MAP_KEY_NOT_PRIMITIVE_EQUALITY:
        case CompileTimeErrorCode.CONST_SET_ELEMENT_NOT_PRIMITIVE_EQUALITY:
        case CompileTimeErrorCode.CONST_TYPE_PARAMETER:
        case CompileTimeErrorCode.CONST_WITH_NON_CONST:
        case CompileTimeErrorCode.CONST_WITH_NON_CONSTANT_ARGUMENT:
        case CompileTimeErrorCode.CONST_WITH_TYPE_PARAMETERS:
        case CompileTimeErrorCode
              .CONST_WITH_TYPE_PARAMETERS_CONSTRUCTOR_TEAROFF:
        case CompileTimeErrorCode.INVALID_CONSTANT:
        case CompileTimeErrorCode.MISSING_CONST_IN_LIST_LITERAL:
        case CompileTimeErrorCode.MISSING_CONST_IN_MAP_LITERAL:
        case CompileTimeErrorCode.MISSING_CONST_IN_SET_LITERAL:
        case CompileTimeErrorCode.NON_BOOL_CONDITION:
        case CompileTimeErrorCode.NON_CONSTANT_LIST_ELEMENT:
        case CompileTimeErrorCode.NON_CONSTANT_MAP_ELEMENT:
        case CompileTimeErrorCode.NON_CONSTANT_MAP_KEY:
        case CompileTimeErrorCode.NON_CONSTANT_MAP_VALUE:
        case CompileTimeErrorCode.NON_CONSTANT_RECORD_FIELD:
        case CompileTimeErrorCode.NON_CONSTANT_SET_ELEMENT:
          hasConstError = true;
      }
    }
  }
}

class _LintCode extends LintCode {
  static final registry = <String, _LintCode>{};

  factory _LintCode(String name, String message) {
    return registry[name + message] ??= _LintCode._(name, message);
  }

  _LintCode._(super.name, super.message);
}

extension on AstNode {
  /// Whether [ConstantVerifier] reports an error when computing the value of
  /// `this` as a constant.
  bool get hasConstantVerifierError {
    var unitElement = thisOrAncestorOfType<CompilationUnit>()?.declaredElement;
    if (unitElement == null) return false;
    var libraryElement = unitElement.library as LibraryElementImpl;

    var dependenciesFinder = ConstantExpressionsDependenciesFinder();
    accept(dependenciesFinder);
    computeConstants(
      declaredVariables: unitElement.session.declaredVariables,
      constants: dependenciesFinder.dependencies.toList(),
      featureSet: libraryElement.featureSet,
      configuration: ConstantEvaluationConfiguration(),
    );

    var listener = _ConstantAnalysisErrorListener();
    var errorReporter = ErrorReporter(listener, unitElement.source);

    accept(
      ConstantVerifier(
        errorReporter,
        libraryElement,
        unitElement.session.declaredVariables,
      ),
    );
    return listener.hasConstError;
  }
}

extension ConstructorDeclarationExtension on ConstructorDeclaration {
  bool get canBeConst {
    var element = declaredElement!;

    var classElement = element.enclosingElement;
    if (classElement is ClassElement && classElement.hasNonFinalField) {
      return false;
    }

    var oldKeyword = constKeyword;
    var self = this as ConstructorDeclarationImpl;
    try {
      temporaryConstConstructorElements[element] = true;
      self.constKeyword = KeywordToken(Keyword.CONST, offset);
      return !hasConstantVerifierError;
    } finally {
      temporaryConstConstructorElements[element] = null;
      self.constKeyword = oldKeyword;
    }
  }
}

extension ExpressionExtension on Expression {
  /// Whether it would be valid for this expression to have a `const` keyword.
  ///
  /// Note that this method can cause constant evaluation to occur, which can be
  /// computationally expensive.
  bool get canBeConst {
    var self = this;
    return switch (self) {
      InstanceCreationExpressionImpl() => _canBeConstInstanceCreation(self),
      TypedLiteralImpl() => _canBeConstTypedLiteral(self),
      _ => false,
    };
  }

  /// Computes the constant value of `this`, if it has one.
  ///
  /// Returns a [LinterConstantEvaluationResult], containing both the computed
  /// constant value, and a list of errors that occurred during the computation.
  LinterConstantEvaluationResult computeConstantValue() {
    var unitElement = thisOrAncestorOfType<CompilationUnit>()?.declaredElement;
    if (unitElement == null) return LinterConstantEvaluationResult(null, []);
    var libraryElement = unitElement.library as LibraryElementImpl;

    var errorListener = RecordingErrorListener();

    var evaluationEngine = ConstantEvaluationEngine(
      declaredVariables: unitElement.session.declaredVariables,
      configuration: ConstantEvaluationConfiguration(),
    );

    var dependencies = <ConstantEvaluationTarget>[];
    accept(ReferenceFinder(dependencies.add));

    computeConstants(
      declaredVariables: unitElement.session.declaredVariables,
      constants: dependencies,
      featureSet: libraryElement.featureSet,
      configuration: ConstantEvaluationConfiguration(),
    );

    var visitor = ConstantVisitor(
      evaluationEngine,
      libraryElement,
      ErrorReporter(errorListener, unitElement.source),
    );

    var constant = visitor.evaluateAndReportInvalidConstant(this);
    var dartObject = constant is DartObjectImpl ? constant : null;
    return LinterConstantEvaluationResult(dartObject, errorListener.errors);
  }

  bool _canBeConstInstanceCreation(InstanceCreationExpressionImpl node) {
    var element = node.constructorName.staticElement;
    if (element == null || !element.isConst) return false;

    // Ensure that dependencies (e.g. default parameter values) are computed.
    var implElement = element.declaration as ConstructorElementImpl;
    implElement.computeConstantDependencies();

    // Verify that the evaluation of the constructor would not produce an
    // exception.
    var oldKeyword = node.keyword;
    try {
      node.keyword = KeywordToken(Keyword.CONST, offset);
      return !hasConstantVerifierError;
    } finally {
      node.keyword = oldKeyword;
    }
  }

  bool _canBeConstTypedLiteral(TypedLiteralImpl node) {
    var oldKeyword = node.constKeyword;
    try {
      node.constKeyword = KeywordToken(Keyword.CONST, offset);
      return !hasConstantVerifierError;
    } finally {
      node.constKeyword = oldKeyword;
    }
  }
}
