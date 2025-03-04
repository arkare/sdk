// Copyright (c) 2017, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:_fe_analyzer_shared/src/flow_analysis/flow_analysis_operations.dart';
import 'package:_fe_analyzer_shared/src/type_inference/assigned_variables.dart';
import 'package:_fe_analyzer_shared/src/type_inference/nullability_suffix.dart';
import 'package:_fe_analyzer_shared/src/type_inference/type_analyzer_operations.dart'
    hide Variance;
import 'package:kernel/ast.dart';
import 'package:kernel/class_hierarchy.dart'
    show ClassHierarchy, ClassHierarchyBase;
import 'package:kernel/core_types.dart' show CoreTypes;
import 'package:kernel/src/norm.dart';
import 'package:kernel/type_algebra.dart';
import 'package:kernel/type_environment.dart';

import '../../base/instrumentation.dart' show Instrumentation;
import '../kernel/benchmarker.dart' show Benchmarker;
import '../kernel/exhaustiveness.dart';
import '../kernel/hierarchy/hierarchy_builder.dart' show ClassHierarchyBuilder;
import '../kernel/hierarchy/members_builder.dart' show ClassMembersBuilder;
import '../kernel/implicit_field_type.dart';
import '../kernel/internal_ast.dart';
import '../kernel/kernel_helper.dart';
import '../source/source_constructor_builder.dart';
import '../source/source_library_builder.dart'
    show FieldNonPromotabilityInfo, SourceLibraryBuilder;
import 'factor_type.dart';
import 'type_inferrer.dart';
import 'type_schema.dart';
import 'type_schema_elimination.dart' as type_schema_elimination;
import 'type_schema_environment.dart'
    show GeneratedTypeConstraint, TypeSchemaEnvironment;

/// Visitor to check whether a given type mentions any of a class's type
/// parameters in a non-covariant fashion.
class IncludesTypeParametersNonCovariantly implements DartTypeVisitor<bool> {
  Variance _variance;

  final List<TypeParameter> _typeParametersToSearchFor;

  IncludesTypeParametersNonCovariantly(this._typeParametersToSearchFor,
      {required Variance initialVariance})
      : _variance = initialVariance;

  @override
  bool visitAuxiliaryType(AuxiliaryType node) {
    throw new UnsupportedError(
        "Unsupported auxiliary type ${node} (${node.runtimeType}).");
  }

  @override
  bool visitDynamicType(DynamicType node) => false;

  @override
  bool visitExtensionType(ExtensionType node) => false;

  @override
  bool visitNeverType(NeverType node) => false;

  @override
  bool visitInvalidType(InvalidType node) => false;

  @override
  bool visitNullType(NullType node) => false;

  @override
  bool visitVoidType(VoidType node) => false;

  @override
  bool visitFunctionType(FunctionType node) {
    if (node.returnType.accept(this)) return true;
    Variance oldVariance = _variance;
    _variance = Variance.invariant;
    for (StructuralParameter parameter in node.typeParameters) {
      if (parameter.bound.accept(this)) return true;
    }
    _variance = Variance.contravariant.combine(oldVariance);
    for (DartType parameter in node.positionalParameters) {
      if (parameter.accept(this)) return true;
    }
    for (NamedType parameter in node.namedParameters) {
      if (parameter.type.accept(this)) return true;
    }
    _variance = oldVariance;
    return false;
  }

  @override
  bool visitRecordType(RecordType node) {
    for (DartType parameter in node.positional) {
      if (parameter.accept(this)) return true;
    }
    for (NamedType parameter in node.named) {
      if (parameter.type.accept(this)) return true;
    }
    return false;
  }

  @override
  bool visitInterfaceType(InterfaceType node) {
    Variance oldVariance = _variance;
    for (int i = 0; i < node.typeArguments.length; i++) {
      _variance =
          node.classNode.typeParameters[i].variance.combine(oldVariance);
      if (node.typeArguments[i].accept(this)) return true;
    }
    _variance = oldVariance;
    return false;
  }

  @override
  bool visitFutureOrType(FutureOrType node) {
    return node.typeArgument.accept(this);
  }

  @override
  bool visitTypedefType(TypedefType node) {
    return node.unalias.accept(this);
  }

  @override
  bool visitTypeParameterType(TypeParameterType node) {
    return !_variance.greaterThanOrEqual(node.parameter.variance) &&
        _typeParametersToSearchFor.contains(node.parameter);
  }

  @override
  bool visitStructuralParameterType(StructuralParameterType node) {
    return false;
  }

  @override
  bool visitIntersectionType(IntersectionType node) {
    return node.left.accept(this);
  }
}

/// Keeps track of the global state for the type inference that occurs outside
/// of method bodies and initializers.
///
/// This class describes the interface for use by clients of type inference
/// (e.g. DietListener).  Derived classes should derive from
/// [TypeInferenceEngineImpl].
abstract class TypeInferenceEngine {
  late ClassHierarchyBuilder hierarchyBuilder;

  late ClassMembersBuilder membersBuilder;

  late CoreTypes coreTypes;

  /// Indicates whether the "prepare" phase of type inference is complete.
  bool isTypeInferencePrepared = false;

  late TypeSchemaEnvironment typeSchemaEnvironment;

  /// A map containing constructors with initializing formals whose types
  /// need to be inferred.
  ///
  /// This is represented as a map from a constructor to its library
  /// builder because the builder is used to report errors due to cyclic
  /// inference dependencies.
  final Map<Member, SourceConstructorBuilder> toBeInferred = {};

  /// A map containing constructors in the process of being inferred.
  ///
  /// This is used to detect cyclic inference dependencies.  It is represented
  /// as a map from a constructor to its library builder because the builder
  /// is used to report errors.
  final Map<Member, SourceConstructorBuilder> beingInferred = {};

  final Map<Member, TypeDependency> typeDependencies = {};

  final Instrumentation? instrumentation;

  final Map<DartType, DartType> typeCacheNonNullable =
      new Map<DartType, DartType>.identity();
  final Map<DartType, DartType> typeCacheNullable =
      new Map<DartType, DartType>.identity();
  final Map<DartType, DartType> typeCacheLegacy =
      new Map<DartType, DartType>.identity();

  TypeInferenceEngine(this.instrumentation);

  /// Creates a type inferrer for use inside of a method body declared in a file
  /// with the given [uri].
  TypeInferrer createLocalTypeInferrer(Uri uri, InterfaceType? thisType,
      SourceLibraryBuilder library, InferenceDataForTesting? dataForTesting);

  /// Creates a [TypeInferrer] object which is ready to perform type inference
  /// on the given [field].
  TypeInferrer createTopLevelTypeInferrer(Uri uri, InterfaceType? thisType,
      SourceLibraryBuilder library, InferenceDataForTesting? dataForTesting);

  /// Performs the third phase of top level inference, which is to visit all
  /// constructors still needing inference and infer the types of their
  /// initializing formals from the corresponding fields.
  void finishTopLevelInitializingFormals() {
    // Field types have all been inferred so we don't need to guard against
    // cyclic dependency.
    for (SourceConstructorBuilder builder in toBeInferred.values) {
      builder.inferFormalTypes(hierarchyBuilder);
    }
    toBeInferred.clear();
    for (TypeDependency typeDependency in typeDependencies.values) {
      typeDependency.copyInferred();
    }
    typeDependencies.clear();
  }

  /// Gets ready to do top level type inference for the component having the
  /// given [hierarchy], using the given [coreTypes].
  void prepareTopLevel(CoreTypes coreTypes, ClassHierarchy hierarchy) {
    this.coreTypes = coreTypes;
    this.typeSchemaEnvironment =
        new TypeSchemaEnvironment(coreTypes, hierarchy);
  }

  static Member? resolveInferenceNode(
      Member? member, ClassHierarchyBase hierarchy) {
    // TODO(johnniwinther): Can we remove this now?
    if (member is Field) {
      DartType type = member.type;
      if (type is InferredType) {
        type.inferType(hierarchy);
      }
    }
    return member;
  }

  Procedure? _addMethod;

  /// Returns the [Procedure] for the [Set.add] method.
  ///
  /// This is used for lowering set literals for targets that don't support the
  /// [SetLiteral] node.
  Procedure get setAddMethod => _addMethod ??= _findAddMethod();

  Procedure _findAddMethod() {
    return coreTypes.index.getProcedure('dart:core', 'Set', 'add');
  }

  FunctionType? _addMethodFunctionType;

  /// Returns the [FunctionType] for the [Set.add] method.
  ///
  /// This is used for lowering set literals for targets that don't support the
  /// [SetLiteral] node.
  FunctionType get setAddMethodFunctionType =>
      _addMethodFunctionType ??= setAddMethod.getterType as FunctionType;

  Procedure? _listAdd;
  Procedure get listAdd =>
      _listAdd ??= coreTypes.index.getProcedure('dart:core', 'List', 'add');

  FunctionType? _listAddFunctionType;
  FunctionType get listAddFunctionType =>
      _listAddFunctionType ??= listAdd.getterType as FunctionType;

  Procedure? _listAddAll;
  Procedure get listAddAll => _listAddAll ??=
      coreTypes.index.getProcedure('dart:core', 'List', 'addAll');

  FunctionType? _listAddAllFunctionType;
  FunctionType get listAddAllFunctionType =>
      _listAddAllFunctionType ??= listAddAll.getterType as FunctionType;

  Procedure? _listOf;
  Procedure get listOf =>
      _listOf ??= coreTypes.index.getProcedure('dart:core', 'List', 'of');

  Procedure? _setFactory;
  Procedure get setFactory => _setFactory ??= _findSetFactory(coreTypes, '');

  Procedure? _setAdd;
  Procedure get setAdd =>
      _setAdd ??= coreTypes.index.getProcedure('dart:core', 'Set', 'add');

  FunctionType? _setAddFunctionType;
  FunctionType get setAddFunctionType =>
      _setAddFunctionType ??= setAdd.getterType as FunctionType;

  Procedure? _setAddAll;
  Procedure get setAddAll =>
      _setAddAll ??= coreTypes.index.getProcedure('dart:core', 'Set', 'addAll');

  FunctionType? _setAddAllFunctionType;
  FunctionType get setAddAllFunctionType =>
      _setAddAllFunctionType ??= setAddAll.getterType as FunctionType;

  Procedure? _setOf;
  Procedure get setOf => _setOf ??= _findSetFactory(coreTypes, 'of');

  Procedure? _mapEntries;
  Procedure get mapEntries => _mapEntries ??=
      coreTypes.index.getProcedure('dart:core', 'Map', 'get:entries');

  Procedure? _mapPut;
  Procedure get mapPut =>
      _mapPut ??= coreTypes.index.getProcedure('dart:core', 'Map', '[]=');

  FunctionType? _mapPutFunctionType;
  FunctionType get mapPutFunctionType =>
      _mapPutFunctionType ??= mapPut.getterType as FunctionType;

  Class? _mapEntryClass;
  Class get mapEntryClass =>
      _mapEntryClass ??= coreTypes.index.getClass('dart:core', 'MapEntry');

  Field? _mapEntryKey;
  Field get mapEntryKey =>
      _mapEntryKey ??= coreTypes.index.getField('dart:core', 'MapEntry', 'key');

  Field? _mapEntryValue;
  Field get mapEntryValue => _mapEntryValue ??=
      coreTypes.index.getField('dart:core', 'MapEntry', 'value');

  Procedure? _mapAddAll;
  Procedure get mapAddAll =>
      _mapAddAll ??= coreTypes.index.getProcedure('dart:core', 'Map', 'addAll');

  FunctionType? _mapAddAllFunctionType;
  FunctionType get mapAddAllFunctionType =>
      _mapAddAllFunctionType ??= mapAddAll.getterType as FunctionType;

  Procedure? _mapOf;
  Procedure get mapOf => _mapOf ??= _findMapFactory(coreTypes, 'of');

  static Procedure _findSetFactory(CoreTypes coreTypes, String name) {
    Procedure factory = coreTypes.index.getProcedure('dart:core', 'Set', name);
    RedirectingFactoryTarget redirectingFactoryTarget =
        factory.function.redirectingFactoryTarget!;
    return redirectingFactoryTarget.target as Procedure;
  }

  static Procedure _findMapFactory(CoreTypes coreTypes, String name) {
    Procedure factory = coreTypes.index.getProcedure('dart:core', 'Map', name);
    RedirectingFactoryTarget redirectingFactoryTarget =
        factory.function.redirectingFactoryTarget!;
    return redirectingFactoryTarget.target as Procedure;
  }
}

/// Concrete implementation of [TypeInferenceEngine] specialized to work with
/// kernel objects.
class TypeInferenceEngineImpl extends TypeInferenceEngine {
  final Benchmarker? benchmarker;
  final FunctionType unknownFunction =
      new FunctionType(const [], const DynamicType(), Nullability.nonNullable);

  TypeInferenceEngineImpl(Instrumentation? instrumentation, this.benchmarker)
      : super(instrumentation);

  @override
  TypeInferrer createLocalTypeInferrer(Uri uri, InterfaceType? thisType,
      SourceLibraryBuilder library, InferenceDataForTesting? dataForTesting) {
    AssignedVariables<TreeNode, VariableDeclaration> assignedVariables;
    if (dataForTesting != null) {
      assignedVariables = dataForTesting.flowAnalysisResult.assignedVariables =
          new AssignedVariablesForTesting<TreeNode, VariableDeclaration>();
    } else {
      assignedVariables =
          new AssignedVariables<TreeNode, VariableDeclaration>();
    }
    if (benchmarker == null) {
      return new TypeInferrerImpl(this, uri, false, thisType, library,
          assignedVariables, dataForTesting, unknownFunction);
    }
    return new TypeInferrerImplBenchmarked(this, uri, false, thisType, library,
        assignedVariables, dataForTesting, benchmarker!, unknownFunction);
  }

  @override
  TypeInferrer createTopLevelTypeInferrer(Uri uri, InterfaceType? thisType,
      SourceLibraryBuilder library, InferenceDataForTesting? dataForTesting) {
    AssignedVariables<TreeNode, VariableDeclaration> assignedVariables;
    if (dataForTesting != null) {
      assignedVariables = dataForTesting.flowAnalysisResult.assignedVariables =
          new AssignedVariablesForTesting<TreeNode, VariableDeclaration>();
    } else {
      assignedVariables =
          new AssignedVariables<TreeNode, VariableDeclaration>();
    }
    if (benchmarker == null) {
      return new TypeInferrerImpl(this, uri, true, thisType, library,
          assignedVariables, dataForTesting, unknownFunction);
    }
    return new TypeInferrerImplBenchmarked(this, uri, true, thisType, library,
        assignedVariables, dataForTesting, benchmarker!, unknownFunction);
  }
}

class InferenceDataForTesting {
  final FlowAnalysisResult flowAnalysisResult = new FlowAnalysisResult();

  final TypeInferenceResultForTesting typeInferenceResult =
      new TypeInferenceResultForTesting();
}

/// The result of performing flow analysis on a unit.
class FlowAnalysisResult {
  /// The list of nodes, [Expression]s or [Statement]s, that cannot be reached,
  /// for example because a previous statement always exits.
  final List<TreeNode> unreachableNodes = [];

  /// The list of function bodies that don't complete, for example because
  /// there is a `return` statement at the end of the function body block.
  final List<TreeNode> functionBodiesThatDontComplete = [];

  /// The list of [Expression]s representing variable accesses that occur before
  /// the corresponding variable has been definitely assigned.
  final List<TreeNode> potentiallyUnassignedNodes = [];

  /// The list of [Expression]s representing variable accesses that occur when
  /// the corresponding variable has been definitely unassigned.
  final List<TreeNode> definitelyUnassignedNodes = [];

  /// The assigned variables information that computed for the member.
  AssignedVariablesForTesting<TreeNode, VariableDeclaration>? assignedVariables;

  /// For each expression that led to an error because it was not promoted, a
  /// string describing the reason it was not promoted.
  final Map<TreeNode, String> nonPromotionReasons = {};

  /// For each auxiliary AST node pointed to by a non-promotion reason, a string
  /// describing the non-promotion reason pointing to it.
  final Map<TreeNode, String> nonPromotionReasonTargets = {};
}

/// CFE-specific implementation of [FlowAnalysisOperations].
class OperationsCfe
    implements
        TypeAnalyzerOperations<VariableDeclaration, DartType, DartType,
            StructuralParameter, TypeDeclarationType, TypeDeclaration> {
  final TypeEnvironment typeEnvironment;

  /// The semantic value of  the omitted nullability for the library.
  ///
  /// Depending on the status of the library, the omitted nullability can be
  /// either [Nullability.nonNullable] (for null-safe libraries) or
  /// [Nullability.legacy] (for legacy libraries).
  final Nullability omittedNullabilityValue;

  /// Information about which fields are promotable in this library.
  ///
  /// If field promotion is disabled for the current library, this field is
  /// still populated, so that [whyPropertyIsNotPromotable] can figure out
  /// whether enabling field promotion would cause a field to be promotable.
  ///
  /// The value is `null` if the current source library builder is for an
  /// augmentation library (augmentation libraries don't support field
  /// promotion).
  final FieldNonPromotabilityInfo? fieldNonPromotabilityInfo;

  final Map<DartType, DartType> typeCacheNonNullable;
  final Map<DartType, DartType> typeCacheNullable;
  final Map<DartType, DartType> typeCacheLegacy;

  OperationsCfe(this.typeEnvironment,
      {required this.omittedNullabilityValue,
      required this.fieldNonPromotabilityInfo,
      required this.typeCacheNonNullable,
      required this.typeCacheNullable,
      required this.typeCacheLegacy});

  @override
  DartType get boolType =>
      typeEnvironment.coreTypes.boolRawType(omittedNullabilityValue);

  @override
  DartType get doubleType => throw new UnimplementedError('TODO(paulberry)');

  @override
  DartType get dynamicType => const DynamicType();

  @override
  DartType get errorType => const InvalidType();

  @override
  DartType get intType => throw new UnimplementedError('TODO(paulberry)');

  @override
  DartType get neverType => const NeverType.nonNullable();

  @override
  DartType get nullType => const NullType();

  @override
  DartType get objectQuestionType =>
      typeEnvironment.coreTypes.objectNullableRawType;

  @override
  DartType get objectType => typeEnvironment.coreTypes.objectNonNullableRawType;

  @override
  DartType get unknownType => const UnknownType();

  @override
  TypeClassification classifyType(DartType? type) {
    if (type == null) {
      // Note: this can happen during top-level inference.
      return TypeClassification.potentiallyNullable;
    } else if (isSubtypeOf(
        type, typeEnvironment.coreTypes.objectNonNullableRawType)) {
      return TypeClassification.nonNullable;
    } else if (isSubtypeOf(type, const NullType())) {
      return TypeClassification.nullOrEquivalent;
    } else {
      return TypeClassification.potentiallyNullable;
    }
  }

  @override
  NullabilitySuffix getNullabilitySuffix(DartType type) {
    if (isTypeWithoutNullabilityMarker(type,
        isNonNullableByDefault:
            omittedNullabilityValue == Nullability.nonNullable)) {
      return NullabilitySuffix.none;
    } else if (isNullableTypeConstructorApplication(type)) {
      return NullabilitySuffix.question;
    } else {
      assert(isLegacyTypeConstructorApplication(type,
          isNonNullableByDefault:
              omittedNullabilityValue == Nullability.nonNullable));
      return NullabilitySuffix.star;
    }
  }

  @override
  DartType factor(DartType from, DartType what) {
    return factorType(typeEnvironment, from, what);
  }

  @override
  DartType greatestClosure(DartType schema) =>
      type_schema_elimination.greatestClosure(
          schema, const DynamicType(), const NeverType.nonNullable());

  @override
  bool isAlwaysExhaustiveType(DartType type) {
    return computeIsAlwaysExhaustiveType(type, typeEnvironment.coreTypes);
  }

  @override
  bool isExtensionType(DartType type) {
    return type is ExtensionType;
  }

  @override
  bool isInterfaceType(DartType type) {
    return type is InterfaceType;
  }

  @override
  bool isNever(DartType type) {
    return typeEnvironment.coreTypes.isBottom(type);
  }

  @override
  bool isNull(DartType type) {
    return type is NullType;
  }

  @override
  bool isObject(DartType type) {
    return type is InterfaceType &&
        type.classNode == typeEnvironment.objectClass &&
        type.nullability == Nullability.nonNullable;
  }

  @override
  bool isPropertyPromotable(covariant Member property) {
    FieldNonPromotabilityInfo? fieldNonPromotabilityInfo =
        this.fieldNonPromotabilityInfo;
    if (fieldNonPromotabilityInfo == null) {
      // This only happens when compiling augmentation libraries. Augmentation
      // libraries don't support field promotion.
      return false;
    }
    if (property is Procedure) {
      if (property.stubKind == ProcedureStubKind.RepresentationField) {
        // Representation fields are promotable if they're non-public.
        return property.name.isPrivate;
      }
      if (!property.isAccessor) {
        // We don't promote methods.
        return false;
      }
    }
    String name = property.name.text;
    if (!name.startsWith('_')) return false;
    return fieldNonPromotabilityInfo.fieldNameInfo[name] == null;
  }

  @override
  bool isRecordType(DartType type) => type is RecordType;

  @override
  PropertyNonPromotabilityReason? whyPropertyIsNotPromotable(
      covariant Member property) {
    FieldNonPromotabilityInfo? fieldNonPromotabilityInfo =
        this.fieldNonPromotabilityInfo;
    if (fieldNonPromotabilityInfo == null) {
      // This only happens when compiling augmentation libraries. Augmentation
      // libraries don't support field promotion.
      return null;
    }
    return fieldNonPromotabilityInfo.individualPropertyReasons[property];
  }

  @override
  bool isSubtypeOf(DartType leftType, DartType rightType) {
    return typeEnvironment.isSubtypeOf(
        leftType, rightType, SubtypeCheckMode.withNullabilities);
  }

  @override
  DartType promoteToNonNull(DartType type) {
    if (type.nullability == Nullability.nonNullable) {
      return type;
    }
    DartType? cached = typeCacheNonNullable[type];
    if (cached != null) {
      return cached;
    }
    DartType result = type.toNonNull();
    typeCacheNonNullable[type] = result;
    return result;
  }

  DartType getNullableType(DartType type) {
    // Note that the [IntersectionType.withDeclaredNullability] is special so
    // we don't trust it.
    if (type.declaredNullability == Nullability.nullable &&
        type is! IntersectionType) {
      return type;
    }
    DartType? cached = typeCacheNullable[type];
    if (cached != null) {
      return cached;
    }
    DartType result = type.withDeclaredNullability(Nullability.nullable);
    typeCacheNullable[type] = result;
    return result;
  }

  DartType getLegacyType(DartType type) {
    // Note that the [IntersectionType.withDeclaredNullability] is special so
    // we don't trust it.
    if (type.declaredNullability == Nullability.legacy &&
        type is! IntersectionType) {
      return type;
    }
    DartType? cached = typeCacheLegacy[type];
    if (cached != null) {
      return cached;
    }
    DartType result = type.withDeclaredNullability(Nullability.legacy);
    typeCacheLegacy[type] = result;
    return result;
  }

  @override
  DartType variableType(VariableDeclaration variable) {
    if (variable is VariableDeclarationImpl) {
      // When late variables get lowered, their type is changed, but the
      // original type is stored in `VariableDeclarationImpl.lateType`, so we
      // use that if it exists.
      return variable.lateType ?? variable.type;
    }
    return variable.type;
  }

  @override
  bool isTypeParameterType(DartType type) {
    return type is TypeParameterType || type is IntersectionType;
  }

  @override
  DartType tryPromoteToType(DartType to, DartType from) {
    if (isSubtypeOf(to, from)) {
      return to;
    }
    if (from is TypeParameterType) {
      if (isSubtypeOf(to, from.bound)) {
        if (to.nullability != Nullability.nullable) {
          // We treat promotions of the form `x is T`, where `T` is not
          // nullable, as a two-step promotions equivalent to
          // `x != null && x is T`.
          return new IntersectionType(
              from.withDeclaredNullability(
                  TypeParameterType.computeNullabilityFromBound(
                      from.parameter)),
              to);
        } else {
          return new IntersectionType(from, to);
        }
      }
    }
    if (from is IntersectionType) {
      if (isSubtypeOf(to, from.right)) {
        return new IntersectionType(from.left, to);
      }
    }
    return from;
  }

  @override
  DartType glb(DartType type1, DartType type2) {
    return typeEnvironment.getStandardLowerBound(type1, type2,
        isNonNullableByDefault:
            omittedNullabilityValue == Nullability.nonNullable);
  }

  @override
  bool isAssignableTo(DartType fromType, DartType toType) {
    if (omittedNullabilityValue == Nullability.nonNullable) {
      if (fromType is DynamicType) return true;
      return typeEnvironment
          .performNullabilityAwareSubtypeCheck(fromType, toType)
          .isSubtypeWhenUsingNullabilities();
    } else {
      return typeEnvironment
          .performNullabilityAwareSubtypeCheck(fromType, toType)
          .orSubtypeCheckFor(toType, fromType, typeEnvironment)
          .isSubtypeWhenIgnoringNullabilities();
    }
  }

  @override
  bool isFunctionType(DartType type) => type is FunctionType;

  @override
  DartType? matchFutureOr(DartType type) {
    if (type is! FutureOrType) {
      return null;
    } else {
      return type.typeArgument;
    }
  }

  @override
  bool isTypeSchemaSatisfied(
          {required DartType typeSchema, required DartType type}) =>
      isSubtypeOf(type, typeSchema);

  @override
  bool isVariableFinal(VariableDeclaration node) {
    return node.isFinal;
  }

  @override
  DartType iterableTypeSchema(DartType elementTypeSchema) {
    return new InterfaceType(typeEnvironment.coreTypes.iterableClass,
        Nullability.nonNullable, <DartType>[elementTypeSchema]);
  }

  @override
  DartType listType(DartType elementType) {
    return new InterfaceType(typeEnvironment.coreTypes.listClass,
        Nullability.nonNullable, <DartType>[elementType]);
  }

  @override
  DartType listTypeSchema(DartType elementTypeSchema) {
    return new InterfaceType(typeEnvironment.coreTypes.listClass,
        Nullability.nonNullable, <DartType>[elementTypeSchema]);
  }

  @override
  DartType lub(DartType type1, DartType type2) {
    return typeEnvironment.getStandardUpperBound(type1, type2,
        isNonNullableByDefault:
            omittedNullabilityValue == Nullability.nonNullable);
  }

  @override
  DartType makeNullable(DartType type) {
    return type.withDeclaredNullability(Nullability.nullable);
  }

  @override
  DartType makeTypeSchemaNullable(DartType typeSchema) =>
      typeSchema.withDeclaredNullability(Nullability.nullable);

  @override
  DartType mapType({required DartType keyType, required DartType valueType}) {
    return new InterfaceType(typeEnvironment.coreTypes.mapClass,
        Nullability.nonNullable, <DartType>[keyType, valueType]);
  }

  @override
  DartType mapTypeSchema(
      {required DartType keyTypeSchema, required DartType valueTypeSchema}) {
    return new InterfaceType(typeEnvironment.coreTypes.mapClass,
        Nullability.nonNullable, <DartType>[keyTypeSchema, valueTypeSchema]);
  }

  @override
  DartType? matchIterableTypeSchema(DartType typeSchema) =>
      matchIterableType(typeSchema);

  @override
  DartType? matchListType(DartType type) {
    if (type is TypeDeclarationType) {
      List<DartType>? typeArguments =
          typeEnvironment.getTypeArgumentsAsInstanceOf(
              type, typeEnvironment.coreTypes.listClass);
      if (typeArguments == null || typeArguments.length != 1) {
        return null;
      } else {
        return typeArguments.single;
      }
    } else {
      return null;
    }
  }

  @override
  ({DartType keyType, DartType valueType})? matchMapType(DartType type) {
    if (type is! TypeDeclarationType) {
      return null;
    } else {
      TypeDeclarationType? mapType = typeEnvironment.getTypeAsInstanceOf(
          type, typeEnvironment.coreTypes.mapClass, typeEnvironment.coreTypes,
          isNonNullableByDefault:
              omittedNullabilityValue == Nullability.nonNullable);
      if (mapType == null) {
        return null;
      } else {
        return (
          keyType: mapType.typeArguments[0],
          valueType: mapType.typeArguments[1]
        );
      }
    }
  }

  @override
  DartType? matchStreamType(DartType type) {
    if (type is TypeDeclarationType) {
      List<DartType>? typeArguments =
          typeEnvironment.getTypeArgumentsAsInstanceOf(
              type, typeEnvironment.coreTypes.streamClass);
      if (typeArguments == null || typeArguments.length != 1) {
        return null;
      } else {
        return typeArguments.single;
      }
    } else {
      return null;
    }
  }

  @override
  DartType normalize(DartType type) {
    return norm(typeEnvironment.coreTypes, type);
  }

  @override
  DartType? matchIterableType(DartType type) {
    if (type is! TypeDeclarationType) {
      return null;
    } else {
      TypeDeclarationType? interfaceType = typeEnvironment.getTypeAsInstanceOf(
          type,
          typeEnvironment.coreTypes.iterableClass,
          typeEnvironment.coreTypes,
          isNonNullableByDefault:
              omittedNullabilityValue == Nullability.nonNullable);
      if (interfaceType == null) {
        return null;
      } else {
        return interfaceType.typeArguments.single;
      }
    }
  }

  @override
  DartType recordType(
      {required List<DartType> positional,
      required List<(String, DartType)> named}) {
    List<NamedType> namedFields = [];
    for (var (name, type) in named) {
      namedFields.add(new NamedType(name, type));
    }
    namedFields.sort((f1, f2) => f1.name.compareTo(f2.name));
    return new RecordType(positional, namedFields, Nullability.nonNullable);
  }

  @override
  DartType recordTypeSchema(
          {required List<DartType> positional,
          required List<(String, DartType)> named}) =>
      recordType(positional: positional, named: named);

  @override
  DartType streamTypeSchema(DartType elementTypeSchema) {
    return new InterfaceType(typeEnvironment.coreTypes.streamClass,
        Nullability.nonNullable, <DartType>[elementTypeSchema]);
  }

  @override
  DartType extensionTypeErasure(DartType type) {
    return type.extensionTypeErasure;
  }

  @override
  DartType typeSchemaGlb(DartType typeSchema1, DartType typeSchema2) =>
      glb(typeSchema1, typeSchema2);

  @override
  bool typeSchemaIsDynamic(DartType typeSchema) => typeSchema is DynamicType;

  @override
  DartType typeToSchema(DartType type) => type;

  @override
  DartType typeSchemaLub(DartType typeSchema1, DartType typeSchema2) {
    return lub(typeSchema1, typeSchema2);
  }

  @override
  bool typeSchemaIsSubtypeOfTypeSchema(
      DartType leftSchema, DartType rightSchema) {
    return isSubtypeOf(leftSchema, rightSchema);
  }

  @override
  bool typeIsSubtypeOfTypeSchema(DartType leftType, DartType rightSchema) {
    return isSubtypeOf(leftType, rightSchema);
  }

  @override
  bool typeSchemaIsSubtypeOfType(DartType leftSchema, DartType rightType) {
    return isSubtypeOf(leftSchema, rightType);
  }

  @override
  DartType withNullabilitySuffix(DartType type, NullabilitySuffix modifier) {
    switch (modifier) {
      case NullabilitySuffix.none:
        return computeTypeWithoutNullabilityMarker(type,
            isNonNullableByDefault:
                omittedNullabilityValue == Nullability.nonNullable);
      case NullabilitySuffix.question:
        return type.withDeclaredNullability(Nullability.nullable);
      case NullabilitySuffix.star:
        return type.withDeclaredNullability(Nullability.legacy);
    }
  }

  @override
  TypeDeclarationKind? getTypeDeclarationKind(DartType type) {
    if (type is TypeDeclarationType) {
      switch (type) {
        case InterfaceType():
          return TypeDeclarationKind.interfaceDeclaration;
        case ExtensionType():
          return TypeDeclarationKind.extensionTypeDeclaration;
      }
    } else {
      return null;
    }
  }

  @override
  TypeDeclarationKind? getTypeSchemaDeclarationKind(DartType typeSchema) {
    return getTypeDeclarationKind(typeSchema);
  }

  @override
  bool isNonNullable(DartType typeSchema) {
    return typeSchema.nullability == Nullability.nonNullable;
  }

  @override
  StructuralParameter? matchInferableParameter(DartType type) {
    if (type is StructuralParameterType) {
      return type.parameter;
    } else {
      return null;
    }
  }

  @override
  InterfaceType futureType(DartType argumentType) {
    return new InterfaceType(typeEnvironment.coreTypes.futureClass,
        omittedNullabilityValue, <DartType>[argumentType]);
  }

  @override
  TypeDeclarationMatchResult? matchTypeDeclarationType(DartType type) {
    if (type is TypeDeclarationType) {
      switch (type) {
        case InterfaceType(:List<DartType> typeArguments, :Class classNode):
          return new TypeDeclarationMatchResult(
              typeDeclarationKind: TypeDeclarationKind.interfaceDeclaration,
              typeDeclaration: classNode,
              typeDeclarationType: type,
              typeArguments: typeArguments);
        case ExtensionType(
            :List<DartType> typeArguments,
            :ExtensionTypeDeclaration extensionTypeDeclaration
          ):
          return new TypeDeclarationMatchResult(
              typeDeclarationKind: TypeDeclarationKind.extensionTypeDeclaration,
              typeDeclaration: extensionTypeDeclaration,
              typeDeclarationType: type,
              typeArguments: typeArguments);
      }
    } else {
      return null;
    }
  }

  @override
  Variance getTypeParameterVariance(
      TypeDeclaration typeDeclaration, int parameterIndex) {
    return typeDeclaration.typeParameters[parameterIndex].variance;
  }

  @override
  bool isDartCoreFunction(DartType type) {
    return omittedNullabilityValue == Nullability.nonNullable
        ? (type == typeEnvironment.coreTypes.functionNonNullableRawType)
        : (type == typeEnvironment.coreTypes.functionLegacyRawType);
  }
}

/// Type inference results used for testing.
class TypeInferenceResultForTesting {
  final Map<TreeNode, List<DartType>> inferredTypeArguments = {};
  final Map<TreeNode, List<GeneratedTypeConstraint>> generatedTypeConstraints =
      {};
  final Map<TreeNode, DartType> inferredVariableTypes = {};
}
