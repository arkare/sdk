// Copyright (c) 2020, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:analysis_server/src/services/correction/dart/abstract_producer.dart';
import 'package:analysis_server/src/services/correction/fix.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:analyzer/src/dart/ast/extensions.dart';
import 'package:analyzer_plugin/utilities/change_builder/change_builder_core.dart';
import 'package:analyzer_plugin/utilities/fixes/fixes.dart';

class ConvertToNamedArguments extends ResolvedCorrectionProducer {
  @override
  CorrectionApplicability get applicability =>
      // TODO(applicability): comment on why.
      CorrectionApplicability.singleLocation;

  @override
  FixKind get fixKind => DartFixKind.CONVERT_TO_NAMED_ARGUMENTS;

  @override
  Future<void> compute(ChangeBuilder builder) async {
    // node is the unmatched argument.
    var argumentList = node.parent;
    if (argumentList is ArgumentList) {
      // Prepare parameters.
      List<ParameterElement>? parameters;
      var parent = argumentList.parent;
      if (parent is FunctionExpressionInvocation) {
        var invokeType = parent.staticInvokeType;
        if (invokeType is FunctionType) {
          parameters = invokeType.parameters;
        }
      } else if (parent is InstanceCreationExpression) {
        parameters = parent.constructorName.staticElement?.parameters;
      } else if (parent is MethodInvocation) {
        var invokeType = parent.staticInvokeType;
        if (invokeType is FunctionType) {
          parameters = invokeType.parameters;
        }
      }
      if (parameters == null) {
        return;
      }

      // Prepare named parameters.
      var numberOfPositionalParameters = 0;
      var namedParameters = <ParameterElement>[];
      for (var parameter in parameters) {
        if (parameter.isNamed) {
          namedParameters.add(parameter);
        } else {
          numberOfPositionalParameters++;
        }
      }
      if (argumentList.arguments.length <= numberOfPositionalParameters) {
        return;
      }

      // Find named parameters for extra arguments.
      var argumentToParameter = <Expression, ParameterElement>{};
      var extraArguments =
          argumentList.arguments.skip(numberOfPositionalParameters);
      for (var argument in extraArguments) {
        if (argument is! NamedExpression) {
          ParameterElement? uniqueNamedParameter;
          for (var namedParameter in namedParameters) {
            if (typeSystem.isSubtypeOf(
                    argument.typeOrThrow, namedParameter.type) &&
                !_namedArgumentExists(extraArguments, namedParameter.name)) {
              if (uniqueNamedParameter == null) {
                uniqueNamedParameter = namedParameter;
              } else {
                uniqueNamedParameter = null;
                break;
              }
            }
          }
          if (uniqueNamedParameter != null) {
            argumentToParameter[argument] = uniqueNamedParameter;
            namedParameters.remove(uniqueNamedParameter);
          }
        }
      }
      if (argumentToParameter.isEmpty) {
        return;
      }

      await builder.addDartFileEdit(file, (builder) {
        for (var entry in argumentToParameter.entries) {
          var argument = entry.key;
          var parameter = entry.value;
          builder.addSimpleInsertion(argument.offset, '${parameter.name}: ');
        }
      });
    }
  }

  /// Check if the argument with the [name] exists in the list of [arguments]
  bool _namedArgumentExists(Iterable<Expression> arguments, String name) {
    for (var argument in arguments) {
      if (argument is NamedExpression) {
        if (argument.name.label.name == name) {
          return true;
        }
      }
    }
    return false;
  }
}
