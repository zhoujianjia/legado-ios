from pathlib import Path
S=Path(__file__).parent;rel='.github/workflows/legado-native-reader-test.yml';p=S/'work'/rel;text=(S/'rawbaseline'/rel).read_text(encoding='utf-8')
marker='          python -B scripts/reader-experience/test-native-smoke-tools.py -v 2>&1 | tee .build/ci-logs/native-reader-source-stamps.log\n';assert text.count(marker)==1;text=text.replace(marker,marker+'          python -B scripts/reader-experience/test-original-cold-process-tools.py -v 2>&1 | tee .build/ci-logs/native-reader-cold-protocol-guards.log\n')
marker='          ORIGINAL_STATUS=$?\n';assert text.count(marker)==1;text=text.replace(marker,marker+'''          # A pending receipt is not success. This controller runs exactly one
          # producer and one consumer in separate frozen-binary App hosts, then
          # validates fresh nonce/source/container/PID and raw case evidence.
          python -B scripts/reader-experience/original-cold-process-tools.py --udid "$(bash scripts/sim.sh udid)"
          COLD_STATUS=$?
''')
marker='&& $CONFIGURATION_COUNT_STATUS == 0 && $LOCAL_PRODUCT_COUNT_STATUS == 0 && $CACHE_COUNT_STATUS == 0 && $NATIVE_RESULT_STATUS == 0 ]]';assert text.count(marker)==1;text=text.replace(marker,'&& $CONFIGURATION_COUNT_STATUS == 0 && $LOCAL_PRODUCT_COUNT_STATUS == 0 && $CACHE_COUNT_STATUS == 0 && $NATIVE_RESULT_STATUS == 0 && $COLD_STATUS == 0 ]]');p.write_text(text,encoding='utf-8',newline='\n')
