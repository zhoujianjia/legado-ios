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
  "identifier" : "/documentation/XCUIAutomation/XCUIApplication/terminate()",
  "metadataVersion" : "0.1.0",
  "role" : "Instance Method",
  "symbol" : {
    "kind" : "Instance Method",
    "modules" : [
      "XCUIAutomation"
    ],
    "preciseIdentifier" : "c:objc(cs)XCUIApplication(im)terminate"
  },
  "title" : "terminate()"
}
-->

# terminate()

Terminates any running instance of the application.

```
func terminate()
```

## Discussion

If the application has an existing debug session via Xcode, the debugger sends a command to terminate the application. Otherwise, an appropriate platform-specific mechanism terminates the process.

---

Copyright &copy; 2026 Apple Inc. All rights reserved. | [Terms of Use](https://www.apple.com/legal/internet-services/terms/site.html) | [Privacy Policy](https://www.apple.com/privacy/privacy-policy)