import 'dart:async';

import 'package:flutter/material.dart';

import '../media/audio_recorder.dart';
import '../theme/theme.dart';

/// CTA "Gravar áudio da corrida" (segurança F5): grava durante a viagem e
/// envia para /rides/{id}/recordings ao parar. No web usa MediaRecorder;
/// sem suporte mostra o estado indisponível sem quebrar.
class RecordAudioButton extends StatefulWidget {
  const RecordAudioButton(
      {super.key, required this.rideId, required this.upload});

  final String rideId;
  final Future<void> Function({
    required String kind,
    required int durationMs,
    required List<int> bytes,
    required String mime,
  }) upload;

  @override
  State<RecordAudioButton> createState() => _RecordAudioButtonState();
}

class _RecordAudioButtonState extends State<RecordAudioButton> {
  final _recorder = AudioRecorder.platform();
  bool _recording = false;
  bool _busy = false;
  Duration _elapsed = Duration.zero;
  Timer? _ticker;

  @override
  void dispose() {
    _ticker?.cancel();
    _recorder.cancel();
    super.dispose();
  }

  Future<void> _toggle() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      if (!_recording) {
        await _recorder.start();
        _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
          if (mounted) setState(() => _elapsed += const Duration(seconds: 1));
        });
        setState(() => _recording = true);
      } else {
        _ticker?.cancel();
        final capture = await _recorder.stop();
        setState(() => _recording = false);
        if (capture != null && mounted) {
          await widget.upload(
            kind: 'AUDIO',
            durationMs: capture.duration.inMilliseconds,
            bytes: capture.bytes,
            mime: capture.mime,
          );
          if (mounted) {
            final s = capture.duration.inSeconds;
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(
              content: Text(
                  'Áudio salvo na corrida (${s}s) — acesso apenas pelo suporte'),
            ));
          }
        }
      }
    } catch (_) {
      if (mounted) {
        setState(() => _recording = false);
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Permissão de microfone negada ou mídia indisponível'),
        ));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String get _mmss {
    final m = _elapsed.inMinutes.toString().padLeft(2, '0');
    final s = (_elapsed.inSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    if (!_recorder.supported) {
      return OutlinedButton.icon(
        onPressed: null,
        icon: const Icon(Icons.mic_off_outlined),
        label: const Text('Gravação de áudio indisponível aqui'),
      );
    }
    if (!_recording) {
      return OutlinedButton.icon(
        onPressed: _busy ? null : _toggle,
        icon: const Icon(Icons.mic_none_outlined),
        label: const Text('Gravar áudio da corrida'),
      );
    }
    // Gravando: chip vermelho pulsante + cronômetro + parar.
    return DecoratedBox(
      decoration: BoxDecoration(
        color: AppColors.danger.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(AppSpace.radiusCard),
        border: Border.all(color: AppColors.danger.withValues(alpha: 0.4)),
      ),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: BorderRadius.circular(AppSpace.radiusCard),
          onTap: _busy ? null : _toggle,
          child: SizedBox(
            height: AppSpace.target,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const _RecDot(),
                const SizedBox(width: AppSpace.s),
                Text('Gravando $_mmss — toque para salvar',
                    style: const TextStyle(
                        color: AppColors.danger, fontWeight: FontWeight.w700)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _RecDot extends StatefulWidget {
  const _RecDot();
  @override
  State<_RecDot> createState() => _RecDotState();
}

class _RecDotState extends State<_RecDot> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 900))
    ..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FadeTransition(
        opacity: Tween(begin: 1.0, end: 0.25)
            .animate(CurvedAnimation(parent: _c, curve: Curves.easeInOut)),
        child: Container(
          width: 12,
          height: 12,
          decoration: const BoxDecoration(
              color: AppColors.danger, shape: BoxShape.circle),
        ),
      );
}
