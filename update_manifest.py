# assets/ 안의 .png 파일을 스캔해서 assets/manifest.js를 만든다. PNG를 추가/삭제할 때마다 실행: python update_manifest.py
import os
base = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'assets')
names = sorted(os.path.relpath(os.path.join(r, f), base).replace(os.sep, '/')[:-4]
               for r, _, fs in os.walk(base) for f in fs if f.lower().endswith('.png'))
open(os.path.join(base, 'manifest.js'), 'w', encoding='utf-8').write('window.ASSET_PNG = ' + repr(names).replace("'", '"') + ';\n')
print(len(names), 'png registered')
