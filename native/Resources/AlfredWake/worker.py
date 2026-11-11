#!/usr/bin/env python3
"""Private fixed-frame PCM input, content-free JSON events. Never owns a microphone."""
import argparse, hashlib, json, pathlib, sys, time, wave

def emit(kind, **fields):
    print(json.dumps(dict(type=kind, **fields)), flush=True)

def load_manifest(path):
    path = pathlib.Path(path)
    manifest = json.loads(path.read_text())
    if manifest.get('version') != 1 or manifest.get('verification_phrase') != 'Hey Alfred':
        raise ValueError('Invalid Alfred model manifest')
    files = manifest.get('files', [])
    expected = {'alfred.onnx', 'melspectrogram.onnx', 'embedding_model.onnx', 'silero_vad.onnx'}
    if len(files) != 4 or {x.get('name') for x in files} != expected:
        raise ValueError('Invalid model asset set')
    threshold = manifest.get('threshold')
    if not isinstance(threshold, (int, float)) or not 0.5 <= threshold <= 0.95:
        raise ValueError('Invalid detector threshold')
    for item in files:
        name = item['name']
        if pathlib.Path(name).name != name or not name.endswith('.onnx'):
            raise ValueError('Invalid model filename')
        data = (path.parent / name).read_bytes()
        if hashlib.sha256(data).hexdigest() != item['sha256']:
            raise ValueError('Model checksum mismatch: ' + name)
    return manifest, path.parent

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--manifest', required=True)
    parser.add_argument('--check', action='store_true')
    parser.add_argument('--fixture')
    args = parser.parse_args()
    manifest, root = load_manifest(args.manifest)
    import numpy as np
    from openwakeword.model import Model
    from openwakeword.vad import VAD
    model = Model(wakeword_models=[str(root / 'alfred.onnx')], inference_framework='onnx',
                  melspec_model_path=str(root / 'melspectrogram.onnx'),
                  embedding_model_path=str(root / 'embedding_model.onnx'),
                  vad_threshold=0)
    vad = VAD(model_path=str(root / 'silero_vad.onnx'))
    emit('ready', protocol=1, sampleRate=16000, frameSamples=1280,
         detectorKeyword=manifest['detector_keyword'], verificationPhrase=manifest['verification_phrase'],
         validatedAcoustically=manifest.get('validated_acoustically', False))
    if args.check:
        return
    source = sys.stdin.buffer
    if args.fixture:
        source = wave.open(args.fixture, 'rb')
        if source.getnchannels() != 1 or source.getframerate() != 16000 or source.getsampwidth() != 2:
            raise ValueError('Fixture must be 16kHz mono int16 WAV')
    buffered = b''; frame_index = 0; last_activation = -1000; hits = 0
    while True:
        data = source.readframes(1280) if args.fixture else source.read(2560 - len(buffered))
        if not data:
            break
        buffered += data
        if len(buffered) < 2560:
            continue
        samples = np.frombuffer(buffered[:2560], dtype='<i2')
        buffered = buffered[2560:]
        predictions = model.predict(samples)
        vad(samples)
        speech = max(list(vad.prediction_buffer)[-4:], default=0) >= 0.35
        score = max(float(x) for x in predictions.values()) if speech else 0
        hits = hits + 1 if score >= manifest.get('threshold', 0.7) else 0
        if hits >= 2 and frame_index - last_activation >= 25:
            emit('wakeDetected', frame=frame_index, score=round(score, 4))
            last_activation = frame_index; hits = 0
        frame_index += 1
    emit('ended', frames=frame_index)

if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        emit('error', message=str(error)[:240])
        sys.exit(1)
