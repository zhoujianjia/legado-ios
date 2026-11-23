import Foundation
import LegadoRuntime

/// An explicitly audited public rule template, not a JavaScript purity heuristic.
/// Unknown or edited rules retain the existing exclusive source operation lease.
/// Eligible single chapters share at most two leases for one exact source revision,
/// with staticHttpUrlsOnly enforced by the JVM for every page. This never changes
/// concurrentRate, the existing App state/cache owners, or chapter generations.
enum OriginalContentReadPolicy {
    static let content = #".con@html##<p>第\d+章[^<]*</p>"#
    static let nextPage = #"<js>var m=result.match(/href="([^"]*-\d+\.html)">下一页/);m?m[1]:'';</js>"#

    static func permits(source: BookSource, book: LegadoOriginalBook,
                        chapters: [OriginalRuntimeBatchChapter], singleChapter: Bool) -> Bool {
        let rule = source.ruleContent
        guard singleChapter, chapters.count == 1, !source.isJsSource, source.bookSourceType == 0,
              source.jsLib.isEmpty, source.loginCheckJs.isEmpty, source.eventListener != true,
              rule.content.utf8.elementsEqual(content.utf8),
              // The shared session also enforces staticHttpUrlsOnly before interpreting
              // any initial or subsequent page URL. Purity of this expression alone is insufficient.
              rule.nextContentUrl.isEmpty || rule.nextContentUrl.utf8.elementsEqual(nextPage.utf8),
              [rule.title, rule.webJs, rule.sourceRegex, rule.replaceRegex, rule.imageStyle,
               rule.imageDecode, rule.payAction, rule.subContent ?? "", rule.callBackJs ?? "",
               rule.contentBatch ?? ""].allSatisfy(\.isEmpty), rule.maxBatchSize == nil,
              staticHeaders(source.header), staticURL(book.bookURL, base: book.bookURL),
              staticURL(book.tocURL, base: book.bookURL),
              chapters.allSatisfy({ staticURL($0.dto.url, base: $0.dto.baseURL) }) else { return false }
        return true
    }

    private static func staticHeaders(_ raw: String) -> Bool {
        if raw.isEmpty { return true }
        // A malformed header only declines this optional concurrent path. The normal
        // exclusive source execution still owns its original parsing/error behavior.
        guard let object = try? JSONSerialization.jsonObject(with: Data(raw.utf8)),
              let values = object as? [String: String],
              values.keys.allSatisfy({ ["user-agent", "referer"].contains($0.lowercased()) }) else { return false }
        // Header values remain literals; URL/JS interpolation is outside this audited template.
        return values.values.allSatisfy { value in
            value.unicodeScalars.allSatisfy { (32...126).contains(Int($0.value)) }
                && !value.contains("{") && !value.contains("}") && !value.contains("<")
                && !value.contains(">") && !value.contains("@js:")
        }
    }

    private static func staticURL(_ raw: String, base: String) -> Bool {
        // Explicitly exclude UrlOption JSON and authored URL expressions before admission.
        let alphabet = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~:/?#[]!$&'()*+;=%")
        guard !raw.isEmpty, raw.unicodeScalars.allSatisfy(alphabet.contains),
              let url = URL(string: raw, relativeTo: URL(string: base))?.absoluteURL,
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else { return false }
        return true
    }
}
