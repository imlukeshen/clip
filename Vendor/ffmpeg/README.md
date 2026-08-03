# Clip FFmpeg framework

`ReelFFmpeg.xcframework` is the Apple Silicon, macOS 14+ dynamic framework used
by both Clip distribution channels. It contains FFmpeg 7.1.2, libvpx 1.15.2,
and libaom 3.12.1 behind the small C API in `bridge/`.

The framework is built in LGPL-safe mode. GPL and nonfree components, the
FFmpeg programs, x264, and x265 are not included. Clip calls the libraries in
process and uses VideoToolbox for H.264 and HEVC encoding.

From the repository root:

```bash
make ffmpeg
make licence-audit
```

The build script downloads pinned source releases, verifies their SHA-256
checksums, creates shared libraries, and packages them with the bridge. Because
the codec libraries remain dynamically linked inside the framework, users can
replace them with compatible modified builds.

License texts for FFmpeg, libvpx, and libaom are included in this directory.
