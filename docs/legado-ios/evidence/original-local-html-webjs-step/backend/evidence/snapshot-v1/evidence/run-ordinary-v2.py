from pathlib import Path
source=Path(__file__).with_name('run-ordinary.py').read_text(encoding='utf-8')
source=source.replace("'consumer-classes'","'consumer-classes-v2'").replace("'ordinary-commands.json'","'ordinary-commands-v2.json'").replace("'compile-consumer.log'","'compile-consumer-v2.log'").replace("'execute-consumer.log'","'execute-consumer-v2.log'")
exec(compile(source,__file__,'exec'))
