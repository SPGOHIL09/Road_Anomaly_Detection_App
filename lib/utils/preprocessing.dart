import 'package:image/image.dart' as img;

List<double> preprocess(img.Image image) {

  const int size = 640;

  // Resize image to model size
  final resized = img.copyResize(image, width: size, height: size);

  // Preallocate tensor
  final List<double> input = List.filled(3 * size * size, 0);

  for (int y = 0; y < size; y++) {
    for (int x = 0; x < size; x++) {

      final pixel = resized.getPixel(x, y);

      final r = pixel.r / 255.0;
      final g = pixel.g / 255.0;
      final b = pixel.b / 255.0;

      final index = y * size + x;

      // Channel-first layout
      input[index] = r;
      input[index + size * size] = g;
      input[index + 2 * size * size] = b;
    }
  }

  return input;
}