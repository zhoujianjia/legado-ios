package io.yuedu.legado.interop;

import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/** Deterministic Java signatures for testing the original LiveConnect wrappers. */
public final class InteropFixture {
    public List<String> newList() { return new ArrayList<>(Arrays.asList("first", null, "last")); }
    public String readListItem(List<String> values, int index) { return values.get(index); }
    public Map<String, Object> newMap() {
        Map<String, Object> values = new LinkedHashMap<>();
        values.put("title", "book"); values.put("count", Integer.valueOf(7)); values.put("nil", null);
        return values;
    }
    public Object readMapItem(Map<String, Object> values, String key) { return values.get(key); }
    public String typeOfObject(Object value) { return value == null ? "null" : value.getClass().getName(); }
    public String javaString() { return "A\u4e66\ud83d\udcda\u0000Z"; }
    public byte[] utf8Bytes() { return "\u4e66".getBytes(StandardCharsets.UTF_8); }
    public String decodeUtf8(byte[] value) { return new String(value, StandardCharsets.UTF_8); }
    public byte[] signedBytes() { return new byte[] {0, 127, -128, -1}; }
    public byte[] echoBytes(byte[] value) { return value; }
    public int sumBytes(byte[] value) { int sum = 0; for (byte item : value) sum += item; return sum; }
    public String[] stringArray() { return new String[] {"first", null, "third"}; }
    public String[] echoStrings(String[] value) { return value; }
    public int[] echoInts(int[] value) { return value; }
    public String stringArrayFirst(String[] value) { return value[0]; }
    public Object nullObject() { return null; }
    public String nullString() { return null; }
    public byte[] nullBytes() { return null; }
    public void returnVoid() { }
    public int acceptInt(int value) { return value; }
    public String acceptLong(long value) { return Long.toString(value); }
    public boolean acceptBoolean(boolean value) { return value; }
    public String acceptChar(char value) { return "char:" + (int) value; }
    public Long boxedLong() { return Long.valueOf(9007199254740993L); }

    public String choose(String value) { return "String:" + (value == null ? "<null>" : value); }
    public String choose(double value) { return "double:" + Double.toString(value); }
    public String choose(boolean value) { return "boolean:" + value; }
    public String choose(Object value) { return "Object:" + typeOfObject(value); }
    public String chooseNumber(int value) { return "int:" + value; }
    public String chooseNumber(double value) { return "double:" + Double.toString(value); }
    public String combine(String value) { return "one:" + value; }
    public String combine(String left, String right) { return "two:" + left + ":" + right; }

    public void fail() { throw new IllegalStateException("interop-instance-failure"); }
    public static void staticFail() { throw new IllegalArgumentException("interop-static-failure"); }
    public Child child() { return new Child(); }
    public List<Child> childrenList() { return new ArrayList<>(List.of(new Child())); }
    public Map<String, Child> childrenMap() { return Map.of("child", new Child()); }
    public Child[] childrenArray() { return new Child[] {new Child()}; }

    public static final class Child {
        public void fail() { throw new IllegalStateException("interop-child-failure"); }
    }
}
