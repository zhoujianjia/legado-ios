<!--
{
  "availability" : [
    "iOS: 2.0.0 -",
    "iPadOS: 2.0.0 -",
    "macCatalyst: 13.1.0 -",
    "macOS: 10.5.0 -",
    "tvOS: 9.0.0 -",
    "visionOS: 1.0.0 -",
    "watchOS: 2.0.0 -"
  ],
  "documentType" : "symbol",
  "framework" : "Foundation",
  "identifier" : "/documentation/Foundation/NSString/rangeOfComposedCharacterSequences(for:)",
  "metadataVersion" : "0.1.0",
  "role" : "Instance Method",
  "symbol" : {
    "kind" : "Instance Method",
    "modules" : [
      "Foundation"
    ],
    "preciseIdentifier" : "c:objc(cs)NSString(im)rangeOfComposedCharacterSequencesForRange:"
  },
  "title" : "rangeOfComposedCharacterSequences(for:)"
}
-->

# rangeOfComposedCharacterSequences(for:)

Returns the range in the string of the composed character sequences for a given range.

```
func rangeOfComposedCharacterSequences(for range: NSRange) -> NSRange
```

## Parameters

`range`

A range in the receiver. The range must not exceed the bounds of the receiver.

## Return Value

The range in the receiver that includes the composed character sequences in `range`.

## Discussion

This method provides a convenient way to grow a range to include all composed character sequences it overlaps.

---

Copyright &copy; 2026 Apple Inc. All rights reserved. | [Terms of Use](https://www.apple.com/legal/internet-services/terms/site.html) | [Privacy Policy](https://www.apple.com/privacy/privacy-policy)