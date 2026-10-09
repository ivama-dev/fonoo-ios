"""Packaging regression check for Apple's ITMS-90626 warning."""
import plistlib,sys
from pathlib import Path
root=Path(__file__).resolve().parents[1]
app=Path(sys.argv[1]) if len(sys.argv)>1 else root/'Fonoo'
if len(sys.argv)>1:
 info=plistlib.loads((app/'Info.plist').read_bytes())
 supported=set(info.get('INIntentsSupported',[]))
else:
 supported=set()
 for config in [root/'Fonoo/Info.plist',root/'Configuration/CarPlay-Info.plist']:
  supported.update(plistlib.loads(config.read_bytes()).get('INIntentsSupported',[]))
assert 'INStartCallIntent' in supported
for language in ('en','de'):
 file=app/(language+'.lproj')/'AppIntentVocabulary.plist';value=plistlib.loads(file.read_bytes())
 samples={item['IntentName']:item['IntentExamples'] for item in value['IntentPhrases']}
 assert supported<=samples.keys(),f'Missing intent examples: {language}'
 for intent in supported:
  assert isinstance(samples[intent],list) and samples[intent]
  assert all(isinstance(phrase,str) and phrase.strip() and 'fonoo' in phrase for phrase in samples[intent])
print('PASS: every supported Siri intent has English/German example phrases'+(' in the built app' if len(sys.argv)>1 else ''))
