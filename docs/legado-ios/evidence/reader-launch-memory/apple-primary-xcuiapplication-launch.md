<!--
{
  "availability" : [
    "Xcode: 16.3.0 -",
    "iOS: -",
    "iPadOS: -",
    "macCatalyst: -",
    "macOS: -",
    "tvOS: -",
    "visionOS: -",
    "watchOS: -"
  ],
  "documentType" : "symbol",
  "framework" : "XCUIAutomation",
  "identifier" : "/documentation/XCUIAutomation/XCUIApplication/launch()",
  "metadataVersion" : "0.1.0",
  "role" : "Instance Method",
  "symbol" : {
    "kind" : "Instance Method",
    "modules" : [
      "XCUIAutomation"
    ],
    "preciseIdentifier" : "c:objc(cs)XCUIApplication(im)launch"
  },
  "title" : "launch()"
}
-->

# launch()

Launches the application.

```
func launch()
```

## Discussion

This call is synchronous. When it returns, the application launches and is ready to handle user events. The system reports any failure in the launch sequence as a test failure and halts the test at this point.

If the application is already running, this call terminates the existing instance, to ensure a clean launch state for the newly launched instance.

---

Copyright &copy; 2026 Apple Inc. All rights reserved. | [Terms of Use](https://www.apple.com/legal/internet-services/terms/site.html) | [Privacy Policy](https://www.apple.com/privacy/privacy-policy)