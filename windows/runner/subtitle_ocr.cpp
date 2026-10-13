// Local OCR helper. A separate process keeps Windows OCR off Flutter's UI thread.
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Windows.Globalization.h>
#include <winrt/Windows.Graphics.Imaging.h>
#include <winrt/Windows.Media.Ocr.h>
#include <winrt/Windows.Storage.h>
#include <winrt/Windows.Storage.Streams.h>
#include <iostream>
#include <vector>

// Keep the original image as the first pass. These alternatives are requested
// only when it did not provide enough evidence. White/pink outlines and mixed
// Chinese/Japanese lines often defeat the OCR engine's text segmentation.
winrt::Windows::Graphics::Imaging::SoftwareBitmap Preprocess(
    winrt::Windows::Graphics::Imaging::BitmapDecoder const& decoder,
    std::wstring const& mode) {
  using namespace winrt::Windows;
  using namespace Graphics::Imaging;
  auto pixels = decoder.GetPixelDataAsync(
      BitmapPixelFormat::Bgra8, BitmapAlphaMode::Ignore, BitmapTransform(),
      ExifOrientationMode::IgnoreExifOrientation,
      ColorManagementMode::DoNotColorManage).get().DetachPixelData();
  const int width = static_cast<int>(decoder.PixelWidth());
  const int height = static_cast<int>(decoder.PixelHeight());
  const int padded_width = width + 40;
  std::vector<uint8_t> output(static_cast<size_t>(padded_width) * (height + 40) * 4, 255);
  for (int y = 0; y < height; ++y) {
    for (int x = 0; x < width; ++x) {
      const uint32_t source = (static_cast<uint32_t>(y) * width + x) * 4;
      const int b = pixels[source], g = pixels[source + 1], r = pixels[source + 2];
      uint8_t value;
      if (mode == L"--gray") {
        value = static_cast<uint8_t>((299 * r + 587 * g + 114 * b) / 1000);
      } else if (mode == L"--white") {
        value = r > 230 && g > 230 && b > 230 ? 0 : 255;
      } else {
        // Isolate bright red/pink glyph fills from white outlines and cyan
        // Japanese text, preserving the demonstrated dual-language subtitles.
        value = r > 200 && r > g * 1.2 && b > g * 1.05 ? 0 : 255;
      }
      const size_t target = (static_cast<size_t>(y + 20) * padded_width + x + 20) * 4;
      output[target] = output[target + 1] = output[target + 2] = value;
    }
  }
  Storage::Streams::DataWriter writer;
  writer.WriteBytes(output);
  return SoftwareBitmap::CreateCopyFromBuffer(writer.DetachBuffer(),
      BitmapPixelFormat::Bgra8, padded_width, height + 40, BitmapAlphaMode::Ignore);
}

int wmain(int argc, wchar_t* argv[]) {
  try {
    winrt::init_apartment(winrt::apartment_type::multi_threaded);
    using namespace winrt::Windows;
    if (argc == 2 && std::wstring(argv[1]) == L"--languages") {
      for (const auto& language : Media::Ocr::OcrEngine::AvailableRecognizerLanguages()) {
        std::cout << winrt::to_string(language.LanguageTag()) << '\n';
      }
      return 0;
    }
    // OCR language controls recognition, not the detected script. Classify the
    // actual recognized characters in Dart rather than using the engine locale.
    auto engine = Media::Ocr::OcrEngine::TryCreateFromLanguage(
        Globalization::Language(L"zh-CN"));
    if (!engine) {
      engine = Media::Ocr::OcrEngine::TryCreateFromLanguage(
          Globalization::Language(L"zh-TW"));
    }
    if (!engine) return 3;
    int first = 1;
    std::wstring mode;
    if (argc > 1 && (std::wstring(argv[1]) == L"--gray" ||
        std::wstring(argv[1]) == L"--white" || std::wstring(argv[1]) == L"--color")) {
      mode = argv[1];
      first = 2;
    }
    for (int i = first; i < argc; ++i) {
      auto file = Storage::StorageFile::GetFileFromPathAsync(argv[i]).get();
      auto stream = file.OpenAsync(Storage::FileAccessMode::Read).get();
      auto decoder = Graphics::Imaging::BitmapDecoder::CreateAsync(stream).get();
      auto bitmap = mode.empty() ? decoder.GetSoftwareBitmapAsync(
          Graphics::Imaging::BitmapPixelFormat::Bgra8,
          Graphics::Imaging::BitmapAlphaMode::Premultiplied).get() : Preprocess(decoder, mode);
      auto result = engine.RecognizeAsync(bitmap).get();
      for (const auto& line : result.Lines()) {
        std::cout << winrt::to_string(line.Text()) << '\n';
      }
      stream.Close();
    }
    return 0;
  } catch (const winrt::hresult_error& error) {
    std::cerr << winrt::to_string(error.message());
    return 2;
  }
}
