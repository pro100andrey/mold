import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Thrown when an archive expands past the caller's limit.
///
/// A [FormatException] so it travels the same path as every other malformed
/// archive: the CLI already reports one as exit 1 with its message.
class ArchiveTooLargeException extends FormatException {
  ArchiveTooLargeException(this.limit)
    : super(
        'Archive expands to more than $limit bytes. Refusing to decompress '
        'further — a small archive that expands without bound is the shape of '
        'a decompression bomb. Raise maxDecompressedBytes if the template is '
        'genuinely this large.',
      );

  /// The limit that was exceeded, in bytes.
  final int limit;
}

/// The default ceiling on a decompressed archive: 512 MiB.
///
/// A template is a source project, so this is orders of magnitude above any
/// real one while still refusing an archive engineered to exhaust memory.
const defaultMaxDecompressedBytes = 512 * 1024 * 1024;

/// Gunzips [bytes], refusing to produce more than [maxBytes].
///
/// Templates are made to be distributed, so `mold unpack` runs on files from
/// elsewhere as its *normal* case, not its edge case. A plain decode expands
/// whatever it is handed: a megabyte crafted to inflate to tens of gigabytes
/// exhausts memory before any validation can look at it.
///
/// Decoding is chunked, so the limit aborts partway through the expansion
/// rather than measuring the result after it has already been materialized.
Uint8List decodeGzipBounded(
  List<int> bytes, {
  int maxBytes = defaultMaxDecompressedBytes,
}) {
  final sink = _BoundedSink(maxBytes);
  gzip.decoder.startChunkedConversion(sink)
    ..add(bytes)
    ..close();

  return sink.takeBytes();
}

/// Accumulates decoded chunks, throwing as soon as they exceed a limit.
class _BoundedSink extends ByteConversionSink {
  _BoundedSink(this.maxBytes);

  /// The ceiling this sink enforces.
  final int maxBytes;

  final _out = BytesBuilder(copy: false);

  @override
  void add(List<int> chunk) {
    if (_out.length + chunk.length > maxBytes) {
      throw ArchiveTooLargeException(maxBytes);
    }
    _out.add(chunk);
  }

  @override
  void addSlice(List<int> chunk, int start, int end, bool isLast) {
    add(start == 0 && end == chunk.length ? chunk : chunk.sublist(start, end));
    if (isLast) {
      close();
    }
  }

  @override
  void close() {}

  /// The decoded bytes, transferring ownership of the buffer.
  Uint8List takeBytes() => _out.takeBytes();
}
