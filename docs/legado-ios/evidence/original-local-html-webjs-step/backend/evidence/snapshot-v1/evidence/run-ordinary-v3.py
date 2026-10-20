from pathlib import Path
source=Path(__file__).with_name('run-ordinary.py').read_text(encoding='utf-8')
source=source.replace("'consumer-classes'","'consumer-classes-v3'").replace("'ordinary-commands.json'","'ordinary-commands-v3.json'").replace("'compile-consumer.log'","'compile-consumer-v3.log'").replace("'execute-consumer.log'","'execute-consumer-v3.log'")
exec(compile(source,__file__,'exec'))
