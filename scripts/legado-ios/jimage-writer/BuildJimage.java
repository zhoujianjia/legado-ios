import java.io.BufferedOutputStream;
import java.io.DataOutputStream;
import java.io.InputStream;
import java.nio.ByteOrder;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardOpenOption;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.TreeMap;
import jdk.tools.jlink.internal.BasicImageWriter;
import jdk.tools.jlink.internal.ImageResourcesTree;

/** Byte-preserving image construction with the pinned OpenJDK Mobile writer. */
public final class BuildJimage {
    public static void main(String[] args) throws Exception {
        if (args.length != 2) {
            throw new IllegalArgumentException("Usage: BuildJimage exploded-modules output-image");
        }
        Path root = Path.of(args[0]);
        Path output = Path.of(args[1]);
        Map<String, Path> resources = new TreeMap<>();
        try (var paths = Files.walk(root)) {
            for (Path path : paths.toList()) {
                if (Files.isSymbolicLink(path)) {
                    throw new IllegalArgumentException("Symbolic links are not module resources");
                }
                if (Files.isRegularFile(path)) {
                    String name = root.relativize(path).toString().replace('\\', '/');
                    if (!name.contains("/") || name.startsWith("/") || name.contains("../")) {
                        throw new IllegalArgumentException("Invalid module resource path");
                    }
                    resources.put("/" + name, path);
                }
            }
        }
        BasicImageWriter writer = new BasicImageWriter(ByteOrder.LITTLE_ENDIAN);
        List<String> names = new ArrayList<>();
        long offset = 0;
        for (var entry : resources.entrySet()) {
            long length = Files.size(entry.getValue());
            // Pinned resources are non-preview classes/resources; Python checks
            // class probes and all payload bytes without parsing newer bytecode.
            writer.addLocation(entry.getKey(), offset, 0, length, 0);
            names.add(entry.getKey());
            offset = Math.addExact(offset, length);
        }
        // The pinned tree writes 1.1 package ModuleLink flags and directory data.
        ImageResourcesTree tree = new ImageResourcesTree(offset, writer, names);
        byte[] index = writer.getBytes();
        try (DataOutputStream out = new DataOutputStream(new BufferedOutputStream(
                Files.newOutputStream(output, StandardOpenOption.CREATE_NEW)))) {
            out.write(index);
            for (Path path : resources.values()) {
                try (InputStream resource = Files.newInputStream(path)) {
                    if (resource.transferTo(out) != Files.size(path)) {
                        throw new IllegalArgumentException("Resource size changed during copy");
                    }
                }
            }
            tree.addContent(out);
        }
        System.out.printf("resources=%d resourceBytes=%d indexBytes=%d imageBytes=%d%n",
            resources.size(), offset, index.length, Files.size(output));
    }
}
