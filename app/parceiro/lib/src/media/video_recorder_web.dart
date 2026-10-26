import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';
import 'dart:ui_web' as ui_web;

import 'package:web/web.dart' as web;

import 'video_recorder.dart';

/// Vídeo real via getUserMedia (facingMode user/environment) + MediaRecorder.
/// O preview é um <video> publicado como platform view ([previewViewId]).
///
/// Trocar de câmera no meio da gravação para o recorder, troca o stream e
/// reinicia — os trechos já capturados são preservados e unidos no [stop].
VideoRecorder createVideoRecorder() => _WebVideoRecorder();

class _WebVideoRecorder implements VideoRecorder {
  static const _viewId = 'grava-video-preview';
  static bool _registered = false;

  web.MediaStream? _stream;
  web.MediaRecorder? _recorder;
  web.HTMLVideoElement? _video;
  final List<Uint8List> _sealed = []; // trechos já encerrados (troca de câmera)
  final List<web.Blob> _chunks = [];
  DateTime? _startedAt;
  CameraSide _side = CameraSide.front;
  bool _recording = false;

  @override
  bool get supported => web.window.hasProperty('MediaRecorder'.toJS).toDart;

  @override
  String? get previewViewId => _video != null ? _viewId : null;

  // constraint de vídeo como JSObject: { facingMode: 'user' | 'environment' }
  static JSObject _videoConstraint(CameraSide side) {
    final o = JSObject();
    o['facingMode'] = (side == CameraSide.front ? 'user' : 'environment').toJS;
    return o;
  }

  @override
  Future<void> openCamera(CameraSide side) async {
    await _stopStream();
    final stream = await web.window.navigator.mediaDevices
        .getUserMedia(web.MediaStreamConstraints(
          video: _videoConstraint(side),
          audio: true.toJS,
        ))
        .toDart;
    _stream = stream;
    _side = side;

    final video = _video ?? web.HTMLVideoElement();
    video
      ..srcObject = stream
      ..autoplay = true
      ..muted = true
      ..setProperty('playsInline'.toJS, true.toJS);
    _video = video;
    if (!_registered) {
      ui_web.platformViewRegistry
          .registerViewFactory(_viewId, (int _) => video);
      _registered = true;
    }
    unawaited(video.play().toDart);
  }

  @override
  Future<void> start() async {
    if (_recording) throw StateError('Gravação já em curso');
    if (_stream == null) await openCamera(_side);
    final s = _stream;
    if (s == null) throw StateError('Câmera indisponível');
    _chunks.clear();
    final recorder =
        web.MediaRecorder(s, web.MediaRecorderOptions(mimeType: 'video/webm'));
    recorder.addEventListener('dataavailable', _onData.toJS);
    _recorder = recorder;
    _startedAt ??= DateTime.now();
    _recording = true;
    recorder.start();
  }

  void _onData(web.Event e) {
    final blob = (e as web.BlobEvent).data;
    if (blob.size > 0) _chunks.add(blob);
  }

  @override
  Future<VideoCapture?> stop() async {
    if (!_recording && _sealed.isEmpty && _chunks.isEmpty) return null;
    _recording = false;
    final started = _startedAt;
    _startedAt = null;
    final recorder = _recorder;
    _recorder = null;
    if (recorder != null) {
      final done = Completer<void>();
      recorder.addEventListener(
          'stop',
          (web.Event e) {
            if (!done.isCompleted) done.complete();
          }.toJS);
      recorder.stop();
      await done.future;
    }

    for (final c in _chunks) {
      final buf = await c.arrayBuffer().toDart;
      _sealed.add(buf.toDart.asUint8List());
    }
    _chunks.clear();
    if (_sealed.isEmpty || started == null) return null;
    final total = _sealed.fold<int>(0, (a, b) => a + b.length);
    final bytes = Uint8List(total);
    var offset = 0;
    for (final p in _sealed) {
      bytes.setAll(offset, p);
      offset += p.length;
    }
    _sealed.clear();
    return VideoCapture(
      bytes: bytes,
      duration: DateTime.now().difference(started),
      mime: 'video/webm',
      camera: _side,
    );
  }

  @override
  Future<void> switchCamera(CameraSide side) async {
    if (side == _side && _stream != null) return;
    if (_recording) {
      // Encerra o trecho atual (fica em _sealed) e recomeça na nova câmera;
      // o cronômetro total continua de onde parou.
      await _sealCurrent();
      await openCamera(side);
      await start();
    } else {
      await openCamera(side);
    }
  }

  Future<void> _sealCurrent() async {
    final recorder = _recorder;
    _recorder = null;
    if (recorder != null) {
      final done = Completer<void>();
      recorder.addEventListener(
          'stop',
          (web.Event e) {
            if (!done.isCompleted) done.complete();
          }.toJS);
      recorder.stop();
      await done.future;
    }
    for (final c in _chunks) {
      final buf = await c.arrayBuffer().toDart;
      _sealed.add(buf.toDart.asUint8List());
    }
    _chunks.clear();
  }

  Future<void> _stopStream() async {
    final stream = _stream;
    _stream = null;
    if (stream != null) {
      for (final t in stream.getTracks().toDart) {
        t.stop();
      }
    }
    final video = _video;
    if (video != null) video.srcObject = null;
  }

  @override
  void close() {
    final recorder = _recorder;
    _recorder = null;
    _recording = false;
    _startedAt = null;
    _chunks.clear();
    _sealed.clear();
    try {
      recorder?.stop();
    } catch (_) {
      // já parado — nada a fazer
    }
    unawaited(_stopStream());
  }
}
