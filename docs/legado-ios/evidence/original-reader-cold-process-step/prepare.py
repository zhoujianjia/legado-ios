from pathlib import Path
import hashlib,json,shutil,sys
sys.dont_write_bytecode=True
R=Path('F:/yuedu-reader');S=Path(__file__).parent;W=S/'work';B=S/'rawbaseline'
paths=['Tests/iOS/LegadoNativeOriginalReaderTests.swift','scripts/xctest.sh','.github/workflows/legado-native-reader-test.yml','scripts/reader-experience/test-native-smoke-tools.py']
def fact(p):b=p.read_bytes();return dict(bytes=len(b),sha256=hashlib.sha256(b).hexdigest())
for rel in paths:
 for folder in [W,B]:
  p=folder/rel;p.parent.mkdir(parents=True,exist_ok=True);assert not p.exists();shutil.copyfile(R/rel,p)
native=W/paths[0];text=native.read_text(encoding='utf-8');fragment=(S/'ColdMethods.swiftpart').read_text(encoding='utf-8');marker='final class LegadoNativeOriginalReaderTests: XCTestCase {\n';assert text.count(marker)==1;text=text.replace(marker,marker+fragment)
marker='    private let runID: String\n';assert text.count(marker)==1;text=text.replace(marker,marker+'    private let emitCookie: Bool\n')
marker='    init(runID: String) throws {\n        self.runID = runID\n';assert text.count(marker)==1;text=text.replace(marker,'    init(runID: String, emitCookie: Bool = true) throws {\n        self.runID = runID\n        self.emitCookie = emitCookie\n')
marker='let setCookie = target == prefix + "/search?key=native-original&page=2"';assert text.count(marker)==1;text=text.replace(marker,'let setCookie = emitCookie && target == prefix + "/search?key=native-original&page=2"');native.write_text(text,encoding='utf-8',newline='\n')
shell=W/'scripts/xctest.sh';text=shell.read_text(encoding='utf-8');marker='SCHEME="${YUEDU_SCHEME:-Yuedu-Reader}"\n';assert text.count(marker)==1;text=text.replace(marker,marker+'''TEST_ACTION="${YUEDU_TEST_ACTION:-test}"
case "$TEST_ACTION" in
  test|test-without-building) ;;
  *) echo "Unsupported YUEDU_TEST_ACTION" >&2; exit 2 ;;
esac
''');marker='"${XCODEBUILD_COMMAND[@]}" test \\\n';assert text.count(marker)==1;text=text.replace(marker,'"${XCODEBUILD_COMMAND[@]}" "$TEST_ACTION" \\\n');shell.write_text(text,encoding='utf-8',newline='\n')
guard=W/'scripts/reader-experience/test-native-smoke-tools.py';text=guard.read_text(encoding='utf-8');a='''                self.assertEqual({name for name, _ in declarations},
                    {method.split("/")[1] for method in methods if method.split("/")[0] == suite})''';b='''                expected_methods = {method.split("/")[1] for method in methods if method.split("/")[0] == suite}
                if suite == "LegadoNativeOriginalReaderTests":
                    # These two methods are selected by distinct, receipt-bound
                    # cold-process host invocations, never this original group.
                    expected_methods |= {"testNativeOriginalColdProducerPersistsPublicReaderBeforeProcessExit",
                        "testNativeOriginalColdConsumerRestoresOwnedReaderWithoutNetwork"}
                self.assertEqual({name for name, _ in declarations}, expected_methods)''';assert text.count(a)==1;text=text.replace(a,b);guard.write_text(text,encoding='utf-8',newline='\n')
(S/'baseline.json').write_text(json.dumps(dict(files=[dict(path=rel,**fact(B/rel))for rel in paths],scope='Future C5 only; no edits to coherent10 or current5 controls'),indent=2)+'\n',encoding='utf-8')
print('prepared future C5 source/wrapper/strict declaration guard')
