#!/usr/bin/env python3
"""Manifest and optional real ONNX worker tests. Never opens the microphone."""
import hashlib, importlib.util, json, os, pathlib, subprocess, tempfile, unittest

HERE = pathlib.Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('wake_worker', HERE/'worker.py')
worker = importlib.util.module_from_spec(spec); spec.loader.exec_module(worker)

class ManifestTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.root = pathlib.Path(self.temp.name)
        self.manifest = json.loads((HERE/'model-manifest.json').read_text())
        for asset in self.manifest['files']:
            data = ('fixture '+asset['name']).encode(); (self.root/asset['name']).write_bytes(data)
            asset['sha256'] = hashlib.sha256(data).hexdigest()
    def tearDown(self): self.temp.cleanup()
    def write(self):
        p = self.root/'model-manifest.json'; p.write_text(json.dumps(self.manifest)); return p
    def test_valid_manifest(self):
        model, root = worker.load_manifest(self.write())
        self.assertEqual(model['verification_phrase'], 'Hey Alfred'); self.assertEqual(root,self.root)
    def test_tampered_asset_rejected(self):
        p=self.write(); (self.root/'alfred.onnx').write_bytes(b'tampered')
        with self.assertRaisesRegex(ValueError,'checksum'): worker.load_manifest(p)
    def test_duplicate_asset_rejected(self):
        self.manifest['files'][1]=self.manifest['files'][0]
        with self.assertRaisesRegex(ValueError,'asset set'): worker.load_manifest(self.write())
    def test_path_escape_rejected(self):
        self.manifest['files'][0]['name']='../alfred.onnx'
        with self.assertRaises(ValueError): worker.load_manifest(self.write())
    def test_unknown_phrase_rejected(self):
        self.manifest['verification_phrase']='Hey Jarvis'
        with self.assertRaisesRegex(ValueError,'manifest'): worker.load_manifest(self.write())
    def test_unsafe_threshold_rejected(self):
        for value in [0, -1, 1.2, float('nan')]:
            self.manifest['threshold']=value
            with self.assertRaisesRegex(ValueError,'threshold'): worker.load_manifest(self.write())

@unittest.skipUnless(os.environ.get('ALFRED_WAKE_TEST_ROOT') and os.environ.get('ALFRED_WAKE_TEST_PYTHON'), 'Set installed runtime paths for real ONNX test')
class RealWorkerTests(unittest.TestCase):
    def test_silence_protocol_never_wakes(self):
        p=subprocess.run([os.environ['ALFRED_WAKE_TEST_PYTHON'],str(HERE/'worker.py'),'--manifest',str(pathlib.Path(os.environ['ALFRED_WAKE_TEST_ROOT'])/'model-manifest.json')],input=b'\0'*2560*50,stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=30,check=True)
        events=[json.loads(line) for line in p.stdout.splitlines()]
        self.assertEqual(events[0]['type'],'ready'); self.assertEqual(events[-1], {'type':'ended','frames':50})
        self.assertFalse(any(x['type']=='wakeDetected' for x in events))
        self.assertNotIn(b'transcript',p.stdout)

if __name__=='__main__': unittest.main()
