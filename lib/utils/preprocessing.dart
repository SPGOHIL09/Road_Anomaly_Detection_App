import 'package:image/image.dart' as img;

class PreprocessResult {
  final List<double> input;
  final double scale;
  final int xOffset;
  final int yOffset;

  PreprocessResult({
    required this.input,
    required this.scale,
    required this.xOffset,
    required this.yOffset,
  });
}

PreprocessResult preprocess(img.Image image) {

  const int size = 640;

  final double scale = size / (image.width > image.height
      ? image.width
      : image.height);

  final int newWidth = (image.width * scale).round();
  final int newHeight = (image.height * scale).round();

  final resized = img.copyResize(image,
      width: newWidth, height: newHeight);

  final padded = img.Image(width: size, height: size);

  img.fill(padded, color: img.ColorRgb8(114, 114, 114));

  final int xOffset = (size - newWidth) ~/ 2;
  final int yOffset = (size - newHeight) ~/ 2;

  img.compositeImage(
    padded,
    resized,
    dstX: xOffset,
    dstY: yOffset,
  );

  final List<double> input = List.filled(3 * size * size, 0);

  for (int y = 0; y < size; y++) {
    for (int x = 0; x < size; x++) {

      final pixel = padded.getPixel(x, y);

      final r = pixel.r / 255.0;
      final g = pixel.g / 255.0;
      final b = pixel.b / 255.0;

      final index = y * size + x;

      input[index] = r;
      input[index + size * size] = g;
      input[index + 2 * size * size] = b;
    }
  }

  return PreprocessResult(
    input: input,
    scale: scale,
    xOffset: xOffset,
    yOffset: yOffset,
  );
}