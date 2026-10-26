import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import 'audio_recorder.dart';

/// Gravação real via MediaRecorder/getUserMedia (web). Microfone pede
/// permissão no `start()`; sem permissão o erro propaga para a UI tratar.
AudioRecorder createAudioRecorder() => _WebAudioRecorder();

class _WebAudioRecorder implements AudioRecorder {
  web.MediaStream? _stream;
  web.MediaRecorder? _recorder;
  final List<web.Blob> _chunks = [];
  DateTime? _startedAt;

  @override
  bool get supported => web.window.hasProperty('MediaRecorder'.toJS).toDart;

  @override
  Future<void> start() async {
    if (_recorder != null) throw StateError('Gravação já em curso');
    final stream = await web.window.navigator.mediaDevices
        .getUserMedia(web.MediaStreamConstraints(audio: true.toJS))
        .toDart;
    _stream = stream;
    _chunks.clear();
    final recorder = web.MediaRecorder(
        stream, web.MediaRecorderOptions(mimeType: 'audio/webm'));
    recorder.addEventListener('dataavailable', _onData.toJS);
    _recorder = recorder;
    _startedAt = DateTime.now();
    recorder.start();
  }

  void _onData(web.Event e) {
    final blob = (e as web.BlobEvent).data;
    if (blob.size > 0) _chunks.add(blob);
  }

  @override
  Future<AudioCapture?> stop() async {
    final recorder = _recorder;
    final stream = _stream;
    final started = _startedAt;
    if (recorder == null || stream == null || started == null) return null;

    final done = Completer<void>();
    recorder.addEventListener(
        'stop',
        (web.Event e) {
          if (!done.isCompleted) done.complete();
        }.toJS);
    recorder.stop();
    await done.future;
    _recorder = null;
    _stream = null;
    _startedAt = null;

    final parts = <Uint8List>[];
    for (final c in _chunks) {
      final buf = await c.arrayBuffer().toDart;
      parts.add(buf.toDart.asUint8List());
    }
    _chunks.clear();
    for (final t in stream.getTracks().toDart) {
      t.stop();
    }
    if (parts.isEmpty) return null;
    final total = parts.fold<int>(0, (a, b) => a + b.length);
    final bytes = Uint8List(total);
    var offset = 0;
    for (final p in parts) {
      bytes.setAll(offset, p);
      offset += p.length;
    }
    return AudioCapture(
      bytes: bytes,
      duration: DateTime.now().difference(started),
      mime: 'audio/webm',
    );
  }

  @override
  void cancel() {
    final recorder = _recorder;
    final stream = _stream;
    _recorder = null;
    _stream = null;
    _startedAt = null;
    _chunks.clear();
    try {
      recorder?.stop();
    } catch (_) {
      // já parado — nada a fazer
    }
    if (stream != null) {
      for (final t in stream.getTracks().toDart) {
        t.stop();
      }
    }
  }
}
