import 'dart:async';

import 'package:flutter/material.dart';

import '../../main.dart';
import '../media/video_recorder.dart';
import '../theme/theme.dart';

/// P5+ "Gravar vídeo (opcional)" — o parceiro escolhe câmera frontal ou
/// traseira, vê o preview ao vivo e grava a corrida. Para no web usa
/// getUserMedia/MediaRecorder; sem suporte avisa sem quebrar.
Future<void> showVideoRecordSheet(BuildContext context, String rideId) =>
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius:
            BorderRadius.vertical(top: Radius.circular(AppSpace.radiusSheet)),
      ),
      builder: (_) => _VideoRecordSheet(rideId: rideId),
    );

class _VideoRecordSheet extends StatefulWidget {
  const _VideoRecordSheet({required this.rideId});
  final String rideId;

  @override
  State<_VideoRecordSheet> createState() => _VideoRecordSheetState();
}

class _VideoRecordSheetState extends State<_VideoRecordSheet> {
  final _rec = VideoRecorder.platform();
  CameraSide _side = CameraSide.front;
  bool _recording = false;
  bool _busy = false;
  Duration _elapsed = Duration.zero;
  Timer? _ticker;
  bool _cameraOpen = false;

  @override
  void initState() {
    super.initState();
    if (_rec.supported) _openCamera(_side);
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _rec.close();
    super.dispose();
  }

  Future<void> _openCamera(CameraSide side) async {
    try {
      await _rec.openCamera(side);
      if (mounted) setState(() => _cameraOpen = true);
    } catch (_) {
      if (mounted) {
        setState(() => _cameraOpen = false);
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Permissão de câmera negada ou indisponível')));
      }
    }
  }

  Future<void> _switch(CameraSide side) async {
    if (_busy || side == _side) return;
    setState(() => _side = side);
    try {
      await _rec.switchCamera(side);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Não foi possível trocar a câmera')));
      }
    }
  }

  Future<void> _toggle() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      if (!_recording) {
        await _rec.start();
        _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
          if (mounted) setState(() => _elapsed += const Duration(seconds: 1));
        });
        setState(() => _recording = true);
      } else {
        _ticker?.cancel();
        final capture = await _rec.stop();
        setState(() => _recording = false);
        if (capture != null && mounted) {
          await AppScope.apiOf(context).uploadRecording(
            rideId: widget.rideId,
            kind: 'VIDEO',
            camera: capture.camera == CameraSide.front ? 'FRONT' : 'REAR',
            durationMs: capture.duration.inMilliseconds,
            bytes: capture.bytes,
            mime: capture.mime,
          );
          if (mounted) {
            final cam =
                capture.camera == CameraSide.front ? 'frontal' : 'traseira';
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(
              content: Text(
                  'Vídeo (${capture.duration.inSeconds}s, câmera $cam) salvo na corrida'),
            ));
            Navigator.pop(context);
          }
        }
      }
    } catch (_) {
      if (mounted) {
        setState(() => _recording = false);
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Erro ao gravar — tente de novo')));
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
    final bottom = MediaQuery.of(context).padding.bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(
          AppSpace.l, AppSpace.l, AppSpace.l, bottom + AppSpace.l),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(children: [
            const Icon(Icons.videocam_outlined, color: AppColors.primary),
            const SizedBox(width: AppSpace.s),
            const Text('Gravar vídeo da corrida', style: AppType.title),
            const Spacer(),
            IconButton(
              icon: const Icon(Icons.close),
              onPressed: () => Navigator.pop(context),
            ),
          ]),
          const SizedBox(height: AppSpace.s),
          const Text(
            'Opcional e só durante esta corrida. Escolha a câmera: frontal '
            '(vc) ou traseira (a rua). O arquivo vai para o suporte em caso '
            'de incidente.',
            style: AppType.label,
          ),
          const SizedBox(height: AppSpace.m),
          // Preview ao vivo (web) ou placeholder.
          ClipRRect(
            borderRadius: BorderRadius.circular(AppSpace.radiusSheet),
            child: Container(
              height: 200,
              color: const Color(0xFF0B1220),
              child: _cameraView(),
            ),
          ),
          const SizedBox(height: AppSpace.m),
          // Escolha de câmera.
          Row(children: [
            Expanded(
              child: _CameraChip(
                icon: Icons.camera_front_outlined,
                label: 'Frontal',
                selected: _side == CameraSide.front,
                onTap: _busy ? null : () => _switch(CameraSide.front),
              ),
            ),
            const SizedBox(width: AppSpace.m),
            Expanded(
              child: _CameraChip(
                icon: Icons.camera_rear_outlined,
                label: 'Traseira',
                selected: _side == CameraSide.rear,
                onTap: _busy ? null : () => _switch(CameraSide.rear),
              ),
            ),
          ]),
          const SizedBox(height: AppSpace.m),
          if (_recording)
            Center(
              child: Text('Gravando $_mmss',
                  style: const TextStyle(
                      color: AppColors.danger, fontWeight: FontWeight.w700)),
            ),
          const SizedBox(height: AppSpace.s),
          GradientButton(
            onPressed: (!_rec.supported || (!_cameraOpen && !_recording))
                ? null
                : _toggle,
            gradient: _recording
                ? const LinearGradient(
                    colors: [AppColors.danger, Color(0xFFE53935)])
                : AppGradients.primary,
            child: Text(_recording ? 'PARAR E SALVAR' : 'GRAVAR VÍDEO'),
          ),
          if (!_rec.supported)
            const Padding(
              padding: EdgeInsets.only(top: AppSpace.s),
              child: Text('Gravação de vídeo indisponível nesta plataforma',
                  textAlign: TextAlign.center, style: AppType.label),
            ),
        ],
      ),
    );
  }

  Widget _cameraView() {
    final viewId = _rec.previewViewId;
    if (viewId == null) {
      return const Center(
        child:
            Icon(Icons.videocam_off_outlined, color: Colors.white54, size: 40),
      );
    }
    // HtmlElementView é web-only; via kIsWeb evitamos o import no io.
    return HtmlElementView(viewType: viewId);
  }
}

class _CameraChip extends StatelessWidget {
  const _CameraChip({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(AppSpace.radiusCard),
          child: Container(
            height: AppSpace.target,
            decoration: BoxDecoration(
              color: selected ? AppColors.primary : AppColors.surface,
              borderRadius: BorderRadius.circular(AppSpace.radiusCard),
              border: Border.all(
                color: selected
                    ? AppColors.primary
                    : AppColors.hairline.withValues(alpha: 0.5),
              ),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon,
                    size: 20, color: selected ? Colors.white : AppColors.muted),
                const SizedBox(width: AppSpace.s),
                Text(label,
                    style: TextStyle(
                        fontWeight: FontWeight.w700,
                        color: selected ? Colors.white : AppColors.muted)),
              ],
            ),
          ),
        ),
      );
}
