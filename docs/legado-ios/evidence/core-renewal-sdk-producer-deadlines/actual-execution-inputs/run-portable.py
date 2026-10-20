from pathlib import Path
import importlib.util
import sys
import unittest
root=Path(__file__).resolve().parent
suite=unittest.TestSuite()
for ordinal,name in enumerate(("test-producer-diagnostics.py","test-producer-timeouts.py")):
    path=root/"work"/name
    spec=importlib.util.spec_from_file_location("owned_producer_tests_"+str(ordinal),path)
    module=importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    suite.addTests(unittest.defaultTestLoader.loadTestsFromModule(module))
result=unittest.TextTestRunner(verbosity=2).run(suite)
sys.exit(0 if result.wasSuccessful() else 1)
