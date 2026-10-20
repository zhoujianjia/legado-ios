from pathlib import Path
import hashlib,json,shutil
R=Path('F:/yuedu-reader');S=Path(__file__).parent;B=S/'rawbaseline';W=S/'work';history=S/'history-initial-baseline';history.mkdir(exist_ok=False)
for rel in ['.github/workflows/legado-native-reader-test.yml','scripts/reader-experience/test-native-smoke-tools.py']:
 for folder in ['rawbaseline','work']:
  p=history/folder/rel;p.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(S/folder/rel,p)
 shutil.copyfile(R/rel,B/rel)
guard=W/'scripts/reader-experience/test-native-smoke-tools.py';text=(B/'scripts/reader-experience/test-native-smoke-tools.py').read_text(encoding='utf-8');a='''                self.assertEqual({name for name, _ in declarations},
                    {method.split("/")[1] for method in methods if method.split("/")[0] == suite})''';b='''                expected_methods = {method.split("/")[1] for method in methods if method.split("/")[0] == suite}
                if suite == "LegadoNativeOriginalReaderTests":
                    # These two methods are selected by distinct, receipt-bound
                    # cold-process host invocations, never this original group.
                    expected_methods |= {"testNativeOriginalColdProducerPersistsPublicReaderBeforeProcessExit",
                        "testNativeOriginalColdConsumerRestoresOwnedReaderWithoutNetwork"}
                self.assertEqual({name for name, _ in declarations}, expected_methods)''';assert text.count(a)==1;guard.write_text(text.replace(a,b),encoding='utf-8',newline='\n')
(S/'baseline-rebind.json').write_text(json.dumps(dict(reason='Parent main523817e integrated immutable coherent26/15 controls during futureC5 authoring. Rebase only two control baselines/C5 hunks, retain current26/15 and all shared source facts.',files=[dict(path=rel,bytes=len((B/rel).read_bytes()),sha256=hashlib.sha256((B/rel).read_bytes()).hexdigest())for rel in ['.github/workflows/legado-native-reader-test.yml','scripts/reader-experience/test-native-smoke-tools.py']],history='history-initial-baseline'),indent=2)+'\n',encoding='utf-8')
