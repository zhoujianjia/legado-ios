import importlib.util,json,sys,unittest
from pathlib import Path
class Result(unittest.TextTestResult):
 def __init__(self,*args,**kwargs):super().__init__(*args,**kwargs);self.passed=[]
 def addSuccess(self,test):super().addSuccess(test);self.passed.append(test.id())
suite=unittest.TestSuite()
for name in ('test-producer-timeouts.py','test-producer-diagnostics.py'):
 spec=importlib.util.spec_from_file_location(name.replace('-','_').replace('.py',''),Path(__file__).with_name(name));module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module);suite.addTests(unittest.defaultTestLoader.loadTestsFromModule(module))
result=unittest.TextTestRunner(verbosity=2,resultclass=Result).run(suite)
print('PORTABLE_SUMMARY_JSON '+json.dumps({'run':result.testsRun,'failures':len(result.failures),'errors':len(result.errors),'skipped':len(result.skipped),'passedMethods':result.passed},sort_keys=True))
sys.exit(0 if result.wasSuccessful() and result.testsRun==15 else 1)
