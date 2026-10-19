import java.io.FileInputStream;
import java.io.OutputStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardOpenOption;
import java.util.ArrayList;
import java.util.Base64;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

import me.ag2s.umdlib.domain.UmdBook;
import me.ag2s.umdlib.domain.UmdChapters;
import me.ag2s.umdlib.domain.UmdHeader;
import me.ag2s.umdlib.umd.UmdReader;

/**
 * Public, self-authored text fixtures only. Calls the unmodified original public writer/reader.
 * This harness does not parse UMD, replace the inflater, or alter the original RNG.
 */
public final class UmdReferenceHarness {
    private record Chapter(String title, String content) {}
    private record Fixture(String id, Map<String, String> metadata, List<Chapter> chapters) {}

    private static Map<String, String> metadata(String title, String author) {
        Map<String, String> result = new LinkedHashMap<>();
        result.put("title", title);
        result.put("author", author);
        for (String key : List.of("year", "month", "day", "bookType", "bookMan", "shopKeeper")) {
            result.put(key, null);
        }
        return result;
    }

    private static Fixture fixture(String id) {
        return switch (id) {
            case "chinese-two-chapters" -> new Fixture(id, metadata("自有中文样本", "公开测试作者"), List.of(
                new Chapter("第一章 初见", "山川与星光。\n这是第一章的自有文字。"),
                new Chapter("第二章 归途", "清风经过书页。\n故事在这里结束。")));
            case "paragraph-separators" -> new Fixture(id, metadata("段落分隔符", "测试作者"), List.of(
                new Chapter("段落一", "甲\u2029乙\n丙\r\n丁\u2029"),
                new Chapter("段落二", "\u2029开头与结尾\u2029"),
                new Chapter("段落三", "普通换行\n保留；回车\r保留。")));
            case "non-bmp-utf16" -> new Fixture(id, metadata("星空😀", "作者𠀀"), List.of(
                new Chapter("第一章 😀", "汉字𠀀与表情😀，音乐符号𝄞。"),
                new Chapter("第二章 𠀀", "组合 e\u0301；火箭🚀\u2029下一段。")));
            case "multi-chapter-optional-metadata" -> {
                Map<String, String> meta = metadata("可选元数据", "");
                meta.put("year", "2026");
                meta.put("month", "10");
                meta.put("day", "19");
                meta.put("bookType", "自有文本");
                meta.put("bookMan", null);
                meta.put("shopKeeper", "公开样本");
                List<Chapter> chapters = new ArrayList<>();
                for (int i = 1; i <= 5; i++) chapters.add(new Chapter("章节 " + i, "第" + i + "章自有内容。"));
                yield new Fixture(id, meta, chapters);
            }
            case "cross-compression-blocks" -> new Fixture(id, metadata("跨压缩块", "测试作者"), List.of(
                // UTF-16 surrogate pair begins at byte 32766, crossing the original 32768-byte chunk.
                new Chapter("块边界一", "汉".repeat(16383) + "😀尾"),
                new Chapter("块边界二", "星\u2029".repeat(10000) + "𠀀"),
                new Chapter("块边界三", "末章\n完成。")));
            default -> throw new IllegalArgumentException("Unknown owned fixture: " + id);
        };
    }

    private static void configure(UmdHeader header, Map<String, String> meta) {
        header.setTitle(meta.get("title"));
        header.setAuthor(meta.get("author"));
        header.setYear(meta.get("year"));
        header.setMonth(meta.get("month"));
        header.setDay(meta.get("day"));
        header.setBookType(meta.get("bookType"));
        header.setBookMan(meta.get("bookMan"));
        header.setShopKeeper(meta.get("shopKeeper"));
    }

    private static Map<String, Object> typed(Object value) {
        Map<String, Object> result = new LinkedHashMap<>();
        result.put("type", value == null ? null : value.getClass().getName());
        result.put("value", value);
        return result;
    }

    private static Map<String, Object> headerValues(UmdHeader header) {
        Map<String, Object> result = new LinkedHashMap<>();
        result.put("title", typed(header.getTitle()));
        result.put("author", typed(header.getAuthor()));
        result.put("year", typed(header.getYear()));
        result.put("month", typed(header.getMonth()));
        result.put("day", typed(header.getDay()));
        result.put("bookType", typed(header.getBookType()));
        result.put("bookMan", typed(header.getBookMan()));
        result.put("shopKeeper", typed(header.getShopKeeper()));
        return result;
    }

    private static void writeNew(Path path, byte[] bytes) throws Exception {
        Files.write(path, bytes, StandardOpenOption.CREATE_NEW, StandardOpenOption.WRITE);
    }

    private static void jsonNew(Path path, Object value) throws Exception {
        writeNew(path, (json(value) + "\n").getBytes(StandardCharsets.UTF_8));
    }

    private static String quote(String value) {
        StringBuilder result = new StringBuilder("\"");
        for (int i = 0; i < value.length(); i++) {
            char c = value.charAt(i);
            switch (c) {
                case '"' -> result.append("\\\"");
                case '\\' -> result.append("\\\\");
                case '\n' -> result.append("\\n");
                case '\r' -> result.append("\\r");
                case '\t' -> result.append("\\t");
                default -> {
                    if (c < 32 || c > 126) result.append(String.format("\\u%04x", (int) c));
                    else result.append(c);
                }
            }
        }
        return result.append('"').toString();
    }

    private static String json(Object value) {
        if (value == null) return "null";
        if (value instanceof String string) return quote(string);
        if (value instanceof Number || value instanceof Boolean) return value.toString();
        if (value instanceof Map<?, ?> map) {
            List<String> entries = new ArrayList<>();
            for (Map.Entry<?, ?> entry : map.entrySet()) entries.add(quote((String) entry.getKey()) + ":" + json(entry.getValue()));
            return "{" + String.join(",", entries) + "}";
        }
        if (value instanceof List<?> list) {
            List<String> entries = new ArrayList<>();
            for (Object item : list) entries.add(json(item));
            return "[" + String.join(",", entries) + "]";
        }
        throw new IllegalArgumentException("Unsupported harness JSON value: " + value.getClass());
    }

    public static void main(String[] args) throws Exception {
        if (args.length != 2) throw new IllegalArgumentException("Expected fixture-id and fresh output directory");
        Fixture fixture = fixture(args[0]);
        Path output = Path.of(args[1]);
        Files.createDirectory(output);
        Map<String, Object> input = new LinkedHashMap<>();
        input.put("id", fixture.id());
        input.put("metadata", fixture.metadata());
        List<Object> inputChapters = new ArrayList<>();
        UmdBook writer = new UmdBook();
        configure(writer.getHeader(), fixture.metadata());
        for (Chapter chapter : fixture.chapters()) {
            Map<String, Object> entry = new LinkedHashMap<>();
            entry.put("title", chapter.title());
            entry.put("content", chapter.content());
            inputChapters.add(entry);
            writer.getChapters().addChapter(chapter.title(), chapter.content());
        }
        input.put("chapters", inputChapters);
        jsonNew(output.resolve("fixture-input.json"), input);
        Path umd = output.resolve("fixture.umd");
        try (OutputStream stream = Files.newOutputStream(umd, StandardOpenOption.CREATE_NEW, StandardOpenOption.WRITE)) {
            writer.buildUmd(stream);
        }
        UmdBook read;
        try (FileInputStream stream = new FileInputStream(umd.toFile())) {
            read = new UmdReader().read(stream);
        }
        Map<String, Object> actual = new LinkedHashMap<>();
        actual.put("id", fixture.id());
        actual.put("umdType", typed(read.getHeader().getUmdType()));
        actual.put("chapterCount", typed(read.getNum()));
        actual.put("totalContentLength", typed(read.getChapters().getTotalContentLen()));
        actual.put("metadata", headerValues(read.getHeader()));
        List<Object> chapters = new ArrayList<>();
        UmdChapters readChapters = read.getChapters();
        for (int i = 0; i < read.getNum(); i++) {
            Map<String, Object> chapter = new LinkedHashMap<>();
            byte[] content = readChapters.getContent(i);
            String contentString = readChapters.getContentString(i);
            String rawFile = String.format("chapter-%02d.actual.utf16le", i);
            writeNew(output.resolve(rawFile), content);
            String stringFile = String.format("chapter-%02d.actual-string.utf8", i);
            if (contentString != null) writeNew(output.resolve(stringFile), contentString.getBytes(StandardCharsets.UTF_8));
            chapter.put("index", i);
            chapter.put("title", typed(readChapters.getTitle(i)));
            chapter.put("offset", typed(readChapters.getContentLength(i)));
            chapter.put("rawContent", Map.of("type", content.getClass().getName(), "valueBase64", Base64.getEncoder().encodeToString(content), "file", rawFile));
            chapter.put("getContentString", typed(contentString));
            chapter.put("stringFile", contentString == null ? null : stringFile);
            chapters.add(chapter);
        }
        actual.put("chapters", chapters);
        jsonNew(output.resolve("reader-output.json"), actual);
        System.out.println("HARNESS_COMPLETED " + fixture.id());
    }
}
