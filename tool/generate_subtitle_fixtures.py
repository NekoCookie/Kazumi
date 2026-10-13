"""Generate local video fixtures for subtitle_script_probe_windows_test.dart.

Requires Pillow, cryptography and FFmpeg. Writes only under build/.
"""
from pathlib import Path
import subprocess

from PIL import Image, ImageDraw, ImageFont
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
from cryptography.hazmat.primitives.padding import PKCS7

folder = Path(__file__).resolve().parents[1] / "build/subtitle-verification"
folder.mkdir(parents=True, exist_ok=True)
font = ImageFont.truetype("C:/Windows/Fonts/msyh.ttc", 48)
texts = {
    "simplified": "欢迎观看这个故事，我们已经准备好了，请继续前进。",
    "traditional": "歡迎觀看這個故事，我們已經準備好了，請繼續前進。",
    "blank": "",
}
for name, text in texts.items():
    image = Image.new("RGB", (1920, 1080), (30, 35, 40))
    draw = ImageDraw.Draw(image)
    # Chinese text outside the subtitle area must not determine the result.
    draw.text((180, 100), texts['traditional'], font=font, fill="white")
    draw.text((180, 970), text, font=font, fill="white", stroke_width=2, stroke_fill="black")
    image.save(folder / f"{name}-video.png")
    subprocess.run([
        "ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-loop", "1",
        "-i", str(folder / f"{name}-video.png"), "-t", "6", "-r", "15",
        "-c:v", "libx264", "-preset", "ultrafast", "-pix_fmt", "yuv420p",
        "-threads", "1", str(folder / f"{name}.ts"),
    ], check=True)

# Regression: heavily outlined pink Chinese above a cyan Japanese line.
for name, text in [('styled-simplified', texts['simplified']),
                   ('styled-traditional', texts['traditional'])]:
    image = Image.new('RGB', (1920, 1080), (30, 35, 40))
    draw = ImageDraw.Draw(image)
    draw.text((180, 950), text, font=font, fill=(250, 110, 165),
              stroke_width=5, stroke_fill='white')
    draw.text((380, 1010), '今日は物語の続きを見ましょう', font=font,
              fill=(70, 205, 225), stroke_width=3, stroke_fill='white')
    image.save(folder / f'{name}-video.png')
    subprocess.run([
        'ffmpeg', '-hide_banner', '-loglevel', 'error', '-y', '-loop', '1',
        '-i', str(folder / f'{name}-video.png'), '-t', '0.8', '-r', '15',
        '-c:v', 'libx264', '-preset', 'ultrafast', '-pix_fmt', 'yuv420p',
        '-threads', '1', str(folder / f'{name}.ts'),
    ], check=True)

# The initial 40% position contains no subtitles. The 25% fallback does.
subprocess.run([
    'ffmpeg', '-hide_banner', '-loglevel', 'error', '-y',
    '-loop', '1', '-t', '7', '-i', str(folder / 'simplified-video.png'),
    '-loop', '1', '-t', '13', '-i', str(folder / 'blank-video.png'),
    '-filter_complex', '[0:v][1:v]concat=n=2:v=1:a=0[v]', '-map', '[v]',
    '-r', '15', '-c:v', 'libx264', '-preset', 'ultrafast', '-pix_fmt', 'yuv420p',
    '-threads', '1', '-movflags', '+faststart', str(folder / 'fallback.mp4'),
], check=True)

# Regression: a 600 ms caption falls between old two-second samples.
subprocess.run([
    'ffmpeg', '-hide_banner', '-loglevel', 'error', '-y',
    '-loop', '1', '-i', str(folder / 'blank-video.png'),
    '-loop', '1', '-i', str(folder / 'simplified-video.png'),
    '-filter_complex', "[0:v][1:v]overlay=enable='between(t,9.35,9.95)'",
    '-t', '20', '-r', '15', '-c:v', 'libx264', '-preset', 'ultrafast',
    '-pix_fmt', 'yuv420p', '-threads', '1', '-movflags', '+faststart',
    str(folder / 'brief-subtitle.mp4'),
], check=True)

# Regression: all three original windows are blank. Dialogue appears at 70%.
subprocess.run([
    'ffmpeg', '-hide_banner', '-loglevel', 'error', '-y',
    '-loop', '1', '-i', str(folder / 'blank-video.png'),
    '-loop', '1', '-i', str(folder / 'simplified-video.png'),
    '-filter_complex', "[0:v][1:v]overlay=enable='between(t,56,63)'",
    '-t', '80', '-r', '5', '-c:v', 'libx264', '-preset', 'ultrafast',
    '-pix_fmt', 'yuv420p', '-threads', '1', '-movflags', '+faststart',
    str(folder / 'expanded-subtitle.mp4'),
], check=True)

key, sequence = bytes(range(16)), 37
padder = PKCS7(128).padder()
plain = (folder / "traditional.ts").read_bytes()
padded = padder.update(plain) + padder.finalize()
encryptor = Cipher(algorithms.AES(key), modes.CBC(sequence.to_bytes(16, "big"))).encryptor()
(folder / "encrypted.ts").write_bytes(encryptor.update(padded) + encryptor.finalize())
(folder / "key.bin").write_bytes(key)

# Include an actual selectable soft subtitle track in an MP4 container.
(folder / "simplified.srt").write_text(
    "1\n00:00:00,000 --> 00:00:06,000\n" + texts["simplified"] + "\n", encoding="utf-8")
subprocess.run([
    "ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
    "-i", str(folder / "blank.ts"), "-i", str(folder / "simplified.srt"),
    "-map", "0:v", "-map", "1:0", "-c:v", "copy", "-c:s", "mov_text",
    "-metadata:s:s:0", "language=zho", "-movflags", "+faststart",
    str(folder / "soft-subtitle.mp4"),
], check=True)
print(folder)
subprocess.run([
    "ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
    "-i", str(folder / "traditional.ts"), "-c:v", "copy", "-f", "hls",
    "-hls_time", "6", "-hls_list_size", "0", "-hls_segment_type", "fmp4",
    "-hls_fmp4_init_filename", "init.mp4", str(folder / "fragment.m3u8"),
], check=True, cwd=folder)
