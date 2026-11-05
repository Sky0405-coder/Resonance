import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';

/// The part of an image of [imageSize] that a square viewport of [viewport] shows when the image is laid out to cover
/// it and then transformed by [matrix] (pan and zoom of an InteractiveViewer).
Rect coverCropRect(Size imageSize, double viewport, Matrix4 matrix) {
  final cover = viewport / math.min(imageSize.width, imageSize.height);
  final scale = matrix.getMaxScaleOnAxis();
  final translation = matrix.getTranslation();
  final left = -translation.x / scale / cover;
  final top = -translation.y / scale / cover;
  final side = viewport / scale / cover;
  return Rect.fromLTWH(
    left.clamp(0, math.max(0, imageSize.width - side)),
    top.clamp(0, math.max(0, imageSize.height - side)),
    math.min(side, math.min(imageSize.width, imageSize.height)),
    math.min(side, math.min(imageSize.width, imageSize.height)),
  );
}

/// Lets the user pick the square part of [bytes] to use (drag and pinch or scroll to zoom); returns it as PNG of at
/// most [maxSize] pixels, or null when cancelled.
Future<Uint8List?> cropSquareImage(BuildContext context, Uint8List bytes, {int maxSize = 1200}) async {
  final codec = await ui.instantiateImageCodec(bytes);
  final image = (await codec.getNextFrame()).image;
  if (!context.mounted) {
    image.dispose();
    return null;
  }
  try {
    final rect = await showDialog<Rect>(
      context: context,
      builder: (_) => _CropDialog(image: image),
    );
    if (rect == null) return null;
    final side = math.min(maxSize.toDouble(), rect.width).roundToDouble();
    final recorder = ui.PictureRecorder();
    Canvas(recorder)
        .drawImageRect(image, rect, Rect.fromLTWH(0, 0, side, side), Paint()..filterQuality = FilterQuality.high);
    final cropped = await recorder.endRecording().toImage(side.toInt(), side.toInt());
    final data = await cropped.toByteData(format: ui.ImageByteFormat.png);
    cropped.dispose();
    return data?.buffer.asUint8List();
  } finally {
    image.dispose();
  }
}

class _CropDialog extends StatefulWidget {
  const _CropDialog({required this.image});
  final ui.Image image;

  @override
  State<_CropDialog> createState() => _CropDialogState();
}

class _CropDialogState extends State<_CropDialog> {
  final _controller = TransformationController();
  double? _viewport;

  Size get _imageSize => Size(widget.image.width.toDouble(), widget.image.height.toDouble());

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final screen = MediaQuery.sizeOf(context);
    final viewport = math.min(420.0, math.min(screen.width - 80, screen.height - 260)).clamp(160.0, 420.0);
    final cover = viewport / math.min(_imageSize.width, _imageSize.height);
    final child = Size(_imageSize.width * cover, _imageSize.height * cover);
    if (_viewport != viewport) {
      // Start centred, like the cover would be shown without picking.
      _viewport = viewport;
      _controller.value = Matrix4.translationValues(-(child.width - viewport) / 2, -(child.height - viewport) / 2, 0);
    }
    return AlertDialog(
      title: Text(context.l10n.coverCropTitle),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: SizedBox.square(
              dimension: viewport,
              child: InteractiveViewer(
                transformationController: _controller,
                constrained: false,
                minScale: 1,
                maxScale: 6,
                child: SizedBox.fromSize(
                  size: child,
                  child: RawImage(image: widget.image, fit: BoxFit.fill),
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Text(context.l10n.coverCropHint, textAlign: TextAlign.center),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(context.l10n.commonCancel)),
        FilledButton(
          onPressed: () => Navigator.pop(context, coverCropRect(_imageSize, viewport, _controller.value)),
          child: Text(context.l10n.commonSave),
        ),
      ],
    );
  }
}
