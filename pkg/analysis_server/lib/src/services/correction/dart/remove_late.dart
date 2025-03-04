// Copyright (c) 2023, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:analysis_server/src/services/correction/dart/abstract_producer.dart';
import 'package:analysis_server/src/services/correction/fix.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/token.dart';
import 'package:analyzer_plugin/utilities/change_builder/change_builder_core.dart';
import 'package:analyzer_plugin/utilities/fixes/fixes.dart';
import 'package:analyzer_plugin/utilities/range_factory.dart';

class RemoveLate extends ResolvedCorrectionProducer {
  @override
  CorrectionApplicability get applicability =>
      CorrectionApplicability.automatically;

  @override
  FixKind get fixKind => DartFixKind.REMOVE_LATE;

  @override
  FixKind get multiFixKind => DartFixKind.REMOVE_LATE_MULTI;

  _LateKeywordLocation? get _lateKeywordLocation {
    var node = this.node;
    if (node is AwaitExpression) {
      var parent = node.parent;
      if (parent is VariableDeclaration) {
        var lateKeyword = parent.parent?.beginToken;
        if (lateKeyword != null && lateKeyword.keyword == Keyword.LATE) {
          return _LateKeywordLocation(
            lateKeyword: lateKeyword,
            nextToken: lateKeyword.next!,
          );
        }
      }
    } else if (node is Block) {
      // The `late` token does not belong any node, so when we look for a
      // node that covers it, we find the enclosing `Block`. So, we iterate
      // over statements to find the actual declaration statement.
      for (var statement in node.statements) {
        if (statement is PatternVariableDeclarationStatement) {
          var beginToken = statement.beginToken;
          var lateKeyword = beginToken.previous;
          if (lateKeyword != null &&
              lateKeyword.keyword == Keyword.LATE &&
              lateKeyword.offset == selectionOffset &&
              lateKeyword.end == selectionEnd) {
            return _LateKeywordLocation(
              lateKeyword: lateKeyword,
              nextToken: beginToken,
            );
          }
        }
      }
    }

    return null;
  }

  @override
  Future<void> compute(ChangeBuilder builder) async {
    var location = _lateKeywordLocation;
    if (location != null) {
      await builder.addDartFileEdit(file, (builder) {
        builder.addDeletion(
          range.startStart(
            location.lateKeyword,
            location.nextToken,
          ),
        );
      });
    }
  }
}

class _LateKeywordLocation {
  final Token lateKeyword;
  final Token nextToken;

  _LateKeywordLocation({
    required this.lateKeyword,
    required this.nextToken,
  });
}
