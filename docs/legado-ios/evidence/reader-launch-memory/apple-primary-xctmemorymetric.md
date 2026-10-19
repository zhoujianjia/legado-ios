<!--
{
  "availability" : [
    "iOS: 13.0.0 -",
    "iPadOS: 13.0.0 -",
    "macCatalyst: 13.0.0 -",
    "tvOS: 13.0.0 -",
    "visionOS: 1.0.0 -",
    "watchOS: 7.0.0 -"
  ],
  "documentType" : "symbol",
  "framework" : "XCTest",
  "identifier" : "/documentation/XCTest/XCTMemoryMetric",
  "metadataVersion" : "0.1.0",
  "role" : "Class",
  "symbol" : {
    "kind" : "Class",
    "modules" : [
      "XCTest"
    ],
    "preciseIdentifier" : "c:objc(cs)XCTMemoryMetric"
  },
  "title" : "XCTMemoryMetric"
}
-->

# XCTMemoryMetric

A metric to record the physical memory that a performance test uses.

```
class XCTMemoryMetric
```

## Overview

`XCTMemoryMetric` compares the memory use before and after running the block argument to [`measure(metrics:block:)`](/documentation/XCTest/XCTestCase/measure(metrics:block:)), and reports the difference.

## Topics

### Initializers

[`init()`](/documentation/XCTest/XCTMemoryMetric/init())

Initializes a metric that measures memory use in the current process.

[`init(application: XCUIApplication)`](/documentation/XCTest/XCTMemoryMetric/init(application:))

Initializes a metric that measures memory use in the target app.

## Relationships

### Conforms To

[`Equatable`](/documentation/Swift/Equatable)

[`CVarArg`](/documentation/Swift/CVarArg)

[`NSObjectProtocol`](/documentation/ObjectiveC/NSObjectProtocol)

[`CustomStringConvertible`](/documentation/Swift/CustomStringConvertible)

[`CustomDebugStringConvertible`](/documentation/Swift/CustomDebugStringConvertible)

[`Hashable`](/documentation/Swift/Hashable)

[`NSCopying`](/documentation/Foundation/NSCopying)

[`XCTMetric`](/documentation/XCTest/XCTMetric)

### Inherits From

[`NSObject-swift.class`](/documentation/ObjectiveC/NSObject-swift.class)

---

Copyright &copy; 2026 Apple Inc. All rights reserved. | [Terms of Use](https://www.apple.com/legal/internet-services/terms/site.html) | [Privacy Policy](https://www.apple.com/privacy/privacy-policy)