// Copyright (c) 2023, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:analysis_server/src/services/correction/dart/abstract_producer.dart';
import 'package:analysis_server/src/services/correction/fix.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer_plugin/utilities/change_builder/change_builder_core.dart';
import 'package:analyzer_plugin/utilities/fixes/fixes.dart';
import 'package:analyzer_plugin/utilities/range_factory.dart';

class ReplaceWithPartOrUriEmpty extends ResolvedCorrectionProducer {
  String _uriStr = '';

  @override
  FixKind fixKind = DartFixKind.REPLACE_WITH_PART_OF_URI;

  @override
  CorrectionApplicability get applicability =>
      // TODO(applicability): comment on why.
      CorrectionApplicability.singleLocation;

  @override
  List<String> get fixArguments => [_uriStr];

  @override
  Future<void> compute(ChangeBuilder builder) async {
    var partOfDirective = node;
    if (partOfDirective is! PartOfDirective) {
      return;
    }

    var libraryName = partOfDirective.libraryName;
    if (libraryName == null) {
      return;
    }

    var libraryElement = partOfDirective.element;
    if (libraryElement is! LibraryElement) {
      return;
    }

    var libraryPath = libraryElement.source.fullName;
    var uriStr = _relativeUriText(libraryPath);
    _uriStr = _uriStr;

    await builder.addDartFileEdit(file, (builder) {
      builder.addReplacement(
        range.node(libraryName),
        (builder) {
          builder.write("'$uriStr'");
        },
      );
    });
  }

  String _relativeUriText(String libraryPath) {
    var pathContext = resourceProvider.pathContext;
    var partFolder = pathContext.dirname(file);
    var relativePath = pathContext.relative(libraryPath, from: partFolder);
    return pathContext.split(relativePath).join('/');
  }
}
