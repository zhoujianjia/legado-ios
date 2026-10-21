import CoreText
import Testing
import UIKit
import YueduCoreText
@testable import yuedu_app

@Suite("Paged and scroll appearance", .serialized)
struct CoreTextPagedScrollAppearanceTests {
    @Test("a taller destination preserves actual CJK and Latin glyph pixels and hit geometry")
    @MainActor
    func tallerPagePreservesGlyphPixelsAndSelection() async throws {
        let nativeSize = CGSize(width: 402, height: 778)
        let tallerSize = CGSize(width: 402, height: 874)
        for mode in [ReaderWritingMode.horizontal, .verticalRTL] {
            let layout = await glyphLayout(size: nativeSize, writingMode: mode)
            let native = pageImage(layout: layout, size: nativeSize)
            let taller = pageImage(layout: layout, size: tallerSize)
            // At equal width this is a pure 48-point translation, never a 1.123x
            // vertical glyph transform. Compare real CoreText compositor pixels.
            let crop = try #require(taller.cgImage?.cropping(to:
                CGRect(x: 0, y: 48, width: nativeSize.width, height: nativeSize.height)))
            #expect(UIImage(cgImage: crop).pngData() == native.pngData())

            let nativeView = CoreTextPageView(frame: CGRect(origin: .zero, size: nativeSize))
            nativeView.configure(layout: layout, pageIndex: 0)
            let tallerView = CoreTextPageView(frame: CGRect(origin: .zero, size: tallerSize))
            tallerView.configure(layout: layout, pageIndex: 0)
            let range = NSRange(location: 0, length: 1)
            let nativeRect = try #require(nativeView.debugSelectionRects(for: range).first)
            let tallerRect = try #require(tallerView.debugSelectionRects(for: range).first)
            #expect(abs(tallerRect.minX - nativeRect.minX) < 0.01)
            #expect(abs(tallerRect.minY - nativeRect.minY - 48) < 0.01)
            #expect(abs(tallerRect.width - nativeRect.width) < 0.01)
            #expect(abs(tallerRect.height - nativeRect.height) < 0.01)
            // CoreText resolves the midpoint to the nearest insertion caret;
            // either edge of the first glyph is valid. Presentation must keep
            // that exact native hit, not force the leading edge at a tie.
            let nativeHit = try #require(nativeView.debugStringIndex(at:
                CGPoint(x: nativeRect.midX, y: nativeRect.midY)))
            #expect((range.location...NSMaxRange(range)).contains(nativeHit))
            #expect(tallerView.debugStringIndex(at:
                CGPoint(x: tallerRect.midX, y: tallerRect.midY)) == nativeHit)
            #expect(tallerView.debugStringIndex(at: CGPoint(x: 201, y: 8)) == nil)
            let attachment = CGRect(x: 44, y: 64, width: 20, height: 20)
            #expect(tallerView.viewRect(forRenderRect: attachment) ==
                attachment.offsetBy(dx: 0, dy: 48))
        }
    }

    @Test("page presentation uses one aspect-preserving transform in both directions")
    func pageGeometryPreservesAspectAndRoundTrips() {
        let nativeSize = CGSize(width: 402, height: 778)
        for bounds in [CGRect(x: 0, y: 0, width: 402, height: 874),
                       CGRect(x: 9, y: 17, width: 874, height: 402),
                       CGRect(x: 4, y: 6, width: 201, height: 389)] {
            let geometry = CoreTextPageView.PageGeometry(renderSize: nativeSize, bounds: bounds)
            let square = geometry.viewRect(CGRect(x: 32, y: 48, width: 20, height: 20))
            #expect(abs(square.width - square.height) < 0.001)
            let original = CGPoint(x: 57, y: 93)
            let presented = original.applying(geometry.renderToView)
            let restored = geometry.renderPoint(presented)
            #expect(abs(restored.x - original.x) < 0.001)
            #expect(abs(restored.y - original.y) < 0.001)
            let page = geometry.viewRect(CGRect(origin: .zero, size: nativeSize))
            #expect(abs(page.midX - bounds.midX) < 0.001)
            #expect(abs(page.midY - bounds.midY) < 0.001)
        }
    }

    @Test("a live page replaces its bitmap when its bounds change")
    @MainActor
    func resizedLivePageRedrawsWithoutStretching() async throws {
        let nativeSize = CGSize(width: 402, height: 778)
        let tallerSize = CGSize(width: 402, height: 874)
        let layout = await glyphLayout(size: nativeSize, writingMode: .horizontal)
        let view = CoreTextPageView(frame: CGRect(origin: .zero, size: nativeSize))
        view.contentScaleFactor = 1
        view.configure(layout: layout, pageIndex: 0)
        view.layer.displayIfNeeded()
        let firstContents = try #require(view.layer.contents)
        let first = firstContents as! CGImage

        view.bounds.size = tallerSize
        view.layoutIfNeeded()
        view.layer.displayIfNeeded()
        let resizedContents = try #require(view.layer.contents)
        let resized = resizedContents as! CGImage
        #expect(resized !== first)
        #expect(resized.width == 402 && resized.height == 874)
        let crop = try #require(resized.cropping(to:
            CGRect(x: 0, y: 48, width: nativeSize.width, height: nativeSize.height)))
        #expect(UIImage(cgImage: crop).pngData() == UIImage(cgImage: first).pngData())
    }

    @MainActor
    private func glyphLayout(size: CGSize, writingMode: ReaderWritingMode) async -> CoreTextPaginator.ChapterLayout {
        let text = NSAttributedString(string: "天地玄黃 ABC abc 1234", attributes: [
            .font: UIFont.systemFont(ofSize: 24), .foregroundColor: UIColor.black
        ])
        return await CoreTextPaginator().paginate(
            spineIndex: 0, attrStr: text, renderSize: size, fontSize: 24,
            contentInsets: UIEdgeInsets(top: 32, left: 32, bottom: 32, right: 32),
            writingMode: writingMode
        )
    }

    @MainActor
    private func pageImage(layout: CoreTextPaginator.ChapterLayout, size: CGSize) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            CoreTextPageView.renderPage(layout: layout, pageIndex: 0,
                in: context.cgContext, bounds: CGRect(origin: .zero, size: size))
        }
    }

    // The same frame isolates paint differences from legitimate page/chunk breaks.
    // These authored fixed-height fills reproduce the gallery heading and resource bar.
    @Test(arguments: [false, true]) @MainActor
    func authoredCompositionMatchesScroll(nestedBackdrop: Bool) async throws {
        let size = CGSize(width: 360, height: 800)
        let config = HTMLAttributedStringBuilder.Config(
            fontSize: 17, lineHeightMultiple: 1.5, lineSpacing: 0,
            paragraphSpacing: 8, firstLineIndent: 0, textColor: .black,
            backgroundColor: .white, fontFamilyName: nil, renderWidth: size.width
        )
        let outerOpen = nestedBackdrop ? "<div style=\"background:#f8f9fa;border:2px solid #dde0e3\">" : ""
        let outerClose = nestedBackdrop ? "</div>" : ""
        let attributed = await EPUBTestFixtures.renderIR(html: """
        <html><body>
        <p>惜春作画＋海棠诗社</p>
        <div style="width:70%;height:32px;margin:0 auto;background:#6050a0;color:white;text-align:center">红 楼 梦 画 册 叁</div>
        <p>A Dream of Red Mansions</p>
        <p>由王子和画师精心绘制</p>
        \(outerOpen)<div style="border:1px solid black;padding:12px">
          <p>本月已用资源额度</p>
          <div style="height:16px;background:#20c997;color:white;text-align:center">294MB/300MB</div>
          <p>资源使用率：98% | 剩余：6MB</p>
        </div>\(outerClose)
        <p>正文继续。</p>
        </body></html>
        """, config: config)
        let layout = await CoreTextPaginator().paginate(
            spineIndex: 0, attrStr: attributed, imagePage: nil,
            anchorOffsets: [:], renderSize: size, fontSize: 17, contentInsets: .zero
        )
        try #require(layout.pageRanges.count == 1)
        let frame = CoreTextPageView.frameForRendering(layout: layout, pageIndex: 0)
        let scrollDecorations = CoreTextChunkSlicer.extractBlockRenderables(
            frame: frame, chunkSize: size, attributedString: layout.attributedString,
            charRange: layout.pageRanges[0]
        )
        let chunk = CoreTextChunk(
            chapterIndex: 0, charRange: layout.pageRanges[0], size: size,
            framesetter: layout.framesetter, attributedString: layout.attributedString,
            frame: frame, blockRenderables: scrollDecorations
        )
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let paged = renderer.image { context in
            CoreTextPageView.renderPage(layout: layout, pageIndex: 0,
                in: context.cgContext, bounds: CGRect(origin: .zero, size: size))
        }
        let scrollView = CoreTextChunkDrawView(frame: CGRect(origin: .zero, size: size))
        scrollView.chunk = chunk
        let scroll = renderer.image { context in
            layout.backgroundColor.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            scrollView.draw(scrollView.bounds)
        }
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("paged-scroll-appearance-\(nestedBackdrop)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try paged.pngData()?.write(to: directory.appendingPathComponent("paged.png"))
        try scroll.pngData()?.write(to: directory.appendingPathComponent("scroll.png"))
        // Compare real compositor output, including text, authored fills and borders.
        let a = try #require(paged.cgImage?.dataProvider?.data) as Data
        let b = try #require(scroll.cgImage?.dataProvider?.data) as Data
        #expect(a == b, "The same chapter frame must retain the scroll composition in paged mode. Captures: \(directory.path)")
    }
}
