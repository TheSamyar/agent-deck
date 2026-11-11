"""Protocol and optional real-model tests; uses no microphone, speaker, or cloud."""
import base64
import importlib.util
import json
import os
from pathlib import Path
import queue
import subprocess
import sys
import threading
import time
import unittest

HELPER = Path(__file__).resolve().parent.parent/'native/Resources/KokoroVoice/kokoro_voice.py'
spec = importlib.util.spec_from_file_location('kokoro_voice', HELPER)
helper = importlib.util.module_from_spec(spec)
spec.loader.exec_module(helper)


class VoiceContractTests(unittest.TestCase):
    def test_rejects_invalid_requests_before_inference(self):
        for request in [[], {}, {'id':'x','text':'hi','voice':'../../other'}, {'id':'x','text':'hi','speed':True}, {'id':'x','text':'hi','speed':2}, {'id':'x','text':' '*3}]:
            with self.subTest(request=request), self.assertRaises(ValueError):
                helper.validate(request)

    def test_chunks_bound_cancellation_and_preserve_words(self):
        text = ' '.join(['This is a sentence that needs to be spoken clearly.']*40)
        chunks = list(helper.segments(text))
        self.assertGreater(len(chunks),1)
        self.assertTrue(all(len(chunk)<=260 for chunk in chunks))
        self.assertEqual(' '.join(chunks),text)
        greeting='Hello. Tell me what you want your agents to work on, and we will take it one step at a time.'
        self.assertEqual(list(helper.segments(greeting)),[greeting])

    @unittest.skipUnless(os.environ.get('AGENT_DECK_TEST_KOKORO')=='1','Requires the installed local voice runtime')
    def test_real_audio_cancel_and_reuse(self):
        root = helper.DEFAULT_ROOT
        process = subprocess.Popen([str(root/'venv/bin/python'),'-u',str(HELPER),'--root',str(root)],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,text=True)
        events = queue.Queue()
        def read():
            for line in process.stdout:
                events.put(json.loads(line))
        threading.Thread(target=read,daemon=True).start()
        def send(value):
            process.stdin.write(json.dumps(value)+'\n');process.stdin.flush()
        def next_event():
            event = events.get(timeout=30)
            self.assertNotEqual(event['type'],'error',event)
            return event
        try:
            self.assertEqual(next_event()['type'],'ready')
            send({'id':'cancel-me','text':'This sentence must be canceled. '*100,'voice':'af_heart','speed':1})
            send({'type':'cancel','id':'cancel-me'})
            send({'id':'first','text':'Hello. I am your local supervisor, ready to help you keep your agents working.','voice':'af_heart','speed':1})
            frames=0
            while True:
                event=next_event()
                if event.get('id')!='first':
                    continue
                if event['type']=='audio':
                    pcm=base64.b64decode(event['pcm'],validate=True)
                    self.assertEqual(event['sampleRate'],24000)
                    self.assertEqual(len(pcm)%2,0)
                    self.assertTrue(any(pcm),'Audio must not be silent zeros')
                    frames+=len(pcm)//2
                if event['type']=='done':
                    break
            self.assertGreater(frames,24000)
            send({'id':'second','text':'We can take this one step at a time. What should your agents finish next?','voice':'am_michael','speed':1})
            second_audio=False
            while True:
                event=next_event()
                self.assertEqual(event.get('id'),'second')
                second_audio |= event['type']=='audio'
                if event['type']=='done':
                    break
            self.assertTrue(second_audio,'Warm runtime must handle the next utterance and a different voice')
        finally:
            process.stdin.close()
            process.wait(timeout=10)
            process.stdout.close()


if __name__=='__main__':
    unittest.main()
