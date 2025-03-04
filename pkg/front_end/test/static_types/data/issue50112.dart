// Copyright (c) 2022, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

/*library: nnbd=true*/

method<T>(T t) {
  if (/*T%*/ t is Iterable) {
    /*current: dynamic*/ for (var e in /*T% & Iterable<dynamic>!*/ t) {
      /*dynamic*/ e;
    }
  }
}
