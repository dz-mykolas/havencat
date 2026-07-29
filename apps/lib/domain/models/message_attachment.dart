import 'dart:convert';
import 'dart:typed_data';

import 'content_modality.dart';

/// Where the bytes for a message attachment live.
enum AttachmentSource { inlineBase64, url, providerFile }

/// Provider-neutral non-text content attached to a chat message.
///
/// Image uploads currently use [AttachmentSource.inlineBase64] so the app can
/// remain fully local and conversations can be replayed after a restart. URL
/// and provider-file sources are represented now for future large-file and
/// audio/video flows.
class MessageAttachment {
  const MessageAttachment({
    required this.id,
    required this.modality,
    required this.mimeType,
    required this.source,
    required this.data,
    this.name,
    this.generated = false,
  });

  factory MessageAttachment.inline({
    required String id,
    required ContentModality modality,
    required String mimeType,
    required Uint8List bytes,
    String? name,
    bool generated = false,
  }) {
    return MessageAttachment(
      id: id,
      modality: modality,
      mimeType: mimeType,
      source: AttachmentSource.inlineBase64,
      data: base64Encode(bytes),
      name: name,
      generated: generated,
    );
  }

  factory MessageAttachment.fromUrl({
    required String id,
    required ContentModality modality,
    required String url,
    String? mimeType,
    String? name,
    bool generated = false,
  }) {
    final RegExpMatch? dataMatch = RegExp(
      r'^data:([^;,]+);base64,(.+)$',
      dotAll: true,
    ).firstMatch(url);
    if (dataMatch != null) {
      return MessageAttachment(
        id: id,
        modality: modality,
        mimeType: dataMatch.group(1)!,
        source: AttachmentSource.inlineBase64,
        data: dataMatch.group(2)!,
        name: name,
        generated: generated,
      );
    }
    return MessageAttachment(
      id: id,
      modality: modality,
      mimeType: mimeType ?? 'application/octet-stream',
      source: AttachmentSource.url,
      data: url,
      name: name,
      generated: generated,
    );
  }

  final String id;
  final ContentModality modality;
  final String mimeType;
  final AttachmentSource source;

  /// Base64 bytes, a URL, or a provider file id according to [source].
  final String data;
  final String? name;
  final bool generated;

  Uint8List? get inlineBytes {
    if (source != AttachmentSource.inlineBase64) return null;
    try {
      return base64Decode(data);
    } on FormatException {
      return null;
    }
  }

  String? get dataUrl {
    return switch (source) {
      AttachmentSource.inlineBase64 => 'data:$mimeType;base64,$data',
      AttachmentSource.url => data,
      AttachmentSource.providerFile => null,
    };
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'modality': modality.name,
    'mimeType': mimeType,
    'source': source.name,
    'data': data,
    if (name != null) 'name': name,
    if (generated) 'generated': true,
  };

  factory MessageAttachment.fromJson(Map<String, Object?> json) {
    return MessageAttachment(
      id: json['id'] as String,
      modality: ContentModality.values.byName(json['modality'] as String),
      mimeType: json['mimeType'] as String,
      source: AttachmentSource.values.byName(json['source'] as String),
      data: json['data'] as String,
      name: json['name'] as String?,
      generated: json['generated'] as bool? ?? false,
    );
  }
}
