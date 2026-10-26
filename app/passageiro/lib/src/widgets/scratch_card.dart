import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../api/client.dart';
import '../theme/theme.dart';

/// Widget de raspagem: o usuário arrasta o dedo para revelar o conteúdo
/// debaixo de uma camada escura. O percentual rasgado é exposto via
/// [ScratchCardState.percentScratched].
class ScratchCard extends StatefulWidget {
  const ScratchCard({
    super.key,
    required this.child,
    this.thresholdPercent = 60.0,
    this.brushWidth = 30.0,
    this.onScratchComplete,
  });

  final Widget child;
  final double thresholdPercent;
  final double brushWidth;
  final VoidCallback? onScratchComplete;

  @override
  State<ScratchCard> createState() => _ScratchCardState();
}

class _ScratchCardState extends State<ScratchCard> {
  static const _cellSize = 8.0;

  final _key = GlobalKey();
  final Set<Offset> _scratchedPoints = {};
  final Set<int> _scratchedCells = {};
  double _percentScratched = 0.0;
  bool _completed = false;
  Offset? _lastPoint;
  int _revision = 0;

  double get percentScratched => _percentScratched;

  void _onPanStart(DragStartDetails details) {
    _lastPoint = null;
    _scratchAt(_toLocal(details.localPosition));
  }

  void _onPanUpdate(DragUpdateDetails details) {
    final box = _key.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return;
    final local = box.globalToLocal(details.globalPosition);
    final previous = _lastPoint;
    if (previous != null) {
      final delta = local - previous;
      final step = math.max(1.0, widget.brushWidth / 2);
      final segments = math.max(1, (delta.distance / step).ceil());
      for (var i = 1; i <= segments; i++) {
        _addScratch(previous + delta * (i / segments));
      }
    } else {
      _addScratch(local);
    }
    _lastPoint = local;
  }

  void _onPanEnd(DragEndDetails details) => _lastPoint = null;

  Offset _toLocal(Offset fallback) {
    final box = _key.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return fallback;
    return box.globalToLocal(box.localToGlobal(fallback));
  }

  void _scratchAt(Offset point) {
    _lastPoint = point;
    _addScratch(point);
  }

  void _addScratch(Offset point) {
    if (_completed) return;
    final box = _key.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || box.size.isEmpty) return;

    final size = box.size;
    final r = widget.brushWidth / 2;
    _scratchedPoints.add(
      Offset(point.dx.roundToDouble(), point.dy.roundToDouble()),
    );

    // O percentual precisa medir ÁREA coberta, não quantidade de pontos:
    // marcar células de uma grade torna o cálculo independente do dedo.
    final cols = (size.width / _cellSize).ceil();
    final rows = (size.height / _cellSize).ceil();
    final minCol =
        ((point.dx - r) / _cellSize).floor().clamp(0, cols - 1).toInt();
    final maxCol =
        ((point.dx + r) / _cellSize).floor().clamp(0, cols - 1).toInt();
    final minRow =
        ((point.dy - r) / _cellSize).floor().clamp(0, rows - 1).toInt();
    final maxRow =
        ((point.dy + r) / _cellSize).floor().clamp(0, rows - 1).toInt();
    for (var row = minRow; row <= maxRow; row++) {
      for (var col = minCol; col <= maxCol; col++) {
        final cx = (col + 0.5) * _cellSize;
        final cy = (row + 0.5) * _cellSize;
        final dx = cx - point.dx;
        final dy = cy - point.dy;
        if (dx * dx + dy * dy <= r * r) {
          _scratchedCells.add(row * cols + col);
        }
      }
    }

    _revision++;
    _recalculatePercent(cols * rows);
  }

  void _recalculatePercent(int totalCells) {
    if (totalCells == 0) return;
    final newPercent =
        (_scratchedCells.length / totalCells * 100).clamp(0.0, 100.0).toDouble();
    if (newPercent != _percentScratched) {
      setState(() => _percentScratched = newPercent);
      if (!_completed && newPercent >= widget.thresholdPercent) {
        _completed = true;
        widget.onScratchComplete?.call();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        return GestureDetector(
          onPanStart: _onPanStart,
          onPanUpdate: _onPanUpdate,
          onPanEnd: _onPanEnd,
          child: SizedBox(
            width: constraints.maxWidth,
            height: constraints.maxHeight,
            child: Stack(
              children: [
                widget.child,
                RepaintBoundary(
                  key: _key,
                  child: CustomPaint(
                    size: Size(constraints.maxWidth, constraints.maxHeight),
                    painter: _ScratchMaskPainter(
                      points: _scratchedPoints,
                      revision: _revision,
                      color: const Color(0xFF333333),
                    ),
                  ),
                ),
                if (_percentScratched < 5)
                  const Center(
                    child: Text(
                      'Raspe para revelar',
                      style: TextStyle(
                        color: Colors.white70,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _ScratchMaskPainter extends CustomPainter {
  _ScratchMaskPainter({
    required this.points,
    required this.revision,
    required this.color,
  });

  final Set<Offset> points;
  final int revision;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    // saveLayer é obrigatório: BlendMode.clear precisa apagar só a máscara
    // e revelar o child, não o canvas inteiro.
    canvas.saveLayer(Offset.zero & size, Paint());

    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;
    canvas.drawRect(Offset.zero & size, paint);

    final clearPaint = Paint()
      ..blendMode = BlendMode.clear
      ..style = PaintingStyle.fill;

    for (final p in points) {
      canvas.drawCircle(p, 15, clearPaint);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _ScratchMaskPainter old) =>
      old.revision != revision;
}

/// Resultado da raspagem: exibe prêmio ou mensagem de participação.
class ScratchResultCard extends StatelessWidget {
  const ScratchResultCard({
    super.key,
    required this.ticket,
    this.onRedeem,
  });

  final ScratchTicket ticket;
  final VoidCallback? onRedeem;

  @override
  Widget build(BuildContext context) {
    final isWinner = ticket.isWinner;
    final t = tokensOf(context);

    return Card(
      color: t.surface,
      child: Padding(
        padding: const EdgeInsets.all(AppSpace.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              isWinner ? Icons.card_giftcard : Icons.close,
              size: 64,
              color: isWinner ? AppColors.earn : AppColors.muted,
            ),
            const SizedBox(height: AppSpace.l),
            Text(
              isWinner
                  ? 'Parabéns! Você ganhou!'
                  : 'Que pena, não foi desta vez.',
              style: titleStyle(context).copyWith(
                color: isWinner ? AppColors.earn : AppColors.danger,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: AppSpace.m),
            if (ticket.prizeId != null) ...[
              Text(
                'Prêmio: ${ticket.prizeId}',
                style: bodyStyle(context),
              ),
              const SizedBox(height: AppSpace.s),
            ],
            const SizedBox(height: AppSpace.l),
            if (ticket.canRedeem && onRedeem != null)
              GradientButton(
                onPressed: onRedeem,
                child: const Text('RESGATAR PRÊMIO'),
              ),
          ],
        ),
      ),
    );
  }
}
